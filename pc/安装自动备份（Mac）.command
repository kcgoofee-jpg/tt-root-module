#!/bin/zsh
# 双击运行一次：开启「手机连上电脑就自动备份」。之后不需要再打开终端，所有操作在手机上的 TT 守护界面里完成。
# 再双击一次会问要不要关闭。
cd "${0:A:h}" || exit 1
if launchctl print "gui/$(id -u)/com.ttguard.pull-backups" >/dev/null 2>&1; then
    print "自动备份已开启。"
    read -q "?要关闭吗？(y/N) " && { print; zsh ./install-mac.sh --uninstall; } || print
else
    zsh ./install-mac.sh && zsh ./pull-backups.sh
fi
print; print "按任意键关闭窗口"; read -k 1 -s
