/*
 * safeunlinkd.c — 常驻守护进程
 *
 * 职责:
 *   1. 占用查询: 维护"谁占用了什么"的快照 (与库共用 snapshot.c),
 *      通过 unix socket 为所有进程提供 O(1) 的 CHECK 查询;
 *   2. GUI 弹窗: ask 场景经 daemon 弹 zenity 询问框; 无 DISPLAY 或
 *      zenity 不可用/超时时按 fail-open 放行 (写日志);
 *   3. 日志: 记录每次 CHECK / ASK 及结果。
 *
 * 协议 (单行, 长度 < 4KB):
 *   PING\n                   → PONG <pid>\n
 *   CHECK <pid> <dev> <ino>\n → FREE\n | HELD <pid> <comm> ...\n | ERR\n
 *   ASK <pid> <text>\n       → YES\n | NO\n
 *   QUIT\n                   → BYE\n (退出)
 * 仅接受同 uid 的连接 (SO_PEERCRED)。
 *
 * 用法:
 *   safeunlinkd run|start|stop|status [--socket PATH] [--log PATH]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "snapshot.h"

static char g_socket_path[PATH_MAX];
static char g_log_path[PATH_MAX];
static volatile sig_atomic_t g_running = 1;

static void on_signal(int sig) { (void)sig; g_running = 0; }

static void usage(void)
{
    fprintf(stderr,
        "用法: safeunlinkd run|start|stop|status [--socket PATH] [--log PATH]\n"
        "  run      前台运行\n"
        "  start    后台运行 (写 <socket>.pid)\n"
        "  stop     停止 daemon\n"
        "  status   查询状态\n");
}

/* ================= 日志 ================= */

static void log_msg(const char *fmt, ...)
{
    if (!strcmp(g_log_path, "none")) return;
    FILE *f = fopen(g_log_path, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(f, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void mkdir_p(const char *path)
{
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

/* ================= 路径解析 ================= */

static void resolve_socket(const char *cli)
{
    if (cli && *cli) { snprintf(g_socket_path, sizeof g_socket_path, "%s", cli); return; }
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (xdg && *xdg) snprintf(g_socket_path, sizeof g_socket_path, "%s/safeunlink.sock", xdg);
    else snprintf(g_socket_path, sizeof g_socket_path, "/tmp/safeunlink-%d.sock", (int)getuid());
}

static void resolve_log(const char *cli)
{
    if (cli && *cli) { snprintf(g_log_path, sizeof g_log_path, "%s", cli); return; }
    const char *state = getenv("XDG_STATE_HOME");
    if (state && *state)
        snprintf(g_log_path, sizeof g_log_path, "%s/safeunlink/safeunlinkd.log", state);
    else {
        const char *home = getenv("HOME");
        snprintf(g_log_path, sizeof g_log_path, "%s/.local/state/safeunlink/safeunlinkd.log",
                 (home && *home) ? home : "/tmp");
    }
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", g_log_path);
    char *slash = strrchr(dir, '/');
    if (slash) { *slash = '\0'; mkdir_p(dir); }
}

/* ================= 客户端操作 (stop/status/预检) ================= */

static int client_op(const char *cmd, char *reply, size_t rsz)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%.*s",
             (int)sizeof addr.sun_path - 1, g_socket_path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { close(fd); return -1; }
    if (write(fd, cmd, strlen(cmd)) < 0) { close(fd); return -1; }
    struct pollfd pfd = {fd, POLLIN, 0};
    int pr = poll(&pfd, 1, 1000);
    ssize_t n = (pr > 0 && (pfd.revents & POLLIN)) ? read(fd, reply, rsz - 1) : -1;
    close(fd);
    if (n < 0) return -1;
    reply[n] = '\0';
    return 0;
}

/* ================= GUI 弹窗 ================= */

/* 等待子进程退出, 最多 timeout_ms; 超时强杀并返回 -1 */
static int wait_child(pid_t pid, int timeout_ms)
{
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        int st = 0;
        pid_t r = waitpid(pid, &st, WNOHANG);
        if (r == pid) {
            if (WIFEXITED(st)) return WEXITSTATUS(st);
            return -1;
        }
        if (r < 0) return -1;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (long)(now.tv_sec - t0.tv_sec) * 1000
                     + (now.tv_nsec - t0.tv_nsec) / 1000000;
        if (elapsed >= timeout_ms) {
            kill(pid, SIGKILL);
            waitpid(pid, NULL, 0);
            return -1;
        }
        usleep(50000);
    }
}

/* 返回 1 = 确认继续, 0 = 取消; 任何失败都按 fail-open 返回 1 */
static int run_dialog(const char *text)
{
    if (!getenv("DISPLAY") && !getenv("WAYLAND_DISPLAY")) {
        log_msg("ASK: 无 DISPLAY/WAYLAND, 无法弹窗, 按 fail-open 继续");
        return 1;
    }
    pid_t pid = fork();
    if (pid == 0) {
        execlp("zenity", "zenity", "--question",
               "--title=safeunlink — 文件被占用",
               "--text", text,
               "--ok-label=仍然删除", "--cancel-label=取消",
               "--width=520", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int code = wait_child(pid, 15000);
        if (code == 0) { log_msg("ASK: zenity 确认继续"); return 1; }
        if (code == 1) { log_msg("ASK: zenity 取消"); return 0; }
        log_msg("ASK: zenity 不可用/超时 (exit=%d), 按 fail-open 继续", code);
        return 1;
    }
    log_msg("ASK: fork 失败, 按 fail-open 继续");
    return 1;
}

/* ================= 请求处理 ================= */

static void handle_client(int cfd)
{
    char line[8192];
    ssize_t n = read(cfd, line, sizeof line - 1);
    if (n <= 0) return;
    line[n] = '\0';
    char *nl = strchr(line, '\n');
    if (nl) *nl = '\0';

    if (!strncmp(line, "PING", 4)) {
        dprintf(cfd, "PONG %d\n", (int)getpid());
    } else if (!strncmp(line, "QUIT", 4)) {
        dprintf(cfd, "BYE\n");
        g_running = 0;
    } else if (!strncmp(line, "CHECK ", 6)) {
        pid_t pid = 0;
        unsigned long long dev = 0, ino = 0;
        if (sscanf(line + 6, "%d %llu %llu", &pid, &dev, &ino) == 3) {
            Holder hs[8];
            int hn = 0;
            int held = snapshot_check((dev_t)dev, (ino_t)ino, pid,
                                      2, hs, 8, &hn);
            if (held < 0) {
                dprintf(cfd, "ERR scan\n");
                log_msg("CHECK: 扫描失败 dev=%llu ino=%llu", dev, ino);
            } else if (!held) {
                dprintf(cfd, "FREE\n");
                log_msg("CHECK: free  dev=%llu ino=%llu (pid %d)", dev, ino, (int)pid);
            } else {
                char buf[2048];
                int off = snprintf(buf, sizeof buf, "HELD");
                for (int i = 0; i < hn && i < 8; i++)
                    off += snprintf(buf + off, sizeof buf - (size_t)off,
                                    " %d %s", (int)hs[i].pid, hs[i].comm);
                dprintf(cfd, "%s\n", buf);
                log_msg("CHECK: held  dev=%llu ino=%llu by %d process(es) (pid %d)",
                        dev, ino, hn, (int)pid);
            }
        } else {
            dprintf(cfd, "ERR bad\n");
        }
    } else if (!strncmp(line, "ASK ", 4)) {
        pid_t pid = 0;
        char *sp = strchr(line + 4, ' ');
        if (sp) {
            *sp = '\0';
            pid = (pid_t)atoi(line + 4);
        }
        const char *text = sp ? sp + 1 : "";
        log_msg("ASK: pid %d 文件: %.200s", (int)pid, text);
        int yes = run_dialog(text);
        dprintf(cfd, yes ? "YES\n" : "NO\n");
    } else {
        dprintf(cfd, "ERR cmd\n");
    }
}

/* ================= 服务器 ================= */

static int run_server(void)
{
    char buf[64];
    if (client_op("PING\n", buf, sizeof buf) == 0) {
        fprintf(stderr, "safeunlinkd: 已有实例在运行 (%s)\n", g_socket_path);
        return 1;
    }
    /* 确保 socket 所在目录存在 (如 XDG_RUNTIME_DIR 指向新建目录) */
    char sockdir[PATH_MAX];
    snprintf(sockdir, sizeof sockdir, "%s", g_socket_path);
    char *slash = strrchr(sockdir, '/');
    if (slash) { *slash = '\0'; mkdir_p(sockdir); }
    unlink(g_socket_path);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return 1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%.*s",
             (int)sizeof addr.sun_path - 1, g_socket_path);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        perror("bind");
        close(lfd);
        return 1;
    }
    chmod(g_socket_path, 0600);
    if (listen(lfd, 8) != 0) {
        perror("listen");
        close(lfd);
        unlink(g_socket_path);
        return 1;
    }

    log_msg("daemon 启动 (pid %d, socket %s)", (int)getpid(), g_socket_path);

    while (g_running) {
        struct pollfd pfd = {lfd, POLLIN, 0};
        int pr = poll(&pfd, 1, 1000);
        if (pr < 0) { if (errno == EINTR) continue; break; }
        if (!pr) continue;
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; continue; }
        struct ucred cred;
        socklen_t clen = sizeof cred;
        if (getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &cred, &clen) == 0 &&
            cred.uid == getuid()) {
            handle_client(cfd);
        }
        close(cfd);
    }

    close(lfd);
    unlink(g_socket_path);
    log_msg("daemon 停止");
    return 0;
}

/* ================= 入口 ================= */

int main(int argc, char **argv)
{
    const char *socket_cli = NULL, *log_cli = NULL;
    int mode = 'r';                 /* r=run s=start t=stop q=status */

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "run") || !strcmp(argv[i], "foreground")) mode = 'r';
        else if (!strcmp(argv[i], "start")) mode = 's';
        else if (!strcmp(argv[i], "stop")) mode = 't';
        else if (!strcmp(argv[i], "status")) mode = 'q';
        else if (!strcmp(argv[i], "--socket") && i + 1 < argc) socket_cli = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) log_cli = argv[++i];
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(); return 0; }
        else { usage(); return 2; }
    }

    resolve_socket(socket_cli);
    resolve_log(log_cli);

    if (mode == 't') {
        char buf[64];
        if (client_op("QUIT\n", buf, sizeof buf) != 0) {
            fprintf(stderr, "safeunlinkd: 未在运行 (%s)\n", g_socket_path);
            return 1;
        }
        printf("safeunlinkd: 已发送停止命令\n");
        return 0;
    }
    if (mode == 'q') {
        char buf[64];
        if (client_op("PING\n", buf, sizeof buf) != 0) {
            printf("safeunlinkd: 未在运行 (%s)\n", g_socket_path);
            return 1;
        }
        printf("safeunlinkd: 运行中 — %s", buf);
        return 0;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    if (mode == 's') {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); return 1; }
        if (pid > 0) {
            for (int i = 0; i < 40; i++) {
                char buf[64];
                if (client_op("PING\n", buf, sizeof buf) == 0) {
                    printf("safeunlinkd: 已启动 (pid %d)\n", (int)pid);
                    return 0;
                }
                usleep(100000);
            }
            fprintf(stderr, "safeunlinkd: 启动超时\n");
            return 1;
        }
        setsid();
        int lfd = open(g_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (lfd >= 0) {
            dup2(lfd, 1);
            dup2(lfd, 2);
            if (lfd > 2) close(lfd);
        }
        char pidfile[PATH_MAX + 16];
        snprintf(pidfile, sizeof pidfile, "%s.pid", g_socket_path);
        FILE *pf = fopen(pidfile, "w");
        if (pf) {
            fprintf(pf, "%d\n", (int)getpid());
            fclose(pf);
        }
    }

    int rc = run_server();

    if (mode == 's') {
        char pidfile[PATH_MAX + 16];
        snprintf(pidfile, sizeof pidfile, "%s.pid", g_socket_path);
        unlink(pidfile);
    }
    return rc;
}
