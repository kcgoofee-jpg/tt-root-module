#!/system/bin/sh
# 从模块的备份恢复酒馆的数据（TauriTavern / SillyDroid / Termux 里的 SillyTavern，按文件名判断）。
# 以 root 运行；界面和电脑上「安卓保活模块」菜单会调它，也可以手动：
#   su -c 'sh /data/adb/modules/claudemax_tt_keepalive/restore.sh tt-default-user-日期-时间.tar.gz'）
# 做法：检查备份 → 解到临时目录 → 先把现在的数据备份一份 → 覆盖回去（default-user、扩展、归档等）→ 把属主改回 TT。
# 备份里有的文件会被覆盖；备份里没有的（比如之后新建的聊天）留着不动；API 密钥不在备份里，不受影响。
# TT 必须先关掉（不会替你强制停止它）。
# 同一时间只能有一个恢复（界面和电脑菜单同时点也不会互相干扰）；恢复期间不会自动重开 TT。
# 退出码：0 成功，2 备份文件不对，3 TT 在运行，4 手机没解锁，5 恢复前的备份失败，6 解压或复制失败，
#         7 另一个恢复正在进行，8 空间不够，9 备份文件校验不对（可能损坏），10 电量低于 15% 且没在充电
# 复制途中断电：开机后 service.sh 看到 restore.pending，发通知提示重新恢复（恢复前的数据已另存）
MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

# 参数 live-tt / live-sillydroid / live-termux：从实时副本恢复（副本本身就是目录，不用解压）
name=${1##*/}
live=""
case "$name" in live-tt|live-sillydroid|live-termux) live=${name#live-} ;; esac
if [ -n "$live" ]; then
    t=$live; f=$(live_dir "$t")
    [ -f "$f/.marker" ] || { echo "没有实时副本"; exit 2; }
else
    is_bk_name "$name" || { echo "不是本模块的备份文件：$1"; exit 2; }
    case "$name" in *..*|*/*) echo "不是本模块的备份文件：$1"; exit 2 ;; esac
    t=$(t_of_name "$name")
    f=$(bdir)/$name
    [ -f "$f" ] || { echo "找不到备份：$f"; exit 2; }
fi
root=$(t_root "$t"); label=$(t_label "$t")
[ -d "$root" ] || { echo "没有找到 $label 的数据目录，请先安装并打开一次"; exit 2; }
t_running "$t" && { echo "$label 正在运行：请先在最近任务中关闭 $label"; exit 3; }
unlocked || { echo "手机开机后还没解锁过，先解锁再恢复"; exit 4; }
low_battery 15 && { echo "电量低于 15%，请先充电再恢复（恢复途中关机会导致数据不完整）"; exit 10; }

lock=$GDIR/.restore.lock
if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ] || { echo "另一个恢复正在进行"; exit 7; }
    rm -rf "${lock:?}"; mkdir "$lock" || exit 7
fi
trap 'rm -rf "${lock:?}"' EXIT

# 备份有 .sha256 就先核对，坏了就不恢复
if [ -z "$live" ] && [ -s "$f.sha256" ]; then
    want=$(cut -d' ' -f1 "$f.sha256")
    got=$( { sha256sum "$f" 2>/dev/null || shasum -a 256 "$f"; } | cut -d' ' -f1)
    [ "$want" = "$got" ] || { echo "备份文件校验不对，可能已损坏，不恢复"; exit 9; }
fi

# 空间：要放得下解开的数据和恢复前的备份
kb=$(du -sk "$f" 2>/dev/null | cut -f1); fr=$(free_kb "$root")
if [ -n "$fr" ] && [ "$fr" -lt $(( ${kb:-60000} * 5 + 512000 )) ]; then
    echo "存储空间不够（剩 $(human_kb "$fr")），不恢复"; exit 8
fi

# 备份里只能有这个目标的那几个目录下的东西，不能有绝对路径或 ..
# 实时副本不用解压：直接从副本目录复制（drop_stage 不删它）
drop_stage() { [ -n "$live" ] || rm -rf "${stage:?}"; }
if [ -n "$live" ]; then
    stage=$f
    [ -n "$(find "$stage" -type d -name default-user | head -n 1)" ] || { echo "实时副本里没有用户数据，不恢复"; exit 2; }
else
    allowed=$(t_members "$t" | sed 's/ /|/g; s/\./\\./g')
    bad=$(tar -tzf "$f" 2>/dev/null | grep -vE "^($allowed)(/|\$)" | head -n 1)
    [ -z "$bad" ] || { echo "备份内容不对（$bad），不恢复"; exit 2; }
    tar -tzf "$f" 2>/dev/null | grep -qE '(^|/)\.\.(/|$)' && { echo "备份里有 ..，不恢复"; exit 2; }
    stage=$root/.cc-restore
    rm -rf "${stage:?}"; mkdir -p "$stage" || exit 6
    tar -xzf "$f" -C "$stage" 2>/dev/null && [ -n "$(find "$stage" -type d -name default-user | head -n 1)" ] \
        || { rm -rf "${stage:?}"; echo "解压失败"; exit 6; }
fi

if ! safety=$(backup_now "$t" prerestore); then
    drop_stage; echo "恢复前先备份现在的数据，失败了，不恢复"; exit 5
fi
log "恢复前自动备份了现在的数据：${safety##*/}"

# 属主、SELinux 标签照原来的用户数据目录（App 私有目录的标签带着这个 App 自己的分类号，不能用固定值）
ud=$(t_userdir "$t")
owner=$(stat -c %u "$ud" 2>/dev/null); group=$(stat -c %g "$ud" 2>/dev/null)
ctx=$(ls -Zd "$ud" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^u:object_r:/) { print $i; exit } }')
# 解压、另存花了点时间：覆盖前再确认一次 TT 没被打开
t_running "$t" && { drop_stage; echo "$label 刚被打开：请先在最近任务中关闭 $label"; exit 3; }
echo "$name|${safety##*/}" > "$GDIR/restore.pending"; sync
copied=1
for m in $(t_members "$t"); do
    if [ -d "$stage/$m" ]; then
        mkdir -p "$root/$m" && cp -a "$stage/$m/." "$root/$m/" || { copied=0; break; }
    elif [ -f "$stage/$m" ]; then
        cp -a "$stage/$m" "$root/$m" || { copied=0; break; }       # config.yaml 这种单个文件
    else
        continue
    fi
    [ -n "$owner" ] && chown -R "$owner:${group:-$owner}" "$root/$m" 2>/dev/null
    [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1 && chcon -R "$ctx" "$root/$m" 2>/dev/null
done
sync; rm -f "$GDIR/restore.pending"
if [ $copied = 1 ]; then
    drop_stage
    state_set restore_interrupted ""
    log "从备份恢复了 $label 数据：$name"
    echo "已恢复：$name"
    prune_prerestore >/dev/null
    echo "恢复前的数据另存为：${safety##*/}"
    exit 0
fi
drop_stage
log "从备份恢复失败（复制时出错）：$name；恢复前的备份在 ${safety##*/}"
echo "复制失败。恢复前的数据在 ${safety##*/}，可以用它恢复回去"
exit 6
