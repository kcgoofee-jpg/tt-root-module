# 安装时由 KernelSU / Magisk 执行（source 进安装脚本，不是单独运行）。只做一件事：
# 升级安装时把旧版本记下的原值（prior.txt）、状态、统计、开关和日志带到新版本，卸载时才能还原成装模块之前的样子。
OLD=${OLD_MODDIR:-/data/adb/modules/claudemax_tt_keepalive}
if [ -f "$OLD/prior.txt" ]; then
    cp -f "$OLD/prior.txt" "$MODPATH/prior.txt"
elif [ -d "$OLD" ]; then
    # 从 1.0 / 1.1 升级：旧版本没记原值。它们会把 TT 加进白名单、允许后台运行，
    # 所以原值多半是「不在白名单、后台运行默认」——卸载时按这个还原。
    {
        echo "# 从旧版本升级：装模块之前的原值没有记录，按 Android 默认"
        echo "whitelist=no"
        echo "RUN_IN_BACKGROUND=default"
        echo "RUN_ANY_IN_BACKGROUND=default"
    } > "$MODPATH/prior.txt"
fi
for f in state.txt stats.txt config.txt backup.marker; do
    [ -f "$OLD/$f" ] && cp -f "$OLD/$f" "$MODPATH/$f"
done
[ -f "$OLD/service.log" ] && cp -f "$OLD/service.log" "$MODPATH/service.log"
ui_print "- 只针对 com.tauritavern.client；重启后生效"
ui_print "- 自动备份 TT 数据（不含 API 密钥），默认放在只有 root 能读的 /data/adb/tt-backups"
ui_print "- 在 KernelSU 管理器里点本模块，可以打开它的界面"
