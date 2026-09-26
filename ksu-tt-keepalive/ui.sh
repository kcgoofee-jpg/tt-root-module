#!/system/bin/sh
# 界面（webroot/index.html，在 KernelSU 管理器里打开）和电脑上的 mac/pull-backups.sh 用的命令，以 root 运行：
#   ui.sh status              全部状态，输出 JSON
#   ui.sh backup              马上备份一次（不管数据变没变），输出 JSON
#   ui.sh restore 文件名      从备份恢复（调 restore.sh），输出 JSON
#   ui.sh set 开关 数字       改 config.txt 里的一个开关（只认 CONFIG_KEYS 里的），输出 JSON
#   ui.sh list-backups        给电脑用：每行「文件名 KB sha256」
#   ui.sh mark-pulled         给电脑用：记下「电脑刚拷走了备份」
#   ui.sh stage 文件名        给电脑用：把一份备份复制到 /data/local/tmp/tt-pull/（adb pull 能读），输出路径
#   ui.sh unstage             给电脑用：删掉上面复制出来的
#   ui.sh plan 天 周 月 文件名…  给电脑用：按同样的分层保留规则，输出「keep 层级 文件名」/「drop - 文件名」
#     （电脑上的保留规则也在手机上算，Mac 和 Windows 就不用各写一份）
#   ui.sh selftest            自检：逐项检查，输出 JSON 数组 [{name, ok, detail}]
#   ui.sh diag                导出诊断包到「内部存储/Download」（只有本模块的日志、状态、设置和自检结果，
#                             没有聊天数据），输出 JSON {ok, file}
# 只读系统状态和本模块自己的文件；会改东西的只有 backup / restore / set / mark-pulled。
MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"
PULL_DIR=${PULL_DIR:-/data/local/tmp/tt-pull}   # 给电脑 adb pull 用的临时副本（shell 身份能读）

# JSON 字符串：转义反斜杠和引号，去掉控制字符
js() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"; }
# 标准输入的每一行 → JSON 字符串数组
jlines() {
    tr -d '\000-\010\013\014\016-\037' | awk 'BEGIN { printf "[" }
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
    printf '"temps":{"battery":%s,"soc":%s,"board":%s},' "$(num "$(battery_temp)")" "$(num "$(soc_temp)")" "$(num "$(board_temp)")"
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
    printf '"free":%s,"restoring":%s,"backing_up":%s,' "$(num "$(free_kb "$TT_DATA")")" \
        "$([ -d "$MODDIR/.restore.lock" ] && echo true || echo false)" "$([ -d "$MODDIR/.backup.lock" ] && echo true || echo false)"
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

# 自检的一项：item 名称 通过(0/1) 说明
item() { [ "$first" = 1 ] || printf ','; first=0; printf '{"name":%s,"ok":%s,"detail":%s}' "$(js "$1")" "$(bool "$2")" "$(js "$3")"; }
selftest() {
    first=1; printf '['
    item "模块版本" 1 "$(sed -n 's/^version=//p' "$MODDIR/module.prop")"
    if pm path "$PKG" >/dev/null 2>&1; then item "TauriTavern" 1 "已安装 $(tt_version)"; else item "TauriTavern" 0 "未安装"; fi
    if unlocked; then item "存储解锁" 1 "已解锁"; else item "存储解锁" 0 "开机后尚未解锁"; fi
    if [ -r "$TT_DATA/default-user" ]; then item "数据目录" 1 "可读"; else item "数据目录" 0 "不可读：$TT_DATA/default-user"; fi
    d=$(bdir)
    if mkdir -p "$d" 2>/dev/null && touch "$d/.selftest" 2>/dev/null; then rm -f "$d/.selftest"; item "备份目录" 1 "$d"; else item "备份目录" 0 "不可写：$d"; fi
    fr=$(free_kb "$d")
    if space_ok; then item "存储空间" 1 "剩余 $(human_kb "$fr")"; else item "存储空间" 0 "不足：剩余 $(human_kb "$fr")"; fi
    miss=""; for c in tar gzip find awk sed df; do command -v $c >/dev/null 2>&1 || miss="$miss $c"; done
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || miss="$miss sha256sum"
    if [ -z "$miss" ]; then item "系统命令" 1 "齐全"; else item "系统命令" 0 "缺少：$miss"; fi
    bad=""
    [ -f "$CONFIG" ] && for k in $CONFIG_KEYS; do
        v=$(tr -d '\r' < "$CONFIG" | sed -n "s/^[[:space:]]*$k[[:space:]]*=[[:space:]]*\([^ #]*\).*/\1/p" | head -1)
        case "$v" in ''|*[!0-9]*) [ -n "$v" ] && bad="$bad $k=$v" ;; esac
    done
    if [ -z "$bad" ]; then item "设置文件" 1 "有效"; else item "设置文件" 0 "无效的值（已按默认值处理）：$bad"; fi
    if ps -ef 2>/dev/null | grep -v grep | grep -q "$MODDIR/service.sh"; then item "后台服务" 1 "运行中"; else item "后台服务" 0 "未运行（重启手机后启动）"; fi
    n=$(list_backups | head -n 1)
    if [ -z "$n" ]; then item "最新备份" 0 "暂无备份"
    elif [ -s "$d/$n.sha256" ] && [ "$(cut -d' ' -f1 "$d/$n.sha256")" = "$( { sha256sum "$d/$n" 2>/dev/null || shasum -a 256 "$d/$n"; } | cut -d' ' -f1)" ]; then
        item "最新备份" 1 "校验通过：$n"
    else item "最新备份" 0 "校验失败：$n"; fi
    printf ']\n'
}

# 诊断包：只放本模块自己的文件和系统状态摘要，不放任何聊天数据
DIAG_DIR=${DIAG_DIR:-/data/media/0/Download}
diag() {
    w=$MODDIR/.diag; rm -rf "${w:?}"; mkdir -p "$w" || return 1
    for f in service.log state.txt stats.txt config.txt prior.txt module.prop; do [ -f "$MODDIR/$f" ] && cp "$MODDIR/$f" "$w/"; done
    [ -d "$CRASH_DIR" ] && cp -r "$CRASH_DIR" "$w/crash"
    selftest > "$w/selftest.json"
    sh "$MODDIR/action.sh" > "$w/status.txt" 2>&1
    { getprop ro.build.fingerprint; getprop ro.build.version.release; /data/adb/ksu/bin/ksud -V 2>/dev/null; } > "$w/device.txt" 2>/dev/null
    list_backups > "$w/backups.txt"
    mkdir -p "$DIAG_DIR" || return 1
    out=$DIAG_DIR/tt-guard-diag-$(date +%Y%m%d-%H%M%S).tar.gz
    tar -czf "$out" -C "$w" . 2>/dev/null || { rm -rf "${w:?}"; return 1; }
    rm -rf "${w:?}"
    chown 1023:1023 "$out" 2>/dev/null; chmod 664 "$out" 2>/dev/null
    command -v chcon >/dev/null && chcon u:object_r:media_rw_data_file:s0 "$out" 2>/dev/null
    echo "$out"
}

case "${1:-}" in
    status) status ;;
    selftest) selftest ;;
    diag)
        if o=$(diag); then printf '{"ok":true,"file":%s}\n' "$(js "$o")"; else printf '{"ok":false,"msg":%s}\n' "$(js "导出失败")"; fi ;;
    backup)
        unlocked || { printf '{"ok":false,"msg":%s}\n' "$(js "开机后尚未解锁")"; exit 0; }
        [ -n "$(pidof "$PKG" 2>/dev/null)" ] && generating && { printf '{"ok":false,"msg":%s}\n' "$(js "正在生成回复，请稍后再试")"; exit 0; }
        space_ok || { printf '{"ok":false,"msg":%s}\n' "$(js "存储空间不足")"; exit 0; }
        if bf=$(backup_now); then
            now=$(date +%s)
            state_set last_backup "$now"; state_set last_backup_check "$now"; state_set backup_fails 0
            kb=$(du -k "$bf" 2>/dev/null | cut -f1)
            dropped=$(apply_retention | wc -l | tr -d ' '); prune_prerestore >/dev/null
            log "手动备份并校验了 TT 数据：${bf##*/}（$kb KB）"
            printf '{"ok":true,"name":%s,"kb":%s,"dropped":%s}\n' "$(js "${bf##*/}")" "$(num "$kb")" "$(num "$dropped")"
        else
            printf '{"ok":false,"msg":%s}\n' "$(js "备份失败：另一个备份正在进行，或数据目录不可读")"
        fi ;;
    restore)
        out=$(sh "$MODDIR/restore.sh" "${2:-}" 2>&1); rc=$?
        printf '{"rc":%s,"out":%s}\n' "$rc" "$(printf '%s\n' "$out" | jlines)" ;;
    set)
        if [ -d "$MODDIR/.backup.lock" ] && [ "${2:-}" = backup_private ]; then
            printf '{"ok":false,"msg":%s}\n' "$(js "正在备份，请稍后再改存储位置")"; exit 0
        fi
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
    stage)
        n=${2:-}
        case "$n" in tt-default-user-[0-9]*.tar.gz) ;; *) echo "不是备份文件名" >&2; exit 2 ;; esac
        case "$n" in */*|*..*) echo "不是备份文件名" >&2; exit 2 ;; esac
        [ -f "$(bdir)/$n" ] || { echo "没有这个备份" >&2; exit 2; }
        mkdir -p "$PULL_DIR" && rm -f "$PULL_DIR"/* && cp "$(bdir)/$n" "$PULL_DIR/$n" || exit 1
        chown -R 2000:2000 "$PULL_DIR" 2>/dev/null; chmod 755 "$PULL_DIR"; chmod 644 "$PULL_DIR/$n"
        echo "$PULL_DIR/$n" ;;
    unstage) rm -rf "${PULL_DIR:?}"; echo ok ;;
    plan)
        shift
        dd=$1 ww=$2 mm=$3; shift 3 2>/dev/null
        for v in "$dd" "$ww" "$mm"; do case "$v" in ''|*[!0-9]*) echo "用法：ui.sh plan 天 周 月 文件名…" >&2; exit 2 ;; esac; done
        for n in "$@"; do echo "$n"; done | awk -v today="$(date +%Y%m%d)" -v days="$dd" -v weeks="$ww" -v months="$mm" -f "$RETENTION" ;;
    *) echo "用法：ui.sh status|backup|restore 文件名|set 开关 数字|list-backups|mark-pulled|stage 文件名|unstage|plan 天 周 月 文件名…|selftest|diag"; exit 2 ;;
esac
