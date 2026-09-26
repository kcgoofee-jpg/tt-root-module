#!/bin/zsh
# 把手机上 TT 守护模块的备份拷到这台 Mac。
#   · launchd 每 30 分钟跑一次（pc/install-mac.sh 装），「安卓保活模块」菜单也会调用。
#   · 只拷电脑上还没有的；拷完用手机给的 sha256 核对，对不上就丢掉、下次重拷。
#   · 电脑上也分层保留（默认 14 天 / 8 周 / 24 个月），规则在手机上算（ui.sh plan），和 Windows 一致。
#   · 连续 3 天没能和手机同步：发一条 macOS 通知（每天最多一次）。
# 设置（环境变量，或 tavern/extension/launcher/config.local 里同名的行）：
#   TT_PHONE_BACKUP_DIR  备份放哪（默认 tavern/phone-backups/tt）
#   TT_PC_KEEP="14 8 24" 电脑上按天 / 周 / 月保留
#   ADB                  adb 路径（默认 tavern/tools/platform-tools/adb，再找 PATH）
# 退出码：0 同步好了（或没有新备份），1 出错，2 没连上手机 / 手机上没装模块（不算错）
set -u
setopt null_glob
REPO=${0:A:h:h}
TAVERN=${REPO:h}
CONF=$TAVERN/extension/launcher/config.local
conf() { [[ -f $CONF ]] && sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}$/\1/p" "$CONF" | tail -n 1; }
DEST=${TT_PHONE_BACKUP_DIR:-$(conf TT_PHONE_BACKUP_DIR)}; DEST=${DEST:-$TAVERN/phone-backups/tt}
KEEP=(${=${TT_PC_KEEP:-$(conf TT_PC_KEEP)}}); (( ${#KEEP} == 3 )) || KEEP=(14 8 24)
PHONE_FILE=$TAVERN/extension/launcher/phone.local
MOD=/data/adb/modules/claudemax_tt_keepalive
QUIET=0; [[ "${1:-}" == --quiet ]] && QUIET=1

mkdir -p "$DEST" || exit 1
LOG=$DEST/pull.log
say() { (( QUIET )) || print -r -- "$*"; print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
trim_log() { [[ $(wc -l < "$LOG") -gt 1200 ]] && { tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }; }
notify_mac() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# 同一时间只跑一个（launchd 和菜单可能撞上）；超过 30 分钟的锁当作残留
LOCK=$DEST/.pull.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    [[ -n $(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null) ]] || { (( QUIET )) || print "另一个拷贝正在进行"; exit 0; }
    rm -rf "$LOCK"; mkdir "$LOCK" || exit 1
fi
trap 'rm -rf "$LOCK"; trim_log' EXIT

# 连续 3 天没同步上：提醒（每天一次）
stale_check() {
    local ok=$(cat "$DEST/.last-sync" 2>/dev/null) today=$(date +%Y%m%d)
    [[ -n $ok ]] || { date +%s > "$DEST/.last-sync"; return; }
    if (( $(date +%s) - ok > 3 * 86400 )) && [[ $(cat "$DEST/.last-alert-day" 2>/dev/null) != $today ]]; then
        print -r -- $today > "$DEST/.last-alert-day"
        say "已经 $(( ($(date +%s) - ok) / 86400 )) 天没和手机同步备份"
        notify_mac "TT 备份" "已经 $(( ($(date +%s) - ok) / 86400 )) 天没从手机拷到电脑。连上手机（数据线或无线调试）即可。"
    fi
}

# ---------- 找 adb 和手机 ----------
adb=${ADB:-$(conf ADB)}
[[ -n $adb && -x $adb ]] || adb=$TAVERN/tools/platform-tools/adb
[[ -x $adb ]] || adb=$(command -v adb 2>/dev/null)
[[ -n $adb && -x $adb ]] || { say "没找到 adb"; stale_check; exit 2; }
devices() { "$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'; }
serial=$(devices | grep -v ':' | head -n 1)              # 先用数据线
if [[ -z $serial ]]; then
    serial=$(devices | head -n 1)
    if [[ -z $serial && -s $PHONE_FILE ]]; then            # 再试无线调试
        addr=$(head -n 1 "$PHONE_FILE" | tr -d '[:space:]')
        [[ $addr == *:* ]] && "$adb" connect "$addr" </dev/null >/dev/null 2>&1
        serial=$(devices | head -n 1)
    fi
fi
[[ -n $serial ]] || { (( QUIET )) || print "没连上手机"; stale_check; exit 2; }
A=("$adb" -s "$serial")
# </dev/null：adb shell 会读标准输入，不挡住的话会把下面循环要读的备份名单吃掉
root() { "${A[@]}" shell "su -c '$1'" </dev/null 2>/dev/null | tr -d '\r'; }
[[ $(root "[ -f $MOD/ui.sh ] && echo y") == y ]] || { say "手机上没装 TT 守护模块（1.6 以上）"; stale_check; exit 2; }

# ---------- 拷新的 ----------
got=0 bad=0
while read -r name kb sha; do
    [[ $name == tt-default-user-*.tar.gz && $sha == [0-9a-f]* && ${#sha} == 64 ]] || continue
    [[ -f $DEST/$name ]] && continue
    # 不能叫 path：zsh 里 path 和 PATH 是绑在一起的
    rpath=$(root "sh $MOD/ui.sh stage $name")
    [[ $rpath == */tt-pull/$name ]] || { say "准备 $name 失败"; bad=$((bad + 1)); continue; }
    if "${A[@]}" pull "$rpath" "$DEST/.$name.part" </dev/null >/dev/null 2>&1 \
        && [[ $(shasum -a 256 "$DEST/.$name.part" | cut -d' ' -f1) == $sha ]]; then
        mv "$DEST/.$name.part" "$DEST/$name"
        print -r -- "$sha  $name" > "$DEST/$name.sha256"
        say "已拷到电脑并核对：$name（$(( kb / 1024 )) MB）"
        got=$((got + 1))
    else
        rm -f "$DEST/.$name.part"
        say "拷贝或核对失败：$name（下次再试）"
        bad=$((bad + 1))
    fi
done < <(root "sh $MOD/ui.sh list-backups")
root "sh $MOD/ui.sh unstage" >/dev/null
rm -f "$DEST"/.*.part(N)

# ---------- 电脑上的分层保留（规则在手机上算） ----------
local_names=($(cd "$DEST" && ls tt-default-user-*.tar.gz 2>/dev/null))
if (( ${#local_names} )); then
    dropped=0
    root "sh $MOD/ui.sh plan ${KEEP[1]} ${KEEP[2]} ${KEEP[3]} ${local_names[*]}" | while read -r act tier n; do
        [[ $act == drop && $n == tt-default-user-*.tar.gz && -f $DEST/$n ]] || continue
        rm -f "$DEST/$n" "$DEST/$n.sha256" && say "按分层保留清掉电脑上的旧备份：$n"
    done
fi

if (( bad == 0 )); then
    date +%s > "$DEST/.last-sync"
    root "sh $MOD/ui.sh mark-pulled" >/dev/null
    (( got )) || { (( QUIET )) || print "电脑上已经是最新的"; }
    exit 0
fi
stale_check
exit 1
