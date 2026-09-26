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
mk dumpsys '[ -n "${DS_LOG:-}" ] && echo "$*" >> "$DS_LOG"
case "$1 ${2:-}" in
  "deviceidle whitelist")
    case "${3:-}" in +*|-*) echo "dumpsys deviceidle whitelist $3" >> "$CALLS" ;;
      *) [ "$FAKE_WL" = yes ] && echo "user,com.tauritavern.client,10447"; echo "system,com.android.shell,2000" ;; esac ;;
  "activity services") if [ "$FAKE_GEN" = 1 ]; then cat "$FIX/services-generating.txt"; else cat "$FIX/services-idle.txt"; fi ;;
  "activity exit-info") cat "$FAKE_EXIT" 2>/dev/null ;;
  "package com.tauritavern.client") echo "    versionName=$FAKE_VER" ;;
  "webviewupdate ") echo "  Current WebView package (name, version): (com.google.android.webview, $FAKE_WV)" ;;
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
  list) [ -n "$FAKE_PMUID" ] && echo "package:com.tauritavern.client uid:$FAKE_PMUID"
        for p in ${FAKE_PKGS:-}; do echo "package:$p"; done ;;
esac'
mk pidof 'echo "$FAKE_PIDS"'
mk su 'echo "su $*" >> "$CALLS"; [ "$1" = 2000 ] && [ "$2" = -c ] && eval "$3"'
mk getprop 'case "$1" in sys.user.0.ce_available) echo "$FAKE_CE" ;; *) echo 1 ;; esac'
mk stat 'echo 10447'
mk sleep ':'
mk settings 'case "$2 $3" in "global low_power") echo "${FAKE_LOWPOWER:-0}" ;; *) echo null ;; esac'
# df：设了 FAKE_FREE（KB）就假装只剩这么多，否则用真的
mk df 'if [ -n "${FAKE_FREE:-}" ]; then echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "/dev/x 100000000 1 $FAKE_FREE 1% /"; else exec /bin/df "$@"; fi'
# date：永远是 FAKE_NOW 那一刻；支持 date -d @秒数（Mac 的 date 用 -r，手机上的用 -d）
mk date '[ "${1:-}" = +%s ] && { echo "$FAKE_NOW"; exit; }
t=$FAKE_NOW; [ "${1:-}" = -d ] && { t=${2#@}; shift 2; }
if "$REAL_DATE" -r 0 +%s >/dev/null 2>&1; then exec "$REAL_DATE" -r "$t" "$@"; else exec "$REAL_DATE" -d "@$t" "$@"; fi'
export PATH="$BIN:$PATH" FIX CALLS=$T/calls
export FAKE_WL=no FAKE_GEN=0 FAKE_EXIT=$FIX/exit-info.txt FAKE_RAIB=default FAKE_BUCKET=5 FAKE_INSTALLED=1 FAKE_PIDS="" FAKE_NOW=1000
export FAKE_VER=2.3.0 FAKE_NET=NONE FAKE_LOGCAT=/nonexistent FAKE_CE=true FAKE_PMUID="" FAKE_WV=153.0.8010.36
DAY0=86400   # 1970-01-02 00:00 UTC，按天算的用例从这里开始

newmod() {   # 新建一个空的模块目录（放进脚本），设好环境
    D=$T/mod$1; rm -rf "$D"; mkdir -p "$D"; cp "$MOD"/*.sh "$MOD"/*.awk "$MOD/module.prop" "$D/"
    export TT_MODDIR=$D TT_GUARD_DIR=$D CG_ROOT=$T/cg$1 OPLUS_FROZEN=$T/oplus$1 TT_DATA=$T/data$1 PRIVATE_BK=$T/backup$1 SHARED_BK=$T/shared$1 \
           TT_LOGS=$T/ttlogs$1 ANR_DIR=$T/anr$1 BATTERY_TEMP=$T/temp$1 \
           BATTERY_DIR=$T/bat$1 ADB_DIR=$T/adb$1
    : > "$CALLS"
    BACKUP_DIR=$PRIVATE_BK   # 默认 backup_private=1
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
    check "强制停止翻成人话" 'case "$l" in "TT（26636）12:29:36.672 退出：强制停止"*"FORCE STOP"*) true ;; *) false ;; esac'
    check "内存不足" 'case "$(exit_line "$(echo "$r" | sed -n 2p)")" in *"内存不足"*) true ;; *) false ;; esac'
    check "被信号杀" 'case "$(exit_line "$(echo "$r" | sed -n 3p)")" in *"厂商后台清理"*"oplus athena kill"*) true ;; *) false ;; esac'
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
    check "日志记退出原因" 'grep -q "TT（26636）12:29:36.672 退出：强制停止" "$LOG"'
    check "发了通知" 'calls | grep -q "notification post -S bigtext -t TauriTavern 在生成中退出 claudemax_tt_keepalive 原因：强制停止"'
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
    check "记了" 'grep -q "退出：强制停止" "$LOG"'
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
    FAKE_GEN=1; FAKE_NOW=1052; tick              # 先看到「在生成」
    echo "frozen 1" > "$ev"; FAKE_NOW=1060; tick # 再被冻结
    check "生成中冻结标出来" 'grep -q "冻结了（正在生成回复）" "$LOG"'
    check "生成中冻结通知" '[ "$(calls | grep -c "^cmd notification")" = 1 ]'
    echo "frozen 0" > "$ev"; FAKE_NOW=1075; tick
    echo "frozen 1" > "$ev"; FAKE_NOW=1090; tick
    check "同一次生成不重复通知" '[ "$(calls | grep -c "^cmd notification")" = 1 ]'
    FAKE_GEN=0; echo "frozen 0" > "$ev"; FAKE_NOW=1105; tick
    FAKE_GEN=1; FAKE_NOW=1112; tick
    echo "frozen 1" > "$ev"; FAKE_NOW=1120; tick
    check "下一次生成再通知" '[ "$(calls | grep -c "^cmd notification")" = 2 ]'
    FAKE_GEN=0; FAKE_NOW=1135; tick; FAKE_NOW=1150; tick
    DS_LOG=$T/ds7; export DS_LOG; : > "$DS_LOG"
    FAKE_NOW=1165; tick
    check "省电：空闲冻结时不去问系统在不在生成" '! grep -q "^activity services" "$DS_LOG"'
    echo "frozen 0" > "$ev"; FAKE_NOW=1180; tick
    check "解冻后照常检查" 'grep -q "^activity services" "$DS_LOG"'
    unset DS_LOG
    )

echo "[1.4] 开关、统计、日志按天清理"
newmod 20; ( load
    check "没写开关用默认" '[ "$(cfg backup 1)" = 1 ]'
    printf '# 注释 backup=0\nbackup=0\nauto_reopen=0  # 行尾注释\n' > "$CONFIG"
    check "读开关" '[ "$(cfg backup 1)" = 0 ]'
    check "行尾注释" '[ "$(cfg auto_reopen 1)" = 0 ]'
    echo "$DEFAULT_CONFIG" > "$CONFIG"
    check "默认 config" '[ "$(cfg backup 0)$(cfg backup_hours 0)$(cfg backup_private 0)$(cfg keep_days 0)$(cfg auto_reopen 0)$(cfg notify 0)" = 161711 ]'
    printf '# 备份留几份\nbackup_keep=3\nbackup=1\n' > "$CONFIG"; config_fill
    check "旧的 backup_keep 换成 keep_days" '! grep -q backup_keep "$CONFIG" && grep -qx keep_days=3 "$CONFIG" && ! grep -q "备份留几份" "$CONFIG"'
    check "config_set 改数字" 'config_set keep_weeks 9 && grep -qx keep_weeks=9 "$CONFIG"'
    check "config_set 不认识的开关" '! config_set evil 1 && ! grep -q evil "$CONFIG"'
    check "config_set 不是数字" '! config_set notify "1;rm" && grep -qx notify=1 "$CONFIG"'
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
    check "到 5 小时提醒" 'calls | grep -q "^cmd notification.*今日生成时长已达 5 小时"'
    FAKE_GEN=1 FAKE_NOW=$((DAY0 + 200)); tick
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 230)); tick
    check "一天只提醒一次" '[ "$(calls | grep -c "^cmd notification.*今日生成时长已达")" = 1 ]'
    : > "$CALLS"
    FAKE_NET=APP_BACKGROUND FAKE_GEN=1 FAKE_NOW=$((DAY0 + 300)); tick
    FAKE_NOW=$((DAY0 + 315)); tick
    check "生成中网络被限制记日志" 'grep -q "网络被限制（APP_BACKGROUND）" "$LOG"'
    check "网络提醒一次" '[ "$(calls | grep -c "^cmd notification.*在生成中网络受限")" = 1 ]'
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
    check "通知里说了" 'calls | grep -q "^cmd notification.*在生成中退出.*内存不足.*已自动重新打开"'
    check "记下谁动的手" 'grep -q "  系统日志：.*athena : kill pid 26440" "$LOG"'
    check "被系统结束 +1，强制停止 +1" '[ "$(stat_get 6)" = 1 ] && [ "$(stat_get 7)" = 1 ]'
    check "生成也算一次" '[ "$(stat_get 2)" = 1 ]'
    )
newmod 23; ( load
    FAKE_WL=yes FAKE_RAIB=allow; state_set last_exit "2026-09-26 12:17:18.751"
    FAKE_EXIT=$T/none FAKE_PIDS=26636 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    check "强制停止不重开" '! calls | grep -q "^am start"'
    check "但通知" 'calls | grep -q "^cmd notification.*在生成中退出.*强制停止"'
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

echo "[1.6] 备份：有变化才备份、校验、分层保留"
bk() { ls "$BACKUP_DIR" 2>/dev/null | grep '\.tar\.gz$'; }
newmod 27; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    U=$TT_DATA/default-user; mkdir -p "$U/chats/角色 A" "$U/backups" "$U/thumbnails" "$U/OpenAI Settings" "$TT_DATA/extensions/third-party/x" "$TT_DATA/_cm_archive" "$TT_DATA/_cache" "$TT_DATA/_tauritavern/mcp"
    echo hi > "$U/chats/角色 A/1.jsonl"; echo '{"api_key":"sk-SECRET"}' > "$U/secrets.json"; echo '{"k":"sk-NESTED"}' > "$TT_DATA/_tauritavern/mcp/secrets.json"
    echo old > "$U/backups/x"; mkdir -p "$U/.staging"; echo w > "$U/.staging/w"; echo t > "$U/thumbnails/t"; echo s > "$U/settings.json"; echo p > "$U/OpenAI Settings/p.json"
    echo e > "$TT_DATA/extensions/third-party/x/index.js"; echo a > "$TT_DATA/_cm_archive/a.json"; echo c > "$TT_DATA/_cache/c"; echo m > "$TT_DATA/_tauritavern/mcp/r.json"
    FAKE_CE=false FAKE_PIDS=9 FAKE_GEN=0 FAKE_NOW=$((DAY0 - 100)); tick
    check "开机后没解锁不备份" '[ -z "$(bk)" ]'
    check "没解锁不算失败" '! grep -q "备份 TauriTavern 数据失败" "$LOG" 2>/dev/null && [ -z "$(state_get backup_try)" ]'
    FAKE_CE=true
    FAKE_PIDS=9 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    check "生成中不备份" '[ -z "$(bk)" ]'
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    f=$BACKUP_DIR/$(bk | head -1)
    check "备份出来了，放在私密位置" '[ -f "$f" ] && [ ! -d "$SHARED_BK" ]'
    list=$(LC_ALL=en_US.UTF-8 tar -tzf "$f" 2>/dev/null)   # Mac 的 tar 在 C 语言环境下会把中文转义
    check "有聊天（带空格和中文的路径）" 'echo "$list" | grep -q "default-user/chats/角色 A/1.jsonl"'
    check "有设置" 'echo "$list" | grep -q "default-user/settings.json" && echo "$list" | grep -q "OpenAI Settings/p.json"'
    check "有扩展、归档、MCP 配置" 'echo "$list" | grep -q "extensions/third-party/x/index.js" && echo "$list" | grep -q "_cm_archive/a.json" && echo "$list" | grep -q "_tauritavern/mcp/r.json"'
    check "没有缓存" '! echo "$list" | grep -q "_cache"'
    check "任何位置的 secrets.json 都不进备份" '! echo "$list" | grep -q secrets && ! tar -xzOf "$f" 2>/dev/null | grep -qE "sk-SECRET|sk-NESTED"'
    check "没有 TT 自己的备份和缩略图" '! echo "$list" | grep -qE "default-user/(backups|thumbnails|\.staging)/"'
    check "没留半截文件和锁" '[ -z "$(ls -a "$BACKUP_DIR" | grep part)" ] && [ ! -d "$TT_MODDIR/.backup.lock" ]'
    check "写了 sha256 且对得上" '( cd "$BACKUP_DIR" && { sha256sum -c "${f##*/}.sha256" || shasum -a 256 -c "${f##*/}.sha256"; } ) >/dev/null 2>&1'
    check "记日志（已校验、文件名和大小）" 'grep -q "已备份并校验 TauriTavern 数据：tt-default-user-19700102-000015.tar.gz（[0-9][0-9]* KB" "$LOG"'
    FAKE_NOW=$((DAY0 + 3600)); tick
    check "6 小时内不再备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    FAKE_NOW=$((DAY0 + 7 * 3600)); tick
    check "数据没变就不备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ] && [ "$(state_get last_backup_check)" = $((DAY0 + 7 * 3600)) ]'
    touch -t 200001010000 "$TT_MODDIR/backup.marker"   # 等于「上次备份以后改过文件」
    FAKE_NOW=$((DAY0 + 8 * 3600)); tick
    check "改过也要等到间隔" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    FAKE_NOW=$((DAY0 + 13 * 3600 + 15)); tick
    check "数据变了、间隔到了就备份" '[ "$(bk | wc -l | tr -d " ")" = 2 ]'
    touch -t 203001010000 "$U/thumbnails/t" "$U/content.log" 2>/dev/null; FAKE_NOW=$((DAY0 + 20 * 3600)); tick
    check "只有缩略图变了不算变化" '[ "$(bk | wc -l | tr -d " ")" = 2 ]'
    echo backup=0 > "$CONFIG"; touch -t 200001010000 "$TT_MODDIR/backup.marker"; FAKE_NOW=$((DAY0 + 30 * 3600)); tick
    check "关了就不备份" '[ "$(bk | wc -l | tr -d " ")" = 2 ]'
    )
newmod 28; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user"; echo x > "$TT_DATA/default-user/a"
    mkdir -p "$T/ro28"; chmod 555 "$T/ro28"; PRIVATE_BK=$T/ro28/bk   # 备份目录建不出来：模拟写入失败
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "没有数据时记失败" 'grep -q "备份 TauriTavern 数据失败（连续第 1 次），1 小时后再试" "$LOG"'
    FAKE_NOW=$((DAY0 + 600)); tick
    check "1 小时内不重试" '[ "$(grep -c "备份 TauriTavern 数据失败" "$LOG")" = 1 ]'
    FAKE_NOW=$((DAY0 + 3700)); tick; FAKE_NOW=$((DAY0 + 7400)); tick
    check "连续失败 3 次发通知" '[ "$(grep -c "备份 TauriTavern 数据失败" "$LOG")" = 3 ] && calls | grep -q "^cmd notification.*TauriTavern 备份连续失败 3 次"'
    PRIVATE_BK=$T/backup28; FAKE_NOW=$((DAY0 + 11100)); tick
    check "成功后失败次数清零" '[ "$(state_get backup_fails)" = 0 ]'
    )

echo "[1.6] 分层保留"
newmod 33; ( load
    mkdir -p "$BACKUP_DIR"
    for n in 20260926-120000 20260926-060000 20260925-230000 20260920-100000 20260920-090000 20260910-100000 20260908-100000 20260801-100000 20250101-100000; do
        echo x > "$BACKUP_DIR/tt-default-user-$n.tar.gz"; echo h > "$BACKUP_DIR/tt-default-user-$n.tar.gz.sha256"
    done
    FAKE_NOW=1790380800   # 2026-09-26 UTC
    check "层级" '[ "$(backup_tiers | cut -d" " -f1 | tr "\n" " ")" = "new 2d 2d day drop week drop month drop " ]'
    dropped=$(apply_retention | tr "\n" " ")
    check "删了多余的三份" '[ "$dropped" = "tt-default-user-20260920-090000.tar.gz tt-default-user-20260908-100000.tar.gz tt-default-user-20250101-100000.tar.gz " ]'
    check "校验文件一起删" '[ ! -f "$BACKUP_DIR/tt-default-user-20250101-100000.tar.gz.sha256" ] && [ -f "$BACKUP_DIR/tt-default-user-20260801-100000.tar.gz.sha256" ]'
    check "剩 6 份" '[ "$(bk | wc -l | tr -d " ")" = 6 ]'
    echo keep_months=0 > "$CONFIG"; apply_retention >/dev/null
    check "keep_months=0 按月的也删" '[ ! -f "$BACKUP_DIR/tt-default-user-20260801-100000.tar.gz" ]'
    check "不认识的文件不碰" 'echo x > "$BACKUP_DIR/notes.txt"; apply_retention >/dev/null; [ -f "$BACKUP_DIR/notes.txt" ]'
    )

echo "[1.6] 备份位置：私密 ↔ 共享"
newmod 34; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$SHARED_BK"; echo x > "$SHARED_BK/tt-default-user-20260926-1349.tar.gz"; echo keep > "$SHARED_BK/我的笔记.txt"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "1.5 的备份搬进私密位置" '[ -f "$PRIVATE_BK/tt-default-user-20260926-1349.tar.gz" ] && [ ! -f "$SHARED_BK/tt-default-user-20260926-1349.tar.gz" ]'
    check "共享位置里别的文件不碰" '[ -f "$SHARED_BK/我的笔记.txt" ]'
    check "记日志" 'grep -q "把 1 个备份文件搬到了 $PRIVATE_BK" "$LOG"'
    check "改开关：共享" 'config_set backup_private 0 && [ "$(bdir)" = "$SHARED_BK" ]'
    n=$(migrate_backups)
    check "改回共享就搬回去" '[ "$n" -ge 1 ] && [ -f "$SHARED_BK/tt-default-user-20260926-1349.tar.gz" ]'
    )

echo "[1.6] 太久没备份 / 没拷到电脑"
newmod 35; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user" "$BACKUP_DIR"; echo x > "$TT_DATA/default-user/a"
    state_set watch_since $DAY0; state_set last_backup $DAY0; state_set last_backup_check $DAY0
    echo x > "$BACKUP_DIR/tt-default-user-19700102-000000.tar.gz"
    echo backup_hours=48 > "$CONFIG"   # 这组只测提醒，别让它去备份
    state_set backup_try $((DAY0 + 10 * 86400))
    FAKE_PIDS="" FAKE_NOW=$((DAY0 + 86400)); tick
    check "1 天：不提醒" '! calls | grep -q "^cmd notification"'
    FAKE_NOW=$((DAY0 + 3 * 86400 + 60)); tick
    check "3 天没拷到电脑提醒" 'calls | grep -q "^cmd notification.*3 天未同步到电脑"'
    check "3 天没备份成功提醒" 'calls | grep -q "^cmd notification.*3 天未备份"'
    FAKE_NOW=$((DAY0 + 3 * 86400 + 120)); tick
    check "同一天不重复提醒" '[ "$(calls | grep -c "^cmd notification")" = 2 ]'
    : > "$CALLS"; sh "$TT_MODDIR/ui.sh" mark-pulled >/dev/null; state_set last_backup_check $((DAY0 + 4 * 86400))
    FAKE_NOW=$((DAY0 + 4 * 86400 + 60)); tick
    check "电脑拷走后不再提醒" '! calls | grep -q "同步到电脑"'
    )

echo "[1.5] 崩溃记录"
newmod 30; ( load
    FAKE_WL=yes FAKE_RAIB=allow; state_set last_exit 0
    cat > "$T/crash-exit.txt" <<'X'
        ApplicationExitInfo #0:
          timestamp=2026-09-27 10:00:00.000 pid=4242 realUid=10447 packageUid=10447 definingUid=10447 user=0
          process=com.tauritavern.client reason=4 (APP CRASH(EXCEPTION)) status=0
          importance=100 pss=0.00 rss=300MB description=crash state=71 bytes trace=null
X
    printf '09-27 10:00:00.000  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main\n09-27 10:00:00.000  999  999 E Other: x\n' > "$T/crashlog"
    mkdir -p "$ANR_DIR" "$TT_LOGS"; printf 'pid 4242\ntrace\n' > "$ANR_DIR/anr_1"; printf 'pid 1\n' > "$ANR_DIR/anr_2"
    echo "old" > "$TT_LOGS/tauritavern.log.2026-09-26"; seq 1 300 > "$TT_LOGS/tauritavern.log.2026-09-27"
    mk logcat 'case "$*" in *crash*) cat "$FAKE_CRASHLOG" 2>/dev/null ;; *) cat "$FAKE_LOGCAT" 2>/dev/null ;; esac'
    export FAKE_CRASHLOG=$T/crashlog
    FAKE_EXIT=$T/crash-exit.txt FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    d=$(ls -d "$CRASH_DIR"/*/ 2>/dev/null | head -1)
    check "存了崩溃记录" '[ -n "$d" ] && grep -q "应用崩溃" "$d/退出原因.txt"'
    check "系统崩溃记录只要这个进程" 'grep -q "FATAL EXCEPTION" "$d/系统崩溃记录.txt" && ! grep -q Other "$d/系统崩溃记录.txt"'
    check "ANR 记录找对文件" 'grep -q "pid 4242" "$d/ANR记录.txt"'
    check "TT 日志取最新一天的最后 200 行" '[ "$(wc -l < "$d/TT日志最后200行.txt" | tr -d " ")" = 200 ] && [ "$(tail -n 1 "$d/TT日志最后200行.txt")" = 300 ]'
    check "日志记了（目录名对）" 'grep -q "已保存崩溃记录：crash/19700102-000000-4242$" "$LOG"'
    check "exit_line 不改外面的变量" 'd=keep; pid=keep; exit_line "2026|1|ANR||100|x" >/dev/null; [ "$d$pid" = keepkeep ]'
    check "发了通知" 'calls | grep -q "^cmd notification.*TauriTavern 异常退出.*应用崩溃"'
    i=0; while [ $i -lt 12 ]; do mkdir -p "$CRASH_DIR/19700101-0000$(printf %02d $i)-1"; i=$((i + 1)); done
    save_crash "2026|4242|ANR||100|" >/dev/null
    check "崩溃记录只留 10 份" '[ "$(ls -d "$CRASH_DIR"/*/ | wc -l | tr -d " ")" = 10 ]'
    mk logcat 'cat "$FAKE_LOGCAT" 2>/dev/null'
    )

echo "[1.5] 清理 TT 旧日志、温度、浏览器内核、补开关"
newmod 31; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_LOGS" "$TT_DATA/_errors" "$TT_DATA/default-user"
    for f in "$TT_LOGS/tauritavern.log.old" "$TT_LOGS/llm-api-1.request.json" "$TT_DATA/_errors/e 1.txt"; do echo x > "$f"; touch -t 202001010000 "$f"; done
    echo x > "$TT_LOGS/tauritavern.log.new"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "删了 30 天前的 TT 日志" '[ ! -f "$TT_LOGS/tauritavern.log.old" ]'
    check "删了带空格名字的错误记录" '[ ! -f "$TT_DATA/_errors/e 1.txt" ]'
    check "请求记录不碰" '[ -f "$TT_LOGS/llm-api-1.request.json" ]'
    check "新日志不碰" '[ -f "$TT_LOGS/tauritavern.log.new" ]'
    check "记日志" 'grep -q "清理了 TT 自己 30 天以前的日志和错误记录：2 个文件" "$LOG"'
    echo x > "$TT_LOGS/tauritavern.log.old2"; touch -t 202001010000 "$TT_LOGS/tauritavern.log.old2"
    FAKE_NOW=$((DAY0 + 60)); tick
    check "一天只清一次" '[ -f "$TT_LOGS/tauritavern.log.old2" ]'
    echo cleanup_days=0 > "$CONFIG"; FAKE_NOW=$((DAY0 + 86400)); tick
    check "cleanup_days=0 不清" '[ -f "$TT_LOGS/tauritavern.log.old2" ]'
    : > "$CONFIG"
    echo 440 > "$BATTERY_TEMP"; FAKE_PIDS=5 FAKE_GEN=1 FAKE_NOW=$((DAY0 + 86500)); tick
    check "44°C 不提醒" '! calls | grep -q "电池温度"'
    echo 463 > "$BATTERY_TEMP"; FAKE_NOW=$((DAY0 + 86515)); tick; FAKE_NOW=$((DAY0 + 86530)); tick
    check "46°C 提醒一次" '[ "$(calls | grep -c "^cmd notification.*电池温度 46°C")" = 1 ]'
    FAKE_GEN=0 FAKE_NOW=$((DAY0 + 86545)); tick
    check "不在生成时不提醒" '[ "$(calls | grep -c "^cmd notification.*电池温度")" = 1 ]'
    echo temp_alert=0 > "$CONFIG"; FAKE_GEN=1 FAKE_NOW=$((DAY0 + 86560)); tick
    check "temp_alert=0 不提醒" '[ "$(calls | grep -c "^cmd notification.*电池温度")" = 1 ]'
    echo abc > "$BATTERY_TEMP"; check "温度读不到时为空" '[ -z "$(battery_temp)" ]'
    ensure
    check "浏览器内核第一次只记下" '[ "$(state_get webview)" = "com.google.android.webview, 153.0.8010.36" ] && ! grep -q WebView "$LOG"'
    FAKE_WV=154.0.1; ensure
    check "浏览器内核更新记一行" 'grep -q "系统浏览器内核（WebView）更新：com.google.android.webview, 153.0.8010.36 → com.google.android.webview, 154.0.1" "$LOG"'
    printf '# 我的注释\nbackup=0\n' > "$CONFIG"; config_fill
    check "补开关：旧的不动" 'grep -qx backup=0 "$CONFIG" && [ "$(grep -c ^backup= "$CONFIG")" = 1 ]'
    check "补开关：新的补上带注释" 'grep -qx cleanup_days=30 "$CONFIG" && grep -qx temp_alert=45 "$CONFIG" && grep -q "^# 清理 TT" "$CONFIG"'
    config_fill; check "补开关：再补一次不重复" '[ "$(grep -c ^temp_alert= "$CONFIG")" = 1 ]'
    )

echo "[1.5] 从备份恢复"
mk chown 'echo "chown $*" >> "$CALLS"'
mk chcon 'echo "chcon $*" >> "$CALLS"'
newmod 32
U=$TT_DATA/default-user; mkdir -p "$U/chats/A" "$BACKUP_DIR" "$TT_DATA/extensions/e"
echo "旧聊天" > "$U/chats/A/1.jsonl"; echo "sk-KEY" > "$U/secrets.json"; echo "旧扩展" > "$TT_DATA/extensions/e/i.js"
( cd "$TT_DATA" && tar -czf "$BACKUP_DIR/tt-default-user-19700101-000000.tar.gz" default-user extensions )
echo "新扩展" > "$TT_DATA/extensions/e/i.js"
echo "新聊天" > "$U/chats/A/1.jsonl"; echo "之后新建" > "$U/chats/A/2.jsonl"
FAKE_PIDS=123 sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "TT 在运行不恢复" '[ $r = 3 ] && grep -q "请先在最近任务中关闭 TauriTavern" "$T/r.out" && grep -qx "新聊天" "$U/chats/A/1.jsonl"'
FAKE_CE=false sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > /dev/null; r=$?
check "没解锁不恢复" '[ $r = 4 ]'
sh "$TT_MODDIR/restore.sh" ../../etc/passwd > /dev/null; r=$?
check "不是备份文件名不恢复" '[ $r = 2 ]'
sh "$TT_MODDIR/restore.sh" tt-default-user-1.tar.gz > /dev/null; r=$?
check "文件不存在不恢复" '[ $r = 2 ]'
mkdir -p "$T/evil/other"; echo x > "$T/evil/other/x"; ( cd "$T/evil" && tar -czf "$BACKUP_DIR/tt-default-user-19700101-000001.tar.gz" other )
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000001.tar.gz > /dev/null; r=$?
check "备份里有别的目录不恢复" '[ $r = 2 ] && [ ! -e "$TT_DATA/other" ]'
: > "$CALLS"; FAKE_NOW=5000
sh "$TT_MODDIR/restore.sh" "$BACKUP_DIR/tt-default-user-19700101-000000.tar.gz" > "$T/r.out"; r=$?
check "恢复成功" '[ $r = 0 ] && grep -q "已恢复" "$T/r.out"'
check "备份里的文件恢复了" 'grep -qx "旧聊天" "$U/chats/A/1.jsonl"'
check "备份里没有的留着" 'grep -qx "之后新建" "$U/chats/A/2.jsonl"'
check "扩展也恢复了" 'grep -qx "旧扩展" "$TT_DATA/extensions/e/i.js"'
check "API 密钥不动" 'grep -qx "sk-KEY" "$U/secrets.json"'
check "恢复前先备份了现在的（单独命名）" '[ -f "$BACKUP_DIR/tt-default-user-19700101-012320-prerestore.tar.gz" ] && tar -xzOf "$BACKUP_DIR/tt-default-user-19700101-012320-prerestore.tar.gz" default-user/chats/A/1.jsonl | grep -qx "新聊天"'
check "恢复前的备份不含密钥" '! tar -tzf "$BACKUP_DIR/tt-default-user-19700101-012320-prerestore.tar.gz" | grep -q secrets'
check "属主改回 TT" 'calls | grep -q "^chown -R 10447:10447 $U"'
check "临时目录删了" '[ ! -e "$TT_DATA/.cc-restore" ]'
check "记日志" 'grep -q "从备份恢复了 TauriTavern 数据：tt-default-user-19700101-000000.tar.gz" "$TT_MODDIR/service.log"'

echo "[1.6] 界面用的 ui.sh"
newmod 36
mkdir -p "$TT_DATA/default-user" "$BACKUP_DIR"; echo x > "$TT_DATA/default-user/a"
printf '01-01 10:00:00 TT（1）12:00:00.000 退出：内存不足，被系统回收［LOW MEMORY］\n01-01 10:00:01 带"引号"和\\反斜杠\t制表\n' > "$TT_MODDIR/service.log"
echo "01-01 2 330 3 1 2 1" > "$TT_MODDIR/stats.txt"
echo 361 > "$BATTERY_TEMP"
out=$(FAKE_WL=yes FAKE_RAIB=allow FAKE_PIDS=26636 FAKE_GEN=1 sh "$TT_MODDIR/ui.sh" status)
if command -v python3 >/dev/null 2>&1; then
    check "status 是合法 JSON" 'printf "%s" "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"tt\"][\"generating\"] is True and d[\"keep\"][\"temp\"]==36 and d[\"config\"][\"keep_days\"]==7 and d[\"days\"][0][2]==330 and \"带\\\"引号\\\"和\\\\反斜杠 制表\" in d[\"log\"][1]"'
else
    check "status 是 { 开头 } 结尾" 'case "$out" in "{"*"}") true ;; *) false ;; esac'
fi
check "status 里有备份位置" 'printf "%s" "$out" | grep -q "dir.:.$PRIVATE_BK"'
r=$(sh "$TT_MODDIR/ui.sh" backup)
check "ui backup 成功" 'echo "$r" | grep -q "\"ok\":true" && [ -n "$(ls "$BACKUP_DIR" | grep "\.tar\.gz$")" ]'
out=$(sh "$TT_MODDIR/ui.sh" status)
check "status 里列出备份和校验" 'echo "$out" | grep -q "\"tier\":\"new\"" && echo "$out" | grep -q "\"verified\":true"'
l=$(sh "$TT_MODDIR/ui.sh" list-backups)
check "list-backups：文件名 KB sha256" 'echo "$l" | grep -qE "^tt-default-user-[0-9-]+\.tar\.gz [0-9]+ [0-9a-f]{64}$"'
check "ui set 改开关" 'sh "$TT_MODDIR/ui.sh" set temp_alert 40 | grep -q "\"ok\":true" && grep -qx temp_alert=40 "$TT_MODDIR/config.txt"'
check "ui set 不认的开关" 'sh "$TT_MODDIR/ui.sh" set "x;touch $T/pwned" 1 | grep -q "\"ok\":false" && [ ! -e "$T/pwned" ]'
check "ui set 改位置时搬备份" 'sh "$TT_MODDIR/ui.sh" set backup_private 0 >/dev/null; [ -n "$(ls "$SHARED_BK" | grep "\.tar\.gz$")" ] && [ -z "$(ls "$PRIVATE_BK" 2>/dev/null | grep "\.tar\.gz$")" ]'
sh "$TT_MODDIR/ui.sh" set backup_private 1 >/dev/null
check "ui mark-pulled" 'sh "$TT_MODDIR/ui.sh" mark-pulled >/dev/null; grep -q "^mac_pulled=" "$TT_MODDIR/state.txt"'
r=$(FAKE_PIDS=5 sh "$TT_MODDIR/ui.sh" restore "$(ls "$BACKUP_DIR" | grep "\.tar\.gz$" | head -1)")
check "ui restore：TT 在运行时 rc=3 并说明" 'echo "$r" | grep -q "\"rc\":3" && echo "$r" | grep -q "请先在最近任务中关闭 TauriTavern"'
check "ui 不认识的命令" '! sh "$TT_MODDIR/ui.sh" rm-rf >/dev/null'

echo "[1.6] 界面文件"
H=$MOD/webroot/index.html
check "界面不引用任何外部网址" '! grep -qE "(src|href)=\"https?://" "$H" && ! grep -q "@import" "$H"'
check "界面只调本模块的 ui.sh" '[ "$(grep -o "ksu\.exec([^)]*" "$H" | wc -l | tr -d " ")" = 1 ] && grep -q "sh \${MOD}/ui.sh" "$H"'
check "恢复时只放行安全的文件名字符" 'grep -q "name.replace(/\[^A-Za-z0-9._-\]/g" "$H"'

echo "[防呆] 设置文件写错"
newmod 40; ( load
    printf 'backup=0\r\nnotify = 0 \r\n' > "$CONFIG"
    check "Windows 记事本的 CRLF" '[ "$(cfg backup 1)" = 0 ]'
    check "等号两边有空格" '[ "$(cfg notify 1)" = 0 ]'
    printf 'backup=yes\nbackup_hours=六\nkeep_days=-3\n' > "$CONFIG"
    check "不是数字：用默认值" '[ "$(cfg backup 1)" = 1 ] && [ "$(cfg backup_hours 6)" = 6 ] && [ "$(cfg keep_days 7)" = 7 ]'
    out=$(sh "$TT_MODDIR/ui.sh" selftest)
    check "自检报出无效的值" 'printf "%s" "$out" | grep -q "\"name\":\"设置文件\",\"ok\":false"'
    rm -f "$CONFIG"
    check "设置文件被删：全用默认值" '[ "$(cfg backup 1)$(cfg backup_private 1)" = 11 ]'
    config_fill
    check "设置文件被删：重新生成" 'grep -qx backup=1 "$CONFIG"'
    echo backup_hours=0 > "$CONFIG"
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user"; echo x > "$TT_DATA/default-user/a"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick; FAKE_NOW=$((DAY0 + 1800)); tick
    check "备份间隔写成 0：按 6 小时，不会狂备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    )

echo "[防呆] 备份"
newmod 41; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user"; echo x > "$TT_DATA/default-user/a"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "先有一份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    rm -rf "$BACKUP_DIR"
    FAKE_NOW=$((DAY0 + 7 * 3600)); tick
    check "手动删光备份目录：数据没变也重新备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    export FAKE_FREE=1000; FAKE_NOW=$((DAY0 + 14 * 3600)); touch -t 200001010000 "$TT_MODDIR/backup.marker"; tick
    check "存储满：不备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    check "存储满：记日志、发通知" 'grep -q "存储空间不足，暂停自动备份" "$LOG" && calls | grep -q "^cmd notification.*存储空间不足"'
    FAKE_NOW=$((DAY0 + 14 * 3600 + 60)); tick; unset FAKE_FREE
    check "存储满：同一天只提醒一次" '[ "$(calls | grep -c "^cmd notification.*存储空间不足")" = 1 ]'
    r=$(FAKE_FREE=1000 sh "$TT_MODDIR/ui.sh" backup)
    check "存储满：手动备份也拒绝" 'echo "$r" | grep -q "存储空间不足"'
    r=$(FAKE_PIDS=5 FAKE_GEN=1 sh "$TT_MODDIR/ui.sh" backup)
    check "生成中点「立即备份」：拒绝" 'echo "$r" | grep -q "正在生成回复"'
    mkdir "$TT_MODDIR/.backup.lock"
    r=$(sh "$TT_MODDIR/ui.sh" backup)
    check "连点两次备份：第二次不跑" 'echo "$r" | grep -q "\"ok\":false"'
    r=$(sh "$TT_MODDIR/ui.sh" set backup_private 0)
    check "备份进行中不能切换存储位置" 'echo "$r" | grep -q "正在备份" && [ "$(cfg backup_private 1)" = 1 ]'
    rmdir "$TT_MODDIR/.backup.lock"
    )

echo "[防呆] 保留规则"
newmod 42; ( load
    mkdir -p "$BACKUP_DIR"
    for n in 20260926-120000 20250926-120000 20240926-120000; do echo x > "$BACKUP_DIR/tt-default-user-$n.tar.gz"; done
    FAKE_NOW=1893456000   # 2030-01-01：系统时间跳到了几年后
    check "系统时间跳到未来：一份都不删" '[ -z "$(apply_retention)" ] && [ "$(bk | wc -l | tr -d " ")" = 3 ]'
    FAKE_NOW=1790380800
    printf 'keep_days=0\nkeep_weeks=0\nkeep_months=0\n' > "$CONFIG"; apply_retention >/dev/null
    check "保留全设成 0：最新一份还在" '[ -f "$BACKUP_DIR/tt-default-user-20260926-120000.tar.gz" ]'
    : > "$CONFIG"
    for i in 1 2 3 4 5; do echo x > "$BACKUP_DIR/tt-default-user-2026092${i}-100000-prerestore.tar.gz"; done
    check "恢复前的那几份不走分层保留" '[ "$(backup_tiers | grep -c "^pre ")" = 5 ] && [ -z "$(apply_retention | grep prerestore)" ]'
    prune_prerestore >/dev/null
    check "恢复前的只留最新 3 份" '[ "$(ls "$BACKUP_DIR" | grep -c prerestore)" = 3 ] && [ -f "$BACKUP_DIR/tt-default-user-20260925-100000-prerestore.tar.gz" ] && [ ! -f "$BACKUP_DIR/tt-default-user-20260921-100000-prerestore.tar.gz" ]'
    )

echo "[防呆] 恢复"
newmod 43
mkdir -p "$TT_DATA/default-user" "$BACKUP_DIR"; echo x > "$TT_DATA/default-user/a"
( cd "$TT_DATA" && tar -czf "$BACKUP_DIR/tt-default-user-19700101-000000.tar.gz" default-user )
( cd "$BACKUP_DIR" && { sha256sum tt-default-user-19700101-000000.tar.gz 2>/dev/null || shasum -a 256 tt-default-user-19700101-000000.tar.gz; } > tt-default-user-19700101-000000.tar.gz.sha256 )
mkdir "$TT_MODDIR/.restore.lock"
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "界面和电脑同时点恢复：第二个不跑" '[ $r = 7 ] && grep -q 另一个恢复正在进行 "$T/r.out"'
rmdir "$TT_MODDIR/.restore.lock"
FAKE_FREE=1000 sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "空间不够：不恢复" '[ $r = 8 ]'
printf 'garbage' >> "$BACKUP_DIR/tt-default-user-19700101-000000.tar.gz"
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "备份文件坏了（校验不对）：不恢复" '[ $r = 9 ] && [ ! -e "$TT_DATA/.cc-restore" ]'
sh "$TT_MODDIR/restore.sh" "tt-default-user-1..tar.gz" > /dev/null; r=$?
check "文件名里有 ..：不恢复" '[ $r = 2 ]'
check "恢复结束后锁都释放" '[ ! -d "$TT_MODDIR/.restore.lock" ]'

echo "[防呆] 划掉 TT 不算被系统杀"
newmod 44; ( load
    check "子原因带 TASK：不算系统杀" '! system_kill "OTHER KILLS BY SYSTEM" "REMOVE TASK"'
    check "子原因带 USER：不算系统杀" '! system_kill "SIGNALED" "USER"'
    check "内存不够：算" 'system_kill "LOW MEMORY" "UNKNOWN"'
    mkdir "$TT_MODDIR/.restore.lock"
    FAKE_WL=yes FAKE_RAIB=allow; state_set last_exit "2026-09-26 12:14:07.288"
    FAKE_EXIT=$T/none FAKE_PIDS=26440 FAKE_GEN=1 FAKE_NOW=$DAY0; tick
    FAKE_EXIT=$FIX/exit-info.txt FAKE_PIDS="" FAKE_GEN=0 FAKE_NOW=$((DAY0 + 15)); tick
    check "正在恢复时不自动重开 TT" '! calls | grep -q "^am start"'
    rmdir "$TT_MODDIR/.restore.lock"
    )

echo "[防呆] 卸载时把私密备份搬出来"
newmod 45
mkdir -p "$PRIVATE_BK"; echo x > "$PRIVATE_BK/tt-default-user-19700101-000000.tar.gz"; echo h > "$PRIVATE_BK/tt-default-user-19700101-000000.tar.gz.sha256"
printf 'whitelist=yes\nRUN_IN_BACKGROUND=allow\nRUN_ANY_IN_BACKGROUND=allow\n' > "$TT_MODDIR/prior.txt"
UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; i=0
while [ $i -lt 50 ] && [ ! -f "$SHARED_BK/tt-default-user-19700101-000000.tar.gz.sha256" ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
"$REAL_SLEEP" 0.3
check "备份搬到共享位置（连校验文件）" '[ -f "$SHARED_BK/tt-default-user-19700101-000000.tar.gz" ] && [ -f "$SHARED_BK/tt-default-user-19700101-000000.tar.gz.sha256" ]'
check "私密目录清空删掉" '[ ! -d "$PRIVATE_BK" ]'
check "发通知告诉位置" 'calls | grep -q "TT 守护已卸载"'

echo "[诊断] 自检和诊断包"
newmod 46
mkdir -p "$TT_DATA/default-user/chats"; echo "秘密聊天" > "$TT_DATA/default-user/chats/a.jsonl"
echo "01-01 10:00:00 x" > "$TT_MODDIR/service.log"
out=$(sh "$TT_MODDIR/ui.sh" selftest)
if command -v python3 >/dev/null 2>&1; then
    check "自检是合法 JSON，12 项" 'printf "%s" "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)==12 and all(set(x)=={\"name\",\"ok\",\"detail\"} for x in d)"'
fi
check "自检：检测到酒馆数据" 'printf "%s" "$out" | grep -q "\"name\":\"酒馆数据\",\"ok\":true"'
check "自检：还没有备份时报出来" 'printf "%s" "$out" | grep -q "\"name\":\"最新备份\",\"ok\":false"'
export DIAG_DIR=$T/download
r=$(sh "$TT_MODDIR/ui.sh" diag)
f=$(ls "$DIAG_DIR"/tt-guard-diag-*.tar.gz 2>/dev/null | head -1)
check "诊断包导出到 Download" 'echo "$r" | grep -q "\"ok\":true" && [ -n "$f" ]'
check "诊断包里有日志、自检、状态" 'tar -tzf "$f" | grep -q service.log && tar -tzf "$f" | grep -q selftest.json && tar -tzf "$f" | grep -q status.txt'
check "诊断包里没有聊天数据" '! tar -tzf "$f" | grep -q chats && ! tar -xzOf "$f" 2>/dev/null | grep -q 秘密聊天'
check "诊断用的临时目录删了" '[ ! -e "$TT_MODDIR/.diag" ]'
unset DIAG_DIR

echo "[多酒馆] SillyDroid 和 Termux 里的 SillyTavern"
newmod 50
export SD_ROOT=$T/sd/server TERMUX_ST=$T/termux/home/SillyTavern
# SillyDroid：config data extensions plugins（数据在 data/default-user）
mkdir -p "$SD_ROOT/config" "$SD_ROOT/data/default-user/chats" "$SD_ROOT/data/_cache" "$SD_ROOT/data/_webpack" "$SD_ROOT/extensions/x" "$SD_ROOT/plugins"
echo y > "$SD_ROOT/config/config.yaml"; echo sd-chat > "$SD_ROOT/data/default-user/chats/a.jsonl"
echo '{"k":"sk-SD"}' > "$SD_ROOT/data/default-user/secrets.json"; echo cookie > "$SD_ROOT/data/cookie-secret.txt"
echo c > "$SD_ROOT/data/_cache/c"; echo w > "$SD_ROOT/data/_webpack/w"; echo e > "$SD_ROOT/extensions/x/i.js"
mkdir -p "$SD_ROOT/data/default-user/backups"; echo old > "$SD_ROOT/data/default-user/backups/b"
# Termux：config.yaml data plugins public/scripts/extensions/third-party（还有不该备份的 node_modules）
mkdir -p "$TERMUX_ST/data/default-user/chats" "$TERMUX_ST/plugins" "$TERMUX_ST/public/scripts/extensions/third-party/ext" "$TERMUX_ST/node_modules/big"
echo port > "$TERMUX_ST/config.yaml"; echo tx-chat > "$TERMUX_ST/data/default-user/chats/b.jsonl"
echo '{"k":"sk-TX"}' > "$TERMUX_ST/data/default-user/secrets.json"; echo e > "$TERMUX_ST/public/scripts/extensions/third-party/ext/i.js"
echo huge > "$TERMUX_ST/node_modules/big/x"
( load
    check "检测到三个里的两个（TT 没数据）" '[ "$(present_targets | tr "\n" " ")" = "sillydroid termux " ]'
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    FAKE_INSTALLED=1 FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    sd=$(ls "$BACKUP_DIR" | grep '^sillydroid-.*\.tar\.gz$'); tx=$(ls "$BACKUP_DIR" | grep '^termux-st-.*\.tar\.gz$')
    check "两个都备份了" '[ -n "$sd" ] && [ -n "$tx" ]'
    l1=$(tar -tzf "$BACKUP_DIR/$sd"); l2=$(tar -tzf "$BACKUP_DIR/$tx")
    check "SillyDroid：聊天、配置、扩展都在" 'echo "$l1" | grep -q "data/default-user/chats/a.jsonl" && echo "$l1" | grep -q "config/config.yaml" && echo "$l1" | grep -q "extensions/x/i.js"'
    check "SillyDroid：两种密钥都不在" '! echo "$l1" | grep -qE "secrets.json|cookie-secret" && ! tar -xzOf "$BACKUP_DIR/$sd" | grep -q "sk-SD"'
    check "SillyDroid：缓存和它自己的备份不在" '! echo "$l1" | grep -qE "_cache|_webpack|default-user/backups/"'
    check "Termux：聊天、config.yaml、第三方扩展都在" 'echo "$l2" | grep -q "data/default-user/chats/b.jsonl" && echo "$l2" | grep -qx "config.yaml" && echo "$l2" | grep -q "third-party/ext/i.js"'
    check "Termux：node_modules 和密钥不在" '! echo "$l2" | grep -qE "node_modules|secrets.json"'
    check "各自记状态" '[ -n "$(state_get last_backup_sillydroid)" ] && [ -n "$(state_get last_backup_termux)" ] && [ -z "$(state_get last_backup)" ]'
    check "日志写明是哪个酒馆" 'grep -q "已备份并校验 SillyDroid 数据" "$LOG" && grep -q "已备份并校验 SillyTavern（Termux） 数据" "$LOG"'
    check "检测到就设保活（记原值）" 'calls | grep -q "whitelist +com.jm.sillydroid" && calls | grep -q "whitelist +com.termux" && grep -q "^com.jm.sillydroid.whitelist=no" "$PRIOR" && grep -q "^com.termux.RUN_ANY_IN_BACKGROUND=" "$PRIOR"'
    check "分层保留按酒馆分开：两个都是最新" '[ "$(backup_tiers | grep -c "^new ")" = 2 ]'
    out=$(sh "$TT_MODDIR/ui.sh" status)
    check "status 里有 targets 和每份备份的 target" 'printf "%s" "$out" | grep -q "\"id\":\"sillydroid\",\"label\":\"SillyDroid\"" && printf "%s" "$out" | grep -q "\"target\":\"termux\""'
    : > "$CALLS"; r=$(sh "$TT_MODDIR/ui.sh" backup)
    check "立即备份：所有检测到的都备份" 'echo "$r" | grep -q "\"ok\":true" && echo "$r" | grep -q sillydroid- && echo "$r" | grep -q termux-st-'
    r=$(sh "$TT_MODDIR/ui.sh" backup sillydroid)
    check "立即备份：可以只备份一个" 'echo "$r" | grep -q sillydroid- && ! echo "$r" | grep -q termux-st-'
)
( load
    echo "改过的配置" > "$TERMUX_ST/config.yaml"; echo 改过 > "$TERMUX_ST/data/default-user/chats/b.jsonl"
    tx=$(list_backups termux | grep -v prerestore | tail -n 1)
    sh "$TT_MODDIR/restore.sh" "$tx" > "$T/r50.out"; r=$?
    check "恢复 Termux 的备份" '[ $r = 0 ] && grep -qx tx-chat "$TERMUX_ST/data/default-user/chats/b.jsonl"'
    check "单个文件（config.yaml）也恢复" 'grep -qx port "$TERMUX_ST/config.yaml"'
    check "密钥不受影响" 'grep -q sk-TX "$TERMUX_ST/data/default-user/secrets.json"'
    check "恢复前先存了一份 Termux 的" '[ -n "$(list_backups termux | grep prerestore)" ]'
    check "日志写明酒馆" 'grep -q "从备份恢复了 SillyTavern（Termux） 数据" "$LOG"'
    mkdir -p "$T/evil50/data/x"; ( cd "$T/evil50" && tar -czf "$BACKUP_DIR/sillydroid-19700101-000001.tar.gz" data ../../etc 2>/dev/null; tar -czf "$BACKUP_DIR/sillydroid-19700101-000002.tar.gz" data )
    sh "$TT_MODDIR/restore.sh" sillydroid-19700101-000002.tar.gz > "$T/r50.out"; r=$?
    check "没有用户数据的 SillyDroid 包：不恢复" '[ $r = 6 ]'
    mkdir -p "$T/evil50b/node_modules"; ( cd "$T/evil50b" && tar -czf "$BACKUP_DIR/sillydroid-19700101-000003.tar.gz" node_modules )
    sh "$TT_MODDIR/restore.sh" sillydroid-19700101-000003.tar.gz > /dev/null; r=$?
    check "包里有不该有的目录：不恢复" '[ $r = 2 ] && [ ! -e "$SD_ROOT/node_modules" ]'
)
printf 'whitelist=yes\nRUN_IN_BACKGROUND=allow\nRUN_ANY_IN_BACKGROUND=allow\ncom.jm.sillydroid.whitelist=no\ncom.jm.sillydroid.RUN_IN_BACKGROUND=default\ncom.jm.sillydroid.RUN_ANY_IN_BACKGROUND=ignore\n' > "$TT_MODDIR/prior.txt"
: > "$CALLS"; G50=$T/g50; cp -r "$TT_MODDIR" "$G50"; cp "$TT_MODDIR/prior.txt" "$G50/prior.txt"
TT_GUARD_DIR=$G50 UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; i=0
while [ $i -lt 50 ] && [ -d "$G50" ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
check "卸载：SillyDroid 撤白名单、还原后台运行" 'calls | grep -q "whitelist -com.jm.sillydroid" && calls | grep -q "appops set com.jm.sillydroid RUN_ANY_IN_BACKGROUND ignore"'
check "卸载：没记过的 Termux 不动" '! calls | grep -q com.termux'
unset SD_ROOT TERMUX_ST

echo "[service] 不再写 /proc"
check "没有往 /proc 写东西" '! grep -nE ">[[:space:]]*\"?(/proc|\\\$f)" "$MOD"/*.sh'

echo "[action] 状态输出"
newmod 8
mkdir -p "$CG_ROOT/uid_10447/pid_26636"; echo "frozen 0" > "$CG_ROOT/uid_10447/pid_26636/cgroup.events"
echo 361 > "$BATTERY_TEMP"; mkdir -p "$TT_MODDIR/crash/19700101-000000-5"
# 假的温度传感器：一个没接（-274000）、一个 125°C 不合理、soc_max 38459 毫摄氏度
export THERMAL_ROOT=$T/thermal8
for z in "0 gpu0 -274000" "1 oled_temp 125000" "2 soc_max 38459" "3 board_temp 125000"; do
    set -- $z; mkdir -p "$THERMAL_ROOT/thermal_zone$1"; echo "$2" > "$THERMAL_ROOT/thermal_zone$1/type"; echo "$3" > "$THERMAL_ROOT/thermal_zone$1/temp"
done
echo "01-01 10:00:00 TT（26636）12:29:36.672 退出：强制停止（…）［USER REQUESTED / FORCE STOP］" > "$TT_MODDIR/service.log"
echo "01-01 10:01:00 TT（1）12:00:00.000 退出：内存不足，被系统回收［LOW MEMORY］" >> "$TT_MODDIR/service.log"
echo "01-01 10:02:00 TT（2）12:00:00.000 退出：内存不足，被系统回收［LOW MEMORY］" >> "$TT_MODDIR/service.log"
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
check "退出原因汇总" 'echo "$out" | grep -q "2 内存不足，被系统回收$"'
check "汇总里强制停止不带括号" 'echo "$out" | grep -q "1 强制停止$"'
check "备份一栏" 'echo "$out" | grep -q "还没有备份" && echo "$out" | grep -q "位置：$PRIVATE_BK（只有 root 能读"'
check "开关一栏" 'echo "$out" | grep -q "备份 1，私密位置 1，自动重开 1，通知 1" && echo "$out" | grep -q "清理 TT 30 天以前的日志（0 = 不清理），温度提醒 45°C（0 = 不提醒），3 天没拷到电脑提醒"'
check "温度" 'echo "$out" | grep -q "温度：电池 36°C，处理器 38°C，主板 —°C"'
check "版本" 'echo "$out" | grep -q "TT 版本：2.3.0；系统浏览器内核：com.google.android.webview, 153.0.8010.36"'
check "空间" 'echo "$out" | grep -q "^聊天和设置 .*，TT 日志 .*，缓存 .*，本模块的备份 "'
check "崩溃记录份数" 'echo "$out" | grep -q "崩溃记录：1 份（最新 19700101-000000-5）"'
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

echo "[customize] 升级：旧模块目录的数据复制到 /data/adb/tt-guard"
newmod 12; OLD=$T/old; G=$T/guard12; mkdir -p "$OLD" "$T/new"
echo whitelist=yes > "$OLD/prior.txt"; echo last_exit=x > "$OLD/state.txt"; echo l > "$OLD/service.log"
echo backup=0 > "$OLD/config.txt"; echo "01-01 1 2 3 4 5 6" > "$OLD/stats.txt"; mkdir -p "$OLD/crash/c1"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "prior" 'grep -qx whitelist=yes "$G/prior.txt"'
check "state、日志、设置、统计、崩溃记录" 'grep -qx last_exit=x "$G/state.txt" && [ -f "$G/service.log" ] && grep -qx backup=0 "$G/config.txt" && [ -f "$G/stats.txt" ] && [ -d "$G/crash/c1" ]'
check "数据目录只有 root 能进" '[ "$(ls -ld "$G" | cut -c1-10)" = drwx------ ]'
echo whitelist=no > "$OLD/prior.txt"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "已有的不覆盖（再装一次）" 'grep -qx whitelist=yes "$G/prior.txt"'
rm -rf "$G" "$OLD/prior.txt"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "从 1.0/1.1 升级按默认" 'grep -qx whitelist=no "$G/prior.txt"'
rm -rf "$G" "$OLD"
( ui_print() { :; }; MODPATH=$T/new OLD_MODDIR=$OLD TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "全新安装不写 prior" '[ ! -f "$G/prior.txt" ]'

echo "[1.6] 旧版本数据迁移、禁用开关"
newmod 13; G=$T/guard13; export TT_GUARD_DIR=$G
echo "01-01 00:00:00 旧日志" > "$TT_MODDIR/service.log"; echo last_exit=y > "$TT_MODDIR/state.txt"
( load; migrate_data
  check "模块目录里的旧数据搬到数据目录" 'grep -q 旧日志 "$G/service.log" && [ ! -f "$TT_MODDIR/service.log" ] && grep -qx last_exit=y "$G/state.txt"'
  FAKE_WL=no FAKE_RAIB=ignore; touch "$TT_MODDIR/disable"; : > "$CALLS"
  FAKE_PIDS="" FAKE_NOW=$DAY0; tick; FAKE_NOW=$((DAY0 + 60)); tick
  check "在管理器里禁用：不改任何设置" '[ ! -s "$CALLS" ]'
  check "禁用：日志只记一次" '[ "$(grep -c "模块已在管理器中禁用" "$LOG")" = 1 ]'
  rm "$TT_MODDIR/disable"; touch "$TT_MODDIR/remove"; FAKE_NOW=$((DAY0 + 120)); tick
  check "标记删除：同样不改" '[ ! -s "$CALLS" ]'
  rm "$TT_MODDIR/remove"; FAKE_NOW=$((DAY0 + 180)); tick
  check "恢复启用：照常工作" 'calls | grep -q "whitelist +com.tauritavern.client"'
)
export TT_GUARD_DIR=$TT_MODDIR

echo "[uninstall] 删除数据目录，备份留着"
newmod 14; G=$T/guard14; mkdir -p "$G" "$PRIVATE_BK"; printf 'whitelist=no\n' > "$G/prior.txt"; echo x > "$G/state.txt"
echo x > "$PRIVATE_BK/tt-default-user-19700101-000000.tar.gz"
TT_GUARD_DIR=$G UNINSTALL_DELAY=0 sh "$TT_MODDIR/uninstall.sh"; i=0
while [ $i -lt 50 ] && [ -d "$G" ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
check "读新位置的原值（撤白名单）" 'calls | grep -q "whitelist -com.tauritavern.client"'
check "数据目录删掉" '[ ! -d "$G" ]'
check "备份没删（搬到共享位置）" '[ -f "$SHARED_BK/tt-default-user-19700101-000000.tar.gz" ]'

echo "[断电 / 没电] 低电量提前备份"
bat() { mkdir -p "$BATTERY_DIR"; echo "$1" > "$BATTERY_DIR/capacity"; echo "$2" > "$BATTERY_DIR/status"; }
newmod 60; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user"; echo x > "$TT_DATA/default-user/a"
    bat 80 Discharging; FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "先有一份正常备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    touch -t 200001010000 "$TT_MODDIR/backup.marker"
    FAKE_NOW=$((DAY0 + 1200)); bat 12 Discharging; tick
    check "低电量：不到 30 分钟不提前备份" '[ "$(bk | wc -l | tr -d " ")" = 1 ]'
    FAKE_NOW=$((DAY0 + 3600)); tick
    check "低电量、数据变了：不等 6 小时提前备份" '[ "$(bk | wc -l | tr -d " ")" = 2 ] && grep -q "电量低于 15%，提前备份" "$LOG"'
    touch -t 200001010000 "$TT_MODDIR/backup.marker"; FAKE_NOW=$((DAY0 + 7200)); tick
    check "同一次放电只提前一次" '[ "$(bk | wc -l | tr -d " ")" = 2 ]'
    bat 12 Charging; FAKE_NOW=$((DAY0 + 7300)); tick
    bat 10 Discharging; FAKE_NOW=$((DAY0 + 7400)); tick
    check "充过电再低电量：可以再提前一次" '[ "$(bk | wc -l | tr -d " ")" = 3 ]'
    touch -t 200001010000 "$TT_MODDIR/backup.marker"; bat 60 Discharging; FAKE_NOW=$((DAY0 + 9500)); tick
    check "电量正常：照常按间隔" '[ "$(bk | wc -l | tr -d " ")" = 3 ]'
    rm -rf "$BATTERY_DIR"; FAKE_NOW=$((DAY0 + 9600)); tick
    check "读不到电量：当作正常" '[ "$(bk | wc -l | tr -d " ")" = 3 ]'
    )

echo "[断电 / 没电] 开机检查：写坏的备份隔离"
newmod 61; ( load
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0
    mkdir -p "$TT_DATA/default-user"; echo x > "$TT_DATA/default-user/a"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    touch -t 200001010000 "$TT_MODDIR/backup.marker"; FAKE_NOW=$((DAY0 + 7 * 3600)); tick
    n=$(bk | sort | tail -n 1); o=$(bk | sort | head -n 1)
    printf 'x' > "$BACKUP_DIR/$n"                                  # 模拟：改名完成，内容没写进存储就断电
    echo half > "$BACKUP_DIR/.tt-default-user-19700102-080000.tar.gz.part"
    migrated=""; : > "$CALLS"; FAKE_NOW=$((DAY0 + 8 * 3600)); tick
    check "最新的备份校验不对：改名隔离" '[ -f "$BACKUP_DIR/$n.broken" ] && [ ! -f "$BACKUP_DIR/$n" ] && [ ! -f "$BACKUP_DIR/$n.sha256" ]'
    check "隔离的不出现在列表里" '! list_backups | grep -q "$n"'
    check "旧的完好备份不动" '[ -f "$BACKUP_DIR/$o" ] && [ -f "$BACKUP_DIR/$o.sha256" ]'
    check "写到一半的临时文件清掉" '[ -z "$(ls -a "$BACKUP_DIR" | grep "\.part")" ]'
    check "记日志并通知" 'grep -q "最新备份校验失败，已隔离" "$LOG" && calls | grep -q "备份文件损坏，已隔离"'
    migrated=""; : > "$CALLS"; FAKE_NOW=$((DAY0 + 9 * 3600)); tick
    check "再开机：完好的不误报" '! calls | grep -q "备份文件损坏"'
    )

echo "[断电 / 没电] 恢复中途断电"
newmod 62
U=$TT_DATA/default-user; mkdir -p "$U/chats" "$BACKUP_DIR"; echo "旧" > "$U/chats/1.jsonl"
( cd "$TT_DATA" && tar -czf "$BACKUP_DIR/tt-default-user-19700101-000000.tar.gz" default-user )
mkdir -p "$BATTERY_DIR"; echo 9 > "$BATTERY_DIR/capacity"; echo Discharging > "$BATTERY_DIR/status"
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "电量低于 15% 且没充电：不恢复" '[ $r = 10 ] && grep -q "请先充电" "$T/r.out" && [ ! -d "$TT_MODDIR/.restore.lock" ]'
echo Charging > "$BATTERY_DIR/status"
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > "$T/r.out"; r=$?
check "低电量但在充电：可以恢复" '[ $r = 0 ]'
check "恢复完成：没有留下「未完成」标记" '[ ! -f "$TT_MODDIR/restore.pending" ]'
( load
    echo "tt-default-user-19700101-000000.tar.gz|tt-default-user-19700101-000100-prerestore.tar.gz" > "$TT_MODDIR/restore.pending"
    mkdir -p "$TT_DATA/.cc-restore/default-user"
    FAKE_WL=yes FAKE_RAIB=allow FAKE_EXIT=$T/none; state_set last_exit 0; : > "$CALLS"
    FAKE_PIDS="" FAKE_NOW=$DAY0; tick
    check "开机发现恢复没做完：通知，说明恢复前的数据在哪" 'calls | grep -q "上次恢复未完成" && calls | grep -q "prerestore"'
    check "清掉残留的临时目录" '[ ! -e "$TT_DATA/.cc-restore" ]'
    check "界面能看到" 'sh "$TT_MODDIR/ui.sh" status | grep -q "\"restore_interrupted\":\"tt-default-user-19700101-000000.tar.gz|"'
    check "只提醒一次" '[ ! -f "$TT_MODDIR/restore.pending" ]'
    )
sh "$TT_MODDIR/restore.sh" tt-default-user-19700101-000000.tar.gz > /dev/null
check "重新恢复成功后界面不再提示" 'sh "$TT_MODDIR/ui.sh" status | grep -q "\"restore_interrupted\":\"\""'

echo "[省电模式]"
newmod 63; ( load
    check_power; check "没开：不记" '! grep -q 省电 "$LOG" 2>/dev/null'
    export FAKE_LOWPOWER=1; check_power
    check "开启时记一行" 'grep -q "系统已开启省电模式" "$LOG"'
    check_power
    check "不重复记" '[ "$(grep -c 省电模式 "$LOG")" = 1 ]'
    export FAKE_LOWPOWER=0; check_power; check "关闭时记一行" 'grep -q "系统已关闭省电模式" "$LOG"'
    out=$(FAKE_LOWPOWER=1 sh "$TT_MODDIR/ui.sh" selftest)   # 给外部命令的前缀赋值是安全的
    check "自检里显示" 'printf "%s" "$out" | grep -q "\"name\":\"省电模式\",\"ok\":false"'
    mkdir -p "$BATTERY_DIR"; echo 55 > "$BATTERY_DIR/capacity"; echo Charging > "$BATTERY_DIR/status"
    check "状态里有电量和充电" 'sh "$TT_MODDIR/ui.sh" status | grep -q "\"power\":{\"level\":55,\"charging\":true,\"saver\":\"\"}"'
    )

echo "[Root 管理器]"
newmod 64; ( load
    check "识别不了：未识别" '[ "$(root_manager)" = 未识别 ]'
    mkdir -p "$ADB_DIR/ksu"; printf '#!/bin/sh\necho "ksud 3.3.0"\n' > "$ADB_DIR/ksud"; chmod +x "$ADB_DIR/ksud"
    check "KernelSU 带版本" '[ "$(root_manager)" = "KernelSU（ksud 3.3.0）" ]'
    check "KernelSU Next" '[ "$(export FAKE_PKGS=com.rifsxd.ksunext; root_manager)" = "KernelSU Next（ksud 3.3.0）" ]'
    check "SukiSU Ultra" '[ "$(export FAKE_PKGS="x com.sukisu.ultra"; root_manager)" = "SukiSU Ultra（ksud 3.3.0）" ]'
    check "包名只按整行匹配" '[ "$(export FAKE_PKGS=com.sukisu.ultra.fake; root_manager)" = "KernelSU（ksud 3.3.0）" ]'
    rm -rf "$ADB_DIR"; mkdir -p "$ADB_DIR/ap"
    check "APatch" '[ "$(root_manager)" = APatch ]'
    rm -rf "$ADB_DIR"; mkdir -p "$ADB_DIR/magisk"
    check "Magisk" 'case "$(root_manager)" in Magisk*) true ;; *) false ;; esac'
    out=$(sh "$TT_MODDIR/ui.sh" selftest)
    check "Magisk：自检说明界面的打开方式" 'printf "%s" "$out" | grep -q "需另装 WebUI X"'
    check "action 输出里有" 'sh "$TT_MODDIR/action.sh" | grep -q "Root 管理器：Magisk"'
    )
G=$T/guard65
( ui_print() { echo "$*" >> "$T/ui65"; }; MODPATH=$T/new MAGISK_VER_CODE=28100 TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "安装时：Magisk 提示界面打开方式" 'grep -q "Magisk 不能直接打开模块界面" "$T/ui65"'
rm -f "$T/ui65"
( ui_print() { echo "$*" >> "$T/ui65"; }; MODPATH=$T/new KSU=true TT_GUARD_DIR=$G; . "$MOD/customize.sh" )
check "安装时：KernelSU 提示点击模块" 'grep -q "点击本模块可打开界面" "$T/ui65"'
export TT_GUARD_DIR=$TT_MODDIR

pass=$(cat "$T/pass" 2>/dev/null | wc -l | tr -d " "); failn=$(cat "$T/fail" 2>/dev/null | wc -l | tr -d " ")
echo "通过 $pass，失败 $failn"
[ "$failn" = 0 ]
