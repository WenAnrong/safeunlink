/* trashretry — 模拟文件管理器同一进程连续操作:
 * 1) rename 到回收站 (应提示并阻止)
 * 2) unlink 永久删除 (应静默阻止)
 * 3) 等 1 秒后再次 rename 到回收站 (应再次提示并阻止)
 * 用法: trashretry <源文件> <回收站目标路径>
 */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    if (rename(argv[1], argv[2]) != 0) perror("r1");
    if (unlink(argv[1]) != 0) perror("u");
    sleep(1);
    if (rename(argv[1], argv[2]) != 0) perror("r2");
    return 0;
}
