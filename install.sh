#!/usr/bin/env bash
# safeunlink 安装脚本 (仅支持 Debian/Ubuntu 系列)
#
# 自动检测依赖 → 自动构建 → 安装到 PREFIX (默认 /usr/local) →
# 生成配置 → 启动守护进程 → 图形会话自启 → 添加 rm 别名。
# 安装后开个新终端即可直接使用 (rm 会被拦截; 无终端程序走 daemon 弹窗)。
#
# 提权策略: 目标路径当前用户可写则直接写, 否则自动用 sudo (如 /usr/local、/etc)。
#
# 用法:
#   ./install.sh                 # 常规安装
#   ./install.sh --no-gui        # 不安装 zenity/libnotify-bin
#   ./install.sh --no-alias      # 不修改 ~/.bashrc
#   ./install.sh --no-autostart  # 不添加图形会话自启
#   ./install.sh --no-install-deps  # 不自动 apt 安装缺失依赖 (仅提示)
# 可用环境变量:
#   PREFIX=/usr/local   安装前缀 (默认 /usr/local)
#   SAFEUNLINK_CONF=/etc/safeunlink.conf  配置文件路径 (默认 /etc/safeunlink.conf)
#     注意: 若改到非默认路径, 库默认不会读取, 需另设 SAFEUNLINK_CONFIG 指向它
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIBDIR="$PREFIX/lib"
BINDIR="$PREFIX/bin"
CONF="${SAFEUNLINK_CONF:-/etc/safeunlink.conf}"

GUI=1; ALIAS=1; AUTOSTART=1; INSTALL_DEPS=1
for a in "$@"; do
    case "$a" in
        --no-gui)           GUI=0 ;;
        --no-alias)         ALIAS=0 ;;
        --no-autostart)     AUTOSTART=0 ;;
        --no-install-deps)  INSTALL_DEPS=0 ;;
        --help|-h)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "错误: 未知参数 $a (见 --help)"; exit 2 ;;
    esac
done

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
say()  { echo "${c_grn}==${c_rst} $*"; }
warn() { echo "${c_yel}警告:${c_rst} $*" >&2; }
die()  { echo "${c_red}错误:${c_rst} $*" >&2; exit 1; }

# ---------- 0. 平台检查: 仅 Debian/Ubuntu 系列 ----------
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case " $ID $ID_LIKE " in
        *" debian "*|*" ubuntu "*) : ;;
        *) die "仅支持 Debian/Ubuntu 系列 (检测到: ${PRETTY_NAME:-未知})" ;;
    esac
else
    die "无法识别系统 (/etc/os-release 不存在), 仅支持 Debian/Ubuntu 系列"
fi

# ---------- 1. 权限准备 ----------
SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "需要 root 权限: 请用 sudo 运行本脚本, 或安装 sudo"
    SUDO_CMD="sudo"
fi

# 目标路径是否可直接写 (免提权); 目录不存在时看其父目录
writable() {
    local dir
    if [[ -d "$1" ]]; then dir="$1"; else dir="$(dirname "$1")"; fi
    [[ -w "$dir" ]]
}
# 按目标路径可写性执行命令
run_priv() { # run_priv <目标路径> <命令...>
    local path="$1"; shift
    if writable "$path"; then "$@"; else $SUDO_CMD "$@"; fi
}

# 用户级操作的目标用户 (root 直跑时跳过)
CAN_USER=1
USER_HOME="$HOME"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
elif [[ $EUID -eq 0 ]]; then
    CAN_USER=0
    warn "以 root 直接运行, 跳过用户级步骤 (daemon 启动/别名/自启); 建议用普通用户运行本脚本"
fi
USER_HOME="${USER_HOME:-$HOME}"

as_user() {  # 以目标用户身份执行用户级命令
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        runuser -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

# ---------- 2. 依赖检测 ----------
say "检测依赖..."
apt_pkgs=()
command -v gcc >/dev/null || apt_pkgs+=(gcc)
command -v make >/dev/null || apt_pkgs+=(make)
dpkg -s libc6-dev >/dev/null 2>&1 || apt_pkgs+=(libc6-dev)
if (( ${#apt_pkgs[@]} )); then
    echo "  缺少构建依赖: ${apt_pkgs[*]} → 将安装 build-essential"
    apt_pkgs=(build-essential)
fi
if [[ $GUI -eq 1 ]]; then
    command -v zenity      >/dev/null || { echo "  缺少 zenity (图形询问框) → 将安装"; apt_pkgs+=(zenity); }
    command -v notify-send >/dev/null || { echo "  缺少 notify-send (系统通知) → 将安装"; apt_pkgs+=(libnotify-bin); }
fi
if (( ${#apt_pkgs[@]} )); then
    if [[ $INSTALL_DEPS -eq 1 ]]; then
        echo "  执行: apt-get install -y ${apt_pkgs[*]}"
        $SUDO_CMD apt-get update -qq
        $SUDO_CMD apt-get install -y --no-install-recommends "${apt_pkgs[@]}"
    else
        warn "--no-install-deps: 跳过依赖安装, 后续可能失败"
    fi
fi

# ---------- 3. 构建 ----------
say "构建..."
make -C "$ROOT" clean >/dev/null 2>&1 || true
make -C "$ROOT"
[[ -f "$ROOT/build/libsafeunlink.so" && -f "$ROOT/build/safeunlinkd" ]] \
    || die "构建产物缺失"

# ---------- 4. 安装文件 ----------
say "安装到 $PREFIX ..."
run_priv "$LIBDIR" install -d "$LIBDIR" "$BINDIR"
run_priv "$LIBDIR/libsafeunlink.so" install -m755 "$ROOT/build/libsafeunlink.so" "$LIBDIR/libsafeunlink.so"
run_priv "$BINDIR/safeunlinkd"      install -m755 "$ROOT/build/safeunlinkd"      "$BINDIR/safeunlinkd"
run_priv "$BINDIR/safe-rm"          install -m755 "$ROOT/bin/safe-rm"            "$BINDIR/safe-rm"
if [[ "$PREFIX" == "/usr" || "$PREFIX" == "/usr/local" ]]; then
    $SUDO_CMD ldconfig 2>/dev/null || true
fi

# ---------- 5. 配置 (不存在才生成, 保留用户修改) ----------
if [[ ! -e "$CONF" ]]; then
    say "生成配置 $CONF"
    run_priv "$CONF" install -m644 "$ROOT/etc/safeunlink.conf" "$CONF"
    if writable "$CONF"; then
        echo "# installed-by-safeunlink" >> "$CONF"
    else
        echo "# installed-by-safeunlink" | $SUDO_CMD tee -a "$CONF" >/dev/null
    fi
else
    echo "  配置已存在, 跳过: $CONF"
fi

# ---------- 6. 用户级: daemon + 自启 + 别名 ----------
if [[ $CAN_USER -eq 1 ]]; then
    say "启动守护进程..."
    start_daemon() {
        if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
            local uid; uid="$(id -u "$SUDO_USER")"
            if [[ -d "/run/user/$uid" ]]; then
                runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
                    "$BINDIR/safeunlinkd" start
            else
                runuser -u "$SUDO_USER" -- "$BINDIR/safeunlinkd" start
                warn "未检测到 /run/user/$uid (无活动图形会话); 登录后请手动执行: safeunlinkd start"
            fi
        else
            "$BINDIR/safeunlinkd" start
        fi
    }
    as_user "$BINDIR/safeunlinkd" stop >/dev/null 2>&1 || true   # 重新加载新版本
    start_daemon
    sleep 0.3
    as_user "$BINDIR/safeunlinkd" status || warn "daemon 状态异常, 可手动执行: $BINDIR/safeunlinkd start"

    if [[ $AUTOSTART -eq 1 ]]; then
        say "添加图形会话自启..."
        mkdir -p "$USER_HOME/.config/autostart"
        cat > "$USER_HOME/.config/autostart/safeunlinkd.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=safeunlink daemon
Comment=删除占用检查守护进程
Exec=$BINDIR/safeunlinkd start
X-GNOME-Autostart-enabled=true
EOF
        if [[ $EUID -eq 0 ]]; then
            chown -R "$SUDO_USER":"$SUDO_USER" "$USER_HOME/.config/autostart"
        fi
        echo "  $USER_HOME/.config/autostart/safeunlinkd.desktop"
    fi

    if [[ $ALIAS -eq 1 ]]; then
        if ! grep -q "# >>> safeunlink >>>" "$USER_HOME/.bashrc" 2>/dev/null; then
            say "添加别名 rm='safe-rm' 到 $USER_HOME/.bashrc"
            cat >> "$USER_HOME/.bashrc" <<'EOF'

# >>> safeunlink >>>
alias rm='safe-rm'
# <<< safeunlink <<<
EOF
            echo "  新终端生效; 当前终端可执行: source ~/.bashrc"
        else
            echo "  别名已存在, 跳过"
        fi
    fi
fi

# ---------- 7. 完成 ----------
echo
say "安装完成 ✓"
echo "  库:     $LIBDIR/libsafeunlink.so"
echo "  daemon: $BINDIR/safeunlinkd"
echo "  包装:   $BINDIR/safe-rm"
echo "  配置:   $CONF (可用 ~/.config/safeunlink.conf 覆盖)"
echo
echo "  现在即可使用:"
echo "    - 终端:  直接 rm 文件 (被占用时会红色提示/确认/拒绝)"
echo "    - 图形:  文件管理器删除被占用文件时弹窗 (需按 README 给文件管理器注入库)"
echo
echo "  验证: 打开一个文件后执行  safe-rm <该文件>  看拦截效果"
echo "  卸载: $ROOT/uninstall.sh"
