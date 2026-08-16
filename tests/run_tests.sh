#!/usr/bin/env bash
# 测试套件 — 默认功能 (提示并阻止, 不允许删除)
# 用法: LIB=<路径> HOLD=<路径> DCLIENT=<路径> DAEMON=<路径> bash tests/run_tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${LIB:-$ROOT/build/libsafeunlink.so}"
HOLD="${HOLD:-$ROOT/build/hold}"
DAEMON="${DAEMON:-$ROOT/build/safeunlinkd}"
DCLIENT="${DCLIENT:-$ROOT/build/dclient}"
RM="$(command -v rm)"
MV="$(command -v mv)"

if [[ ! -f "$LIB" ]]; then echo "缺少 $LIB, 先 make" >&2; exit 1; fi
if [[ ! -f "$HOLD" ]]; then echo "缺少 $HOLD, 先 make" >&2; exit 1; fi

# pty 探测: 部分沙箱环境无法分配伪终端, 终端显示测试自动跳过
PTY_OK=0
if command -v script >/dev/null && script -qec "true" /dev/null >/dev/null 2>&1; then
    PTY_OK=1
fi

TMP="$(mktemp -d)"
# 隔离: socket 与回收站目录都从 XDG 环境变量推导
export XDG_RUNTIME_DIR="$TMP/run"
export XDG_DATA_HOME="$TMP/xdg"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME"
TRASH="$XDG_DATA_HOME/Trash/files"
mkdir -p "$TRASH"
SOCK="$XDG_RUNTIME_DIR/safeunlink.sock"
LOG="$TMP/su.log"

trap '[[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null; "$DAEMON" stop --socket "$SOCK" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

start_hold() {
    local f="$1"
    "$HOLD" "$f" 30 >"$TMP/hold.out" 2>&1 &
    HOLD_PID=$!
    for _ in $(seq 1 50); do
        grep -q HOLDING "$TMP/hold.out" 2>/dev/null && return 0
        sleep 0.05
    done
    echo "hold 进程未就绪" >&2; return 1
}
stop_hold() {
    [[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null
    wait "${HOLD_PID:-}" 2>/dev/null
    HOLD_PID=
}

run_rm() { # run_rm [额外 env...] -- rm 参数...
    local extra=()
    while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
    shift
    env LD_PRELOAD="$LIB" "${extra[@]}" "$RM" "$@"
}
run_mv() { # run_mv [额外 env...] -- mv 参数...
    local extra=()
    while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
    shift
    env LD_PRELOAD="$LIB" "${extra[@]}" "$MV" "$@"
}

echo "== 1. 未占用 → 正常删除 =="
f="$TMP/free1"; echo x > "$f"
err=$(run_rm -- -f "$f" 2>&1)
if [[ ! -e "$f" && "$err" != *"[safeunlink]"* ]]; then ok "直接删除, 无提示"; else bad "直接删除, 无提示 [$err]"; fi

echo "== 2. 占用 → 提示并阻止, 不允许删除 =="
f="$TMP/held1"; echo x > "$f"
start_hold "$f"
err=$(run_rm -- -f "$f" 2>&1); rc=$?
if [[ -e "$f" && $rc -ne 0 && "$err" == *"[safeunlink]"* && "$err" == *"已阻止"* ]]; then
    ok "提示被占用并阻止删除 (EBUSY), 文件保留"
else
    bad "提示被占用并阻止删除 [rc=$rc err=$err]"
fi
stop_hold

echo "== 3. 紧急开关 =="
f="$TMP/disable"; echo x > "$f"
start_hold "$f"
run_rm SAFEUNLINK_DISABLE=1 -- -f "$f" 2>/dev/null
if [[ ! -e "$f" ]]; then ok "SAFEUNLINK_DISABLE=1 完全放行"; else bad "SAFEUNLINK_DISABLE=1 完全放行"; fi
stop_hold

echo "== 4. 符号链接 / 硬链接 =="
t="$TMP/target"; echo x > "$t"
start_hold "$t"
ln -s "$t" "$TMP/sym"
run_rm -- "$TMP/sym" 2>/dev/null
if [[ ! -e "$TMP/sym" && -e "$t" ]]; then ok "删除符号链接不误报"; else bad "删除符号链接不误报"; fi
stop_hold

ln "$TMP/target" "$TMP/hard"
start_hold "$TMP/target"
err=$(run_rm -- "$TMP/hard" 2>&1)
if [[ -e "$TMP/hard" ]]; then ok "硬链接被占用时按 inode 阻止删除另一链接"; else bad "硬链接被占用时按 inode 阻止 [$err]"; fi
stop_hold

echo "== 5. 回收站 (移入 Trash) =="
f="$TMP/t1"; echo x > "$f"
start_hold "$f"
err=$(run_mv -- "$f" "$TRASH/" 2>&1)
if [[ -e "$f" && ! -e "$TRASH/t1" && "$err" == *"移入回收站"* ]]; then
    ok "占用时移入回收站被阻止"
else
    bad "占用时移入回收站被阻止 [err=$err]"
fi
stop_hold

f="$TMP/t2"; echo x > "$f"
run_mv -- "$f" "$TRASH/" 2>/dev/null
if [[ ! -e "$f" && -e "$TRASH/t2" ]]; then ok "未占用 → 正常移入回收站"; else bad "未占用 → 正常移入回收站"; fi

d="$TMP/other"; mkdir -p "$d"
f="$TMP/t3"; echo x > "$f"
start_hold "$f"
run_mv -- "$f" "$d/" 2>/dev/null
if [[ ! -e "$f" && -e "$d/t3" ]]; then ok "移到普通目录不拦截 (仅回收站)"; else bad "移到普通目录不拦截"; fi
stop_hold

echo x > "$TMP/hl_a"; ln "$TMP/hl_a" "$TMP/hl_b"
start_hold "$TMP/hl_a"
err=$(run_mv -- "$TMP/hl_b" "$TRASH/" 2>&1)
if [[ -e "$TMP/hl_b" && ! -e "$TRASH/hl_b" ]]; then ok "硬链接占用时移入回收站按 inode 阻止"; else bad "硬链接占用时移入回收站按 inode 阻止 [$err]"; fi
stop_hold

# 模拟文件管理器流程: 移入回收站被阻止后, 文件管理器弹"要立刻删除吗?",
# 确认后执行 unlink → 同样被阻止, 且不再二次提示 (全程只提示一次)
TF="$ROOT/build/trashflow"
f="$TMP/tf"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" "$TF" "$f" "$TRASH/tf" 2>&1)
n=$(printf '%s' "$err" | grep -c "文件正被其他程序使用")
if [[ -e "$f" ]]; then
    ok "回收站被阻止后的跟随删除同样被阻止, 文件保留"
else
    bad "回收站被阻止后的跟随删除同样被阻止 [$err]"
fi
if [[ "$n" -eq 1 ]]; then ok "整个流程只提示一次"; else bad "整个流程只提示一次 (实际 $n 次) [$err]"; fi
stop_hold

# 同进程重试 (文件管理器连续操作): 移入回收站被阻止 → 跟随 unlink 静默阻止
# → 等 1 秒后再移入回收站 → 再次提示; 全程文件保留, 共 2 次提示
TR="$ROOT/build/trashretry"
f="$TMP/tr"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" "$TR" "$f" "$TRASH/tr" 2>&1)
n=$(printf '%s' "$err" | grep -c "文件正被其他程序使用")
if [[ -e "$f" && "$n" -eq 2 ]]; then ok "同进程重试: 两次移入回收站各提示一次, 文件保留"; else bad "同进程重试: 两次移入回收站各提示一次 [n=$n err=$err]"; fi
stop_hold

echo "== 6. 守护进程 (GUI 提示链路) =="
# 快照在首次 CHECK 时构建; 每个占用场景前重启 daemon 保证快照新鲜
restart_daemon() {
    "$DAEMON" stop --socket "$SOCK" >/dev/null 2>&1
    sleep 0.2
    # 显式无 DISPLAY: 跳过 zenity (本环境无真实图形服务器)
    env -u DISPLAY -u WAYLAND_DISPLAY "$DAEMON" start --socket "$SOCK" --log "$LOG" >/dev/null
    sleep 0.3
}
restart_daemon
if [[ -S "$SOCK" ]]; then ok "daemon start: socket 就绪"; else bad "daemon start"; fi

out=$("$DCLIENT" "$SOCK" PING)
if [[ "$out" == PONG* ]]; then ok "PING → PONG"; else bad "PING → PONG [$out]"; fi

f="$TMP/d1"; echo x > "$f"
read -r ddev dino < <(stat -c '%d %i' "$f")
out=$("$DCLIENT" "$SOCK" CHECK 999999 "$ddev" "$dino")
if [[ "$out" == FREE ]]; then ok "CHECK 未占用 → FREE"; else bad "CHECK 未占用 → FREE [$out]"; fi

restart_daemon
start_hold "$f"
out=$("$DCLIENT" "$SOCK" CHECK 999999 "$ddev" "$dino")
if [[ "$out" == HELD*"hold"* ]]; then ok "CHECK 被占用 → HELD(hold)"; else bad "CHECK 被占用 → HELD [$out]"; fi
out=$("$DCLIENT" "$SOCK" CHECK "$HOLD_PID" "$ddev" "$dino")
if [[ "$out" == FREE ]]; then ok "CHECK 排除删除者自身 → FREE"; else bad "CHECK 排除删除者自身 [$out]"; fi

# 占用 + 无终端 → daemon ASK 提示框 → 仍阻止删除
err=$(run_rm -- -f "$f" 2>&1); rc=$?
if [[ -e "$f" && $rc -ne 0 ]]; then ok "无终端 → daemon 提示框, 仍阻止删除"; else bad "无终端 → daemon 提示框, 仍阻止删除 [rc=$rc err=$err]"; fi
if grep -q "ASK" "$LOG"; then ok "daemon 日志记录了 ASK"; else bad "daemon 日志记录了 ASK"; fi
stop_hold

# 批量删除: 被占用文件被阻止, 其余正常删除
d2="$TMP/batch"; mkdir -p "$d2"
echo x > "$d2/a"; echo x > "$d2/b"; echo x > "$d2/c"
restart_daemon
start_hold "$d2/c"
run_rm -- -rf "$d2" 2>/dev/null
if [[ ! -e "$d2/a" && ! -e "$d2/b" && -e "$d2/c" ]]; then
    ok "rm -rf 中被占用文件被阻止, 其余删除"
else
    bad "rm -rf 中被占用文件被阻止, 其余删除"
fi
stop_hold

# 非阻塞弹窗: 提示框未关闭时, 后续请求不能被阻塞 (否则第二次删除静默无提示)
FD="$TMP/fakebin2"; mkdir -p "$FD"
printf '#!/bin/sh\nsleep 5\n' > "$FD/zenity"; chmod +x "$FD/zenity"
"$DAEMON" stop --socket "$SOCK" >/dev/null 2>&1
sleep 0.2
env -u WAYLAND_DISPLAY DISPLAY=:99 PATH="$FD:$PATH" \
    "$DAEMON" start --socket "$SOCK" --log "$LOG" >/dev/null
sleep 0.3
t0=$(date +%s%N)
out=$("$DCLIENT" "$SOCK" ASK 12345 非阻塞提示框测试)
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [[ $ms -lt 3000 ]]; then ok "弹窗不阻塞主循环 (ASK 应答 ${ms}ms)"; else bad "弹窗不阻塞主循环 (ASK 应答 ${ms}ms)"; fi
t0=$(date +%s%N)
out=$("$DCLIENT" "$SOCK" PING)
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [[ $ms -lt 3000 ]]; then ok "弹窗挂起期间 PING 仍即时应答 (${ms}ms)"; else bad "弹窗挂起期间 PING 仍即时应答 (${ms}ms)"; fi

"$DAEMON" stop --socket "$SOCK" >/dev/null
sleep 0.3
if [[ ! -S "$SOCK" ]]; then ok "stop: socket 已移除"; else bad "stop: socket 已移除"; fi
if ! "$DAEMON" status --socket "$SOCK" >/dev/null 2>&1; then ok "stop 后 status 报告未运行"; else bad "stop 后 status 报告未运行"; fi

# daemon 停止后回退本进程扫描
f="$TMP/d3"; echo x > "$f"
start_hold "$f"
err=$(run_rm -- "$f" 2>&1)
if [[ -e "$f" ]]; then ok "daemon 停止后回退本进程扫描, 仍阻止"; else bad "daemon 停止后回退本进程扫描 [$err]"; fi
stop_hold

echo "== 7. 安装脚本: 自动注入文件管理器 =="
IHOME="$TMP/ihome"; IPREFIX="$TMP/iprefix"; IRUN="$TMP/irun"
mkdir -p "$IHOME" "$IPREFIX" "$IRUN" "$TMP/fakebin" "$TMP/fakeapps"
printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/nautilus"; chmod +x "$TMP/fakebin/nautilus"
cat > "$TMP/fakeapps/org.gnome.Nautilus.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Fake Files
Exec=/usr/bin/nautilus %U
DBusActivatable=true
EOF
env PATH="$TMP/fakebin:$PATH" HOME="$IHOME" XDG_RUNTIME_DIR="$IRUN" PREFIX="$IPREFIX" \
    SAFEUNLINK_NO_RESTART=1 DESKTOP_DIRS="$TMP/fakeapps" bash "$ROOT/install.sh" >/dev/null 2>&1
OVERRIDE="$IHOME/.local/share/applications/org.gnome.Nautilus.desktop"
if [[ -f "$OVERRIDE" ]] && grep -q "^# safeunlink-injected" "$OVERRIDE" \
    && grep -q "Exec=env LD_PRELOAD=$IPREFIX/lib/libsafeunlink.so " "$OVERRIDE" \
    && grep -q "^DBusActivatable=false" "$OVERRIDE"; then
    ok "install.sh 自动注入文件管理器 (LD_PRELOAD + DBusActivatable=false)"
else
    bad "install.sh 自动注入文件管理器"; cat "$OVERRIDE" 2>/dev/null
fi
env HOME="$IHOME" XDG_RUNTIME_DIR="$IRUN" PREFIX="$IPREFIX" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
if [[ ! -f "$OVERRIDE" ]]; then ok "uninstall.sh 移除注入的启动项"; else bad "uninstall.sh 移除注入的启动项"; fi

echo "== 8. install.sh 自动重启文件管理器 =="
if pgrep -x nautilus >/dev/null 2>&1; then
    echo "  (跳过: 检测到真实 nautilus 正在运行, 避免测试误杀用户文件管理器)"
else
R2="$TMP/rtest"; mkdir -p "$R2/home" "$R2/prefix" "$R2/run" "$R2/fakebin" "$R2/fakeapps" "$R2/logbin"
# 假 gio: 只记录 launch 参数 (必须是 gio launch <覆盖项路径>, 不能用 gtk-launch)
cat > "$R2/logbin/gio" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GIO_LAUNCH_LOG:?}"
EOF
chmod +x "$R2/logbin/gio"
# 假 nautilus 进程: hold 改名后 comm=nautilus, 常驻模拟"旧文件管理器"
cp "$HOLD" "$R2/fakebin/nautilus"
echo x > "$R2/fakeapps-target.txt"
"$R2/fakebin/nautilus" "$R2/fakeapps-target.txt" 30 >/dev/null 2>&1 &
FAKEPID=$!
sleep 0.3
cat > "$R2/fakeapps/org.gnome.Nautilus.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Fake Files
Exec=/usr/bin/nautilus %U
DBusActivatable=true
EOF
GIO_LAUNCH_LOG="$R2/launch.log" \
env PATH="$R2/fakebin:$R2/logbin:$PATH" HOME="$R2/home" XDG_RUNTIME_DIR="$R2/run" PREFIX="$R2/prefix" \
    DESKTOP_DIRS="$R2/fakeapps" bash "$ROOT/install.sh" >/dev/null 2>&1
if ! kill -0 "$FAKEPID" 2>/dev/null; then
    ok "install.sh 自动退出运行中的文件管理器"
else
    bad "install.sh 自动退出运行中的文件管理器"; kill "$FAKEPID" 2>/dev/null
fi
if [[ -f "$R2/launch.log" ]] && grep -q "launch" "$R2/launch.log" \
    && grep -q "org.gnome.Nautilus.desktop" "$R2/launch.log"; then
    ok "install.sh 经 gio launch 覆盖项重新启动 (LD_PRELOAD 生效)"
else
    bad "install.sh 经 gio launch 覆盖项重新启动 (log: $(cat "$R2/launch.log" 2>/dev/null))"
fi
# 回归: 自动重启后安装必须完整跑完 (别名等后续步骤不能因 set -e 中断丢失)
if [[ -f "$R2/home/.bashrc" ]] && grep -q "# >>> safeunlink >>>" "$R2/home/.bashrc"; then
    ok "install.sh 完整执行 (别名步骤未被中断)"
else
    bad "install.sh 完整执行 (别名步骤未被中断)"
fi
env HOME="$R2/home" XDG_RUNTIME_DIR="$R2/run" PREFIX="$R2/prefix" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
fi

if [[ $PTY_OK -eq 1 ]]; then
    echo "== 9. 真实终端显示 (pty) =="
    f="$TMP/pty"; echo x > "$f"
    start_hold "$f"
    out=$(script -qec "env LD_PRELOAD=$LIB $RM -f '$f'" /dev/null 2>&1)
    if [[ -e "$f" ]]; then ok "终端提示后仍阻止删除, 文件保留"; else bad "终端提示后仍阻止删除"; fi
    if [[ "$out" == *$'\e[31m'* ]]; then ok "终端下红色 ANSI 警告"; else bad "终端下红色 ANSI 警告"; fi
    if [[ "$out" == *"已阻止"* ]]; then ok "提示包含'已阻止'"; else bad "提示包含'已阻止'"; fi
    stop_hold
else
    echo "  (跳过 pty 终端显示测试: 本环境无法分配伪终端)"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[[ $FAIL -eq 0 ]]
