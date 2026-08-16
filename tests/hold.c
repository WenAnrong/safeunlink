/* hold — 测试辅助: 打开一个文件并保持占用一段时间
 * 用法: hold <file> <seconds>
 * 打开成功后打印 "HOLDING <pid>" 并 sleep。
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    printf("HOLDING %d\n", (int)getpid());
    fflush(stdout);
    sleep((unsigned)atoi(argv[2]));
    close(fd);
    return 0;
}
