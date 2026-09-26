#!/system/bin/sh
# 从模块的备份恢复 TT 的数据（以 root 运行；电脑上「安卓保活模块」菜单会调它，也可以手动：
#   su -c 'sh /data/adb/modules/claudemax_tt_keepalive/restore.sh tt-default-user-日期-时间.tar.gz'）
# 做法：检查备份 → 解到临时目录 → 先把现在的数据备份一份 → 覆盖回去（default-user、扩展、归档等）→ 把属主改回 TT。
# 备份里有的文件会被覆盖；备份里没有的（比如之后新建的聊天）留着不动；API 密钥不在备份里，不受影响。
# TT 必须先关掉（不会替你强制停止它）。
# 退出码：0 成功，2 备份文件不对，3 TT 在运行，4 手机没解锁，5 恢复前的备份失败，6 解压或复制失败
MODDIR=${TT_MODDIR:-${0%/*}}
. "$MODDIR/common.sh"

name=${1##*/}
case "$name" in
    tt-default-user-[0-9]*.tar.gz) ;;
    *) echo "不是本模块的备份文件：$1"; exit 2 ;;
esac
f=$(bdir)/$name
[ -f "$f" ] || { echo "找不到备份：$f"; exit 2; }
[ -z "$(pidof "$PKG" 2>/dev/null)" ] || { echo "TT 正在运行：先在最近任务里把 TT 划掉，再恢复"; exit 3; }
unlocked || { echo "手机开机后还没解锁过，先解锁再恢复"; exit 4; }

# 备份里只能有 BACKUP_MEMBERS 这几个目录下的东西，不能有绝对路径或 ..
allowed=$(echo "$BACKUP_MEMBERS" | sed 's/ /|/g')
bad=$(tar -tzf "$f" 2>/dev/null | grep -vE "^($allowed)(/|\$)" | head -n 1)
[ -z "$bad" ] || { echo "备份内容不对（$bad），不恢复"; exit 2; }
tar -tzf "$f" 2>/dev/null | grep -qE '(^|/)\.\.(/|$)' && { echo "备份里有 ..，不恢复"; exit 2; }

stage=$TT_DATA/.cc-restore
rm -rf "${stage:?}"; mkdir -p "$stage" || exit 6
tar -xzf "$f" -C "$stage" 2>/dev/null && [ -d "$stage/default-user" ] || { rm -rf "${stage:?}"; echo "解压失败"; exit 6; }

if ! safety=$(backup_now); then
    rm -rf "${stage:?}"; echo "恢复前先备份现在的数据，失败了，不恢复"; exit 5
fi
log "恢复前自动备份了现在的数据：${safety##*/}"

owner=$(stat -c %u "$TT_DATA/default-user" 2>/dev/null); group=$(stat -c %g "$TT_DATA/default-user" 2>/dev/null)
[ -n "$owner" ] || owner=$(app_uid)
[ -n "$group" ] || group=1078
copied=1
for m in $BACKUP_MEMBERS; do
    [ -d "$stage/$m" ] || continue
    mkdir -p "$TT_DATA/$m" && cp -a "$stage/$m/." "$TT_DATA/$m/" || { copied=0; break; }
    chown -R "$owner:$group" "$TT_DATA/$m" 2>/dev/null
    command -v chcon >/dev/null 2>&1 && chcon -R u:object_r:media_rw_data_file:s0 "$TT_DATA/$m" 2>/dev/null
done
if [ $copied = 1 ]; then
    rm -rf "${stage:?}"
    log "从备份恢复了 TT 数据：$name"
    echo "已恢复：$name"
    echo "恢复前的数据另存为：${safety##*/}（同一个文件夹，想撤销就恢复它）"
    exit 0
fi
rm -rf "${stage:?}"
log "从备份恢复失败（复制时出错）：$name；恢复前的备份在 ${safety##*/}"
echo "复制失败。恢复前的数据在 ${safety##*/}，可以用它恢复回去"
exit 6
