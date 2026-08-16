/* dclient — 测试/调试客户端: 向 safeunlinkd 发一行命令并打印回复。
 * 用法: dclient <sock> <命令...>      (参数用空格连接后发送)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <sock> <命令...>\n", argv[0]);
        return 2;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", argv[1]);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        perror("connect");
        return 1;
    }

    size_t len = 1;
    for (int i = 2; i < argc; i++) len += strlen(argv[i]) + 1;
    char *cmd = malloc(len + 1);
    if (!cmd) return 1;
    cmd[0] = '\0';
    for (int i = 2; i < argc; i++) {
        strcat(cmd, argv[i]);
        strcat(cmd, " ");
    }
    strcat(cmd, "\n");

    if (write(fd, cmd, strlen(cmd)) < 0) { perror("write"); return 1; }
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    if (n < 0) { perror("read"); return 1; }
    buf[n] = '\0';
    printf("%s", buf);
    close(fd);
    free(cmd);
    return 0;
}
