#!/usr/bin/env bash
# 测试套件: 阶段 1 终端 MVP
# 用法: LIB=<路径> HOLD=<路径> bash tests/run_tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${LIB:-$ROOT/build/libsafeunlink.so}"
HOLD="${HOLD:-$ROOT/build/hold}"
DAEMON="${DAEMON:-$ROOT/build/safeunlinkd}"
DCLIENT="${DCLIENT:-$ROOT/build/dclient}"
RM="$(command -v rm)"

if [[ ! -f "$LIB" ]]; then echo "缺少 $LIB, 先 make" >&2; exit 1; fi
if [[ ! -f "$HOLD" ]]; then echo "缺少 $HOLD, 先 make" >&2; exit 1; fi

# pty 探测: 部分沙箱环境无法分配伪终端, 交互测试自动跳过
PTY_OK=0
if command -v script >/dev/null && script -qec "true" /dev/null >/dev/null 2>&1; then
    PTY_OK=1
fi

TMP="$(mktemp -d)"
DAEMON_SOCKS=()
stop_daemons() {
    for s in "${DAEMON_SOCKS[@]+"${DAEMON_SOCKS[@]}"}"; do
        "$DAEMON" stop --socket "$s" >/dev/null 2>&1
    done
    DAEMON_SOCKS=()
}
trap '[[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null; stop_daemons; rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# 启动一个占用文件的进程, 等待它就绪
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

# 统一的 rm 执行入口 (环境变量 + 库)
run_rm() { # run_rm <mode> [额外 env...] -- rm 参数...
    local mode="$1"; shift
    local extra=()
    while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done
    shift
    env LD_PRELOAD="$LIB" SAFEUNLINK_MODE="$mode" \
        SAFEUNLINK_SOCKET="$TMP/none.sock" "${extra[@]}" "$RM" "$@"
}

echo "== 1. warn 模式 =="

f="$TMP/warn_unheld"; echo x > "$f"
err=$(run_rm warn -- -f "$f" 2>&1)
if [[ ! -e "$f" && "$err" != *"[safeunlink]"* ]]; then ok "未占用时直接删除, 无提示"; else bad "未占用时直接删除, 无提示 [$err]"; fi

f="$TMP/warn_held"; echo x > "$f"
start_hold "$f"
err=$(run_rm warn -- -f "$f" 2>&1)
if [[ ! -e "$f" && "$err" == *"[safeunlink]"* ]]; then ok "被占用时红色提示后仍删除"; else bad "被占用时红色提示后仍删除 [$err]"; fi
stop_hold

echo "== 2. block 模式 =="

f="$TMP/block_held"; echo x > "$f"
start_hold "$f"
err=$(run_rm block -- "$f" 2>&1); rc=$?
if [[ -e "$f" && $rc -ne 0 && "$err" == *"[safeunlink]"* ]]; then ok "被占用时拒绝删除 (EBUSY), 文件保留"; else bad "被占用时拒绝删除 (EBUSY), 文件保留 [rc=$rc err=$err]"; fi
stop_hold

f="$TMP/block_unheld"; echo x > "$f"
run_rm block -- "$f" 2>/dev/null
if [[ ! -e "$f" ]]; then ok "未占用时 block 模式正常删除"; else bad "未占用时 block 模式正常删除"; fi

echo "== 3. ask 模式 =="

f="$TMP/ask_deny"; echo x > "$f"
start_hold "$f"
err=$(run_rm ask SAFEUNLINK_ANSWER=n -- -f "$f" 2>&1); rc=$?
if [[ -e "$f" && $rc -ne 0 ]]; then ok "SAFEUNLINK_ANSWER=n → 取消删除"; else bad "SAFEUNLINK_ANSWER=n → 取消删除 [rc=$rc err=$err]"; fi
stop_hold

f="$TMP/ask_confirm"; echo x > "$f"
start_hold "$f"
err=$(run_rm ask SAFEUNLINK_ANSWER=y -- -f "$f" 2>&1)
if [[ ! -e "$f" ]]; then ok "SAFEUNLINK_ANSWER=y → 确认删除"; else bad "SAFEUNLINK_ANSWER=y → 确认删除 [$err]"; fi
stop_hold

f="$TMP/ask_notty"; echo x > "$f"
start_hold "$f"
err=$(run_rm ask -- -f "$f" 2>&1)
if [[ ! -e "$f" && "$err" == *"无交互终端"* ]]; then ok "无 tty 且无预置回答 → 回退 warn 继续删除"; else bad "无 tty 且无预置回答 → 回退 warn 继续删除 [$err]"; fi
stop_hold

if [[ $PTY_OK -eq 1 ]]; then
    f="$TMP/ask_pty_deny"; echo x > "$f"
    start_hold "$f"
    out=$(printf 'n\n' | script -qec "env LD_PRELOAD=$LIB SAFEUNLINK_MODE=ask $RM '$f'" /dev/null 2>&1)
    if [[ -e "$f" ]]; then ok "pty 交互: 回答 n → 取消删除"; else bad "pty 交互: 回答 n → 取消删除"; fi
    stop_hold

    f="$TMP/ask_pty_confirm"; echo x > "$f"
    start_hold "$f"
    out=$(printf 'y\n' | script -qec "env LD_PRELOAD=$LIB SAFEUNLINK_MODE=ask $RM '$f'" /dev/null 2>&1)
    if [[ ! -e "$f" ]]; then ok "pty 交互: 回答 y → 确认删除"; else bad "pty 交互: 回答 y → 确认删除"; fi
    stop_hold
else
    echo "  (跳过 pty 交互测试: 本环境无法分配伪终端)"
fi

echo "== 4. 颜色输出 =="

f="$TMP/color"; echo x > "$f"
start_hold "$f"
err=$(run_rm warn SAFEUNLINK_COLOR=1 -- -f "$f" 2>&1)
if [[ "$err" == *$'\e[31m'* ]]; then ok "SAFEUNLINK_COLOR=1 强制输出红色 ANSI"; else bad "SAFEUNLINK_COLOR=1 强制输出红色 ANSI"; fi
stop_hold

if [[ $PTY_OK -eq 1 ]]; then
    f="$TMP/color_tty"; echo x > "$f"
    start_hold "$f"
    out=$(script -qec "env LD_PRELOAD=$LIB SAFEUNLINK_MODE=warn $RM -f '$f'" /dev/null 2>&1)
    if [[ "$out" == *$'\e[31m'* ]]; then ok "真实终端下自动输出红色 ANSI"; else bad "真实终端下自动输出红色 ANSI"; fi
    stop_hold
fi

echo "== 5. 豁免机制 =="

# exempt_procs 豁免的是"执行删除的进程" (这里把 rm 复制成名为 apt 的二进制)
f="$TMP/exempt_proc"; echo x > "$f"
cp "$RM" "$TMP/apt"
start_hold "$f"
env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=block SAFEUNLINK_EXEMPT_PROCS=apt "$TMP/apt" -f "$f" 2>/dev/null
if [[ ! -e "$f" ]]; then ok "exempt_procs 豁免执行删除的进程 (apt)"; else bad "exempt_procs 豁免执行删除的进程 (apt)"; fi
stop_hold

f="$TMP/exempt_path"; echo x > "$f"
start_hold "$f"
run_rm block SAFEUNLINK_EXEMPT_PATHS="$TMP" -- -f "$f" 2>/dev/null
if [[ ! -e "$f" ]]; then ok "exempt_paths 豁免该目录"; else bad "exempt_paths 豁免该目录"; fi
stop_hold

echo "== 6. 紧急开关 =="

f="$TMP/killswitch"; echo x > "$f"
start_hold "$f"
run_rm block SAFEUNLINK_DISABLE=1 -- -f "$f" 2>/dev/null
if [[ ! -e "$f" ]]; then ok "SAFEUNLINK_DISABLE=1 完全放行"; else bad "SAFEUNLINK_DISABLE=1 完全放行"; fi
stop_hold

echo "== 7. 批量删除 rm -rf =="

d="$TMP/batch"; mkdir -p "$d"
echo x > "$d/a"; echo x > "$d/b"; echo x > "$d/c"
start_hold "$d/c"
err=$(run_rm block -- -rf "$d" 2>&1); rc=$?
if [[ -e "$d/c" && ! -e "$d/a" && ! -e "$d/b" ]]; then ok "rm -rf 中仅被占用文件被拦截, 其余删除"; else bad "rm -rf 中仅被占用文件被拦截, 其余删除 [rc=$rc err=$err]"; fi
stop_hold

echo "== 8. 符号链接 / 硬链接 =="

t="$TMP/target"; echo x > "$t"
start_hold "$t"
ln -s "$t" "$TMP/sym"
run_rm block -- "$TMP/sym" 2>/dev/null
if [[ ! -e "$TMP/sym" && -e "$t" ]]; then ok "删除符号链接不误报 (lstat 按链接自身 inode)"; else bad "删除符号链接不误报"; fi
stop_hold

ln "$TMP/target" "$TMP/hard"
start_hold "$TMP/target"
err=$(run_rm block -- "$TMP/hard" 2>&1)
if [[ -e "$TMP/hard" ]]; then ok "硬链接被占用时按 inode 拦截另一链接"; else bad "硬链接被占用时按 inode 拦截另一链接 [$err]"; fi
stop_hold

echo "== 9. 一次 rm 多个文件 =="

f1="$TMP/m1"; f2="$TMP/m2"; echo x > "$f1"; echo x > "$f2"
start_hold "$f1"
run_rm block -- -f "$f1" "$f2" 2>/dev/null
if [[ -e "$f1" && ! -e "$f2" ]]; then ok "同一 rm 内仅占用文件被拦截"; else bad "同一 rm 内仅占用文件被拦截"; fi
stop_hold

echo "== 10. 守护进程 (阶段 2) =="

SOCK="$TMP/su.sock"; LOG="$TMP/su.log"
SOCK2="$TMP/su2.sock"; LOG2="$TMP/su2.log"

env SAFEUNLINK_TTL=0 "$DAEMON" start --socket "$SOCK" --log "$LOG" --config /dev/null
DAEMON_SOCKS+=("$SOCK")
sleep 0.3
if [[ -S "$SOCK" ]]; then ok "daemon start: socket 就绪"; else bad "daemon start: socket 就绪"; fi

out=$("$DCLIENT" "$SOCK" PING)
if [[ "$out" == PONG* ]]; then ok "PING → PONG"; else bad "PING → PONG [$out]"; fi

f="$TMP/d_free"; echo x > "$f"
read -r ddev dino < <(stat -c '%d %i' "$f")
out=$("$DCLIENT" "$SOCK" CHECK 999999 "$ddev" "$dino")
if [[ "$out" == FREE ]]; then ok "CHECK 未占用 → FREE"; else bad "CHECK 未占用 → FREE [$out]"; fi

start_hold "$f"
out=$("$DCLIENT" "$SOCK" CHECK 999999 "$ddev" "$dino")
if [[ "$out" == HELD*"hold"* ]]; then ok "CHECK 被占用 → HELD(hold)"; else bad "CHECK 被占用 → HELD [$out]"; fi
out=$("$DCLIENT" "$SOCK" CHECK "$HOLD_PID" "$ddev" "$dino")
if [[ "$out" == FREE ]]; then ok "CHECK 排除删除者自身 → FREE"; else bad "CHECK 排除删除者自身 [$out]"; fi
stop_hold

f="$TMP/d_block"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=block SAFEUNLINK_SOCKET="$SOCK" "$RM" "$f" 2>&1)
if [[ -e "$f" ]]; then ok "daemon 在场时 block 仍拦截 (经 daemon 查询)"; else bad "daemon 在场时 block 仍拦截 [$err]"; fi
if grep -q "CHECK" "$LOG"; then ok "daemon 日志记录了 CHECK"; else bad "daemon 日志记录了 CHECK"; fi
stop_hold

# ask 无终端 → daemon 弹窗; dialog=none → fail-open 确认删除
env SAFEUNLINK_TTL=0 SAFEUNLINK_DIALOG=none "$DAEMON" start --socket "$SOCK2" --log "$LOG2" --config /dev/null
DAEMON_SOCKS+=("$SOCK2")
sleep 0.3
f="$TMP/d_ask"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=ask SAFEUNLINK_SOCKET="$SOCK2" "$RM" -f "$f" 2>&1)
if [[ ! -e "$f" ]]; then ok "ask 无终端 → daemon 弹窗 (dialog=none→确认) → 删除"; else bad "ask 无终端 → daemon 弹窗 [$err]"; fi
if grep -q "无法弹窗" "$LOG2"; then ok "daemon 日志记录弹窗失败回退"; else bad "daemon 日志记录弹窗失败回退"; fi
stop_hold

f="$TMP/d_ask_ans"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=ask SAFEUNLINK_ANSWER=n SAFEUNLINK_SOCKET="$SOCK2" "$RM" -f "$f" 2>&1); rc=$?
if [[ -e "$f" && $rc -ne 0 ]]; then ok "SAFEUNLINK_ANSWER=n 优先于 daemon 弹窗"; else bad "SAFEUNLINK_ANSWER=n 优先于 daemon 弹窗 [rc=$rc]"; fi
stop_hold

out=$("$DCLIENT" "$SOCK" NOTIFY 测试通知)
if [[ "$out" == OK ]]; then ok "NOTIFY → OK"; else bad "NOTIFY → OK [$out]"; fi
if grep -q "NOTIFY" "$LOG"; then ok "daemon 日志记录了 NOTIFY"; else bad "daemon 日志记录了 NOTIFY"; fi

# 无 DISPLAY 时跳过 zenity, 不挂起, fail-open 放行
SOCK3="$TMP/su3.sock"; LOG3="$TMP/su3.log"
env -u DISPLAY -u WAYLAND_DISPLAY SAFEUNLINK_TTL=0 "$DAEMON" start --socket "$SOCK3" --log "$LOG3" --config /dev/null
DAEMON_SOCKS+=("$SOCK3")
sleep 0.3
f="$TMP/d_zenity"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=ask SAFEUNLINK_SOCKET="$SOCK3" "$RM" -f "$f" 2>&1)
if [[ ! -e "$f" ]]; then ok "无 DISPLAY: 跳过 zenity, fail-open 放行 (不挂起)"; else bad "无 DISPLAY: 跳过 zenity [$err]"; fi
if grep -q "跳过 zenity" "$LOG3"; then ok "daemon 日志记录跳过 zenity"; else bad "daemon 日志记录跳过 zenity"; fi
stop_hold

"$DAEMON" stop --socket "$SOCK" >/dev/null
"$DAEMON" stop --socket "$SOCK2" >/dev/null
"$DAEMON" stop --socket "$SOCK3" >/dev/null
DAEMON_SOCKS=()
sleep 0.3
if [[ ! -S "$SOCK" && ! -S "$SOCK2" && ! -S "$SOCK3" ]]; then ok "stop: socket 已移除"; else bad "stop: socket 已移除"; fi
if ! "$DAEMON" status --socket "$SOCK" >/dev/null 2>&1; then ok "stop 后 status 报告未运行"; else bad "stop 后 status 报告未运行"; fi

# daemon 停止后回退本进程扫描
f="$TMP/d_fallback"; echo x > "$f"
start_hold "$f"
err=$(env LD_PRELOAD="$LIB" SAFEUNLINK_MODE=block SAFEUNLINK_SOCKET="$SOCK" "$RM" "$f" 2>&1)
if [[ -e "$f" ]]; then ok "daemon 停止后回退本进程扫描, 仍拦截"; else bad "daemon 停止后回退本进程扫描 [$err]"; fi
stop_hold

echo
echo "结果: $PASS 通过, $FAIL 失败"
[[ $FAIL -eq 0 ]]
