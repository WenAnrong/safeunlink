/* 占用快照扫描 — 库与 daemon 共用。
 * 一次全量扫描 /proc/<pid>/fd、maps、exe、cwd, 构建"所有进程持有的
 * inode"哈希集合; 查询时按 (dev, ino) O(1) 查找, 并过滤调用方指定的
 * exclude_pid (执行删除的进程)。
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "snapshot.h"

#define HSIZE (1u << 17)               /* 131072 桶 */

typedef struct {
    pid_t pid;
    char  comm[16];
} SlotHolder;

typedef struct {
    dev_t dev;
    ino_t ino;
    int   n;
    SlotHolder h[8];
} Slot;

static Slot g_ht[HSIZE];
static struct timespec g_built = {0, 0};
static unsigned long g_checks_since = 0;
static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;

static unsigned long long hash_key(dev_t dev, ino_t ino)
{
    return ((unsigned long long)ino * 2654435761ULL)
         ^ ((unsigned long long)dev * 31ULL);
}

static void ht_put(dev_t dev, ino_t ino, pid_t pid, const char *comm)
{
    unsigned i = (unsigned)(hash_key(dev, ino) & (HSIZE - 1));
    for (unsigned probes = 0; probes < 8; probes++, i = (i + 1) & (HSIZE - 1)) {
        Slot *s = &g_ht[i];
        if (s->n == 0 && s->dev == 0 && s->ino == 0) {
            s->dev = dev; s->ino = ino; s->n = 0;
        }
        if (s->dev == dev && s->ino == ino) {
            for (int k = 0; k < s->n; k++)
                if (s->h[k].pid == pid) return;
            if (s->n < 8) {
                s->h[s->n].pid = pid;
                snprintf(s->h[s->n].comm, sizeof s->h[s->n].comm, "%s",
                         comm ? comm : "?");
                s->n++;
            }
            return;
        }
    }
    /* 表满丢弃: fail-open, 最多是漏报一次提示 */
}

static Slot *ht_get(dev_t dev, ino_t ino)
{
    unsigned i = (unsigned)(hash_key(dev, ino) & (HSIZE - 1));
    for (unsigned probes = 0; probes < 8; probes++, i = (i + 1) & (HSIZE - 1)) {
        Slot *s = &g_ht[i];
        if (s->dev == dev && s->ino == ino) return s;
        if (s->n == 0 && s->dev == 0 && s->ino == 0) return NULL;
    }
    return NULL;
}

static void read_comm(pid_t pid, char *out, size_t sz)
{
    char p[80];
    snprintf(p, sizeof p, "/proc/%ld/comm", (long)pid);
    FILE *f = fopen(p, "r");
    if (!f) { snprintf(out, sz, "?"); return; }
    size_t n = fread(out, 1, sz - 1, f);
    fclose(f);
    out[n] = '\0';
    char *nl = strchr(out, '\n');
    if (nl) *nl = '\0';
}

/* 构建快照; 排除本进程自身 (库=删除进程, daemon=daemon 自己)。 */
static int build_held_set(void)
{
    pid_t self = getpid();
    DIR *pd = opendir("/proc");
    if (!pd) return -1;
    memset(g_ht, 0, sizeof g_ht);

    struct dirent *de;
    while ((de = readdir(pd)) != NULL) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        pid_t pid = atoi(de->d_name);
        if (pid == self || pid <= 1) continue;

        char base[64];
        snprintf(base, sizeof base, "/proc/%.24s", de->d_name);
        char comm[16];
        read_comm(pid, comm, sizeof comm);

        char fdp[96];
        snprintf(fdp, sizeof fdp, "%s/fd", base);
        DIR *fd = opendir(fdp);
        if (fd) {
            struct dirent *fe;
            while ((fe = readdir(fd)) != NULL) {
                if (fe->d_name[0] == '.') continue;
                char fp[PATH_MAX];
                snprintf(fp, sizeof fp, "%s/%s", fdp, fe->d_name);
                struct stat st;
                if (stat(fp, &st) == 0)
                    ht_put(st.st_dev, st.st_ino, pid, comm);
            }
            closedir(fd);
        }

        char mp[96];
        snprintf(mp, sizeof mp, "%s/maps", base);
        FILE *m = fopen(mp, "r");
        if (m) {
            char line[1024];
            while (fgets(line, sizeof line, m)) {
                unsigned long long a1, a2, off, ino_m;
                char perms[16], devs[32];
                if (sscanf(line, "%llx-%llx %15s %llx %31s %llu",
                           &a1, &a2, perms, &off, devs, &ino_m) >= 6 && ino_m) {
                    unsigned maj = 0, min = 0;
                    if (sscanf(devs, "%x:%x", &maj, &min) == 2)
                        ht_put(makedev(maj, min), (ino_t)ino_m, pid, comm);
                }
            }
            fclose(m);
        }

        char ep[96];
        snprintf(ep, sizeof ep, "%s/exe", base);
        struct stat est;
        if (stat(ep, &est) == 0)
            ht_put(est.st_dev, est.st_ino, pid, comm);

        char cp[96];
        snprintf(cp, sizeof cp, "%s/cwd", base);
        struct stat cst;
        if (stat(cp, &cst) == 0 && S_ISDIR(cst.st_mode))
            ht_put(cst.st_dev, cst.st_ino, pid, comm);
    }
    closedir(pd);

    clock_gettime(CLOCK_MONOTONIC, &g_built);
    g_checks_since = 0;
    return 0;
}

int snapshot_check(dev_t dev, ino_t ino, pid_t exclude_pid, long ttl_sec,
                   Holder *out, int max, int *n)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long long ttl_ns = (long long)ttl_sec * 1000000000LL;

    pthread_mutex_lock(&g_mtx);
    long long age_ns = (long long)(now.tv_sec - g_built.tv_sec) * 1000000000LL
                     + (now.tv_nsec - g_built.tv_nsec);
    int stale = (g_built.tv_sec == 0)
             || age_ns > ttl_ns
             || (++g_checks_since > 4096 && age_ns > 100000000LL);
    if (stale) {
        if (build_held_set() != 0) {
            pthread_mutex_unlock(&g_mtx);
            return -1;
        }
    }

    *n = 0;
    Slot *s = ht_get(dev, ino);
    if (s && s->n > 0) {
        for (int i = 0; i < s->n && *n < max; i++) {
            if (s->h[i].pid == exclude_pid) continue;   /* 排除删除者自身 */
            out[*n].pid = s->h[i].pid;
            snprintf(out[*n].comm, sizeof out[*n].comm, "%s", s->h[i].comm);
            (*n)++;
        }
    }
    pthread_mutex_unlock(&g_mtx);
    return *n > 0 ? 1 : 0;
}
