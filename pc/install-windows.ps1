# 在这台 Windows 电脑上装 / 卸任务计划：每 30 分钟（和登录时）跑一次 pull-backups.ps1，把手机上的 TT 备份拷过来。
#   右键「使用 PowerShell 运行」，或：powershell -ExecutionPolicy Bypass -File pc\install-windows.ps1
#   卸载：powershell -ExecutionPolicy Bypass -File pc\install-windows.ps1 -Uninstall（已拷到电脑的备份不删）
# 不需要管理员权限：任务只以当前用户身份运行。
param([switch]$Uninstall, [string]$Dest)
$Name = 'TT 守护 - 拷手机备份'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
if ($Uninstall) { Write-Host '已卸载任务计划（电脑上的备份没删）'; exit 0 }
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Here\pull-backups.ps1`" -Quiet"
if ($Dest) { $argLine += " -Dest `"$Dest`"" }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($every, $logon) -Settings $settings -Description '把手机上 TT 守护模块的备份拷到这台电脑并核对' | Out-Null
Write-Host '已安装：每 30 分钟把手机上的 TT 备份拷到电脑（记录在备份文件夹的 pull.log）'
