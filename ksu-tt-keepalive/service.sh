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
#   5. TT 进程没了时，把系统记的退出原因（ApplicationExitInfo）翻成人话记一行
#   6. TT 正在生成回复（它自己开着前台服务）时被冻结或进程没了：发一条通知
# 不再调 /proc/<pid>/oom_score_adj（1.2 及以前做过）：系统决定冻结和查杀都不看它，还会被改回去。
# 生成回复时 TT 2.3.0 自己开前台服务，系统优先级约 200，本来就不会被 Android 冻结；空闲时被冻结是正常省电。
# 不联网、不下载、不含可执行文件；日志写在本模块目录的 service.log，最多 200 行。

MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

FAST=15      # TT 在运行时的检查间隔（秒）
SLOW=60      # TT 没在运行时
CHECK=600    # 白名单 / 后台运行 / 待机分组的核对间隔

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
    uid=$(app_uid)
    return 0
}

# 记下新的退出记录；生成回复到一半进程没了就发通知
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
        echo "$rec"
    done > "$STATE.exits"
    newest=$(tail -n 1 "$STATE.exits" 2>/dev/null | cut -d'|' -f1)
    [ -n "$newest" ] && state_set last_exit "$newest"
    if [ -n "$died_in_gen" ]; then
        rec=$(grep "^[^|]*|$died_in_gen|" "$STATE.exits" | tail -n 1)
        if [ -n "$rec" ]; then
            why=$(exit_reason_zh "$(echo "$rec" | cut -d'|' -f3)" "$(echo "$rec" | cut -d'|' -f4)")
        else
            why="系统没记原因"
            log "TT（$died_in_gen）生成回复时进程没了，系统没记原因"
        fi
        notify "TT 生成回复到一半进程没了" "原因：$why。Claude Max 代理会暂存回复，重开 TT 后会补回。"
    fi
    rm -f "$STATE.exits"
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
    [ "$gen" = 1 ] && [ "$gen_prev" != 1 ] && gen_alerted=""

    if [ "$pids" != "$prev_pids" ] || [ $((now - last_exit_scan)) -ge $CHECK ]; then
        report_exits
        last_exit_scan=$now
    fi

    for pid in $pids; do
        by=$(frozen_by "$pid" "$uid")
        if [ -n "$by" ] && [ -z "$frozen_since" ]; then
            frozen_since=$now
            if [ "$gen" = 1 ]; then
                log "TT（$pid）被 $by 冻结了（正在生成回复）"
                if [ -z "$gen_alerted" ]; then
                    notify "TT 生成回复时被 $by 冻结了" "回复可能停住。点开 TT 就会解冻；Claude Max 代理会暂存回复。"
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
frozen_since=""
[ "${TT_KEEPALIVE_TEST:-}" = 1 ] || main
