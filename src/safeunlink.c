/*
 * safeunlink.c — "删除前占用检查" LD_PRELOAD 拦截库 (阶段 2: daemon + GUI)
 *
 * 拦截 unlink / unlinkat / remove / rmdir, 在真正删除前检查是否有
 * 其他进程仍持有该文件的 fd / mmap / cwd / exe, 并按模式处理:
 *   warn  — 提示后继续删除 (终端: 红色文字; 无终端: 通知 daemon 弹系统通知)
 *   ask   — 交互确认 (终端: y/N; 无终端: daemon 弹 zenity 图形框)
 *   block — 提示并直接拒绝 (返回 EBUSY)
 *
 * 占用检查优先走常驻 daemon (共享快照 + GUI 能力); daemon 不可用时
 * 回退为本进程内的快照扫描 (阶段 1 逻辑)。
 *
 * 设计铁律: fail-open。任何异常一律放行, 调用真实 syscall。
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "config.h"
#include "snapshot.h"

/* ================= 守护进程客户端 ================= */

static const char *daemon_socket_path(void)
{
    static char path[PATH_MAX];
    static int done = 0;
    if (done) return path;
    const char *e = getenv("SAFEUNLINK_SOCKET");
    if (e && *e) snprintf(path, sizeof path, "%s", e);
    else {
        const char *xdg = getenv("XDG_RUNTIME_DIR");
        if (xdg && *xdg) snprintf(path, sizeof path, "%s/safeunlink.sock", xdg);
        else snprintf(path, sizeof path, "/tmp/safeunlink-%d.sock", (int)getuid());
    }
    done = 1;
    return path;
}

static int daemon_connect(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%.*s",
             (int)sizeof addr.sun_path - 1, daemon_socket_path());

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof addr);
    if (rc != 0 && errno != EINPROGRESS) { close(fd); return -1; }
    struct pollfd pfd = {fd, POLLOUT, 0};
    int pr = poll(&pfd, 1, 300);
    if (pr <= 0 || !(pfd.revents & POLLOUT)) { close(fd); return -1; }
    int err = 0;
    socklen_t el = sizeof err;
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
    if (err) { close(fd); return -1; }
    fcntl(fd, F_SETFL, flags);
    return fd;
}

/* 发送一行命令并读取一行回复。返回 0 成功 (回复去掉换行存 out), -1 失败。
 * timeout_ms: 读取等待上限 (ASK 弹窗需要长超时, 其余短超时)。 */
static int daemon_roundtrip(const char *line, char *out, size_t outsz,
                            int timeout_ms)
{
    int fd = daemon_connect();
    if (fd < 0) return -1;
    if (write(fd, line, strlen(line)) < 0) { close(fd); return -1; }
    struct pollfd pfd = {fd, POLLIN, 0};
    int pr = poll(&pfd, 1, timeout_ms);
    if (pr <= 0 || !(pfd.revents & POLLIN)) { close(fd); return -1; }
    ssize_t n = read(fd, out, outsz - 1);
    close(fd);
    if (n <= 0) return -1;
    out[n] = '\0';
    char *nl = strchr(out, '\n');
    if (nl) *nl = '\0';
    return 0;
}

/* 向 daemon 查询占用。返回 1=占用 (out 填充), 0=未占用, -1=daemon 不可用 */
static int daemon_check(dev_t dev, ino_t ino, pid_t self,
                        Holder *out, int max, int *n)
{
    if (getenv("SAFEUNLINK_NO_DAEMON")) return -1;
    char line[128];
    snprintf(line, sizeof line, "CHECK %d %llu %llu\n",
             (int)self, (unsigned long long)dev, (unsigned long long)ino);
    char reply[2048];
    if (daemon_roundtrip(line, reply, sizeof reply, 2000) != 0) return -1;
    if (!strncmp(reply, "FREE", 4)) return 0;
    if (!strncmp(reply, "HELD", 4)) {
        *n = 0;
        char *p = reply + 4;
        while (*p && *n < max) {
            while (*p == ' ') p++;
            char *end = NULL;
            long pid = strtol(p, &end, 10);
            if (end == p) break;
            p = end;
            while (*p == ' ') p++;
            char *comm = p;
            while (*p && *p != ' ') p++;
            int has_more = (*p == ' ');
            if (*p) *p = '\0';
            out[*n].pid = (pid_t)pid;
            snprintf(out[*n].comm, sizeof out[*n].comm, "%s", comm);
            (*n)++;
            if (!has_more) break;
        }
        return 1;
    }
    return -1;                    /* ERR 等 → 回退本进程扫描 */
}

/* 请求 daemon 弹 GUI 询问框。返回 1=确认, 0=取消, -1=不可用 */
static int daemon_ask(const char *text)
{
    if (getenv("SAFEUNLINK_NO_DAEMON")) return -1;
    char line[4096];
    snprintf(line, sizeof line, "ASK %d %s\n", (int)getpid(), text);
    char reply[64];
    if (daemon_roundtrip(line, reply, sizeof reply, 120000) != 0) return -1;
    if (!strncmp(reply, "YES", 3)) return 1;
    if (!strncmp(reply, "NO", 2)) return 0;
    return -1;
}

/* 请求 daemon 发系统通知 (warn/block 模式、无终端的 GUI 场景), 尽力而为 */
static void daemon_notify(const char *text)
{
    if (getenv("SAFEUNLINK_NO_DAEMON")) return;
    char line[4096];
    snprintf(line, sizeof line, "NOTIFY %s\n", text);
    char reply[16];
    daemon_roundtrip(line, reply, sizeof reply, 2000);
}

/* 替换 \n / \t 为空格, 保证单行协议 */
static void sanitize_text(char *s)
{
    for (; *s; s++)
        if (*s == '\n' || *s == '\t') *s = ' ';
}

static void build_holder_text(char *buf, size_t sz, const char *path,
                              const Holder *holders, int n, const char *op)
{
    int off = snprintf(buf, sz, "文件正被其他程序使用 (%s):\n\n%s\n\n占用:",
                       op, path);
    for (int i = 0; i < n && i < 8 && off < (int)sz - 32; i++)
        off += snprintf(buf + off, sz - (size_t)off, " %s(pid %d)",
                        holders[i].comm, (int)holders[i].pid);
}

/* ================= 提示与决策 ================= */

static int stderr_color(void)
{
    const char *cenv = getenv("SAFEUNLINK_COLOR");
    if (cenv && *cenv && *cenv != '0') return 1;    /* 强制颜色 */
    return isatty(fileno(stderr));
}

static void print_warning(const char *path, const Holder *holders, int n,
                          const char *op)
{
    int color = stderr_color();
    const char *R = color ? "\033[31m" : "";
    const char *Y = color ? "\033[33m" : "";
    const char *B = color ? "\033[1m"  : "";
    const char *N = color ? "\033[0m"  : "";

    fprintf(stderr, "%s%s[safeunlink] 文件正被其他程序使用 (%s):%s\n", R, B, op, N);
    fprintf(stderr, "%s  目标: %s%s\n", R, path, N);
    for (int i = 0; i < n && i < 8; i++)
        fprintf(stderr, "%s  占用: %s (pid %d)%s\n",
                R, holders[i].comm, (int)holders[i].pid, N);
    if (g_cfg.mode == 2)
        fprintf(stderr, "%s  → block 模式, 已拒绝删除 (EBUSY)%s\n", R, N);
    else if (g_cfg.mode == 1)
        fprintf(stderr, "%s  → ask 模式, 等待你的选择…%s\n", Y, N);
    else
        fprintf(stderr, "%s  → warn 模式, 仍将继续删除%s\n", Y, N);
}

/* warn / block 模式下, 无终端 (GUI 程序) 时通知 daemon 弹系统通知 */
static void maybe_notify_gui(const char *path, const Holder *holders, int n,
                             const char *op)
{
    if (isatty(fileno(stderr))) return;
    char text[2048];
    build_holder_text(text, sizeof text, path, holders, n, op);
    sanitize_text(text);
    daemon_notify(text);
}

/* 返回 1 = 继续, 0 = 取消 (errno=EBUSY) */
static int ask_user(const char *path, const Holder *holders, int n,
                    const char *op)
{
    /* 1) 交互终端 */
    int tty = open("/dev/tty", O_RDWR);
    if (tty >= 0) {
        dprintf(tty, "\033[33m[safeunlink] 文件正被其他程序使用, 仍要%s \"%s\" 吗? [y/N] \033[0m",
                op, path);
        char buf[16];
        ssize_t rd;
        do { rd = read(tty, buf, sizeof buf - 1); } while (rd < 0 && errno == EINTR);
        close(tty);
        if (rd > 0) {
            buf[rd] = '\0';
            char *p = buf;
            while (*p && *p != '\n' && *p != '\r') p++;
            *p = '\0';
            if (buf[0] == 'y' || buf[0] == 'Y') return 1;
        }
        fprintf(stderr, "\033[31m[safeunlink] 已取消删除: %s\033[0m\n", path);
        errno = EBUSY;
        return 0;
    }

    int color = stderr_color();
    const char *Y = color ? "\033[33m" : "";
    const char *R = color ? "\033[31m" : "";
    const char *N = color ? "\033[0m"  : "";

    /* 2) 预置回答 */
    const char *ans = getenv("SAFEUNLINK_ANSWER");
    if (ans && *ans) {
        int yes = (ans[0] == 'y' || ans[0] == 'Y');
        fprintf(stderr, "%s[safeunlink] 使用 SAFEUNLINK_ANSWER 预置回答 → %s%s\n",
                Y, yes ? "确认删除" : "取消删除", N);
        if (!yes) { errno = EBUSY; return 0; }
        return 1;
    }

    /* 3) daemon GUI 弹窗 */
    char text[2048];
    build_holder_text(text, sizeof text, path, holders, n, op);
    off_t o = strlen(text);
    snprintf(text + o, sizeof text - (size_t)o, "\n\n仍要%s吗?", op);
    sanitize_text(text);
    int r = daemon_ask(text);
    if (r >= 0) {
        if (!r) {
            fprintf(stderr, "%s[safeunlink] 已取消删除: %s%s\n", R, path, N);
            errno = EBUSY;
        }
        return r;
    }

    /* 4) fail-open */
    fprintf(stderr, "%s[safeunlink] 无交互终端且无法弹窗, 按 warn 模式继续删除: %s%s\n",
            Y, path, N);
    return 1;
}

static int path_exempt(const char *path)
{
    static const char *builtin[] = {"/proc", "/sys", "/run"};
    for (size_t i = 0; i < sizeof builtin / sizeof builtin[0]; i++)
        if (strncmp(path, builtin[i], strlen(builtin[i])) == 0) return 1;

    char buf[sizeof g_cfg.exempt_paths];
    snprintf(buf, sizeof buf, "%s", g_cfg.exempt_paths);
    char *save = NULL;
    for (char *tok = strtok_r(buf, ",", &save); tok;
         tok = strtok_r(NULL, ",", &save)) {
        while (*tok && isspace((unsigned char)*tok)) tok++;
        if (*tok && strncmp(path, tok, strlen(tok)) == 0) return 1;
    }
    return 0;
}

static int self_proc_exempt(void)
{
    if (!g_cfg.exempt_procs[0]) return 0;
    char comm[64] = {0};
    FILE *f = fopen("/proc/self/comm", "r");
    if (!f) return 0;
    size_t n = fread(comm, 1, sizeof comm - 1, f);
    fclose(f);
    comm[n] = '\0';
    char *nl = strchr(comm, '\n');
    if (nl) *nl = '\0';

    char buf[sizeof g_cfg.exempt_procs];
    snprintf(buf, sizeof buf, "%s", g_cfg.exempt_procs);
    char *save = NULL;
    for (char *tok = strtok_r(buf, ",", &save); tok;
         tok = strtok_r(NULL, ",", &save)) {
        while (*tok && isspace((unsigned char)*tok)) tok++;
        if (*tok && strcmp(tok, comm) == 0) return 1;
    }
    return 0;
}

/*
 * 删除前的守卫。
 * 返回 0 = 放行, -1 = 拒绝 (errno 已设置, 通常 EBUSY)。
 * op: 操作描述 ("删除" / "移入回收站"), 仅用于提示文案。
 *
 * 去重: mv 会先试 renameat2 失败后再回退 renameat, 同一 inode 会在
 * 极短时间内被守卫两次; 记录最近一次判定结果, 300ms 内重复调用
 * 静默复用 (拒绝则继续拒绝, 放行则继续放行), 避免重复提示/询问。
 */
static struct {
    dev_t dev;
    ino_t ino;
    pid_t pid;
    long long ts_ms;
    int refused;
} g_last_guard;

static long long now_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int maybe_guard(const char *path, const char *op)
{
    if (getenv("SAFEUNLINK_DISABLE")) return 0;     /* 紧急开关 */
    safe_config_load_once();
    if (!path || !*path) return 0;
    if (path_exempt(path)) return 0;
    if (self_proc_exempt()) return 0;

    struct stat st;
    if (lstat(path, &st) != 0) return 0;            /* 不存在/不可访问 → 放行 */
    if (S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) return 0;  /* 设备节点 */

    long long ts = now_ms();
    if (g_last_guard.pid == getpid() &&
        g_last_guard.dev == st.st_dev &&
        g_last_guard.ino == st.st_ino &&
        ts - g_last_guard.ts_ms < 300) {
        if (g_last_guard.refused) { errno = EBUSY; return -1; }
        return 0;
    }

    Holder holders[8];
    int n = 0, held = 0;

    /* 优先 daemon (共享快照); 不可用则回退本进程扫描 */
    held = daemon_check(st.st_dev, st.st_ino, getpid(), holders, 8, &n);
    if (held < 0)
        held = snapshot_check(st.st_dev, st.st_ino, getpid(),
                              g_cfg.ttl_sec, holders, 8, &n);
    if (held <= 0) return 0;

    int rc;
    print_warning(path, holders, n, op);
    if (g_cfg.mode == 0) {                          /* warn */
        maybe_notify_gui(path, holders, n, op);
        rc = 0;
    } else if (g_cfg.mode == 2) {                   /* block */
        maybe_notify_gui(path, holders, n, op);
        errno = EBUSY;
        rc = -1;
    } else {                                        /* ask */
        rc = ask_user(path, holders, n, op) ? 0 : -1;
    }

    g_last_guard.dev = st.st_dev;
    g_last_guard.ino = st.st_ino;
    g_last_guard.pid = getpid();
    g_last_guard.ts_ms = ts;
    g_last_guard.refused = (rc != 0);
    return rc;
}

/* ================= 真实函数解析 ================= */

static int real_fn(const char *name, void **out)
{
    if (!*out) *out = dlsym(RTLD_NEXT, name);
    return *out != NULL;
}

/* unlinkat 的 dirfd + 相对路径 → 完整路径; 失败返回 -1 (fail-open) */
static int build_path(int dirfd, const char *path, char *out, size_t outsz)
{
    if (!path) return -1;
    if (path[0] == '/') { snprintf(out, outsz, "%s", path); return 0; }
    if (dirfd == AT_FDCWD) { snprintf(out, outsz, "%s", path); return 0; }
    char link[64];
    snprintf(link, sizeof link, "/proc/self/fd/%d", dirfd);
    char dir[PATH_MAX];
    ssize_t n = readlink(link, dir, sizeof dir - 1);
    if (n <= 0) return -1;
    dir[n] = '\0';
    if (snprintf(out, outsz, "%s/%s", dir, path) >= (int)outsz) return -1;
    return 0;
}

/* ================= 被拦截的系统调用 ================= */

int unlink(const char *path)
{
    static int (*real)(const char *);
    if (!real_fn("unlink", (void **)&real))
        return syscall(SYS_unlink, path);
    int saved = errno;
    if (maybe_guard(path, "删除") != 0) return -1;
    errno = saved;
    return real(path);
}

int unlinkat(int dirfd, const char *path, int flags)
{
    static int (*real)(int, const char *, int);
    if (!real_fn("unlinkat", (void **)&real))
        return syscall(SYS_unlinkat, dirfd, path, flags);

    char full[PATH_MAX];
    if (build_path(dirfd, path, full, sizeof full) != 0)
        return real(dirfd, path, flags);            /* 解析失败 → 放行 */

    int saved = errno;
    if (maybe_guard(full, "删除") != 0) return -1;
    errno = saved;
    return real(dirfd, path, flags);
}

int rmdir(const char *path)
{
    static int (*real)(const char *);
    if (!real_fn("rmdir", (void **)&real))
        return syscall(SYS_rmdir, path);
    int saved = errno;
    if (maybe_guard(path, "删除") != 0) return -1;
    errno = saved;
    return real(path);
}

int remove(const char *path)
{
    static int (*real)(const char *);
    if (!real_fn("remove", (void **)&real)) {
        struct stat st;
        if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode))
            return syscall(SYS_rmdir, path);
        return syscall(SYS_unlink, path);
    }
    int saved = errno;
    if (maybe_guard(path, "删除") != 0) return -1;
    errno = saved;
    return real(path);
}

/* ================= 回收站 (移入 Trash) 拦截 ================= */

/* 返回本用户的回收站文件目录: Trash/files (按 XDG 规范) */
static const char *trash_files_dir(void)
{
    static char dir[PATH_MAX];
    static int inited = 0;
    if (!inited) {
        const char *e = getenv("SAFEUNLINK_TRASH_DIR");
        if (e && *e) snprintf(dir, sizeof dir, "%s", e);
        else {
            const char *xdg = getenv("XDG_DATA_HOME");
            if (xdg && *xdg) snprintf(dir, sizeof dir, "%s/Trash/files", xdg);
            else {
                const char *home = getenv("HOME");
                snprintf(dir, sizeof dir, "%s/.local/share/Trash/files",
                         (home && *home) ? home : "/tmp");
            }
        }
        inited = 1;
    }
    return dir;
}

/* 目标路径是否位于回收站文件目录 (前缀匹配, 路径边界) */
static int is_trash_move(const char *dest)
{
    if (!dest || !*dest) return 0;
    const char *dir = trash_files_dir();
    size_t len = strlen(dir);
    if (!len || strncmp(dest, dir, len) != 0) return 0;
    return dest[len] == '\0' || dest[len] == '/';
}

/* rename 系列的守卫: 仅当目标是"移入回收站"时检查源文件占用 */
static int maybe_guard_rename(const char *old, const char *newp)
{
    if (!old || !newp) return 0;
    safe_config_load_once();
    if (!g_cfg.trash) return 0;                     /* 关闭回收站拦截 */
    if (!is_trash_move(newp)) return 0;             /* 普通移动不拦截 */
    int saved = errno;
    int rc = maybe_guard(old, "移入回收站");
    if (rc == 0) errno = saved;
    return rc;
}

int rename(const char *old, const char *newp)
{
    static int (*real)(const char *, const char *);
    if (!real_fn("rename", (void **)&real))
        return syscall(SYS_rename, old, newp);
    if (maybe_guard_rename(old, newp) != 0) return -1;
    return real(old, newp);
}

int renameat(int olddirfd, const char *old, int newdirfd, const char *newp)
{
    static int (*real)(int, const char *, int, const char *);
    if (!real_fn("renameat", (void **)&real))
        return syscall(SYS_renameat, olddirfd, old, newdirfd, newp);

    char oldp[PATH_MAX], newfull[PATH_MAX];
    if (build_path(olddirfd, old, oldp, sizeof oldp) != 0 ||
        build_path(newdirfd, newp, newfull, sizeof newfull) != 0)
        return real(olddirfd, old, newdirfd, newp); /* 解析失败 → 放行 */

    if (maybe_guard_rename(oldp, newfull) != 0) return -1;
    return real(olddirfd, old, newdirfd, newp);
}

int renameat2(int olddirfd, const char *old, int newdirfd, const char *newp,
              unsigned int flags)
{
    static int (*real)(int, const char *, int, const char *, unsigned int);
    if (!real_fn("renameat2", (void **)&real))
        return syscall(SYS_renameat2, olddirfd, old, newdirfd, newp, flags);

    char oldp[PATH_MAX], newfull[PATH_MAX];
    if (build_path(olddirfd, old, oldp, sizeof oldp) != 0 ||
        build_path(newdirfd, newp, newfull, sizeof newfull) != 0)
        return real(olddirfd, old, newdirfd, newp, flags);

    if (maybe_guard_rename(oldp, newfull) != 0) return -1;
    return real(olddirfd, old, newdirfd, newp, flags);
}

__attribute__((constructor))
static void safeunlink_ctor(void)
{
    safe_config_load(NULL);
}
