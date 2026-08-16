/* trashflow — 模拟文件管理器行为: 先把文件移入回收站(rename),
 * 若被拒绝 (EBUSY), 紧接着执行永久删除 (unlink)。
 * 用法: trashflow <源文件> <回收站目标路径>
 */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    if (rename(argv[1], argv[2]) != 0) perror("rename");
    if (unlink(argv[1]) != 0) perror("unlink");
    return 0;
}
