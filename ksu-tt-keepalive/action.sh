#!/system/bin/sh
# KernelSU 管理器里点模块的「执行」按钮：只读，显示 TT 现在的后台状态、最近的退出原因和日志
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
today=$(date '+%m-%d')
count() { c=$(grep -c "$1" "$LOG" 2>/dev/null); echo "${c:-0}"; }
echo "今天被冻结：$(count "^$today .*冻结了") 次（生成中 $(count "^$today .*冻结了（正在生成") 次）"

echo "== 最近 3 次 TT 退出（系统记录）=="
exit_records | head -n 3 | while IFS= read -r rec; do exit_line "$rec"; done
[ -f "$PRIOR" ] && { echo "== 装模块前的原值（卸载时还原）=="; grep -v '^#' "$PRIOR"; }
echo "== 最近的日志 =="
tail -n 10 "$LOG" 2>/dev/null
