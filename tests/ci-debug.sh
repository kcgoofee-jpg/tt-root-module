# CI 上测试失败时的调试输出（只在 GitHub Actions 失败后运行）
set -x
T=$(mktemp -d); export ADB_DIR=$T/adb TT_GUARD_DIR=$T/g TT_MODDIR=$PWD/ksu-tt-keepalive; mkdir -p $TT_GUARD_DIR
mkdir -p "$ADB_DIR/ksu"; printf '#!/bin/sh\necho "ksud 3.3.0"\n' > "$ADB_DIR/ksud"; chmod +x "$ADB_DIR/ksud"
"$ADB_DIR/ksud" -V; ls -la "$ADB_DIR"; mount | head -5
. ksu-tt-keepalive/common.sh
root_manager
r=$(exit_records < /dev/null | head -1); echo "rec=$r"
FAKE_EXIT=tests/fixtures/exit-info.txt
dumpsys() { cat tests/fixtures/exit-info.txt; }
exit_records | head -3
exit_line "$(exit_records | head -1)"
