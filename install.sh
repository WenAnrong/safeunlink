#!/usr/bin/env bash
# safeunlink 安装脚本 (仅支持 Debian/Ubuntu 系列)
#
# 自动检测依赖 → 自动构建 → 安装到 PREFIX (默认 /usr/local) →
# 启动守护进程 → 图形会话自启 → 自动注入并重启文件管理器 → 添加 rm 别名。
# 安装后开个新终端即可直接使用: 删除被占用文件时提示并阻止
# (终端红字 / 图形弹窗), 不允许继续删除。
#
# 权限要求:
#   - 必须以普通用户运行; root 直接运行会被拒绝。
#   - 需要 root 权限的步骤 (安装到 /usr/local、apt 安装依赖等)
#     会自动使用 sudo 并询问密码。
#
# 环境变量: PREFIX=/usr/local  安装前缀
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIBDIR="$PREFIX/lib"
BINDIR="$PREFIX/bin"

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

# ---------- 1. 权限: 只允许普通用户运行 ----------
if [[ $EUID -eq 0 ]]; then
    die "不允许以 root 运行本脚本。
请用普通用户执行: ./install.sh
(需要 root 权限的步骤会自动使用 sudo 并询问密码)"
fi
command -v sudo >/dev/null || die "需要 sudo (用于安装系统文件), 但未检测到 sudo"
SUDO_CMD="sudo"

USER_HOME="$HOME"

# 目标路径当前用户可写则直接写, 否则用 sudo
writable() {
    local dir
    if [[ -d "$1" ]]; then dir="$1"; else dir="$(dirname "$1")"; fi
    [[ -w "$dir" ]]
}
run_priv() { # run_priv <目标路径> <命令...>
    local path="$1"; shift
    if writable "$path"; then "$@"; else $SUDO_CMD "$@"; fi
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
command -v zenity >/dev/null || { echo "  缺少 zenity (图形弹窗) → 将安装"; apt_pkgs+=(zenity); }
if (( ${#apt_pkgs[@]} )); then
    echo "  执行: apt-get install -y ${apt_pkgs[*]} (需要 sudo 密码)"
    $SUDO_CMD apt-get update -qq
    $SUDO_CMD apt-get install -y --no-install-recommends "${apt_pkgs[@]}"
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

# 重启单个文件管理器: 优雅退出 → 兜底 pkill → 经 .desktop 重新拉起 → 验证库加载
restart_fm() {
    local bin="$1" id="$2"
    command -v pgrep >/dev/null 2>&1 || { warn "缺少 pgrep, 无法自动重启 $bin"; return 1; }
    if ! pgrep -x "$bin" >/dev/null 2>&1; then
        echo "  $bin 未在运行, 无需重启"
        return 0
    fi
    echo "  自动重启 $bin ..."
    # 1) 优雅退出
    case "$bin" in
        nautilus|nemo|caja|thunar) "$bin" -q >/dev/null 2>&1 || true ;;
        dolphin|pcmanfm|pcmanfm-qt) pkill -x "$bin" >/dev/null 2>&1 || true ;;
    esac
    sleep 0.5
    # 2) 兜底强杀
    if pgrep -x "$bin" >/dev/null 2>&1; then
        pkill -x "$bin" >/dev/null 2>&1 || true
        sleep 0.3
    fi
    # 3) 经 .desktop 重新启动 (LD_PRELOAD 才会生效)
    #    注意: 不能用 gtk-launch <id> —— 它走 D-Bus 激活 (--gapplication-service),
    #    绕过 Exec=, 库不会加载; 必须 gio launch 用户覆盖项文件路径
    if command -v gio >/dev/null 2>&1; then
        gio launch "$USER_HOME/.local/share/applications/$id" >/dev/null 2>&1 &
    else
        warn "缺少 gio, 无法自动重启 $bin; 请手动重新打开"
        return 1
    fi
    # 4) 验证拦截库是否加载
    local pid=""
    for _ in $(seq 1 10); do
        # 注意: set -o pipefail 下 pgrep 无匹配会返回 1, 必须 || true,
        # 否则安装脚本会在此处被 set -e 终止 (别名等后续步骤丢失)
        pid="$(pgrep -x "$bin" 2>/dev/null | head -1 || true)"
        [[ -n "$pid" ]] && break
        sleep 0.3
    done
    if [[ -n "$pid" ]] && grep -q libsafeunlink "/proc/$pid/maps" 2>/dev/null; then
        echo "  $bin 已重启, 拦截库已加载 ✓ (pid $pid)"
    elif [[ -n "$pid" ]]; then
        warn "$bin 已重启, 但未检测到拦截库加载 (pid $pid)"
    else
        warn "$bin 重启后未检测到进程 (窗口管理器可能未拉起)"
    fi
}

# 给常见文件管理器创建 ~/.local/share/applications 覆盖项,
# 在 Exec 前加 env LD_PRELOAD=... 使文件管理器加载拦截库 (图形弹窗的前提)。
# 检测: 可执行名 → .desktop 文件名; DESKTOP_DIRS 可覆盖搜索目录 (测试用)。
inject_desktop_overrides() {
    local -A fms=(
        [nautilus]=org.gnome.Nautilus.desktop
        [thunar]=thunar.desktop
        [dolphin]=org.kde.dolphin.desktop
        [nemo]=nemo.desktop
        [caja]=caja.desktop
        [pcmanfm]=pcmanfm.desktop
        [pcmanfm-qt]=org.pcmanfm.pcmanfm-qt.desktop
    )
    local appdir="$USER_HOME/.config/safeunlink"
    local list="$appdir/desktop-overrides.list"
    local deskdirs="${DESKTOP_DIRS:-/usr/local/share/applications /usr/share/applications}"
    local lib="$LIBDIR/libsafeunlink.so"
    local libq="$lib"
    [[ "$lib" == *" "* ]] && libq="\"$lib\""
    mkdir -p "$appdir"
    : > "$list"

    local found=0 bin name src dst
    local -a injected=()
    for bin in "${!fms[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || continue
        name="${fms[$bin]}"
        src=""
        for d in $deskdirs; do
            if [[ -f "$d/$name" ]]; then src="$d/$name"; break; fi
        done
        [[ -n "$src" ]] || continue
        dst="$USER_HOME/.local/share/applications/$name"

        if [[ -f "$dst" ]] && ! grep -q "^# safeunlink-injected" "$dst"; then
            warn "已存在自定义启动项, 跳过注入: $dst (可手动加 env LD_PRELOAD=$lib)"
            continue
        fi

        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        if ! grep -q "^Exec=env LD_PRELOAD=" "$dst"; then
            if grep -q "^Exec=" "$dst"; then
                # 用 | 作分隔符, 避免与路径中的 / 冲突
                sed -i "s|^Exec=|Exec=env LD_PRELOAD=$libq |" "$dst"
            else
                printf 'Exec=env LD_PRELOAD=%s %s %%U\n' "$libq" "$(command -v "$bin")" >> "$dst"
            fi
        fi
        # 关键: DBusActivatable=true 的应用由 D-Bus 激活 (按系统服务文件拉起),
        # 会绕过 Exec= 行, LD_PRELOAD 不生效; 必须置 false 让启动器走 Exec=
        if grep -q "^DBusActivatable=true" "$dst"; then
            sed -i "s|^DBusActivatable=true|DBusActivatable=false|" "$dst"
        fi
        grep -q "^# safeunlink-injected" "$dst" || {
            printf '# safeunlink-injected\n' | cat - "$dst" > "$dst.tmp" && mv "$dst.tmp" "$dst"
        }
        echo "$dst" >> "$list"
        found=1
        injected+=("$bin")
        echo "  $name → $dst"
    done

    if [[ $found -eq 0 ]]; then
        echo "  (未检测到常见文件管理器, 跳过注入; 可手动按 README 操作)"
        rm -f "$list"
    else
        # 自动重启注入过的文件管理器: 旧进程不带库, 必须经 .desktop 重新拉起
        if [[ -n "${SAFEUNLINK_NO_RESTART:-}" ]]; then
            echo "  (SAFEUNLINK_NO_RESTART=1, 跳过自动重启; 请手动完全退出并重新打开文件管理器)"
        else
            for bin in "${injected[@]}"; do
                restart_fm "$bin" "${fms[$bin]}"
            done
        fi
    fi
}

# ---------- 5. 用户级: daemon + 自启 + 文件管理器注入 + 别名 ----------
say "启动守护进程..."
"$BINDIR/safeunlinkd" stop >/dev/null 2>&1 || true   # 先停旧的, 再加载新版本
"$BINDIR/safeunlinkd" start
sleep 0.3
"$BINDIR/safeunlinkd" status || warn "daemon 状态异常, 可手动执行: $BINDIR/safeunlinkd start"

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
echo "  $USER_HOME/.config/autostart/safeunlinkd.desktop"

# 给常见文件管理器注入库, 让图形删除/移入回收站也能弹窗
say "给文件管理器注入拦截库 (图形弹窗)..."
inject_desktop_overrides

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

# ---------- 6. 完成 ----------
echo
say "安装完成 ✓"
echo "  库:     $LIBDIR/libsafeunlink.so"
echo "  daemon: $BINDIR/safeunlinkd"
echo "  包装:   $BINDIR/safe-rm"
echo
echo "  现在即可使用:"
echo "    - 终端:  直接 rm 文件, 被占用时红色提示并阻止删除"
echo "    - 图形:  文件管理器删除/移入回收站被占用时弹提示框, 阻止删除 (已自动注入)"
echo
echo "  验证: 打开一个文件后执行  safe-rm <该文件>  看拦截效果"
echo "  卸载: $ROOT/uninstall.sh"
