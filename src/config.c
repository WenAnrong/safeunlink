/* 配置加载 — 库与 daemon 共用。
 * 查找顺序: 自定义路径 (SAFEUNLINK_CONFIG / --config) →
 *           ~/.config/safeunlink.conf → /etc/safeunlink.conf;
 * 环境变量优先级最高。
 */
#include "config.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

SafeConfig g_cfg;
static int g_loaded = 0;

static int parse_bool(const char *s);

static void parse_keyval(char *line)
{
    char *p = line;
    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p || *p == '#') return;
    char *eq = strchr(p, '=');
    if (!eq) return;
    *eq = '\0';
    char *key = p;
    char *val = eq + 1;
    char *ke = key + strlen(key);
    while (ke > key && isspace((unsigned char)ke[-1])) *--ke = '\0';
    while (*val && isspace((unsigned char)*val)) val++;
    char *ve = val + strlen(val);
    while (ve > val && isspace((unsigned char)ve[-1])) *--ve = '\0';

    if (!strcmp(key, "mode")) {
        if      (!strcmp(val, "warn"))  g_cfg.mode = 0;
        else if (!strcmp(val, "ask"))   g_cfg.mode = 1;
        else if (!strcmp(val, "block")) g_cfg.mode = 2;
    } else if (!strcmp(key, "exempt_procs")) {
        snprintf(g_cfg.exempt_procs, sizeof g_cfg.exempt_procs, "%s", val);
    } else if (!strcmp(key, "exempt_paths")) {
        snprintf(g_cfg.exempt_paths, sizeof g_cfg.exempt_paths, "%s", val);
    } else if (!strcmp(key, "ttl")) {
        char *end = NULL;
        long v = strtol(val, &end, 10);
        if (end != val && v >= 0) g_cfg.ttl_sec = v;
    } else if (!strcmp(key, "trash")) {
        int b = parse_bool(val);
        if (b >= 0) g_cfg.trash = b;
    } else if (!strcmp(key, "dialog")) {
        snprintf(g_cfg.dialog, sizeof g_cfg.dialog, "%s", val);
    } else if (!strcmp(key, "log")) {
        snprintf(g_cfg.log_path, sizeof g_cfg.log_path, "%s", val);
    } else if (!strcmp(key, "socket")) {
        snprintf(g_cfg.socket_path, sizeof g_cfg.socket_path, "%s", val);
    }
}

static void parse_file(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[4096];
    while (fgets(line, sizeof line, f)) {
        char *c = strchr(line, '#');
        if (c) *c = '\0';
        parse_keyval(line);
    }
    fclose(f);
}

static void set_mode_from_str(const char *s)
{
    if (!s) return;
    if      (!strcmp(s, "warn"))  g_cfg.mode = 0;
    else if (!strcmp(s, "ask"))   g_cfg.mode = 1;
    else if (!strcmp(s, "block")) g_cfg.mode = 2;
}

/* 解析布尔值: 1/yes/on/true/y → 1; 0/no/off/false/n → 0; 其他 → -1 */
static int parse_bool(const char *s)
{
    if (!s) return -1;
    if (!strcmp(s, "1") || !strcmp(s, "yes") || !strcmp(s, "on") ||
        !strcmp(s, "true") || !strcmp(s, "y")) return 1;
    if (!strcmp(s, "0") || !strcmp(s, "no") || !strcmp(s, "off") ||
        !strcmp(s, "false") || !strcmp(s, "n")) return 0;
    return -1;
}

void safe_config_load(const char *custom)
{
    g_cfg.mode = 1;                       /* 默认 ask */
    g_cfg.exempt_procs[0] = '\0';
    g_cfg.exempt_paths[0] = '\0';
    g_cfg.ttl_sec = 2;
    g_cfg.trash = 1;
    snprintf(g_cfg.dialog, sizeof g_cfg.dialog, "zenity");
    snprintf(g_cfg.log_path, sizeof g_cfg.log_path, "auto");
    snprintf(g_cfg.socket_path, sizeof g_cfg.socket_path, "auto");

    if (custom && *custom) {
        parse_file(custom);
    } else {
        const char *home = getenv("HOME");
        if (home && *home) {
            char p[PATH_MAX];
            snprintf(p, sizeof p, "%s/.config/safeunlink.conf", home);
            parse_file(p);
        }
        parse_file("/etc/safeunlink.conf");
    }

    set_mode_from_str(getenv("SAFEUNLINK_MODE"));
    const char *e;
    if ((e = getenv("SAFEUNLINK_EXEMPT_PROCS")) && *e)
        snprintf(g_cfg.exempt_procs, sizeof g_cfg.exempt_procs, "%s", e);
    if ((e = getenv("SAFEUNLINK_EXEMPT_PATHS")) && *e)
        snprintf(g_cfg.exempt_paths, sizeof g_cfg.exempt_paths, "%s", e);
    if ((e = getenv("SAFEUNLINK_TTL")) && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end != e && v >= 0) g_cfg.ttl_sec = v;
    }
    {
        int b = parse_bool(getenv("SAFEUNLINK_TRASH"));
        if (b >= 0) g_cfg.trash = b;
    }
    if ((e = getenv("SAFEUNLINK_DIALOG")) && *e)
        snprintf(g_cfg.dialog, sizeof g_cfg.dialog, "%s", e);
    if ((e = getenv("SAFEUNLINK_LOG")) && *e)
        snprintf(g_cfg.log_path, sizeof g_cfg.log_path, "%s", e);
    if ((e = getenv("SAFEUNLINK_SOCKET")) && *e)
        snprintf(g_cfg.socket_path, sizeof g_cfg.socket_path, "%s", e);
    g_loaded = 1;
}

void safe_config_load_once(void)
{
    if (!g_loaded) safe_config_load(NULL);
}
