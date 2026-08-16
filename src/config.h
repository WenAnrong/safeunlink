#ifndef SAFEUNLINK_CONFIG_H
#define SAFEUNLINK_CONFIG_H

#include <limits.h>

/* 库与 daemon 共享的配置结构。
 * 库使用: mode / exempt_procs / exempt_paths / ttl_sec
 * daemon 使用: ttl_sec / dialog / log_path / socket_path
 */
typedef struct {
    int  mode;                   /* 0=warn 1=ask 2=block */
    char exempt_procs[1024];     /* 豁免"执行删除的进程"名, 逗号分隔 */
    char exempt_paths[4096];     /* 豁免路径前缀, 逗号分隔 */
    long ttl_sec;                /* 占用快照有效期秒数, 0 = 每次全盘扫描 */
    char dialog[16];             /* zenity | notify | none */
    char log_path[PATH_MAX];     /* auto | none | <路径> */
    char socket_path[PATH_MAX];  /* auto | <路径> */
} SafeConfig;

extern SafeConfig g_cfg;

void safe_config_load(const char *custom);   /* custom 为 NULL 时按默认查找顺序 */
void safe_config_load_once(void);

#endif
