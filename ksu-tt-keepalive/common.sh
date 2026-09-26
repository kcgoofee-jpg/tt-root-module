# service.sh 和 action.sh 共用的函数（source 进来，不单独运行）。
# 只读系统状态、只动 com.tauritavern.client 一个包；所有外部命令都是 Android 自带的。
# 测试时（tests/run.sh）用同名 shell 函数替换 dumpsys / cmd / am / pidof 等，并改下面几个路径。

# KernelSU 启动 service.sh 时 umask 是 0，新建的文件会变成人人可写；改回常规的 022
umask 022

PKG=com.tauritavern.client
MODDIR=${TT_MODDIR:-${0%/*}}
LOG=${LOG:-$MODDIR/service.log}
PRIOR=${PRIOR:-$MODDIR/prior.txt}
STATE=${STATE:-$MODDIR/state.txt}
CG_ROOT=${CG_ROOT:-/sys/fs/cgroup/apps}                 # Android 冻结器（cgroup v2）
OPLUS_FROZEN=${OPLUS_FROZEN:-/dev/freezer/frozen/cgroup.procs}   # ColorOS 自己的冻结器（cgroup v1）
GEN_SERVICE=AiGenerationForegroundService              # TT 2.3.0 起生成回复时才开的前台服务
NOTIFY_TAG=claudemax_tt_keepalive

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
    # 超过 240 行就只留最近 200 行
    if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 240 ] 2>/dev/null; then
        tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

# 状态文件：key=value，每个 key 一行
state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1; }
state_set() {
    { grep -v "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

app_uid() { stat -c %u "/data/data/$PKG" 2>/dev/null; }

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
            r = $0; sub(/.* reason=[0-9]* \(/, "", r); sub(/\).*/, "", r)
            s = ""; if ($0 ~ /subreason=/) { s = $0; sub(/.* subreason=[0-9]* \(/, "", s); sub(/\).*/, "", s) }
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

# 一条退出记录 → 一行人话
exit_line() {
    IFS='|' read -r ts pid r s imp d <<EOF
$1
EOF
    echo "TT（$pid）${ts#* } 退出：$(exit_reason_zh "$r" "$s")［$r${s:+ / $s}，重要度 $imp${d:+，$(echo "$d" | cut -c1-60)}］"
}

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

# 网络是否被系统限制：输出 blocked_state 里 effective= 后面的值（NONE = 没限制）
net_effective() {
    dumpsys netpolicy 2>/dev/null | sed -n "s/.*UID=$1 state=.*effective=\([A-Z_|]*\).*/\1/p" | head -1
}
