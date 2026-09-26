#!/bin/zsh
# 打包模块：ksu-tt-keepalive → dist/claudemax-tt-keepalive-<版本>.zip（最后一行输出 zip 的路径）
# 先跑语法检查和 tests/run.sh，不过就不打包。
# KernelSU 直接用；也带了 Magisk 要的 META-INF（按 Magisk 文档写的安装器，Magisk 上没实测过）。
set -e
HERE=${0:A:h}
FILES=(module.prop common.sh service.sh uninstall.sh action.sh customize.sh restore.sh
       META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script)
cd "$HERE/ksu-tt-keepalive"
v=$(sed -n "s/^version=//p" module.prop)
for f in ${FILES[@]:#*.prop}; do [[ $f == *updater-script ]] || sh -n "$f"; done
sh "$HERE/tests/run.sh" > /dev/null || { print -u2 "单元测试没通过：sh tests/run.sh 看详情"; exit 1; }
out="$HERE/dist"; mkdir -p "$out"
rm -f "$out/claudemax-tt-keepalive-$v.zip"
COPYFILE_DISABLE=1 zip -q -X "$out/claudemax-tt-keepalive-$v.zip" ${FILES[@]}
print -r -- "$out/claudemax-tt-keepalive-$v.zip"
