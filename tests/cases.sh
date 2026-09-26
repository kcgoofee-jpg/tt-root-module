# 单元测试的用例：由 tests/run.sh 用 dash / sh / ksh 各跑一遍（手机上是 busybox ash 或 mksh）。
# 用 PATH 里的假命令代替 dumpsys / cmd / am / pm / pidof / su / getprop / stat / date / sleep / logcat，
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
export TZ=UTC
REAL_DATE=$(command -v date); REAL_SLEEP=$(command -v sleep); SH=$(command -v sh)
export REAL_DATE
# run.sh 给了 TEST_BIN 就共用（macOS 第一次执行新文件要扫描，约 0.3 秒一个）
BIN=${TEST_BIN:-$T/bin}; mkdir -p "$BIN"
mk() { printf '#!%s\n%s\n' "$SH" "$2" > "$BIN/$1.new"
       if cmp -s "$BIN/$1.new" "$BIN/$1"; then rm -f "$BIN/$1.new"; else mv "$BIN/$1.new" "$BIN/$1"; chmod +x "$BIN/$1"; fi; }
mk dumpsys 'case "$1 ${2:-}" in
  "deviceidle whitelist")
    case "${3:-}" in +*|-*) echo "dumpsys deviceidle whitelist $3" >> "$CALLS" ;;
      *) [ "$FAKE_WL" = yes ] && echo "user,com.tauritavern.client,10447"; echo "system,com.android.shell,2000" ;; esac ;;
  "activity services") if [ "$FAKE_GEN" = 1 ]; then cat "$FIX/services-generating.txt"; else cat "$FIX/services-idle.txt"; fi ;;
  "activity exit-info") cat "$FAKE_EXIT" 2>/dev/null ;;
  "package com.tauritavern.client") echo "    versionName=$FAKE_VER" ;;
  "netpolicy ") sed "s/effective=NONE/effective=$FAKE_NET/" "$FIX/netpolicy.txt" ;;
esac'
mk cmd 'case "$1 $2" in
  "appops get") echo "$4: $FAKE_RAIB" ;;
  "appops set") echo "cmd $*" >> "$CALLS" ;;
  "notification post") echo "cmd $*" >> "$CALLS" ;;
esac'
mk am 'case "$1" in get-standby-bucket) echo "$FAKE_BUCKET" ;; *) echo "am $*" >> "$CALLS" ;; esac'
mk logcat 'cat "$FAKE_LOGCAT" 2>/dev/null'
mk pm 'case "$1" in
  path) [ "$FAKE_INSTALLED" = 1 ] ;;
  list) [ -n "$FAKE_PMUID" ] && echo "package:com.tauritavern.client uid:$FAKE_PMUID" ;;
esac'
mk pidof 'echo "$FAKE_PIDS"'
mk su 'echo "su $*" >> "$CALLS"; [ "$1" = 2000 ] && [ "$2" = -c ] && eval "$3"'
mk getprop 'case "$1" in sys.user.0.ce_available) echo "$FAKE_CE" ;; *) echo 1 ;; esac'
mk stat 'echo 10447'
mk sleep ':'
# date：永远是 FAKE_NOW 那一刻；支持 date -d @秒数（Mac 的 date 用 -r，手机上的用 -d）
mk date '[ "${1:-}" = +%s ] && { echo "$FAKE_NOW"; exit; }
t=$FAKE_NOW; [ "${1:-}" = -d ] && { t=${2#@}; shift 2; }
if "$REAL_DATE" -r 0 +%s >/dev/null 2>&1; then exec "$REAL_DATE" -r "$t" "$@"; else exec "$REAL_DATE" -d "@$t" "$@"; fi'
export PATH="$BIN:$PATH" FIX CALLS=$T/calls
export FAKE_WL=no FAKE_GEN=0 FAKE_EXIT=$FIX/exit-info.txt FAKE_RAIB=default FAKE_BUCKET=5 FAKE_INSTALLED=1 FAKE_PIDS="" FAKE_NOW=1000
export FAKE_VER=2.3.0 FAKE_NET=NONE FAKE_LOGCAT=/nonexistent FAKE_CE=true FAKE_PMUID=""
DAY0=86400   # 1970-01-02 00:00 UTC，按天算的用例从这里开始

newmod() {   # 新建一个空的模块目录（放进脚本），设好环境
    D=$T/mod$1; rm -rf "$D"; mkdir -p "$D"; cp "$MOD"/*.sh "$MOD/module.prop" "$D/"
    export TT_MODDIR=$D CG_ROOT=$T/cg$1 OPLUS_FROZEN=$T/oplus$1 TT_DATA=$T/data$1 BACKUP_DIR=$T/backup$1
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

echo "[1.4] 开关、统计、日志按天清理"
newmod 20; ( load
    check "没写开关用默认" '[ "$(cfg backup 1)" = 1 ]'
    printf '# 注释 backup=0\nbackup=0\nauto_reopen=0  # 行尾注释\n' > "$CONFIG"
    check "读开关" '[ "$(cfg backup 1)" = 0 ]'
    check "行尾注释" '[ "$(cfg auto_reopen 1)" = 0 ]'
    echo "$DEFAULT_CONFIG" > "$CONFIG"
    check "默认 config 是全开" '[ "$(cfg backup 0)$(cfg backup_keep 0)$(cfg auto_reopen 0)$(cfg notify 0)" = 1711 ]'
    FAKE_NOW=$DAY0
    check "没统计时是 0" '[ "$(stat_get 3)" = 0 ]'
    stat_add 2 1; stat_add 3 40; stat_add 3 5
    check "累加" '[ "$(stat_get 2)" = 1 ] && [ "$(stat_get 3)" = 45 ]'
    check "一行七列" '[ "$(cat "$STATS")" = "01-02 1 45 0 0 0 0" ]'
    i=1; while [ $i -le 10 ]; do FAKE_NOW=$((DAY0 + i * 86400)); stat_add 4 1; i=$((i + 1)); done
    check "统计只留 8 天" '[ "$(wc -l < "$STATS" | tr -d " ")" = 8 ]'
    FAKE_NOW=$((DAY0 + 9 * 86400))
    check "最近几天" '[ "$(recent_days 3)" = "01-11 01-10 01-09" ]'
    printf '01-03 a\n01-04 b\n01-05 c\n01-11 d\n' > "$LOG"
    prune_log
    check "日志只留 7 天" '[ "$(cut -c1-5 "$LOG" | tr "\n" " ")" = "01-05 01-11 " ]'
    check "human_secs" '[ "$(human_secs 3900)" = "1 小时 5 分" ] && [ "$(human_secs 59)" = "0 分" ] && [ "$(human_secs "")" = "0 分" ]'
    )

echo "[1.4] 生成统计、5 小时提醒、网络提醒"
newmod 21; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    FAKE_PIDS=800 FAKE_GEN=0 FAKE_NOW=$DAY0; tick
    FAKE_GEN=1 FAKE_NOW=$((DAY0 + 15)); tick
    FAKE_NOW=$((DAY0 + 30)); tick
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 60)); tick
    check "一次生成 45 秒" '[ "$(stat_get 2)" = 1 ] && [ "$(stat_get 3)" = 45 ]'
    check "没到 5 小时不提醒" '! calls | grep -q "^cmd notification"'
    stat_add 3 17950
    FAKE_GEN=1 FAKE_NOW=$((DAY0 + 100)); tick
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 130)); tick
    check "到 5 小时提醒" 'calls | grep -q "^cmd notification.*今天生成已累计 5 小时"'
    FAKE_GEN=1 FAKE_NOW=$((DAY0 + 200)); tick
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 230)); tick
    check "一天只提醒一次" '[ "$(calls | grep -c "^cmd notification.*今天生成已累计")" = 1 ]'
    : > "$CALLS"
    FAKE_NET=APP_BACKGROUND FAKE_GEN=1 FAKE_NOW=$((DAY0 + 300)); tick
    FAKE_NOW=$((DAY0 + 315)); tick
    check "生成中网络被限制记日志" 'grep -q "网络被限制（APP_BACKGROUND）" "$LOG"'
    check "网络提醒一次" '[ "$(calls | grep -c "^cmd notification.*网络被系统限制")" = 1 ]'
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 330)); tick
    : > "$CALLS"; FAKE_NET=APP_BACKGROUND
    FAKE_NOW=$((DAY0 + 345)); tick
    check "不在生成时不管网络" '! calls | grep -q notification'
    )

echo "[1.4] 生成中被系统杀：自动重开、谁动的手、统计"
newmod 22; ( load
    FAKE_WL=yes FAKE_RAIB=allow; state_set last_exit "2026-09-26 12:14:07.288"
    echo "09-26 12:17:18.700  1000  2000 I athena : kill pid 26440 reason=bg_clean" > "$T/logcat"; FAKE_LOGCAT=$T/logcat
    FAKE_EXIT=$T/none FAKE_PIDS=26440 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    check "重开 TT" 'calls | grep -q "^am start -n com.tauritavern.client/.MainActivity"'
    check "日志：已自动重新打开" 'grep -q "已自动重新打开 TT" "$LOG"'
    check "通知里说了" 'calls | grep -q "^cmd notification.*内存不够.*已自动重新打开"'
    check "记下谁动的手" 'grep -q "  系统日志：.*athena : kill pid 26440" "$LOG"'
    check "被系统结束 +1，强制停止 +1" '[ "$(stat_get 6)" = 1 ] && [ "$(stat_get 7)" = 1 ]'
    check "生成也算一次" '[ "$(stat_get 2)" = 1 ]'
    )
newmod 23; ( load
    FAKE_WL=yes FAKE_RAIB=allow; state_set last_exit "2026-09-26 12:17:18.751"
    FAKE_EXIT=$T/none FAKE_PIDS=26636 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    check "强制停止不重开" '! calls | grep -q "^am start"'
    check "但通知" 'calls | grep -q "^cmd notification.*被强制停止"'
    )
newmod 24; ( load
    FAKE_WL=yes FAKE_RAIB=allow; echo auto_reopen=0 > "$CONFIG"; state_set last_exit "2026-09-26 12:14:07.288"
    FAKE_EXIT=$T/none FAKE_PIDS=26440 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    check "关了自动重开就不重开" '! calls | grep -q "^am start"'
    )
newmod 25; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    FAKE_PIDS=1 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    FAKE_PIDS=2 FAKE_GEN=1 FAKE_NOW=$((DAY0 + 30)); tick
    FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 45)); tick
    check "10 分钟内只重开一次" '[ "$(calls | grep -c "^am start")" = 1 ]'
    echo notify=0 > "$CONFIG"; : > "$CALLS"
    FAKE_PIDS=3 FAKE_GEN=1 FAKE_NOW=$((DAY0 + 900)); tick
    FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 915)); tick
    check "notify=0 不发通知" '! calls | grep -q notification'
    check "notify=0 照样记日志" '[ "$(grep -c "系统没记原因" "$LOG")" = 3 ]'
    )

echo "[1.4] TT 升级、重装"
newmod 26; ( load
    FAKE_PMUID=10500
    check "uid 先用 pm 查（没解锁也能查到）" '[ "$(app_uid)" = 10500 ]'
    FAKE_PMUID=""
    check "pm 查不到再用 stat" '[ "$(app_uid)" = 10447 ]'
    FAKE_WL=yes FAKE_RAIB=allow
    ensure
    check "第一次只记下不报" '! grep -q "TT 版本" "$LOG" && [ "$(state_get tt_version)" = 2.3.0 ]'
    FAKE_VER=2.4.0; ensure
    check "升级记一行" 'grep -q "TT 版本 2.3.0 → 2.4.0" "$LOG"'
    state_set tt_uid 10001; ensure
    check "重装记一行" 'grep -q "TT 重装过（uid 10001 → 10447）" "$LOG"'
    )

echo "[1.4] 每天备份"
newmod 27; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    U=$TT_DATA/default-user; mkdir -p "$U/chats/角色 A" "$U/backups" "$U/thumbnails" "$U/OpenAI Settings"
    echo hi > "$U/chats/角色 A/1.jsonl"; echo '{"api_key":"sk-SECRET"}' > "$U/secrets.json"
    echo old > "$U/backups/x"; mkdir -p "$U/.staging"; echo w > "$U/.staging/w"; echo t > "$U/thumbnails/t"; echo s > "$U/settings.json"; echo p > "$U/OpenAI Settings/p.json"
    FAKE_CE=false FAKE_PIDS=9 FAKE_GEN=0 FAKE_NOW=$((DAY0 - 100)); tick
    check "开机后没解锁不备份" '[ -z "$(ls "$BACKUP_DIR" 2>/dev/null)" ]'
    check "没解锁不算失败" '! grep -q "备份 TT 数据失败" "$LOG" 2>/dev/null && [ -z "$(state_get backup_try)" ]'
    FAKE_CE=true
    FAKE_PIDS=9 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    check "生成中不备份" '[ -z "$(ls "$BACKUP_DIR" 2>/dev/null)" ]'
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    f=$(ls "$BACKUP_DIR"/tt-default-user-*.tar.gz 2>/dev/null | head -1)
    check "备份出来了" '[ -n "$f" ]'
    list=$(LC_ALL=en_US.UTF-8 tar -tzf "$f" 2>/dev/null)   # Mac 的 tar 在 C 语言环境下会把中文转义
    check "有聊天（带空格和中文的路径）" 'echo "$list" | grep -q "default-user/chats/角色 A/1.jsonl"'
    check "有设置" 'echo "$list" | grep -q "default-user/settings.json" && echo "$list" | grep -q "OpenAI Settings/p.json"'
    check "没有 API 密钥" '! echo "$list" | grep -q secrets && ! tar -xzOf "$f" 2>/dev/null | grep -q sk-SECRET'
    check "没有 TT 自己的备份和缩略图" '! echo "$list" | grep -qE "default-user/(backups|thumbnails|\.staging)/"'
    check "没留半截文件" '[ -z "$(ls -a "$BACKUP_DIR" | grep part)" ]'
    check "记日志（文件名和大小）" 'grep -q "已备份 TT 数据：tt-default-user-19700102-0000.tar.gz（[0-9][0-9]* KB" "$LOG"'
    FAKE_NOW=$((DAY0 + 3600)); tick
    check "一天只备份一次" '[ "$(ls "$BACKUP_DIR" | wc -l | tr -d " ")" = 1 ]'
    echo backup_keep=2 > "$CONFIG"
    for k in 1 2 3; do FAKE_NOW=$((DAY0 + 15 + k * 86400)); tick; done
    check "只留 2 份，删最旧的" '[ "$(ls "$BACKUP_DIR" | tr "\n" " ")" = "tt-default-user-19700104-0000.tar.gz tt-default-user-19700105-0000.tar.gz " ]'
    echo backup=0 > "$CONFIG"; FAKE_NOW=$((DAY0 + 15 + 5 * 86400)); tick
    check "关了就不备份" '[ "$(ls "$BACKUP_DIR" | wc -l | tr -d " ")" = 2 ]'
    )
newmod 28; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "没有数据时记失败" 'grep -q "备份 TT 数据失败，1 小时后再试" "$LOG"'
    FAKE_NOW=$((DAY0 + 600)); tick
    check "1 小时内不重试" '[ "$(grep -c "备份 TT 数据失败" "$LOG")" = 1 ]'
    FAKE_NOW=$((DAY0 + 3700)); tick
    check "1 小时后重试" '[ "$(grep -c "备份 TT 数据失败" "$LOG")" = 2 ]'
    )

echo "[service] 不再写 /proc"
check "没有往 /proc 写东西" '! grep -nE ">[[:space:]]*\"?(/proc|\\\$f)" "$MOD"/*.sh'

echo "[action] 状态输出"
newmod 8
mkdir -p "$CG_ROOT/uid_10447/pid_26636"; echo "frozen 0" > "$CG_ROOT/uid_10447/pid_26636/cgroup.events"
echo "01-01 10:00:00 TT（26636）12:29:36.672 退出：被强制停止（…）［USER REQUESTED / FORCE STOP］" > "$TT_MODDIR/service.log"
echo "01-01 10:01:00 TT（1）12:00:00.000 退出：内存不够，被系统回收［LOW MEMORY］" >> "$TT_MODDIR/service.log"
echo "01-01 10:02:00 TT（2）12:00:00.000 退出：内存不够，被系统回收［LOW MEMORY］" >> "$TT_MODDIR/service.log"
echo "01-01 2 330 3 1 2 1" > "$TT_MODDIR/stats.txt"
out=$(FAKE_WL=yes FAKE_RAIB=allow FAKE_BUCKET=5 FAKE_PIDS=26636 FAKE_GEN=1 sh "$TT_MODDIR/action.sh" 2>&1)
check "白名单" 'echo "$out" | grep -q "电池优化白名单：在"'
check "后台运行" 'echo "$out" | grep -q "后台运行：allow"'
check "分组" 'echo "$out" | grep -q "待机分组：5（豁免"'
check "网络" 'echo "$out" | grep -q "网络：没被限制"'
check "生成中" 'echo "$out" | grep -q "正在生成回复：是"'
check "进程" 'echo "$out" | grep -q "进程 26636：没冻结"'
check "今天统计" 'echo "$out" | grep -q "今天：生成 2 次，共 5 分；冻结 3 次（生成中 1 次）；被系统结束 2 次，被强制停止 1 次"'
check "7 天表" 'echo "$out" | grep -q "^01-01 .* 2 .*5 分 .*3(1)"'
check "退出原因汇总" 'echo "$out" | grep -q "2 内存不够，被系统回收$"'
check "汇总里强制停止不带括号" 'echo "$out" | grep -q "1 被强制停止$"'
check "备份一栏" 'echo "$out" | grep -q "现有 0 份"'
check "开关一栏" 'echo "$out" | grep -q "备份 1，自动重开 1，通知 1"'
check "最近三次退出" '[ "$(echo "$out" | grep -c "^TT（.*退出：")" = 3 ]'
check "action 不改任何东西" '[ ! -s "$CALLS" ]'
out=$(FAKE_PIDS="" sh "$TT_MODDIR/action.sh" 2>&1)
check "没运行" 'echo "$out" | grep -q "TT 没在运行"'
check "没有统计时为 0" 'rm -f "$TT_MODDIR/service.log" "$TT_MODDIR/stats.txt"; FAKE_PIDS="" sh "$TT_MODDIR/action.sh" | grep -q "今天：生成 0 次，共 0 分；冻结 0 次"'
check "没有统计时的提示" 'FAKE_PIDS="" sh "$TT_MODDIR/action.sh" | grep -q "还没有统计"'
check "关掉备份" 'echo backup=0 > "$TT_MODDIR/config.txt"; FAKE_PIDS="" sh "$TT_MODDIR/action.sh" | grep -q "已关（config.txt 里 backup=0）"'

echo "[uninstall] 还原"
wait_calls() { i=0; while [ $i -lt 50 ] && [ "$(wc -l < "$CALLS" | tr -d " ")" -lt "$1" ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done; }
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
echo backup=0 > "$OLD/config.txt"; echo "01-01 1 2 3 4 5 6" > "$OLD/stats.txt"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "prior" 'grep -qx whitelist=yes "$T/new/prior.txt"'
check "state" 'grep -qx last_exit=x "$T/new/state.txt"'
check "log" '[ -f "$T/new/service.log" ]'
check "开关" 'grep -qx backup=0 "$T/new/config.txt"'
check "统计" '[ -f "$T/new/stats.txt" ]'
rm -rf "$T/new" "$OLD/prior.txt"; mkdir -p "$T/new"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "从 1.0/1.1 升级按默认" 'grep -qx whitelist=no "$T/new/prior.txt"'
rm -rf "$T/new" "$OLD"; mkdir -p "$T/new"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD; . "$MOD/customize.sh" )
check "全新安装不写 prior" '[ ! -f "$T/new/prior.txt" ]'

pass=$(cat "$T/pass" 2>/dev/null | wc -l | tr -d " "); failn=$(cat "$T/fail" 2>/dev/null | wc -l | tr -d " ")
echo "通过 $pass，失败 $failn"
[ "$failn" = 0 ]
