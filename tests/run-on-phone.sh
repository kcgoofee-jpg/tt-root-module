#!/bin/zsh
# 在手机上用真正的 shell 跑单元测试：Android 自带的 mksh 和 KernelSU 的 busybox ash。
# 以 shell 身份（adb shell）跑，用的全是假命令，不改手机上任何设置；跑完删掉临时目录。
# 用法：ADB=adb路径 ANDROID_SERIAL=序列号 zsh tests/run-on-phone.sh
set -u
HERE=${0:A:h}; ROOT=${HERE:h}
adb=${ADB:-adb}
D=/data/local/tmp/tt-ka-test
"$adb" shell "rm -rf $D; mkdir -p $D/tmp" || exit 1
"$adb" push -q "$ROOT/ksu-tt-keepalive" "$ROOT/tests" "$D/" >/dev/null || exit 1
# busybox 在 /data/adb 里，shell 身份读不到：有 root 就复制一份到临时目录（只读取，不改模块）
"$adb" shell "su -c 'cp /data/adb/ksu/bin/busybox $D/busybox && chmod 755 $D/busybox'" >/dev/null 2>&1
rc=0
shells=(sh)
[[ -n "$("$adb" shell "[ -x $D/busybox ] && echo y")" ]] && shells+=("$D/busybox sh") || print "== 没有 root，跳过 busybox"
for s in $shells; do
    print "== 手机：$s"
    out=$("$adb" shell "cd $D/tests && TMPDIR=$D/tmp TESTS_DIR=$D/tests $s ./cases.sh; echo rc=\$?")
    print -r -- "$out" | grep -E '✗|通过|rc=|not found|rror'
    [[ "$out" == *"rc=0"* ]] || rc=1
done
"$adb" shell "rm -rf $D"
exit $rc
