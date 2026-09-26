@echo off
rem 双击运行一次：开启「手机连上电脑就自动备份」。之后所有操作在手机上的 TT 守护界面里完成。
rem 关闭：在 PowerShell 中运行 install-windows.ps1 -Uninstall
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pull-backups.ps1"
echo.
pause
