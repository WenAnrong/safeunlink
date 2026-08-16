#ifndef SAFEUNLINK_SNAPSHOT_H
#define SAFEUNLINK_SNAPSHOT_H

#include <sys/types.h>

typedef struct {
    pid_t pid;
    char  comm[16];
} Holder;

/* 检查 (dev, ino) 是否被"除 exclude_pid 之外"的进程占用。
 *
 * 内部按 TTL 维护一份"当前所有进程持有的 inode"快照 (哈希集合):
 * 一次全量扫描 /proc, 之后每次查询 O(1)。
 *
 * 参数:
 *   dev/ino      目标文件身份 (lstat 得到)
 *   exclude_pid  排除的进程 (执行删除的进程)
 *   ttl_sec      快照有效期; 0 = 每次查询都全盘重建
 *   out/max      输出占用者列表 (最多 max 个)
 *   n            输出实际占用者数量
 *
 * 返回: 1 = 被占用, 0 = 未占用, -1 = 扫描失败 (调用方应 fail-open)。
 */
int snapshot_check(dev_t dev, ino_t ino, pid_t exclude_pid, long ttl_sec,
                   Holder *out, int max, int *n);

#endif
