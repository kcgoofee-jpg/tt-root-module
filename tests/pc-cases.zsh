#!/bin/zsh
# 电脑端 pc/pull-backups.sh 的测试：假的 adb 在本机模拟一台手机（手机那头跑的就是真的 ui.sh）。
# 用法：zsh tests/pc-cases.zsh（tests/run.sh 会调用）
set -u
HERE=${0:A:h}; ROOT=${HERE:h}
T=$(mktemp -d "${TMPDIR:-/tmp}/tt-pc-test.XXXXXX"); [[ -n ${KEEP_T:-} ]] || trap 'rm -rf "$T"' EXIT; print -r -- "$T" > /tmp/claude-pc-T
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); print "  ✗ $1"; fi; }

# ---------- 假手机 ----------
export PHONE_MOD=$T/phone/mod PRIVATE_BK=$T/phone/bk PULL_DIR=$T/phone/tt-pull TT_DATA=$T/phone/data ADB_CALLS=$T/adb-calls
mkdir -p "$PHONE_MOD" "$PRIVATE_BK" "$TT_DATA/default-user"
cp "$ROOT"/ksu-tt-keepalive/*.sh "$ROOT"/ksu-tt-keepalive/*.awk "$ROOT/ksu-tt-keepalive/module.prop" "$PHONE_MOD/"
export TT_MODDIR=$PHONE_MOD
BIN=$T/bin; mkdir -p "$BIN"
cat > "$BIN/adb" <<'EOF'
#!/bin/sh
[ "$1" = -s ] && shift 2
case "$1" in
  devices) echo "List of devices attached"; [ -n "${FAKE_SERIAL:-}" ] && printf '%s\tdevice\n' "$FAKE_SERIAL" ;;
  connect) echo "connect $2" >> "$ADB_CALLS" ;;
  shell)
    c=$2; c=${c#su -c \'}; c=${c%\'}
    c=$(printf '%s' "$c" | sed "s#/data/adb/modules/claudemax_tt_keepalive#$PHONE_MOD#g")
    [ -n "${FAKE_NO_MODULE:-}" ] && c=$(printf '%s' "$c" | sed "s#$PHONE_MOD#/nonexistent#g")
    sh -c "$c" ;;
  pull) if [ -n "${FAKE_CORRUPT:-}" ]; then echo broken > "$3"; else cp "$2" "$3"; fi ;;
esac
EOF
chmod +x "$BIN/adb"
export ADB=$BIN/adb FAKE_SERIAL=USB123
DEST="$T/电脑 上的 备份"; export TT_PHONE_BACKUP_DIR=$DEST TT_PC_KEEP="14 8 24"
day() { date -v-"$1"d +%Y%m%d; }
mkbk() { # 在假手机上做一份备份（内容不同，sha256 由 ui.sh 算）
    local n=tt-default-user-$1.tar.gz
    print -r -- "data $1" | gzip > "$PRIVATE_BK/$n"
    ( cd "$PRIVATE_BK" && shasum -a 256 "$n" > "$n.sha256" )
}
run() { zsh "$ROOT/pc/pull-backups.sh" "$@" > "$T/out" 2>&1; }

print "[电脑] 连不上 / 没装模块"
FAKE_SERIAL= run; r=$?
check "没连上手机：退出码 2" '[[ $r == 2 ]] && grep -q 没连上手机 "$T/out"'
FAKE_NO_MODULE=1 run; r=$?
check "手机上没装模块：退出码 2" '[[ $r == 2 ]] && grep -q 没装 "$T/out"'

print "[电脑] 拷新备份并核对"
mkbk "$(day 0)-120000"; mkbk "$(day 1)-080000"
run; r=$?
check "成功" '[[ $r == 0 ]]'
check "两份都拷到了（路径有空格和中文）" '[[ -f "$DEST/tt-default-user-$(day 0)-120000.tar.gz" && -f "$DEST/tt-default-user-$(day 1)-080000.tar.gz" ]]'
check "电脑上的 sha256 对得上" '( cd "$DEST" && shasum -a 256 -c "tt-default-user-$(day 0)-120000.tar.gz.sha256" ) >/dev/null'
check "手机记下「电脑拷走了」" 'grep -q "^mac_pulled=" "$PHONE_MOD/state.txt"'
check "手机上的临时副本删了" '[[ ! -e $PULL_DIR ]]'
check "记了日志" 'grep -q "已拷到电脑并核对" "$DEST/pull.log"'
run
check "再跑一次：已经是最新的" 'grep -q 已经是最新的 "$T/out"'

print "[电脑] 防呆"
rm -f "$DEST/tt-default-user-$(day 1)-080000.tar.gz"
run
check "手动删了电脑上的一份：会重新拷回来" '[[ -f "$DEST/tt-default-user-$(day 1)-080000.tar.gz" ]]'
touch "$DEST/.tt-default-user-x.tar.gz.part"; print keep > "$DEST/我的笔记.txt"
run
check "残留的半截文件清掉" '[[ ! -e "$DEST/.tt-default-user-x.tar.gz.part" ]]'
check "备份文件夹里别的文件不碰" '[[ -f "$DEST/我的笔记.txt" ]]'
mkdir "$DEST/.pull.lock"; mkbk "$(day 0)-180000"
run; r=$?
check "另一个拷贝正在进行：不重复跑" '[[ $r == 0 ]] && grep -q 正在进行 "$T/out" && [[ ! -f "$DEST/tt-default-user-$(day 0)-180000.tar.gz" ]]'
touch -t 200001010000 "$DEST/.pull.lock"
run
check "锁超过 30 分钟当作残留" '[[ -f "$DEST/tt-default-user-$(day 0)-180000.tar.gz" ]]'

print "[电脑] 拷坏了"
mkbk "$(day 0)-200000"
FAKE_CORRUPT=1 run; r=$?
check "核对不上：退出码 1，不留坏文件" '[[ $r == 1 && ! -f "$DEST/tt-default-user-$(day 0)-200000.tar.gz" ]] && grep -q 核对失败 "$DEST/pull.log"'
run
check "下次重拷成功" '[[ -f "$DEST/tt-default-user-$(day 0)-200000.tar.gz" ]]'

print "[电脑] 分层保留"
for n in "$(day 400)-100000" "$(day 1000)-100000" "$(day 20)-100000" "$(day 20)-090000"; do print x > "$DEST/tt-default-user-$n.tar.gz"; done
run
check "两年前的删了" '[[ ! -f "$DEST/tt-default-user-$(day 1000)-100000.tar.gz" ]]'
check "同一周多出来的删了" '[[ ! -f "$DEST/tt-default-user-$(day 20)-090000.tar.gz" && -f "$DEST/tt-default-user-$(day 20)-100000.tar.gz" ]]'
check "一年多以前的（24 个月内）留着" '[[ -f "$DEST/tt-default-user-$(day 400)-100000.tar.gz" ]]'
check "手机上的备份一份没少" '[[ $(ls "$PRIVATE_BK" | grep -c "\.tar\.gz$") == 4 ]]'

print "[电脑] 太久没同步"
print $(( $(date +%s) - 5 * 86400 )) > "$DEST/.last-sync"; rm -f "$DEST/.last-alert-day"
FAKE_SERIAL= run
check "5 天没同步：记日志（每天一次）" 'grep -q "已经 5 天没和手机同步备份" "$DEST/pull.log" && [[ -f "$DEST/.last-alert-day" ]]'
FAKE_SERIAL= run
check "同一天不重复" '[[ $(grep -c "天没和手机同步备份" "$DEST/pull.log") == 1 ]]'

print "[电脑] Windows 脚本（静态检查）"
W=$ROOT/pc/pull-backups.ps1
check "两个 .ps1 都带 UTF-8 BOM（PowerShell 5.1 才不乱码）" '[[ $(head -c 3 "$W" | xxd -p) == efbbbf && $(head -c 3 "$ROOT/pc/install-windows.ps1" | xxd -p) == efbbbf ]]'
check "不给自动变量 \$args 赋值" '! grep -qE "^\s*\\\$args\s*=" "$ROOT"/pc/*.ps1'
check "和 Mac 版用同样的手机命令" 'for c in list-backups "stage \$name" unstage plan mark-pulled; do grep -q "ui.sh $c" "$W" || exit 1; done'
check "文件名、sha256 都做了格式检查" 'grep -q "tt-default-user-\[0-9-\]+" "$W" && grep -q "\[0-9a-f\]{64}" "$W"'
if command -v pwsh >/dev/null 2>&1; then
    check "PowerShell 语法" 'pwsh -NoProfile -Command "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile(\"$W\",[ref]\$null,[ref]\$e) | Out-Null; if (\$e.Count) { exit 1 }"'
else
    print "  （这台电脑没有 PowerShell，跳过 Windows 脚本的语法检查）"
fi

print "通过 $pass，失败 $fail"
(( fail == 0 ))
