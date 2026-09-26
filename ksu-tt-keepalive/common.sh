# service.sh 和 action.sh 共用的函数（source 进来，不单独运行）。
# 只动 com.tauritavern.client 一个包；所有外部命令都是 Android 自带的。
# 测试时（tests/run.sh）用 PATH 里的假命令替换 dumpsys / cmd / am / pidof 等，并用环境变量改下面几个路径。

# KernelSU 启动 service.sh 时 umask 是 0，新建的文件会变成人人可写；改回常规的 022
umask 022

PKG=com.tauritavern.client
MODDIR=${TT_MODDIR:-${0%/*}}
LOG=${LOG:-$MODDIR/service.log}
PRIOR=${PRIOR:-$MODDIR/prior.txt}
STATE=${STATE:-$MODDIR/state.txt}
STATS=${STATS:-$MODDIR/stats.txt}      # 每天一行的统计，留 8 天
CONFIG=${CONFIG:-$MODDIR/config.txt}   # 开关，改完不用重启
TT_DATA=${TT_DATA:-/data/media/0/Android/data/$PKG/data}
TT_LOGS=${TT_LOGS:-/data/media/0/Android/data/$PKG/logs}   # TT 自己的日志和请求记录
CRASH_DIR=${CRASH_DIR:-$MODDIR/crash}                       # TT 崩溃 / 没响应时存的记录，留 10 份
ANR_DIR=${ANR_DIR:-/data/anr}
BATTERY_TEMP=${BATTERY_TEMP:-/sys/class/power_supply/battery/temp}   # 单位 0.1°C
# 就是「内部存储/Documents/TauriTavern-backup」。直接写底层目录（不依赖 /sdcard 的挂载），
# 写完把属主改成 media_rw（1023），文件管理器才能看到、删掉
BACKUP_DIR=${BACKUP_DIR:-/data/media/0/Documents/TauriTavern-backup}
CG_ROOT=${CG_ROOT:-/sys/fs/cgroup/apps}                 # Android 冻结器（cgroup v2）
OPLUS_FROZEN=${OPLUS_FROZEN:-/dev/freezer/frozen/cgroup.procs}   # ColorOS 自己的冻结器（cgroup v1）
GEN_SERVICE=AiGenerationForegroundService              # TT 2.3.0 起生成回复时才开的前台服务
NOTIFY_TAG=claudemax_tt_keepalive

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
    # 保底：超过 3000 行就只留最近 2500 行（平时按天清理，见 prune_log）
    if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 3000 ] 2>/dev/null; then
        tail -n 2500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

# 最近 N 天的日期（MM-DD），今天在前，空格分隔
recent_days() {
    n=0; out=""; t=$(date +%s)
    while [ $n -lt "$1" ]; do
        out="$out $(date -d "@$((t - n * 86400))" +%m-%d)"
        n=$((n + 1))
    done
    echo $out
}

# 日志只留最近 7 天
prune_log() {
    [ -f "$LOG" ] || return
    keep=$(recent_days 7)
    awk -v keep=" $keep " 'index(keep, " " $1 " ") > 0' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# 开关：config.txt 里 key=value；没写就用默认值 $2
cfg() {
    v=$(sed -n "s/^$1=\([^ #]*\).*/\1/p" "$CONFIG" 2>/dev/null | head -1)
    echo "${v:-$2}"
}

# 每日统计：一行「日期 生成次数 生成秒数 冻结 生成中冻结 被系统结束 被强制停止」
# stat_add 列号 增量（列号 2..7）
stat_add() {
    today=$(date +%m-%d)
    cat "$STATS" 2>/dev/null | awk -v d="$today" -v c="$1" -v n="$2" '
        $1 == d { $c += n; hit = 1 }
        { print }
        END { if (!hit) { split(d " 0 0 0 0 0 0", f, " "); f[c] += n; print f[1], f[2], f[3], f[4], f[5], f[6], f[7] } }' > "$STATS.tmp"
    tail -n 8 "$STATS.tmp" > "$STATS"; rm -f "$STATS.tmp"
}
stat_get() { cat "$STATS" 2>/dev/null | awk -v d="$(date +%m-%d)" -v c="$1" '$1 == d { print $c; f = 1 } END { if (!f) print 0 }'; }

# 状态文件：key=value，每个 key 一行
state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
state_set() {
    { grep -v "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# TT 的 uid。pm 在开机后、第一次解锁前也能查到；/data/data 要解锁后才读得到，只作后备
app_uid() {
    u=$(pm list packages -U "$PKG" 2>/dev/null | sed -n "s/^package:$PKG uid:\([0-9]*\).*/\1/p" | head -1)
    [ -n "$u" ] || u=$(stat -c %u "/data/data/$PKG" 2>/dev/null)
    echo "$u"
}

# 开机后第一次解锁手机之前，应用的数据（包括内部存储）是加密的，读不到
unlocked() { [ "$(getprop sys.user.0.ce_available)" = true ]; }

appop_mode() {   # 输出 allow / ignore / deny / default …
    m=$(cmd appops get "$PKG" "$1" 2>/dev/null | sed -n "s/^$1: \([a-z_]*\).*/\1/p" | head -1)
    echo "${m:-default}"
}

in_whitelist() { dumpsys deviceidle whitelist 2>/dev/null | grep -q ",$PKG,"; }

# 冻结状态：输出 Android / ColorOS，没冻结时什么都不输出。$1 = pid，$2 = uid
frozen_by() {
    ev=$CG_ROOT/uid_$2/pid_$1/cgroup.events
    [ -n "$2" ] && [ -r "$ev" ] && grep -q '^frozen 1' "$ev" && { echo Android; return; }
    [ -r "$OPLUS_FROZEN" ] && grep -qx "$1" "$OPLUS_FROZEN" && echo ColorOS
}

# TT 是否正在生成回复（它自己的前台服务在不在）
generating() {
    dumpsys activity services "$PKG" 2>/dev/null | grep -q "ServiceRecord{.* $PKG/[^ ]*$GEN_SERVICE"
}

# 系统记的 TT 主进程退出记录（ApplicationExitInfo），新的在前，一行一条：
#   时间|pid|原因|子原因|重要度|描述
exit_records() {
    dumpsys activity exit-info "$PKG" 2>/dev/null | awk -v p="$PKG" '
        /timestamp=/ {
            ts = $0; sub(/.*timestamp=/, "", ts); sub(/ pid=.*/, "", ts)
            pid = $0; sub(/.* pid=/, "", pid); sub(/ .*/, "", pid)
            want = 0; next
        }
        /process=/ && ts != "" {
            proc = $0; sub(/.*process=/, "", proc); sub(/ .*/, "", proc)
            want = (proc == p)
            # 原因文字本身可能带括号（APP CRASH(EXCEPTION)），所以截到「) subreason=」或「) status=」
            r = $0; sub(/.* reason=[0-9]* \(/, "", r); sub(/\) (subreason|status)=.*/, "", r)
            s = ""; if ($0 ~ /subreason=/) { s = $0; sub(/.* subreason=[0-9]* \(/, "", s); sub(/\) status=.*/, "", s) }
            next
        }
        /importance=/ && want {
            imp = $0; sub(/.*importance=/, "", imp); sub(/ .*/, "", imp)
            d = $0; sub(/.*description=/, "", d); sub(/ state=.*/, "", d); sub(/ trace=.*/, "", d)
            if ($0 !~ /description=/) d = ""
            print ts "|" pid "|" r "|" s "|" imp "|" d
            want = 0; ts = ""
        }'
}

# 把退出原因翻成人话。$1 = 原因，$2 = 子原因
exit_reason_zh() {
    case "$1" in
        "LOW MEMORY")               echo "内存不够，被系统回收" ;;
        "USER REQUESTED")
            case "$2" in
                "FORCE STOP") echo "被强制停止（最近任务里划掉、设置里强行停止，或电脑上 adb am force-stop）" ;;
                *)            echo "用户操作停止" ;;
            esac ;;
        "USER STOPPED")             echo "用户在任务管理里停止" ;;
        "SIGNALED")                 echo "被信号杀掉（多半是厂商的后台清理）" ;;
        "APP CRASH(EXCEPTION)"|"APP CRASH(NATIVE)"|CRASH*) echo "TT 自己崩溃了" ;;
        "ANR")                      echo "TT 没响应（ANR）被结束" ;;
        "EXCESSIVE RESOURCE USAGE") echo "占用资源太多被系统结束" ;;
        "FREEZER")                  echo "冻结期间被系统结束" ;;
        "PACKAGE UPDATED")          echo "TT 更新安装" ;;
        "PACKAGE STATE CHANGE")     echo "TT 被停用或状态变化" ;;
        "EXIT SELF")                echo "TT 自己退出" ;;
        "OTHER KILLS BY SYSTEM")    echo "系统的其他清理" ;;
        *)                          echo "其他（$1）" ;;
    esac
}

# 一条退出记录 → 一行人话（在子 shell 里跑，不改外面的同名变量）
exit_line() (
    IFS='|' read -r ts pid r s imp d <<EOF
$1
EOF
    echo "TT（$pid）${ts#* } 退出：$(exit_reason_zh "$r" "$s")［$r${s:+ / $s}，重要度 $imp${d:+，$(echo "$d" | cut -c1-60)}］"
)

# 比 state 里 last_exit 新的退出记录，旧的在前逐条输出（输出的是 exit_records 的原始行）
new_exits() {
    last=$(state_get last_exit)
    exit_records | awk -F'|' -v last="$last" '$1 > last' | sed -n '1!G;h;$p'
}

# 发一条通知（以 shell 身份发，root 直接发会被系统丢掉）；同一个 tag 只留最新一条
notify() {
    t=$(echo "$1" | tr -d "'"); b=$(echo "$2" | tr -d "'")
    su 2000 -c "cmd notification post -S bigtext -t '$t' $NOTIFY_TAG '$b'" >/dev/null 2>&1
}

# TT 的版本号
tt_version() { dumpsys package "$PKG" 2>/dev/null | sed -n 's/^ *versionName=//p' | head -1; }

# 系统结束 TT 的原因（不是用户、不是 TT 自己）：这类才值得自动重开
system_kill() {
    case "$1" in "LOW MEMORY"|SIGNALED|"OTHER KILLS BY SYSTEM"|FREEZER|"EXCESSIVE RESOURCE USAGE") return 0 ;; esac
    return 1
}

# 进程被杀时系统日志里谁动的手（ColorOS 的 athena / hans、lmkd 等），只读；$1 = pid
kill_source() {
    logcat -d -b main -b events 2>/dev/null | grep -E "[^0-9]$1[^0-9]" | grep -iE 'athena|hans|lmk|kill' | tail -n 1 | cut -c1-160
}

# 秒 → 「1 小时 5 分」
human_secs() {
    t=${1:-0}; h=$((t / 3600)); m=$((t % 3600 / 60))
    if [ $h -gt 0 ]; then echo "$h 小时 $m 分"; else echo "$m 分"; fi
}

# 网络是否被系统限制：输出 blocked_state 里 effective= 后面的值（NONE = 没限制）
net_effective() {
    dumpsys netpolicy 2>/dev/null | sed -n "s/.*UID=$1 state=.*effective=\([A-Z_|]*\).*/\1/p" | head -1
}

# 备份 TT 的数据（default-user），不含 API 密钥（secrets.json）、TT 自己的备份、缩略图和日志。
# 成功输出备份文件路径，失败返回 1。
backup_now() {
    [ -d "$TT_DATA/default-user" ] || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    name=tt-default-user-$(date +%Y%m%d-%H%M%S).tar.gz
    part=$BACKUP_DIR/.$name.part
    if nice -n 19 tar -czf "$part" -C "$TT_DATA" \
        --exclude=default-user/secrets.json --exclude=default-user/backups \
        --exclude=default-user/thumbnails --exclude=default-user/content.log \
        --exclude=default-user/.staging --exclude=default-user/.cc-restore \
        default-user 2>/dev/null && [ -s "$part" ]; then
        mv "$part" "$BACKUP_DIR/$name" || return 1
        chown 1023:1023 "$BACKUP_DIR" "$BACKUP_DIR/$name" 2>/dev/null
        chmod 775 "$BACKUP_DIR" 2>/dev/null; chmod 664 "$BACKUP_DIR/$name" 2>/dev/null
        echo "$BACKUP_DIR/$name"
    else
        rm -f "$part"; return 1
    fi
}

# 只留最新的 $1 份备份
prune_backups() {
    ls "$BACKUP_DIR"/tt-default-user-*.tar.gz 2>/dev/null | sort -r | tail -n +"$(($1 + 1))" | while IFS= read -r stale; do
        rm -f "$stale"
    done
}

# 系统浏览器内核（WebView）的版本，TT 靠它显示界面
webview_version() {
    dumpsys webviewupdate 2>/dev/null | sed -n 's/.*Current WebView package (name, version): (\(.*\))/\1/p' | head -1
}

# 电池温度（整数 °C），读不到时什么都不输出
battery_temp() {
    t=$(cat "$BATTERY_TEMP" 2>/dev/null)
    case "$t" in ''|*[!0-9-]*) return ;; esac
    echo $((t / 10))
}

# 是不是崩溃 / 没响应（这类要存证据）
crash_reason() {
    case "$1" in "APP CRASH"*|CRASH*|ANR) return 0 ;; esac
    return 1
}

# TT 崩溃 / 没响应时，把系统的崩溃记录、ANR 记录、TT 日志的最后一段存进 crash/时间-pid/，只留 10 份。
# $1 = exit_records 的一行。输出存放的目录。在子 shell 里跑，不改外面的同名变量
save_crash() (
    pid=$(echo "$1" | cut -d'|' -f2)
    d=$CRASH_DIR/$(date +%Y%m%d-%H%M%S)-$pid
    mkdir -p "$d" || return 1
    { exit_line "$1"; echo; echo "$1"; } > "$d/退出原因.txt"
    logcat -d -b crash 2>/dev/null | grep -E "[^0-9]$pid[^0-9]" | tail -n 300 > "$d/系统崩溃记录.txt"
    anr=$(grep -l "pid $pid" "$ANR_DIR"/anr_* 2>/dev/null | tail -n 1)
    [ -n "$anr" ] && head -n 400 "$anr" > "$d/ANR记录.txt"
    ttlog=$(ls "$TT_LOGS"/tauritavern.log.* 2>/dev/null | sort | tail -n 1)
    [ -n "$ttlog" ] && tail -n 200 "$ttlog" > "$d/TT日志最后200行.txt"
    for f in "$d"/*; do [ -s "$f" ] || rm -f "$f"; done
    ls -d "$CRASH_DIR"/*/ 2>/dev/null | sort -r | tail -n +11 | while IFS= read -r stale; do rm -rf "${stale:?}"; done
    echo "$d"
)

# 清理 TT 自己的旧日志：$1 天以前的 TT 运行日志（tauritavern.log.日期）和错误记录（_errors）。
# 请求记录（llm-api-*）TT 自己会清，不碰。输出删了几个文件
cleanup_tt() {
    [ "$1" -gt 0 ] 2>/dev/null || { echo 0; return; }
    { find "$TT_LOGS" -maxdepth 1 -type f -name 'tauritavern.log.*' -mtime +"$1" 2>/dev/null
      find "$TT_DATA/_errors" -maxdepth 1 -type f -mtime +"$1" 2>/dev/null; } > "$STATE.clean"
    n=0
    while IFS= read -r f; do rm -f "$f" && n=$((n + 1)); done < "$STATE.clean"
    rm -f "$STATE.clean"
    echo $n
}

# TT 各部分占多大（KB）：「数据 日志 缓存 本模块的备份」
tt_space() {
    k() { du -sk "$1" 2>/dev/null | cut -f1; }
    echo "$(k "$TT_DATA/default-user") $(k "$TT_LOGS") $(k "$TT_DATA/_cache") $(k "$BACKUP_DIR")"
}

# KB → 「12.3 MB」
human_kb() { awk -v k="${1:-0}" 'BEGIN { if (k >= 1024) printf "%.1f MB", k / 1024; else printf "%d KB", k }'; }
