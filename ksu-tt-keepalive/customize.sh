# 安装时由 KernelSU / Magisk 执行（source 进安装脚本，不是单独运行）。只做一件事：
# 升级安装时把旧版本记下的原值（prior.txt）、状态、统计、开关和日志带到新版本，卸载时才能还原成装模块之前的样子。
# 1.6 起持久数据放在 /data/adb/tt-guard，不在模块目录里，更新时不需要搬。
# 从旧版本升级：把旧模块目录里的数据复制过去（已有的不覆盖）；1.0 / 1.1 没记原值，按 Android 默认。
OLD=${OLD_MODDIR:-/data/adb/modules/claudemax_tt_keepalive}
G=${TT_GUARD_DIR:-/data/adb/tt-guard}
mkdir -p "$G" && chmod 700 "$G"
for f in prior.txt state.txt stats.txt config.txt backup.marker service.log; do
    [ -f "$OLD/$f" ] && [ ! -f "$G/$f" ] && cp -f "$OLD/$f" "$G/$f"
done
[ -d "$OLD/crash" ] && [ ! -d "$G/crash" ] && cp -r "$OLD/crash" "$G/crash"
if [ -d "$OLD" ] && [ ! -f "$G/prior.txt" ]; then
    # 1.0 / 1.1 会把 TT 加进白名单、允许后台运行，所以原值多半是「不在白名单、后台运行默认」
    {
        echo "# 从旧版本升级：装模块之前的原值没有记录，按 Android 默认"
        echo "whitelist=no"
        echo "RUN_IN_BACKGROUND=default"
        echo "RUN_ANY_IN_BACKGROUND=default"
    } > "$G/prior.txt"
fi
ui_print "- TT 守护：自动检测 TauriTavern、SillyDroid、Termux 版 SillyTavern，重启后生效"
ui_print "- 备份位置：/data/adb/tt-backups（私密存储，不含 API 密钥）"
ui_print "- 在 KernelSU 模块列表中点击本模块可打开界面"
