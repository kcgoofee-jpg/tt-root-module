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
# 不同 Root 管理器：界面的打开方式不同（安装环境里 KSU / APATCH / MAGISK_VER_CODE 由管理器设置）
if [ "${KSU:-}" = true ] || [ "${APATCH:-}" = true ]; then
    ui_print "- 在管理器的模块列表中点击本模块可打开界面"
elif [ -n "${MAGISK_VER_CODE:-}" ]; then
    ui_print "- Magisk 不能直接打开模块界面：可安装 WebUI X 等应用打开，或使用模块的「执行」按钮（Magisk 28 以上）"
else
    ui_print "- 未识别的 Root 管理器：自动备份照常运行，界面可能无法打开"
fi
