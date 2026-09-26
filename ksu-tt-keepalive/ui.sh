#!/system/bin/sh
# 界面（webroot/index.html，在 KernelSU 管理器里打开）和电脑上的 mac/pull-backups.sh 用的命令，以 root 运行：
#   ui.sh status              全部状态，输出 JSON
#   ui.sh backup              马上备份一次（不管数据变没变），输出 JSON
#   ui.sh restore 文件名      从备份恢复（调 restore.sh），输出 JSON
#   ui.sh set 开关 数字       改 config.txt 里的一个开关（只认 CONFIG_KEYS 里的），输出 JSON
#   ui.sh list-backups        给电脑用：每行「文件名 KB sha256」
#   ui.sh mark-pulled         给电脑用：记下「电脑刚拷走了备份」
# 只读系统状态和本模块自己的文件；会改东西的只有 backup / restore / set / mark-pulled。
MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

# JSON 字符串：转义反斜杠和引号，去掉控制字符
js() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"; }
# 标准输入的每一行 → JSON 字符串数组
jlines() {
    awk 'BEGIN { printf "[" }
         { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, " "); gsub(/\r/, ""); printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 }
         END { printf "]" }'
}
num() { case "$1" in ''|*[!0-9-]*) echo null ;; *) echo "$1" ;; esac; }
bool() { if [ "$1" = 1 ]; then echo true; else echo false; fi; }

status() {
    now=$(date +%s)
    uid=$(app_uid)
    pids=$(pidof "$PKG" 2>/dev/null)
    gen=0; [ -n "$pids" ] && generating && gen=1
    frz=""; for p in $pids; do by=$(frozen_by "$p" "$uid"); [ -n "$by" ] && frz=$by; done
    wl=0; in_whitelist && wl=1
    set -- $(tt_space)
    sp_data=$1 sp_logs=$2 sp_cache=$3 sp_bk=$4
    printf '{'
    printf '"now":%s,' "$now"
    printf '"version":%s,' "$(js "$(sed -n 's/^version=//p' "$MODDIR/module.prop")")"
    printf '"tt":{"installed":%s,"running":%s,"generating":%s,"frozen":%s,"pids":%s,"version":%s,"webview":%s},' \
        "$(pm path "$PKG" >/dev/null 2>&1 && echo true || echo false)" "$(bool "$([ -n "$pids" ] && echo 1)")" \
        "$(bool $gen)" "$(js "$frz")" "$(js "$pids")" "$(js "$(tt_version)")" "$(js "$(webview_version)")"
    printf '"keep":{"whitelist":%s,"background":%s,"bucket":%s,"network":%s,"temp":%s},' \
        "$(bool $wl)" "$(js "$(appop_mode RUN_ANY_IN_BACKGROUND)")" "$(num "$(am get-standby-bucket "$PKG" 2>/dev/null)")" \
        "$(js "$(net_effective "$uid")")" "$(num "$(battery_temp)")"
    printf '"today":[%s,%s,%s,%s,%s,%s],' "$(num "$(stat_get 2)")" "$(num "$(stat_get 3)")" "$(num "$(stat_get 4)")" \
        "$(num "$(stat_get 5)")" "$(num "$(stat_get 6)")" "$(num "$(stat_get 7)")"
    printf '"days":['
    tail -n 7 "$STATS" 2>/dev/null | awk '{ printf "%s[\"%s\",%d,%d,%d,%d,%d,%d]", (NR > 1 ? "," : ""), $1, $2, $3, $4, $5, $6, $7 }'
    printf '],'
    printf '"reasons":'
    grep "退出：" "$LOG" 2>/dev/null | sed 's/.*退出：//; s/［.*//; s/（.*//' | sort | uniq -c | sort -rn | sed 's/^ *//' | jlines
    printf ',"exits":'
    exit_records | head -n 5 | while IFS= read -r rec; do exit_line "$rec"; done | jlines
    printf ',"space":{"data":%s,"logs":%s,"cache":%s,"backups":%s},' "$(num "$sp_data")" "$(num "$sp_logs")" "$(num "$sp_cache")" "$(num "$sp_bk")"
    printf '"crashes":%s,' "$(ls -d "$CRASH_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')"
    printf '"backup":{"dir":%s,"last":%s,"check":%s,"fails":%s,"mac_pulled":%s,"watch_since":%s,"items":[' \
        "$(js "$(bdir)")" "$(num "$(state_get last_backup)")" "$(num "$(state_get last_backup_check)")" \
        "$(num "$(state_get backup_fails)")" "$(num "$(state_get mac_pulled)")" "$(num "$(state_get watch_since)")"
    d=$(bdir); first=1
    backup_tiers | while read -r tier n; do
        kb=$(du -k "$d/$n" 2>/dev/null | cut -f1)
        v=false; [ -s "$d/$n.sha256" ] && v=true
        [ $first = 1 ] || printf ','; first=0
        printf '{"name":%s,"tier":%s,"kb":%s,"verified":%s}' "$(js "$n")" "$(js "$tier")" "$(num "$kb")" "$v"
    done
    printf ']},'
    printf '"config":{'
    first=1
    for k in $CONFIG_KEYS; do
        v=$(echo "$DEFAULT_CONFIG" | sed -n "s/^$k=//p")
        [ $first = 1 ] || printf ','; first=0
        printf '"%s":%s' "$k" "$(num "$(cfg "$k" "$v")")"
    done
    printf '},'
    printf '"log":'
    tail -n 80 "$LOG" 2>/dev/null | jlines
    printf '}\n'
}

case "${1:-}" in
    status) status ;;
    backup)
        unlocked || { printf '{"ok":false,"msg":%s}\n' "$(js "手机开机后还没解锁过")"; exit 0; }
        if bf=$(backup_now); then
            now=$(date +%s)
            state_set last_backup "$now"; state_set last_backup_check "$now"; state_set backup_fails 0
            kb=$(du -k "$bf" 2>/dev/null | cut -f1)
            dropped=$(apply_retention | wc -l | tr -d ' ')
            log "手动备份并校验了 TT 数据：${bf##*/}（$kb KB）"
            printf '{"ok":true,"name":%s,"kb":%s,"dropped":%s}\n' "$(js "${bf##*/}")" "$(num "$kb")" "$(num "$dropped")"
        else
            printf '{"ok":false,"msg":%s}\n' "$(js "备份失败（可能正有另一个备份在跑，或者手机空间不够）")"
        fi ;;
    restore)
        out=$(sh "$MODDIR/restore.sh" "${2:-}" 2>&1); rc=$?
        printf '{"rc":%s,"out":%s}\n' "$rc" "$(printf '%s\n' "$out" | jlines)" ;;
    set)
        if config_set "${2:-}" "${3:-}"; then
            [ "$2" = backup_private ] && migrate_backups >/dev/null
            printf '{"ok":true}\n'
        else
            printf '{"ok":false,"msg":%s}\n' "$(js "不认识的开关或数值：${2:-} ${3:-}")"
        fi ;;
    list-backups)
        d=$(bdir)
        list_backups | while IFS= read -r n; do
            echo "$n $(du -k "$d/$n" 2>/dev/null | cut -f1) $(cut -d' ' -f1 "$d/$n.sha256" 2>/dev/null)"
        done ;;
    mark-pulled) state_set mac_pulled "$(date +%s)"; echo ok ;;
    *) echo "用法：ui.sh status|backup|restore 文件名|set 开关 数字|list-backups|mark-pulled"; exit 2 ;;
esac
