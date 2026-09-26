#!/system/bin/sh
# TauriTavern 后台保活（KernelSU 模块；按 Magisk 的模块格式打包，Magisk 上没实测过），开机后以 root 运行，常驻一个很轻的循环
#
# 只动 com.tauritavern.client 这一个应用，全部是 Android 自带的开关：
#   1. 电池优化白名单（deviceidle）：息屏打盹（Doze）时网络不断、不受待机限制
#   2. 允许后台运行（appops RUN_IN_BACKGROUND / RUN_ANY_IN_BACKGROUND）
#   1、2 每 10 分钟核对一次，丢了就补（比如重装过 TT）；改之前把原来的值记在本模块目录的 prior.txt，卸载时还原成它
#   3. 待机分组：只在被系统降到「活跃」以下时拉回「活跃」（在白名单里时是 5「豁免」，更好，不去碰）。
#      这个设置系统会存盘，重启后还在；卸载时还原成改之前的分组
# 下面几条只看不改：
#   4. TT 被 Android 或 ColorOS 冻结 / 解冻时记一行（含冻了多久、当时是否在生成回复）
#   5. TT 进程没了时，把系统记的退出原因（ApplicationExitInfo）翻成人话记一行；被系统杀的，顺带记系统日志里是谁动的手
#   6. TT 正在生成回复（它自己开着前台服务）时被冻结、进程没了或网络被限制：发一条通知
#   7. 每天统计：生成几次、多久，冻结几次，被系统结束 / 被强制停止几次（stats.txt，留 8 天）；
#      当天生成累计超过 5 小时提醒一次（Android 15 起这类前台服务每 24 小时最多约 6 小时）
#   8. TT 升级、重装时记一行
# 另外两件（config.txt 里可以关）：
#   9. 每天备份一次 TT 的数据到 /sdcard/Documents/TauriTavern-backup（不含 API 密钥），留最近 7 份
#  10. TT 生成回复到一半被「系统」杀掉（不是你划掉、不是强制停止）时，自动重新打开 TT，10 分钟内最多一次
#  11. 每天清理一次 TT 自己 30 天以前的运行日志和错误记录
#  12. 生成回复时手机太烫（电池 45°C 以上）提醒一次
# 另外只记录：TT 崩溃 / 没响应时把系统的崩溃记录和 TT 日志最后一段存进 crash/；系统浏览器内核（WebView）更新时记一行
# 从备份恢复见 restore.sh
# 不再调 /proc/<pid>/oom_score_adj（1.2 及以前做过）：系统决定冻结和查杀都不看它，还会被改回去。
# 生成回复时 TT 2.3.0 自己开前台服务，系统优先级约 200，本来就不会被 Android 冻结；空闲时被冻结是正常省电。
# 不联网、不下载、不含可执行文件；日志写在本模块目录的 service.log，留最近 7 天。

MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

FAST=15      # TT 在运行时的检查间隔（秒）
SLOW=60      # TT 没在运行时
CHECK=600    # 白名单 / 后台运行 / 待机分组的核对间隔
QUOTA=18000  # 当天生成累计到这么多秒就提醒一次（5 小时）
REOPEN_GAP=600

DEFAULT_CONFIG='# TauriTavern 保活模块的开关（1 开 0 关）。改完不用重启，最多 1 分钟后生效。
# 每天备份一次 TT 的数据到 /sdcard/Documents/TauriTavern-backup（不含 API 密钥）
backup=1
# 备份留几份
backup_keep=7
# 生成回复到一半被系统杀掉时，自动重新打开 TT
auto_reopen=1
# 出事时发通知
notify=1
# 清理 TT 自己多少天以前的运行日志和错误记录（0 = 不清理）
cleanup_days=30
# 生成回复时电池温度到多少度提醒（0 = 不提醒）
temp_alert=45'

# 旧版本升级上来的 config.txt 里没有的新开关，按默认值补上（已有的不动）
config_fill() {
    echo "$DEFAULT_CONFIG" | grep -E '^[a-z_]+=' | while IFS= read -r line; do
        k=${line%%=*}
        grep -q "^$k=" "$CONFIG" 2>/dev/null && continue
        echo "$DEFAULT_CONFIG" | grep -B1 "^$k=" | head -n 1 | grep '^#' >> "$CONFIG"
        echo "$line" >> "$CONFIG"
    done
}

# 第一次运行（装上后第一次开机）：记下改之前的原值，卸载时还原成它
record_prior() {
    [ -f "$PRIOR" ] && return
    if in_whitelist; then wl=yes; else wl=no; fi
    {
        echo "# $(date '+%Y-%m-%d %H:%M:%S') 模块第一次运行前的原值（卸载时还原成这些）"
        echo "whitelist=$wl"
        echo "RUN_IN_BACKGROUND=$(appop_mode RUN_IN_BACKGROUND)"
        echo "RUN_ANY_IN_BACKGROUND=$(appop_mode RUN_ANY_IN_BACKGROUND)"
    } > "$PRIOR"
    log "记下原值：白名单 $wl，后台运行 $(appop_mode RUN_ANY_IN_BACKGROUND)"
}

ensure() {
    if ! pm path "$PKG" >/dev/null 2>&1; then
        [ "$installed" != "no" ] && log "没装 $PKG，先不做，装上后自动生效"
        installed=no
        return 1
    fi
    installed=yes
    record_prior
    if ! in_whitelist; then
        dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 && log "已加入电池优化白名单"
    fi
    if [ "$(appop_mode RUN_ANY_IN_BACKGROUND)" != allow ]; then
        cmd appops set "$PKG" RUN_IN_BACKGROUND allow >/dev/null 2>&1
        cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 && log "已允许后台运行"
    fi
    b=$(am get-standby-bucket "$PKG" 2>/dev/null)
    case "$b" in ''|*[!0-9]*) ;; *)
        if [ "$b" -gt 10 ]; then
            grep -q '^bucket=' "$PRIOR" 2>/dev/null || echo "bucket=$b" >> "$PRIOR"
            am set-standby-bucket "$PKG" active >/dev/null 2>&1
            log "待机分组 $b → 10（活跃）"
        fi ;;
    esac
    new_uid=$(app_uid)
    old_uid=$(state_get tt_uid)
    [ -n "$old_uid" ] && [ -n "$new_uid" ] && [ "$old_uid" != "$new_uid" ] && log "TT 重装过（uid $old_uid → $new_uid）"
    [ -n "$new_uid" ] && [ "$new_uid" != "$old_uid" ] && state_set tt_uid "$new_uid"
    uid=$new_uid
    v=$(tt_version)
    old_v=$(state_get tt_version)
    [ -n "$old_v" ] && [ -n "$v" ] && [ "$old_v" != "$v" ] && log "TT 版本 $old_v → $v"
    [ -n "$v" ] && [ "$v" != "$old_v" ] && state_set tt_version "$v"
    w=$(webview_version)
    old_w=$(state_get webview)
    [ -n "$old_w" ] && [ -n "$w" ] && [ "$old_w" != "$w" ] && log "系统浏览器内核（WebView）更新：$old_w → $w"
    [ -n "$w" ] && [ "$w" != "$old_w" ] && state_set webview "$w"
    return 0
}

# 通知（config.txt 里 notify=0 就不发，只记日志）
alert() { [ "$(cfg notify 1)" = 1 ] && notify "$1" "$2"; }

# 记下新的退出记录；生成回复到一半进程没了就发通知，被系统杀的按开关自动重开
report_exits() {
    died_in_gen=""
    if [ "$gen_prev" = 1 ]; then
        for p in $prev_pids; do
            case " $pids " in *" $p "*) ;; *) died_in_gen=$p ;; esac
        done
    fi
    new_exits | while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        log "$(exit_line "$rec")"
        r=$(echo "$rec" | cut -d'|' -f3)
        if system_kill "$r"; then
            stat_add 6 1
            src=$(kill_source "$(echo "$rec" | cut -d'|' -f2)")
            [ -n "$src" ] && log "  系统日志：$src"
        elif [ "$r" = "USER REQUESTED" ]; then
            stat_add 7 1
        elif crash_reason "$r"; then
            cd_=$(save_crash "$rec")
            [ -n "$cd_" ] && log "  已保存崩溃记录：crash/${cd_##*/}"
            alert "TT $(exit_reason_zh "$r")" "系统的崩溃记录和 TT 日志已存进模块的 crash 文件夹，电脑上的「安卓保活模块」菜单会拷回电脑。"
        fi
        echo "$rec"
    done > "$STATE.exits"
    newest=$(tail -n 1 "$STATE.exits" 2>/dev/null | cut -d'|' -f1)
    [ -n "$newest" ] && state_set last_exit "$newest"
    if [ -n "$died_in_gen" ]; then
        gen_end; check_quota
        rec=$(grep "^[^|]*|$died_in_gen|" "$STATE.exits" | tail -n 1)
        r=$(echo "$rec" | cut -d'|' -f3)
        if [ -n "$rec" ]; then
            why=$(exit_reason_zh "$r" "$(echo "$rec" | cut -d'|' -f4)")
        else
            why="系统没记原因"; r=unknown
            log "TT（$died_in_gen）生成回复时进程没了，系统没记原因"
        fi
        extra="打开 TT 后，Claude Max 代理会补回暂存的回复。"
        if { system_kill "$r" || [ "$r" = unknown ]; } && [ "$(cfg auto_reopen 1)" = 1 ] \
            && [ $((now - last_reopen)) -ge $REOPEN_GAP ]; then
            if am start -n "$PKG/.MainActivity" >/dev/null 2>&1; then
                last_reopen=$now
                log "已自动重新打开 TT"
                extra="已自动重新打开 TT，Claude Max 代理会补回暂存的回复。"
            fi
        fi
        alert "TT 生成回复到一半进程没了" "原因：$why。$extra"
    fi
    rm -f "$STATE.exits"
}

# 一次生成结束：记进当天统计
gen_end() {
    [ -n "$gen_start" ] || return
    stat_add 2 1
    stat_add 3 $((now - gen_start))
    gen_start=""
}

# 当天生成累计快到上限时提醒一次
check_quota() {
    secs=$(stat_get 3)
    [ "${secs:-0}" -ge $QUOTA ] || return
    [ "$(state_get quota_day)" = "$(date +%m-%d)" ] && return
    state_set quota_day "$(date +%m-%d)"
    log "今天生成累计 $(human_secs "$secs")，快到 Android 的前台服务上限（每 24 小时约 6 小时）"
    alert "TT 今天生成已累计 $(human_secs "$secs")" "Android 限制这类后台生成每 24 小时约 6 小时，超过后 TT 在后台可能停住，放前台就没事。"
}

# 每天备份一次（生成中不备份；失败 1 小时后再试）
maybe_backup() {
    [ "$(cfg backup 1)" = 1 ] || return
    [ "$installed" = yes ] && [ "$gen" = 0 ] && unlocked || return
    last=$(state_get last_backup); last=${last:-0}
    tried=$(state_get backup_try); tried=${tried:-0}
    [ $((now - last)) -ge 86400 ] && [ $((now - tried)) -ge 3600 ] || return
    state_set backup_try "$now"
    if bf=$(backup_now); then
        state_set last_backup "$now"
        kb=$(du -k "$bf" 2>/dev/null | cut -f1)
        prune_backups "$(cfg backup_keep 7)"
        log "已备份 TT 数据：${bf##*/}（$kb KB，不含 API 密钥）"
    else
        log "备份 TT 数据失败，1 小时后再试"
    fi
}

# 每天清理一次 TT 自己的旧日志
maybe_cleanup() {
    [ "$installed" = yes ] && unlocked || return
    [ "$(state_get cleanup_day)" = "$day" ] && return
    state_set cleanup_day "$day"
    n=$(cleanup_tt "$(cfg cleanup_days 30)")
    [ "$n" -gt 0 ] 2>/dev/null && log "清理了 TT 自己 $(cfg cleanup_days 30) 天以前的日志和错误记录：$n 个文件"
}

# 生成回复时手机太烫：提醒一次
check_temp() {
    lim=$(cfg temp_alert 45)
    [ "$lim" -gt 0 ] 2>/dev/null && [ -z "$temp_alerted" ] || return
    t=$(battery_temp)
    [ -n "$t" ] && [ "$t" -ge "$lim" ] || return
    temp_alerted=1
    log "TT 生成回复时电池 ${t}°C（提醒线 ${lim}°C）"
    alert "手机有点烫：电池 ${t}°C" "TT 正在生成回复。可以先放下手机、别边充电边用，或在 TT 里调低动画和美化效果。"
}

tick() {
    now=$(date +%s)
    if [ $((now - last_check)) -ge $CHECK ]; then
        ensure
        last_check=$now
    fi

    pids=$(pidof "$PKG" 2>/dev/null)
    gen=0
    [ -n "$pids" ] && generating && gen=1
    if [ "$gen" = 1 ] && [ "$gen_prev" != 1 ]; then gen_alerted=""; net_alerted=""
temp_alerted=""; temp_alerted=""; gen_start=$now; fi
    [ "$gen" = 0 ] && [ "$gen_prev" = 1 ] && [ -n "$pids" ] && { gen_end; check_quota; }

    # 换了一天：日志只留 7 天
    day=$(date +%m-%d)
    [ "$day" != "$last_day" ] && { prune_log; last_day=$day; }

    if [ "$pids" != "$prev_pids" ] || [ $((now - last_exit_scan)) -ge $CHECK ]; then
        report_exits
        last_exit_scan=$now
    fi

    for pid in $pids; do
        by=$(frozen_by "$pid" "$uid")
        if [ -n "$by" ] && [ -z "$frozen_since" ]; then
            frozen_since=$now
            stat_add 4 1
            if [ "$gen" = 1 ]; then
                stat_add 5 1
                log "TT（$pid）被 $by 冻结了（正在生成回复）"
                if [ -z "$gen_alerted" ]; then
                    alert "TT 生成回复时被 $by 冻结了" "回复可能停住。打开 TT 就会解冻；Claude Max 代理会暂存回复。"
                    gen_alerted=1
                fi
            else
                log "TT（$pid）被 $by 冻结了"
            fi
        elif [ -z "$by" ] && [ -n "$frozen_since" ]; then
            log "TT（$pid）解冻，冻了约 $((now - frozen_since)) 秒"
            frozen_since=""
        fi
    done
    [ -z "$pids" ] && frozen_since=""

    # 生成中网络被系统限制：提醒一次
    if [ "$gen" = 1 ] && [ -z "$net_alerted" ]; then
        n=$(net_effective "$uid")
        if [ -n "$n" ] && [ "$n" != NONE ]; then
            log "TT 生成回复时网络被限制（$n）"
            alert "TT 生成回复时网络被系统限制了" "限制：$n。回复可能收不到，打开 TT 看看。"
            net_alerted=1
        fi
    fi

    [ "$gen" = 1 ] && check_temp

    maybe_backup
    maybe_cleanup

    gen_prev=$gen
    prev_pids=$pids
}

main() {
    # 等开机完成
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
    sleep 20
    # 第一次运行：系统里已有的退出记录不算新的
    if [ -z "$(state_get last_exit)" ]; then
        first=$(exit_records | head -n 1 | cut -d'|' -f1)
        state_set last_exit "${first:-0}"
    fi
    [ -f "$CONFIG" ] || echo "$DEFAULT_CONFIG" > "$CONFIG"
    config_fill
    log "开始运行（版本 $(sed -n 's/^version=//p' "$MODDIR/module.prop")）"
    while true; do
        tick
        if [ -n "$pids" ]; then sleep $FAST; else sleep $SLOW; fi
    done
}

installed=""
uid=""
last_check=0
last_exit_scan=0
prev_pids=""
gen_prev=0
gen_alerted=""
net_alerted=""
gen_start=""
frozen_since=""
last_reopen=0
last_day=""
[ "${TT_KEEPALIVE_TEST:-}" = 1 ] || main
