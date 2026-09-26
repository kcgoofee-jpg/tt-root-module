#!/bin/sh
# 在 Mac 上跑模块的单元测试：同一组用例分别用 dash（接近手机上 KernelSU 的 busybox ash）、
# sh 和 ksh（接近 Android 自带的 mksh）跑。用法：sh tests/run.sh
cd "$(dirname "$0")" || exit 1
TESTS_DIR=$PWD; export TESTS_DIR
TEST_BIN=$(mktemp -d "${TMPDIR:-/tmp}/tt-ka-bin.XXXXXX") || exit 1; export TEST_BIN
trap 'rm -rf "$TEST_BIN"' EXIT
rc=0
for s in dash sh ksh; do
    command -v "$s" >/dev/null 2>&1 || { echo "== $s：没装，跳过"; continue; }
    echo "== $s"
    "$s" ./cases.sh || rc=1
done
if command -v zsh >/dev/null 2>&1; then
    echo "== 电脑端（pc/pull-backups.sh）"
    zsh ./pc-cases.zsh || rc=1
fi
exit $rc
