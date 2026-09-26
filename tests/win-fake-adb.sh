#!/bin/sh
# Windows 测试用的假 adb（Git Bash 运行）：在本机模拟一台装了模块的手机，手机那头跑的是真的 ui.sh
[ "$1" = -s ] && shift 2
case "$1" in
  devices) echo "List of devices attached"; [ -n "${FAKE_SERIAL:-}" ] && printf '%s\tdevice\n' "$FAKE_SERIAL" ;;
  connect) : ;;
  shell)
    c=$2; c=${c#su -c \'}; c=${c%\'}
    c=$(printf '%s' "$c" | sed "s#/data/adb/modules/claudemax_tt_keepalive#$PHONE_MOD#g")
    # 手机上的中转目录 /data/local/tmp/tt-pull 对应本机的 FAKE_PULL（电脑端脚本核对的是手机上的路径）
    PULL_DIR=$FAKE_PULL sh -c "$c" | sed "s#$FAKE_PULL#/data/local/tmp/tt-pull#g" ;;
  pull) src=$(printf '%s' "$2" | sed "s#^/data/local/tmp/tt-pull#$FAKE_PULL#")
        d=$3; command -v cygpath >/dev/null && d=$(cygpath -u "$3")
        if [ -n "${FAKE_CORRUPT:-}" ]; then echo broken > "$d"; else cp "$src" "$d"; fi ;;
esac
