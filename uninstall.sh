#!/usr/bin/env bash
# safeunlink 卸载脚本 — 移除安装脚本安装的全部内容 (仓库源码保留)。
#
# 用法: ./uninstall.sh [--keep-config]
#   --keep-config  保留配置文件 (默认仅删除带本脚本标记的配置)
# 环境变量与安装脚本一致: PREFIX / SAFEUNLINK_CONF
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIBDIR="$PREFIX/lib"
BINDIR="$PREFIX/bin"
CONF="${SAFEUNLINK_CONF:-/etc/safeunlink.conf}"
KEEP_CONFIG=0
[[ "${1:-}" == "--keep-config" ]] && KEEP_CONFIG=1

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
say()  { echo "${c_grn}==${c_rst} $*"; }
die()  { echo "${c_red}错误:${c_rst} $*" >&2; exit 1; }

SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "需要 root 权限: 请用 sudo 运行, 或安装 sudo"
    SUDO_CMD="sudo"
fi

writable() {
    local dir
    if [[ -d "$1" ]]; then dir="$1"; else dir="$(dirname "$1")"; fi
    [[ -w "$dir" ]]
}
run_priv() { # run_priv <目标路径> <命令...>
    local path="$1"; shift
    if writable "$path"; then "$@"; else $SUDO_CMD "$@"; fi
}

CAN_USER=1
USER_HOME="$HOME"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
elif [[ $EUID -eq 0 ]]; then
    CAN_USER=0
fi
USER_HOME="${USER_HOME:-$HOME}"

as_user() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        runuser -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

removed=0

# ---------- 1. 用户级: 停 daemon / 删自启 / 删别名 ----------
if [[ $CAN_USER -eq 1 ]]; then
    say "停止守护进程..."
    if as_user "$BINDIR/safeunlinkd" stop >/dev/null 2>&1; then
        echo "  已停止"; removed=1
    else
        echo "  未在运行 (或已卸载)"
    fi
    # 兜底清理 socket / pid 残留
    rm -f "${XDG_RUNTIME_DIR:-/tmp}/safeunlink.sock" \
          "${XDG_RUNTIME_DIR:-/tmp}/safeunlink.sock.pid" \
          "/tmp/safeunlink-$(id -u).sock" \
          "/tmp/safeunlink-$(id -u).sock.pid"

    if [[ -f "$USER_HOME/.config/autostart/safeunlinkd.desktop" ]]; then
        rm -f "$USER_HOME/.config/autostart/safeunlinkd.desktop"
        echo "  已删除自启: ~/.config/autostart/safeunlinkd.desktop"; removed=1
    fi

    if [[ -f "$USER_HOME/.bashrc" ]] && grep -q "# >>> safeunlink >>>" "$USER_HOME/.bashrc"; then
        sed -i '/# >>> safeunlink >>>/,/# <<< safeunlink <<</d' "$USER_HOME/.bashrc"
        echo "  已删除 ~/.bashrc 中的 safeunlink 别名块"; removed=1
    fi
fi

# ---------- 2. 系统级: 删除文件与配置 ----------
say "删除系统文件..."
for f in "$LIBDIR/libsafeunlink.so" "$BINDIR/safeunlinkd" "$BINDIR/safe-rm"; do
    if [[ -e "$f" ]]; then
        run_priv "$f" rm -f "$f"
        echo "  已删除: $f"; removed=1
    fi
done
if [[ $KEEP_CONFIG -eq 0 && -f "$CONF" ]] && grep -q "installed-by-safeunlink" "$CONF" 2>/dev/null; then
    run_priv "$CONF" rm -f "$CONF"
    echo "  已删除: $CONF"; removed=1
elif [[ -f "$CONF" ]]; then
    echo "  保留配置: $CONF (非本脚本生成, 或 --keep-config)"
fi
if [[ "$PREFIX" == "/usr" || "$PREFIX" == "/usr/local" ]]; then
    $SUDO_CMD ldconfig 2>/dev/null || true
fi

if [[ $removed -eq 0 ]]; then
    echo "没有发现已安装的 safeunlink 组件 (可能已卸载)。"
else
    say "卸载完成 ✓ (仓库源码与 build/ 目录保留; 如需清理: rm -rf $ROOT/build)"
fi
