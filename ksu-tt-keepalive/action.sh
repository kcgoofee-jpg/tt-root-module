#!/system/bin/sh
# KernelSU 管理器里点模块的「执行」按钮：只读，显示 TT 现在的状态、今天和最近 7 天的统计、备份和最近的日志
MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

echo "== TauriTavern 后台状态 =="
if in_whitelist; then echo "电池优化白名单：在"; else echo "电池优化白名单：不在"; fi
echo "后台运行：$(appop_mode RUN_ANY_IN_BACKGROUND)"
b=$(am get-standby-bucket "$PKG" 2>/dev/null)
case "$b" in 5) m="豁免，最好" ;; 10) m="活跃" ;; 20) m="常用" ;; 30) m="偶尔" ;; 40) m="很少" ;; 45) m="受限" ;; *) m="?" ;; esac
echo "待机分组：$b（$m）"
uid=$(app_uid)
n=$(net_effective "$uid")
case "$n" in NONE) echo "网络：没被限制" ;; '') echo "网络：看不到（TT 没在运行时正常）" ;; *) echo "网络：被限制（$n）" ;; esac
t=$(battery_temp); c=$(soc_temp); b=$(board_temp)
[ -n "$t$c$b" ] && echo "温度：电池 ${t:-—}°C，处理器 ${c:-—}°C，主板 ${b:-—}°C"
echo "TT 版本：$(tt_version)；系统浏览器内核：$(webview_version)"
l=$(battery_level); ps_=$(power_save)
[ -n "$l" ] && echo "电量：$l%$(charging && echo "，充电中")${ps_:+；已开启$ps_}"
echo "Root 管理器：$(root_manager)"

pids=$(pidof "$PKG" 2>/dev/null)
if [ -z "$pids" ]; then
    echo "TT 没在运行"
else
    if generating; then echo "正在生成回复：是（TT 开着前台服务，不会被 Android 冻结）"; else echo "正在生成回复：否"; fi
    for pid in $pids; do
        by=$(frozen_by "$pid" "$uid")
        echo "进程 $pid：${by:+被 $by 冻结}${by:-没冻结}"
    done
    # 系统自己记的优先级（冻结和查杀按这个判断：900 及以上会被冻结）
    dumpsys activity processes "$PKG" 2>/dev/null | awk -v p="$PKG" '/\*APP\*/{m=index($0, ":" p "/")>0} m&&/oom adj:/{sub(/^ */,""); print "系统记录的 " $0} m&&/isFrozen=/{match($0,/isFrozen=[a-z]*/); print "系统记录的 " substr($0,RSTART,RLENGTH); m=0}'
fi
echo "今天：生成 $(stat_get 2) 次，共 $(human_secs "$(stat_get 3)")；冻结 $(stat_get 4) 次（生成中 $(stat_get 5) 次）；被系统结束 $(stat_get 6) 次，被强制停止 $(stat_get 7) 次"

echo "== 最近 7 天 =="
if [ -s "$STATS" ]; then
    echo "日期   生成  时长   冻结(生成中)  被系统结束  被强制停止"
    tail -n 7 "$STATS" | while read -r d g gs f gf k st; do
        printf '%s  %4s  %-6s %4s(%s)  %6s  %8s\n' "$d" "$g" "$(human_secs "$gs")" "$f" "$gf" "$k" "$st"
    done
else
    echo "还没有统计（1.4 起才有）"
fi
r=$(grep "退出：" "$LOG" 2>/dev/null | sed 's/.*退出：//; s/［.*//; s/（.*//' | sort | uniq -c | sort -rn)
[ -n "$r" ] && { echo "退出原因（最近 7 天）："; echo "$r" | sed 's/^ */  /'; }

echo "== TT 占的空间 =="
set -- $(tt_space)
echo "聊天和设置 $(human_kb "$1")，TT 日志 $(human_kb "$2")，缓存 $(human_kb "$3")，本模块的备份 $(human_kb "$4")"
nc=$(ls -d "$CRASH_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
[ "$nc" -gt 0 ] && echo "崩溃记录：$nc 份（最新 $(ls -d "$CRASH_DIR"/*/ | sort | tail -n 1 | sed 's|/$||; s|.*/||')）"

echo "== 最近 3 次 TT 退出（系统记录）=="
exit_records | head -n 3 | while IFS= read -r rec; do exit_line "$rec"; done
echo "== 备份 =="
if [ "$(cfg backup 1)" = 1 ]; then
    now=$(date +%s)
    lb=$(state_get last_backup); ck=$(state_get last_backup_check); mp=$(state_get mac_pulled)
    ago() { [ -n "$1" ] && echo "$(human_secs $((now - $1)))前" || echo "还没有"; }
    echo "最近一次备份：$(ago "$lb")；最近确认数据没变：$(ago "$ck")；最近拷到电脑：$(ago "$mp")"
    echo "有变化时最多每 $(cfg backup_hours 6) 小时一次；保留 $(cfg keep_days 7) 天 / $(cfg keep_weeks 4) 周 / $(cfg keep_months 6) 个月"
    echo "位置：$(bdir)（$([ "$(cfg backup_private 1)" = 0 ] && echo "文件管理器能看到" || echo "只有 root 能读")，不含 API 密钥）"
    for tg in $TARGETS; do
        if t_present "$tg"; then echo "$(t_label "$tg")：已检测到，$(list_backups "$tg" | wc -l | tr -d ' ') 份备份"
        elif pm path "$(t_pkg "$tg")" >/dev/null 2>&1; then echo "$(t_label "$tg")：已安装，未检测到数据"; fi
    done
    backup_tiers | while read -r tier n; do
        case "$tier" in new) t=最新 ;; 2d) t=近两天 ;; day) t=每天 ;; week) t=每周 ;; month) t=每月 ;; pre) t=恢复前 ;; *) t=多余 ;; esac
        v=""; [ -s "$(bdir)/$n.sha256" ] && v="，已校验"
        echo "  $n（$t，$(human_kb "$(du -k "$(bdir)/$n" 2>/dev/null | cut -f1)")$v）"
    done
    [ -n "$(list_backups | head -n 1)" ] || echo "  还没有备份"
else
    echo "已关（config.txt 里 backup=0）"
fi
echo "== 开关（模块目录的 config.txt，也可以在 KernelSU 里打开本模块的界面改）=="
echo "备份 $(cfg backup 1)，私密位置 $(cfg backup_private 1)，自动重开 $(cfg auto_reopen 1)，通知 $(cfg notify 1)（1 开 0 关）"
echo "清理 TT $(cfg cleanup_days 30) 天以前的日志（0 = 不清理），温度提醒 $(cfg temp_alert 45)°C（0 = 不提醒），$(cfg mac_alert_days 3) 天没拷到电脑提醒（0 = 不提醒）"
[ -f "$PRIOR" ] && { echo "== 装模块前的原值（卸载时还原）=="; grep -v '^#' "$PRIOR"; }
echo "== 最近的日志 =="
tail -n 10 "$LOG" 2>/dev/null
