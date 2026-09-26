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

echo "== 最近 3 次 TT 退出（系统记录）=="
exit_records | head -n 3 | while IFS= read -r rec; do exit_line "$rec"; done
echo "== 备份 =="
if [ "$(cfg backup 1)" = 1 ]; then
    n=$(ls "$BACKUP_DIR"/tt-default-user-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    newest=$(ls "$BACKUP_DIR"/tt-default-user-*.tar.gz 2>/dev/null | sort | tail -n 1)
    echo "每天一次，留 $(cfg backup_keep 7) 份；现有 $n 份${newest:+，最新 ${newest##*/}}"
    echo "位置：内部存储/Documents/TauriTavern-backup（不含 API 密钥）"
else
    echo "已关（config.txt 里 backup=0）"
fi
echo "== 开关（模块目录的 config.txt）=="
echo "备份 $(cfg backup 1)，自动重开 $(cfg auto_reopen 1)，通知 $(cfg notify 1)（1 开 0 关）"
[ -f "$PRIOR" ] && { echo "== 装模块前的原值（卸载时还原）=="; grep -v '^#' "$PRIOR"; }
echo "== 最近的日志 =="
tail -n 10 "$LOG" 2>/dev/null
