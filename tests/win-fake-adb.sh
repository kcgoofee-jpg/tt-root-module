#!/bin/sh
# Windows 测试用的假 adb（Git Bash 运行）：在本机模拟一台装了模块的手机，手机那头跑的是真的 ui.sh
[ "$1" = -s ] && shift 2
case "$1" in
  devices) echo "List of devices attached"; [ -n "${FAKE_SERIAL:-}" ] && printf '%s\tdevice\n' "$FAKE_SERIAL" ;;
  connect) : ;;
  shell)
    c=$2; c=${c#su -c \'}; c=${c%\'}
    c=$(printf '%s' "$c" | sed "s#/data/adb/modules/claudemax_tt_keepalive#$PHONE_MOD#g")
    sh -c "$c" ;;
  pull) d=$3; command -v cygpath >/dev/null && d=$(cygpath -u "$3")
        if [ -n "${FAKE_CORRUPT:-}" ]; then echo broken > "$d"; else cp "$2" "$d"; fi ;;
esac
