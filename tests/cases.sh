# 单元测试的用例：由 tests/run.sh 用 dash / sh / ksh 各跑一遍（手机上是 busybox ash 或 mksh）。
# 用 PATH 里的假命令代替 dumpsys / cmd / am / pm / pidof / su / getprop / stat / date / sleep，
# 它们按 FAKE_* 环境变量回答，改动类命令记到 $CALLS。模块脚本本身不改一行地被测。
set -u
HERE=${TESTS_DIR:?}
MOD=$HERE/../ksu-tt-keepalive
FIX=$HERE/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/tt-ka-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
# 结果写进文件：子 shell 里的用例也能算进去
ok()   { echo . >> "$T/pass"; }
bad()  { echo . >> "$T/fail"; echo "  ✗ $*"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# ---------- 假命令 ----------
# run.sh 给了 TEST_BIN 就共用（macOS 第一次执行新文件要扫描，约 0.3 秒一个）
BIN=${TEST_BIN:-$T/bin}; mkdir -p "$BIN"
mk() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1.new"
       if cmp -s "$BIN/$1.new" "$BIN/$1"; then rm -f "$BIN/$1.new"; else mv "$BIN/$1.new" "$BIN/$1"; chmod +x "$BIN/$1"; fi; }
mk dumpsys 'case "$1 ${2:-}" in
  "deviceidle whitelist")
    case "${3:-}" in +*|-*) echo "dumpsys deviceidle whitelist $3" >> "$CALLS" ;;
      *) [ "$FAKE_WL" = yes ] && echo "user,com.tauritavern.client,10447"; echo "system,com.android.shell,2000" ;; esac ;;
  "activity services") if [ "$FAKE_GEN" = 1 ]; then cat "$FIX/services-generating.txt"; else cat "$FIX/services-idle.txt"; fi ;;
  "activity exit-info") cat "$FAKE_EXIT" 2>/dev/null ;;
  "netpolicy ") cat "$FIX/netpolicy.txt" ;;
esac'
mk cmd 'case "$1 $2" in
  "appops get") echo "$4: $FAKE_RAIB" ;;
  "appops set") echo "cmd $*" >> "$CALLS" ;;
  "notification post") echo "cmd $*" >> "$CALLS" ;;
esac'
mk am 'case "$1" in get-standby-bucket) echo "$FAKE_BUCKET" ;; *) echo "am $*" >> "$CALLS" ;; esac'
mk pm '[ "$FAKE_INSTALLED" = 1 ]'
mk pidof 'echo "$FAKE_PIDS"'
mk su 'echo "su $*" >> "$CALLS"; [ "$1" = 2000 ] && [ "$2" = -c ] && sh -c "$3"'
mk getprop 'echo 1'
mk stat 'echo 10447'
mk sleep ':'
mk date 'if [ "${1:-}" = +%s ]; then echo "$FAKE_NOW"; else exec /bin/date "$@"; fi'
export PATH="$BIN:$PATH" FIX CALLS=$T/calls
export FAKE_WL=no FAKE_GEN=0 FAKE_EXIT=$FIX/exit-info.txt FAKE_RAIB=default FAKE_BUCKET=5 FAKE_INSTALLED=1 FAKE_PIDS="" FAKE_NOW=1000

newmod() {   # 新建一个空的模块目录（放进脚本），设好环境
    D=$T/mod$1; rm -rf "$D"; mkdir -p "$D"; cp "$MOD"/*.sh "$MOD/module.prop" "$D/"
    export TT_MODDIR=$D CG_ROOT=$T/cg$1 OPLUS_FROZEN=$T/oplus$1
    : > "$CALLS"
}
calls() { cat "$CALLS"; }

# 在子 shell 里加载 service.sh 的函数（不进主循环）
load() { TT_KEEPALIVE_TEST=1; . "$TT_MODDIR/service.sh"; }

echo "[common] 退出记录解析"
newmod 1; ( load
    r=$(exit_records)
    check "只取主进程三条" '[ "$(echo "$r" | wc -l | tr -d " ")" = 3 ]'
    check "第一条字段" '[ "$(echo "$r" | head -1)" = "2026-09-26 12:29:36.672|26636|USER REQUESTED|FORCE STOP|400|stop com.tauritavern.client due to from pid 1387" ]'
    check "没有 description 时为空" '[ "$(echo "$r" | sed -n 2p)" = "2026-09-26 12:17:18.751|26440|LOW MEMORY|UNKNOWN|400|" ]'
    check "没有 subreason 时为空" '[ "$(echo "$r" | sed -n 3p | cut -d"|" -f3,4)" = "SIGNALED|" ]'
    l=$(exit_line "$(echo "$r" | head -1)")
    check "强制停止翻成人话" 'case "$l" in "TT（26636）12:29:36.672 退出：被强制停止"*"FORCE STOP"*) true ;; *) false ;; esac'
    check "内存不够" 'case "$(exit_line "$(echo "$r" | sed -n 2p)")" in *"内存不够"*) true ;; *) false ;; esac'
    check "被信号杀" 'case "$(exit_line "$(echo "$r" | sed -n 3p)")" in *"厂商的后台清理"*"oplus athena kill"*) true ;; *) false ;; esac'
    state_set last_exit "2026-09-26 12:14:07.288"
    n=$(new_exits)
    check "new_exits 只要更新的、旧的在前" '[ "$(echo "$n" | cut -d"|" -f2 | tr "\n" " ")" = "26440 26636 " ]'
    state_set last_exit "2026-09-26 12:29:36.672"
    check "没有新的时为空" '[ -z "$(new_exits)" ]'
    ( umask 000; . "$TT_MODDIR/common.sh"; state_set x 1 )
    check "新建文件不是人人可写" '[ "$(ls -l "$STATE" | cut -c9)" = "-" ]'
    check "state_set 覆盖不重复" '[ "$(grep -c ^last_exit= "$STATE")" = 1 ]'
    )

echo "[common] 生成中 / 冻结 / 网络"
newmod 2; ( load
    FAKE_GEN=1; check "生成中" 'generating'
    FAKE_GEN=0; check "没生成" '! generating'
    check "没冻结" '[ -z "$(frozen_by 111 10447)" ]'
    mkdir -p "$CG_ROOT/uid_10447/pid_111"; printf 'populated 1\nfrozen 1\n' > "$CG_ROOT/uid_10447/pid_111/cgroup.events"
    check "Android 冻结" '[ "$(frozen_by 111 10447)" = Android ]'
    printf 'populated 1\nfrozen 0\n' > "$CG_ROOT/uid_10447/pid_111/cgroup.events"; printf '5\n111\n' > "$OPLUS_FROZEN"
    check "ColorOS 冻结" '[ "$(frozen_by 111 10447)" = ColorOS ]'
    check "ColorOS 不误认 1111" '[ -z "$(frozen_by 11 10447)" ]'
    check "网络没限制" '[ "$(net_effective 10447)" = NONE ]'
    check "网络被限制" '[ "$(net_effective 10999)" = APP_BACKGROUND ]'
    )

echo "[service] ensure：记原值、补设置、不再 set-inactive"
newmod 3; ( load
    FAKE_WL=no FAKE_RAIB=ignore FAKE_BUCKET=40
    ensure
    check "prior 白名单" 'grep -qx whitelist=no "$PRIOR"'
    check "prior 后台运行" 'grep -qx RUN_ANY_IN_BACKGROUND=ignore "$PRIOR"'
    check "prior 分组" 'grep -qx bucket=40 "$PRIOR"'
    check "加白名单" 'calls | grep -q "whitelist +com.tauritavern.client"'
    check "允许后台" 'calls | grep -q "appops set com.tauritavern.client RUN_ANY_IN_BACKGROUND allow"'
    check "分组拉回活跃" 'calls | grep -q "am set-standby-bucket com.tauritavern.client active"'
    check "不再 set-inactive" '! calls | grep -q set-inactive'
    check "uid" '[ "$uid" = 10447 ]'
    : > "$CALLS"; FAKE_WL=yes FAKE_RAIB=allow FAKE_BUCKET=5
    ensure
    check "都对时不改任何东西" '[ ! -s "$CALLS" ]'
    check "原值只记一次" '[ "$(grep -c ^whitelist= "$PRIOR")" = 1 ]'
    FAKE_INSTALLED=0; ensure; r=$?
    check "没装 TT 返回 1" '[ $r = 1 ]'
    check "没装 TT 记日志" 'grep -q "没装" "$LOG"'
    )

echo "[service] tick：生成中进程没了 → 记原因 + 通知"
newmod 4; ( load
    FAKE_WL=yes FAKE_RAIB=allow
    state_set last_exit "2026-09-26 12:17:18.751"
    FAKE_EXIT=$T/none; FAKE_PIDS=26636 FAKE_GEN=1 FAKE_NOW=1000; tick
    check "生成中没通知" '! calls | grep -q notification'
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=1015; tick
    check "日志记退出原因" 'grep -q "TT（26636）12:29:36.672 退出：被强制停止" "$LOG"'
    check "发了通知" 'calls | grep -q "notification post -S bigtext -t TT 生成回复到一半进程没了 claudemax_tt_keepalive 原因：被强制停止"'
    check "以 shell 身份发" 'calls | grep -q "^su 2000 -c"'
    check "last_exit 前进" '[ "$(state_get last_exit)" = "2026-09-26 12:29:36.672" ]'
    : > "$CALLS"; FAKE_NOW=1075; tick
    check "不重复记" '[ "$(grep -c "退出：" "$LOG")" = 1 ]'
    check "不重复通知" '! calls | grep -q notification'
    )

echo "[service] tick：生成中进程没了但系统没记原因"
newmod 5; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none
    state_set last_exit 0
    FAKE_PIDS=500 FAKE_GEN=1 FAKE_NOW=1000; tick
    FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=1015; tick
    check "日志" 'grep -q "TT（500）生成回复时进程没了，系统没记原因" "$LOG"'
    check "通知" 'calls | grep -q "原因：系统没记原因"'
    )

echo "[service] tick：空闲时被杀只记日志"
newmod 6; ( load
    FAKE_WL=yes FAKE_RAIB=allow
    state_set last_exit "2026-09-26 12:17:18.751"
    FAKE_EXIT=$T/none FAKE_PIDS=26636 FAKE_NOW=1000; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_NOW=1015; tick
    check "记了" 'grep -q "退出：被强制停止" "$LOG"'
    check "没通知" '! calls | grep -q notification'
    )

echo "[service] tick：冻结记录，生成中只通知一次"
newmod 7; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    ev=$CG_ROOT/uid_10447/pid_700; mkdir -p "$ev"; ev=$ev/cgroup.events
    echo "frozen 0" > "$ev"; FAKE_PIDS=700 FAKE_GEN=0 FAKE_NOW=1000; tick
    echo "frozen 1" > "$ev"; FAKE_NOW=1015; tick
    check "空闲冻结记日志" 'grep -q "TT（700）被 Android 冻结了$" "$LOG"'
    check "空闲冻结不通知" '! calls | grep -q notification'
    echo "frozen 0" > "$ev"; FAKE_NOW=1045; tick
    check "解冻记时长" 'grep -q "TT（700）解冻，冻了约 30 秒" "$LOG"'
    FAKE_GEN=1; echo "frozen 1" > "$ev"; FAKE_NOW=1060; tick
    check "生成中冻结标出来" 'grep -q "冻结了（正在生成回复）" "$LOG"'
    check "生成中冻结通知" '[ "$(calls | grep -c "^cmd notification")" = 1 ]'
    echo "frozen 0" > "$ev"; FAKE_NOW=1075; tick
    echo "frozen 1" > "$ev"; FAKE_NOW=1090; tick
    check "同一次生成不重复通知" '[ "$(calls | grep -c "^cmd notification")" = 1 ]'
    FAKE_GEN=0; echo "frozen 0" > "$ev"; FAKE_NOW=1105; tick
    FAKE_GEN=1; echo "frozen 1" > "$ev"; FAKE_NOW=1120; tick
    check "下一次生成再通知" '[ "$(calls | grep -c "^cmd notification")" = 2 ]'
    )

echo "[service] 不再写 /proc"
check "没有往 /proc 写东西" '! grep -nE ">[[:space:]]*\"?(/proc|\\\$f)" "$MOD"/*.sh'

echo "[action] 状态输出"
newmod 8
mkdir -p "$CG_ROOT/uid_10447/pid_26636"; echo "frozen 0" > "$CG_ROOT/uid_10447/pid_26636/cgroup.events"
echo "$(/bin/date '+%m-%d') 10:00:00 TT（1）被 Android 冻结了" > "$TT_MODDIR/service.log"
echo "$(/bin/date '+%m-%d') 10:01:00 TT（1）被 Android 冻结了（正在生成回复）" >> "$TT_MODDIR/service.log"
out=$(FAKE_WL=yes FAKE_RAIB=allow FAKE_BUCKET=5 FAKE_PIDS=26636 FAKE_GEN=1 sh "$TT_MODDIR/action.sh" 2>&1)
check "白名单" 'echo "$out" | grep -q "电池优化白名单：在"'
check "后台运行" 'echo "$out" | grep -q "后台运行：allow"'
check "分组" 'echo "$out" | grep -q "待机分组：5（豁免"'
check "网络" 'echo "$out" | grep -q "网络：没被限制"'
check "生成中" 'echo "$out" | grep -q "正在生成回复：是"'
check "进程" 'echo "$out" | grep -q "进程 26636：没冻结"'
check "冻结次数" 'echo "$out" | grep -q "今天被冻结：2 次（生成中 1 次）"'
check "最近三次退出" '[ "$(echo "$out" | grep -c "退出：")" = 3 ]'
check "action 不改任何东西" '[ ! -s "$CALLS" ]'
out=$(FAKE_PIDS="" sh "$TT_MODDIR/action.sh" 2>&1)
check "没运行" 'echo "$out" | grep -q "TT 没在运行"'
check "没有日志时次数为 0" 'rm -f "$TT_MODDIR/service.log"; FAKE_PIDS="" sh "$TT_MODDIR/action.sh" | grep -q "今天被冻结：0 次（生成中 0 次）"'

echo "[uninstall] 还原"
wait_calls() { i=0; while [ $i -lt 50 ] && [ "$(wc -l < "$CALLS" | tr -d " ")" -lt "$1" ]; do /bin/sleep 0.1; i=$((i + 1)); done; }
newmod 9; printf 'whitelist=no\nRUN_IN_BACKGROUND=ignore\nRUN_ANY_IN_BACKGROUND=default\nbucket=40\n' > "$TT_MODDIR/prior.txt"
UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; wait_calls 4
check "撤白名单" 'calls | grep -q "whitelist -com.tauritavern.client"'
check "还原 RUN_IN_BACKGROUND" 'calls | grep -q "RUN_IN_BACKGROUND ignore"'
check "还原 RUN_ANY_IN_BACKGROUND" 'calls | grep -q "RUN_ANY_IN_BACKGROUND default"'
check "还原分组" 'calls | grep -q "set-standby-bucket com.tauritavern.client rare"'
newmod 10; printf 'whitelist=yes\nRUN_IN_BACKGROUND=allow\nRUN_ANY_IN_BACKGROUND=allow\n' > "$TT_MODDIR/prior.txt"
UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; wait_calls 2
check "原来就在白名单就留着" '! calls | grep -q whitelist'
check "没改过分组就不动" '! calls | grep -q standby'
check "原值 allow 就还原成 allow" '[ "$(calls | grep -c " allow$")" = 2 ]'
newmod 11; UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; wait_calls 3
check "没有 prior 按默认" 'calls | grep -q "whitelist -com" && [ "$(calls | grep -c " default$")" = 2 ]'

echo "[customize] 升级时带上原值、状态、日志"
newmod 12; OLD=$T/old; mkdir -p "$OLD" "$T/new"
echo whitelist=yes > "$OLD/prior.txt"; echo last_exit=x > "$OLD/state.txt"; echo l > "$OLD/service.log"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "prior" 'grep -qx whitelist=yes "$T/new/prior.txt"'
check "state" 'grep -qx last_exit=x "$T/new/state.txt"'
check "log" '[ -f "$T/new/service.log" ]'
rm -rf "$T/new" "$OLD/prior.txt"; mkdir -p "$T/new"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "从 1.0/1.1 升级按默认" 'grep -qx whitelist=no "$T/new/prior.txt"'
rm -rf "$T/new" "$OLD"; mkdir -p "$T/new"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "全新安装不写 prior" '[ ! -f "$T/new/prior.txt" ]'

pass=$(cat "$T/pass" 2>/dev/null | wc -l | tr -d " "); failn=$(cat "$T/fail" 2>/dev/null | wc -l | tr -d " ")
echo "通过 $pass，失败 $failn"
[ "$failn" = 0 ]
