#!/system/bin/sh
# 卸载模块时把 service.sh 改过的设置还原成装模块之前的值（记在 prior.txt；没记的按 Android 默认）。
# KernelSU / Magisk 在开机早期（系统服务还没起来）运行这个脚本、随后删掉模块目录：
# 所以先把 prior.txt 读进变量，再在后台等开机完成后才执行 dumpsys / cmd / am。
# 模块只改过这三样（白名单、后台运行、待机分组），其余都是只读；日志、状态、统计、开关随模块目录一起删掉。
# 备份是你的数据，卸载时不删：放在私密位置（/data/adb/tt-backups）的，等手机解锁后搬到
# 「内部存储/Documents/TauriTavern-backup」，免得留在一个看不到的地方；不要了可以自己删。
PKG=com.tauritavern.client
MODDIR=${TT_MODDIR:-${0%/*}}
DELAY=${UNINSTALL_DELAY:-10}
PRIVATE_BK=${PRIVATE_BK:-/data/adb/tt-backups}
SHARED_BK=${SHARED_BK:-/data/media/0/Documents/TauriTavern-backup}
get() { sed -n "s/^$1=//p" "$MODDIR/prior.txt" 2>/dev/null | head -1; }
WL=$(get whitelist)
RIB=$(get RUN_IN_BACKGROUND)
RAIB=$(get RUN_ANY_IN_BACKGROUND)
BUCKET=$(get bucket)
(
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
    sleep "$DELAY"
    # 原来就在白名单里（用户自己加的）就留着，否则撤掉
    [ "$WL" = "yes" ] || dumpsys deviceidle whitelist -"$PKG" >/dev/null 2>&1
    cmd appops set "$PKG" RUN_IN_BACKGROUND "${RIB:-default}" >/dev/null 2>&1
    cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND "${RAIB:-default}" >/dev/null 2>&1
    # 待机分组：只在模块改过时还原（系统之后会按使用情况自己调整）
    case "$BUCKET" in
        20) am set-standby-bucket "$PKG" working_set >/dev/null 2>&1 ;;
        30) am set-standby-bucket "$PKG" frequent >/dev/null 2>&1 ;;
        40) am set-standby-bucket "$PKG" rare >/dev/null 2>&1 ;;
        45) am set-standby-bucket "$PKG" restricted >/dev/null 2>&1 ;;
    esac
    # 私密位置的备份搬到共享位置（要等手机解锁：内部存储在解锁前是加密的）
    if ls "$PRIVATE_BK"/tt-default-user-* >/dev/null 2>&1; then
        until [ "$(getprop sys.user.0.ce_available)" = true ]; do sleep 10; done
        mkdir -p "$SHARED_BK" && for f in "$PRIVATE_BK"/tt-default-user-*; do mv "$f" "$SHARED_BK/"; done
        chown -R 1023:1023 "$SHARED_BK"; chmod 775 "$SHARED_BK"; chmod 664 "$SHARED_BK"/tt-default-user-*
        rmdir "$PRIVATE_BK"
    fi
    # 模块发过的通知撤掉不了（Android 没这个命令），留着的可以手动划掉
) </dev/null >/dev/null 2>&1 &
