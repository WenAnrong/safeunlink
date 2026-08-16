#!/usr/bin/env bash
# safeunlink 卸载脚本 — 移除安装脚本安装的全部内容 (仓库源码保留)。
#
# 用法: ./uninstall.sh
# 环境变量: PREFIX=/usr/local  与安装脚本一致
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIBDIR="$PREFIX/lib"
BINDIR="$PREFIX/bin"

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
run_priv() {
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

# 与 install.sh 一致: 用目标用户的 XDG_RUNTIME_DIR 运行 daemon 命令
daemon_run() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        local uid; uid="$(id -u "$SUDO_USER")"
        if [[ -d "/run/user/$uid" ]]; then
            runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
                "$BINDIR/safeunlinkd" "$1"
        else
            runuser -u "$SUDO_USER" -- "$BINDIR/safeunlinkd" "$1"
        fi
    else
        "$BINDIR/safeunlinkd" "$1"
    fi
}

removed=0

# ---------- 1. 用户级: 停 daemon / 删自启 / 删别名 ----------
if [[ $CAN_USER -eq 1 ]]; then
    say "停止守护进程..."
    if daemon_run stop >/dev/null 2>&1; then
        echo "  已停止"; removed=1
    else
        echo "  未在运行 (或已卸载)"
    fi
    # 兜底清理 socket / pid 残留 (两个可能位置都清; root 运行时用目标用户 uid)
    target_uid="$(id -u "${SUDO_USER:-$(id -un)}")"
    rm -f "/run/user/$target_uid/safeunlink.sock" \
          "/run/user/$target_uid/safeunlink.sock.pid" \
          "${XDG_RUNTIME_DIR:-/tmp}/safeunlink.sock" \
          "${XDG_RUNTIME_DIR:-/tmp}/safeunlink.sock.pid" \
          "/tmp/safeunlink-$target_uid.sock" \
          "/tmp/safeunlink-$target_uid.sock.pid"

    if [[ -f "$USER_HOME/.config/autostart/safeunlinkd.desktop" ]]; then
        rm -f "$USER_HOME/.config/autostart/safeunlinkd.desktop"
        echo "  已删除自启: ~/.config/autostart/safeunlinkd.desktop"; removed=1
    fi

    if [[ -f "$USER_HOME/.bashrc" ]] && grep -q "# >>> safeunlink >>>" "$USER_HOME/.bashrc"; then
        sed -i '/# >>> safeunlink >>>/,/# <<< safeunlink <<</d' "$USER_HOME/.bashrc"
        # root 运行时 sed -i 可能改属主, 修正回来
        if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER":"$SUDO_USER" "$USER_HOME/.bashrc" 2>/dev/null || true
        fi
        echo "  已删除 ~/.bashrc 中的 safeunlink 别名块"; removed=1
    fi

    # 删除注入的文件管理器启动项 (仅本脚本创建的)
    list="$USER_HOME/.config/safeunlink/desktop-overrides.list"
    if [[ -f "$list" ]]; then
        while IFS= read -r f; do
            if [[ -f "$f" ]] && grep -q "^# safeunlink-injected" "$f"; then
                rm -f "$f"
                echo "  已删除注入: $f"; removed=1
            fi
        done < "$list"
        rm -f "$list"
        rmdir "$USER_HOME/.config/safeunlink" 2>/dev/null || true
        rmdir "$USER_HOME/.local/share/applications" 2>/dev/null || true
    fi
fi

# ---------- 2. 系统级: 删除文件 ----------
say "删除系统文件..."
for f in "$LIBDIR/libsafeunlink.so" "$BINDIR/safeunlinkd" "$BINDIR/safe-rm"; do
    if [[ -e "$f" ]]; then
        run_priv "$f" rm -f "$f"
        echo "  已删除: $f"; removed=1
    fi
done
if [[ "$PREFIX" == "/usr" || "$PREFIX" == "/usr/local" ]]; then
    $SUDO_CMD ldconfig 2>/dev/null || true
fi

if [[ $removed -eq 0 ]]; then
    echo "没有发现已安装的 safeunlink 组件 (可能已卸载)。"
else
    say "卸载完成 ✓ (仓库源码与 build/ 目录保留; 如需清理: rm -rf $ROOT/build)"
fi
