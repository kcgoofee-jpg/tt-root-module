#!/bin/zsh
# 在这台 Mac 上装 / 卸定时任务：每分钟（和登录时）跑一次 pull-backups.sh，手机连上时自动把备份拷过来。
#   zsh pc/install-mac.sh             安装（重复运行 = 更新）
#   zsh pc/install-mac.sh --uninstall 卸载（已拷到电脑的备份不删）
# 要在模块仓库的主目录里运行（定时任务记的是这个脚本所在的路径）。
set -eu
HERE=${0:A:h}
LABEL=com.ttguard.pull-backups
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == --uninstall ]]; then
    rm -f "$PLIST"
    print "已卸载定时任务（电脑上的备份没删）"
    exit 0
fi
[[ "$HERE" == */.claude/worktrees/* ]] && { print -u2 "请在模块仓库的主目录里运行，不要在临时工作区里运行"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$HERE/pull-backups.sh</string><string>--quiet</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PL
launchctl bootstrap "$DOMAIN" "$PLIST"
print "已开启自动备份到这台电脑：手机连上（数据线或无线调试）后自动同步。记录在备份文件夹的 pull.log。"
