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
# 备份放哪（config.txt 的 backup_private）：
#   1（默认）/data/adb/tt-backups：只有 root 能读，别的应用看不到你的聊天；卸载模块时搬到下面的共享位置
#   0 「内部存储/Documents/TauriTavern-backup」：文件管理器能直接看到（有存储权限的应用也都能读）
PRIVATE_BK=${PRIVATE_BK:-/data/adb/tt-backups}
SHARED_BK=${SHARED_BK:-/data/media/0/Documents/TauriTavern-backup}
# 备份哪些：聊天、角色卡、设置（default-user），扩展，Claude Max 的归档，自定义样式，TT 的 MCP / 技能配置
BACKUP_MEMBERS="default-user extensions _cm_archive _css _tauritavern"
RETENTION=${RETENTION:-$MODDIR/retention.awk}
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
# 开关：config.txt 里 key=value；没写、写错（不是数字）就用默认值 $2。
# 容错：Windows 记事本存的 \r、行尾注释、前后空格
cfg() {
    [ -f "$CONFIG" ] || { echo "$2"; return; }
    v=$(tr -d '\r' < "$CONFIG" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^ #]*\).*/\1/p" | head -1)
    case "$v" in ''|*[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac
}

# 开关的默认值（config.txt 没有的就用这里的）。改完不用重启，最多 1 分钟生效
DEFAULT_CONFIG='# TauriTavern 保活模块的开关（1 开 0 关）。改完不用重启，最多 1 分钟后生效；也可以在 KernelSU 里打开本模块的界面改。
# 自动备份 TT 的数据（不含 API 密钥）
backup=1
# 数据有变化时，最多每几小时备份一次
backup_hours=6
# 备份放在只有 root 能读的地方（1）还是「内部存储/Documents/TauriTavern-backup」（0）
backup_private=1
# 分层保留：按天留几天、按周留几周、按月留几个月
keep_days=7
keep_weeks=4
keep_months=6
# 几天没把备份拷到电脑就提醒（0 = 不提醒）
mac_alert_days=3
# 生成回复到一半被系统杀掉时，自动重新打开 TT
auto_reopen=1
# 出事时发通知
notify=1
# 清理 TT 自己多少天以前的运行日志和错误记录（0 = 不清理）
cleanup_days=30
# 生成回复时电池温度到多少度提醒（0 = 不提醒）
temp_alert=45'
# 界面上能改的开关（值只能是数字）
CONFIG_KEYS="backup backup_hours backup_private keep_days keep_weeks keep_months mac_alert_days auto_reopen notify cleanup_days temp_alert"

# 旧版本升级上来的 config.txt：补上没有的新开关（已有的不动），去掉不再用的（backup_keep 换成了 keep_days）
config_fill() {
    [ -f "$CONFIG" ] || { echo "$DEFAULT_CONFIG" > "$CONFIG"; return; }
    if grep -q '^backup_keep=' "$CONFIG"; then
        kd=$(cfg backup_keep 7)
        grep -v -e '^backup_keep=' -e '^# 备份留几份' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        grep -q '^keep_days=' "$CONFIG" || { echo "# 分层保留：按天留几天、按周留几周、按月留几个月"; echo "keep_days=$kd"; } >> "$CONFIG"
    fi
    echo "$DEFAULT_CONFIG" | grep -E '^[a-z_]+=' | while IFS= read -r line; do
        k=${line%%=*}
        grep -q "^$k=" "$CONFIG" 2>/dev/null && continue
        c=$(echo "$DEFAULT_CONFIG" | grep -B1 "^$k=" | head -n 1)
        case "$c" in '#'*) grep -qxF "$c" "$CONFIG" || echo "$c" >> "$CONFIG" ;; esac
        echo "$line" >> "$CONFIG"
    done
}

# 改一个开关：$1 名字（必须在 CONFIG_KEYS 里），$2 数字
config_set() {
    case " $CONFIG_KEYS " in *" $1 "*) ;; *) return 2 ;; esac
    case "$2" in ''|*[!0-9]*) return 2 ;; esac
    config_fill
    if grep -q "^$1=" "$CONFIG"; then
        sed "s/^$1=.*/$1=$2/" "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    else
        echo "$1=$2" >> "$CONFIG"
    fi
}

# 每日统计：一行「日期 生成次数 生成秒数 冻结 生成中冻结 被系统结束 被强制停止」
# stat_add 列号 增量（列号 2..7）
stat_add() { with_lock stats _stat_add "$@"; }
_stat_add() {
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
# 状态文件和统计文件会被好几个进程写（常驻循环、界面、电脑），改之前先拿锁，免得互相覆盖丢掉
# 在子 shell 里跑（圆括号），不改外面的同名变量（i、r 之类）
with_lock() (   # with_lock 锁名 命令…：最多等 5 秒；超过 60 秒的锁当作残留
    l=$MODDIR/.$1.lock; shift; i=0
    until mkdir "$l" 2>/dev/null; do
        i=$((i + 1))
        if [ $i -gt 50 ]; then
            [ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "${l:?}" && continue
            break
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    "$@"; r=$?
    rm -rf "${l:?}"
    exit $r
)
_state_set() {
    { grep -v "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } > "$STATE.tmp.$$" && mv "$STATE.tmp.$$" "$STATE"
}
state_set() { with_lock state _state_set "$@"; }

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
        "LOW MEMORY")               echo "内存不足，被系统回收" ;;
        "USER REQUESTED")
            case "$2" in
                "FORCE STOP") echo "强制停止（最近任务划掉、设置中强行停止或 adb）" ;;
                *)            echo "用户停止" ;;
            esac ;;
        "USER STOPPED")             echo "用户在任务管理中停止" ;;
        "SIGNALED")                 echo "被系统信号结束（通常为厂商后台清理）" ;;
        "APP CRASH(EXCEPTION)"|"APP CRASH(NATIVE)"|CRASH*) echo "应用崩溃" ;;
        "ANR")                      echo "应用无响应（ANR）" ;;
        "EXCESSIVE RESOURCE USAGE") echo "资源占用过高，被系统结束" ;;
        "FREEZER")                  echo "冻结期间被系统结束" ;;
        "PACKAGE UPDATED")          echo "应用更新" ;;
        "PACKAGE STATE CHANGE")     echo "应用被停用或状态变化" ;;
        "EXIT SELF")                echo "应用自行退出" ;;
        "OTHER KILLS BY SYSTEM")    echo "系统清理" ;;
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
    case "${2:-}" in *TASK*|*USER*) return 1 ;; esac   # 最近任务里划掉之类，是用户的意思
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

# 现在的备份目录 / 另一个位置
bdir() { if [ "$(cfg backup_private 1)" = 0 ]; then echo "$SHARED_BK"; else echo "$PRIVATE_BK"; fi; }
other_bdir() { if [ "$(cfg backup_private 1)" = 0 ]; then echo "$PRIVATE_BK"; else echo "$SHARED_BK"; fi; }

# 备份文件名，新的在前
list_backups() { ls "$(bdir)" 2>/dev/null | grep '^tt-default-user-.*\.tar\.gz$' | sort -r; }

# 私密位置只有 root 能读；共享位置给 media_rw（1023），文件管理器才能看到、删掉
# 同一分区里 mv 会带着原来的 SELinux 标签，搬完要改成目标位置该有的标签，文件管理器才读得到
fix_bk_perms() {
    if [ "$1" = "$PRIVATE_BK" ]; then
        chown -R 0:0 "$1"; chmod 700 "$1"; chmod 600 "$1"/tt-default-user-*
        command -v chcon >/dev/null && chcon -R u:object_r:adb_data_file:s0 "$1"
    else
        chown -R 1023:1023 "$1"; chmod 775 "$1"; chmod 664 "$1"/tt-default-user-*
        command -v chcon >/dev/null && chcon -R u:object_r:media_rw_data_file:s0 "$1"
    fi 2>/dev/null
}

# 目录所在分区的剩余空间（KB）
free_kb() { df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

# 空间够不够再做一份备份：留出「上一份的两倍 + 500 MB」，免得挤得 TT 自己存不了聊天
space_ok() {
    d=$(bdir); mkdir -p "$d" 2>/dev/null
    newest=$(ls "$d" 2>/dev/null | grep '^tt-default-user-.*\.tar\.gz$' | sort -r | head -n 1)
    last=$([ -n "$newest" ] && du -k "$d/$newest" 2>/dev/null | cut -f1)
    need=$(( ${last:-60000} * 2 + 512000 ))
    f=$(free_kb "$d")
    [ -z "$f" ] || [ "$f" -ge "$need" ]
}

# 换了位置（backup_private 改了）就把已有的备份搬过去。输出搬了几个文件
migrate_backups() {
    to=$(bdir); from=$(other_bdir); n=0
    for f in "$from"/tt-default-user-*; do
        [ -f "$f" ] || continue
        mkdir -p "$to" && mv "$f" "$to/" && n=$((n + 1))
    done
    [ $n -gt 0 ] && { rmdir "$from" 2>/dev/null; fix_bk_perms "$to"; }
    echo $n
}

# 算文件的 sha256，输出「哈希  文件名」（和 sha256sum / shasum -c 的格式一样）；$1 目录，$2 文件名
sha_line() {
    ( cd "$1" && { sha256sum "$2" 2>/dev/null || shasum -a 256 "$2"; } )
}

# 上次备份以后 TT 的数据有没有变（有变化才值得再备份）
data_changed() {
    [ -f "$MODDIR/backup.marker" ] || return 0
    [ -n "$(list_backups | grep -v prerestore | head -n 1)" ] || return 0   # 备份被删光了：当作有变化
    for mem in $BACKUP_MEMBERS; do
        [ -e "$TT_DATA/$mem" ] || continue
        find "$TT_DATA/$mem" -type f -newer "$MODDIR/backup.marker" 2>/dev/null \
            | grep -vE '/default-user/(backups|thumbnails|\.staging)/|/default-user/content\.log$|/secrets\.json$' \
            | grep -q . && return 0
    done
    return 1
}

# 备份 TT 的数据，做完马上校验（完整读一遍、里面要有 default-user），再写 .sha256 给电脑核对。
# 不含：API 密钥（任何位置的 secrets.json）、TT 自己的备份、缩略图、日志和临时文件。
# 成功输出备份文件路径，失败返回 1。同一时间只跑一个（界面上点的和定时的不会撞车）
backup_now() {
    [ -d "$TT_DATA/default-user" ] || return 1
    d=$(bdir); mkdir -p "$d" || return 1
    lock=$MODDIR/.backup.lock
    if ! mkdir "$lock" 2>/dev/null; then
        # 超过 30 分钟的锁当作是上次断电 / 被杀留下的
        [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ] || return 1
        rm -rf "${lock:?}"; mkdir "$lock" || return 1
    fi
    touch "$MODDIR/backup.marker.new"   # 备份开始前的时间点：备份途中改的文件下次还会算「有变化」
    name=tt-default-user-$(date +%Y%m%d-%H%M%S)${1:+-$1}.tar.gz   # $1=prerestore：恢复前自动存的那份
    part=$d/.$name.part
    members=""
    for m in $BACKUP_MEMBERS; do [ -e "$TT_DATA/$m" ] && members="$members $m"; done
    good=0
    if nice -n 19 tar -czf "$part" -C "$TT_DATA" \
        --exclude='*/secrets.json' --exclude=default-user/secrets.json --exclude=default-user/backups \
        --exclude=default-user/thumbnails --exclude=default-user/content.log --exclude=default-user/.staging \
        $members 2>/dev/null \
        && tar -tzf "$part" > "$part.list" 2>/dev/null && grep -q '^default-user/' "$part.list" \
        && ! grep -q 'secrets\.json$' "$part.list" \
        && mv "$part" "$d/$name"; then
        sha_line "$d" "$name" > "$d/$name.sha256" && good=1
    fi
    if [ $good = 1 ]; then
        [ -n "${1:-}" ] || mv "$MODDIR/backup.marker.new" "$MODDIR/backup.marker"
        rm -f "$MODDIR/backup.marker.new"
        fix_bk_perms "$d"
    else
        rm -f "$part" "$d/$name" "$d/$name.sha256" "$MODDIR/backup.marker.new"
    fi
    rm -f "$part.list"
    # 备份途中改了备份位置：搬到新位置，免得留在界面看不到的地方
    [ $good = 1 ] && [ "$d" != "$(bdir)" ] && migrate_backups >/dev/null
    [ $good = 1 ] && echo "$(bdir)/$name"
    rm -rf "${lock:?}"
    [ $good = 1 ]
}

# 按天 / 周 / 月分层保留（见 retention.awk），删掉多出来的。输出删掉的文件名
apply_retention() {
    d=$(bdir)
    list_backups | awk -v today="$(date +%Y%m%d)" -v days="$(cfg keep_days 7)" \
        -v weeks="$(cfg keep_weeks 4)" -v months="$(cfg keep_months 6)" -f "$RETENTION" |
    while read -r act tier n; do
        [ "$act" = drop ] || continue
        rm -f "$d/$n" "$d/$n.sha256" && echo "$n"
    done
}

# 恢复前自动存的那几份（-prerestore）不走分层保留，单独只留最新 3 份
prune_prerestore() {
    d=$(bdir)
    ls "$d" 2>/dev/null | grep '^tt-default-user-.*-prerestore\.tar\.gz$' | sort -r | tail -n +4 | while IFS= read -r n; do
        rm -f "$d/$n" "$d/$n.sha256" && echo "$n"
    done
}

# 每份备份的层级：输出「层级 文件名」，新的在前
backup_tiers() {
    list_backups | awk -v today="$(date +%Y%m%d)" -v days="$(cfg keep_days 7)" \
        -v weeks="$(cfg keep_weeks 4)" -v months="$(cfg keep_months 6)" -f "$RETENTION" |
    while read -r act tier n; do
        if [ "$act" = drop ]; then echo "drop $n"; else echo "$tier $n"; fi
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

# 某个温度传感器（/sys/class/thermal 里 type 等于 $1 的第一个）的整数 °C；读不到或读数不合理（没接的传感器
# 常报 -274 / 125 之类）就什么都不输出。$2 可以给第二个候选名（不同机型叫法不同）
THERMAL_ROOT=${THERMAL_ROOT:-/sys/class/thermal}
thermal_temp() {
    for want in "$@"; do
        for z in "$THERMAL_ROOT"/thermal_zone*; do
            [ "$(cat "$z/type" 2>/dev/null)" = "$want" ] || continue
            t=$(cat "$z/temp" 2>/dev/null)
            case "$t" in ''|*[!0-9-]*) continue ;; esac
            [ "$t" -gt 1000 ] 2>/dev/null && t=$((t / 1000))   # 大多数是毫摄氏度
            [ "$t" -ge -20 ] && [ "$t" -le 110 ] && { echo "$t"; return; }
        done
    done
}
soc_temp() { thermal_temp soc_max cpu-big-core7-0 cpu0-thermal tsens_tz_sensor0; }
board_temp() { thermal_temp board_temp skin-therm shell_front quiet-therm; }

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
    echo "$(k "$TT_DATA/default-user") $(k "$TT_LOGS") $(k "$TT_DATA/_cache") $(k "$(bdir)")"
}

# KB → 「12.3 MB」
human_kb() { awk -v k="${1:-0}" 'BEGIN { if (k >= 1024) printf "%.1f MB", k / 1024; else printf "%d KB", k }'; }
