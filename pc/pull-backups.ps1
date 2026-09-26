# 把手机上 TT 守护模块的备份拷到这台 Windows 电脑（Windows 10 / 11 自带的 PowerShell 5.1 即可）。
#   · 任务计划每分钟跑一次（双击「安装自动备份（Windows）.cmd」装）。没连手机时立即退出；
#     连上后先问手机有没有新备份或「立即同步」请求，没有就立即退出，所以很轻。
#   · 只拷电脑上还没有的；拷完用手机给的 sha256 核对，对不上就丢掉、下次重拷。
#   · 电脑上也分层保留（默认 14 天 / 8 周 / 24 个月），规则在手机上算（ui.sh plan），和 Mac 一致。
#   · 连续 3 天没能和手机同步：弹一条 Windows 通知（每天最多一次）。
# 参数：-Dest 备份放哪（默认 文档\TT-phone-backups）；-Adb adb.exe 路径；-Keep "14 8 24"；-Quiet
# 退出码：0 同步好了（或没有新备份），1 出错，2 没连上手机 / 手机上没装模块（不算错）
param(
    [string]$Dest = $(if ($env:TT_PHONE_BACKUP_DIR) { $env:TT_PHONE_BACKUP_DIR } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'TT-phone-backups' }),
    [string]$Adb = $env:ADB,
    [string]$Keep = $(if ($env:TT_PC_KEEP) { $env:TT_PC_KEEP } else { '14 8 24' }),
    [string]$PhoneAddr = $env:TT_PHONE_ADDR,
    [switch]$Quiet
)
$ErrorActionPreference = 'Continue'
$Mod = '/data/adb/modules/claudemax_tt_keepalive'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tavern = Split-Path -Parent (Split-Path -Parent $Here)

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$Log = Join-Path $Dest 'pull.log'
function Say([string]$msg) {
    if (-not $Quiet) { Write-Host $msg }
    Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}
function Trim-Log {
    $lines = Get-Content -Path $Log -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($lines.Count -gt 1200) { $lines | Select-Object -Last 1000 | Set-Content -Path $Log -Encoding UTF8 }
}
function Notify-Win([string]$title, [string]$body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $xml.GetElementsByTagName('text')
        $t.Item(0).AppendChild($xml.CreateTextNode($title)) | Out-Null
        $t.Item(1).AppendChild($xml.CreateTextNode($body)) | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { }
}
# 用 UTC：PS 5.1 的 Get-Date -UFormat %s 按本地时间算，和 PS 7 差时区
function Now-Epoch { [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# 同一时间只跑一个；超过 30 分钟的锁当作残留
$Lock = Join-Path $Dest '.pull.lock'
if (Test-Path $Lock) {
    if ((Get-Item $Lock).LastWriteTime -gt (Get-Date).AddMinutes(-30)) { if (-not $Quiet) { Write-Host '另一个拷贝正在进行' }; exit 0 }
    Remove-Item -Recurse -Force $Lock
}
New-Item -ItemType Directory -Path $Lock | Out-Null

function Stale-Check {
    $f = Join-Path $Dest '.last-sync'; $day = Get-Date -Format 'yyyyMMdd'
    if (-not (Test-Path $f)) { Set-Content $f (Now-Epoch); return }
    $ok = [int64](Get-Content $f); $gap = (Now-Epoch) - $ok
    $alertFile = Join-Path $Dest '.last-alert-day'
    $last = if (Test-Path $alertFile) { (Get-Content $alertFile) } else { '' }
    if ($gap -gt 3 * 86400 -and $last -ne $day) {
        Set-Content $alertFile $day
        $d = [math]::Floor($gap / 86400)
        Say "已经 $d 天没和手机同步备份"
        Notify-Win 'TT 备份' "已经 $d 天没从手机拷到电脑。连上手机（数据线或无线调试）即可。"
    }
}
function Finish([int]$code) { Remove-Item -Recurse -Force $Lock -ErrorAction SilentlyContinue; Trim-Log; exit $code }

# ---------- 找 adb 和手机 ----------
if (-not $Adb -or -not (Test-Path $Adb)) { $Adb = Join-Path $Tavern 'tools\platform-tools\adb.exe' }
if (-not (Test-Path $Adb)) { $c = Get-Command adb.exe -ErrorAction SilentlyContinue; $Adb = if ($c) { $c.Source } else { '' } }
if (-not $Adb) { Say '没找到 adb.exe'; Stale-Check; Finish 2 }
function Devices { & $Adb devices 2>$null | Select-Object -Skip 1 | ForEach-Object { $p = $_ -split '\s+'; if ($p.Count -ge 2 -and $p[1] -eq 'device') { $p[0] } } }
$serial = Devices | Where-Object { $_ -notmatch ':' } | Select-Object -First 1
if (-not $serial) {
    $serial = Devices | Select-Object -First 1
    if (-not $serial) {
        if (-not $PhoneAddr) {
            $pf = Join-Path $Tavern 'extension\launcher\phone.local'
            if (Test-Path $pf) { $PhoneAddr = (Get-Content $pf -TotalCount 1).Trim() }
        }
        if ($PhoneAddr -match ':') { & $Adb connect $PhoneAddr 2>$null | Out-Null }
        $serial = Devices | Select-Object -First 1
    }
}
if (-not $serial) { if (-not $Quiet) { Write-Host '没连上手机' }; Stale-Check; Finish 2 }
function Root([string]$cmd) {
    $out = & $Adb -s $serial shell "su -c '$cmd'" 2>$null
    if ($null -eq $out) { return @() }
    return @($out | ForEach-Object { $_.TrimEnd("`r") })
}
if ((Root "[ -f $Mod/ui.sh ] && echo y") -notcontains 'y') { Say '手机上没装 TT 守护模块（1.6 以上）'; Stale-Check; Finish 2 }
$HostName = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '')

# 快速判断：没有「立即同步」请求、手机上的每份备份电脑上都有、今天已经整理过 → 不用同步
# （每小时告诉手机一次「电脑在」）。每分钟只多两次很轻的 adb 调用
$info = ((Root "sh $Mod/ui.sh sync-info") | Select-Object -First 1)
$req = ''
if ($info) { $parts = @($info.Trim() -split '\s+'); if ($parts[0] -ne '0') { $req = $parts[0] } }
$phoneList = @(Root "sh $Mod/ui.sh list-backups")
$missing = @($phoneList | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0] } | Where-Object { -not (Test-Path (Join-Path $Dest $_)) }).Count
$pruneFile = Join-Path $Dest '.last-prune'
Get-ChildItem -Path $Dest -Filter '.*.part' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
function Local-Count { @(Get-ChildItem -Path $Dest -Filter '*.tar.gz' | Where-Object { $_.Name -match '^(tt-default-user|sillydroid|termux-st)-[0-9]{8}-[0-9]+(-prerestore)?\.tar\.gz$' }).Count }
# 换了一天，或者电脑上的备份份数和上次整理时不一样，就再整理一次
$pruneKey = "{0} {1}" -f (Get-Date -Format 'yyyyMMdd'), (Local-Count)
$prunedToday = (Test-Path $pruneFile) -and ((Get-Content $pruneFile) -eq $pruneKey)
if (-not $env:FORCE -and -not $req -and $missing -eq 0 -and $prunedToday) {
    Set-Content (Join-Path $Dest '.last-sync') (Now-Epoch)
    $markFile = Join-Path $Dest '.last-mark'
    $lastMark = if (Test-Path $markFile) { [int64](Get-Content $markFile) } else { 0 }
    if ((Now-Epoch) - $lastMark -gt 3600) { Root "sh $Mod/ui.sh mark-pulled $HostName" | Out-Null; Set-Content $markFile (Now-Epoch) }
    if (-not $Quiet) { Write-Host '电脑上已经是最新的' }
    Finish 0
}
if ($req) { Say '收到手机上的「立即同步」请求' }

# ---------- 拷新的 ----------
$got = 0; $bad = 0
foreach ($line in $phoneList) {
    $p = $line -split ' '
    if ($p.Count -lt 3) { continue }
    $name = $p[0]; $kb = [int]$p[1]; $sha = $p[2].ToLower()
    if ($name -notmatch '^(tt-default-user|sillydroid|termux-st)-[0-9]{8}-[0-9]{4,6}(-prerestore)?\.tar\.gz$' -or $sha -notmatch '^[0-9a-f]{64}$') { continue }
    $target = Join-Path $Dest $name
    if (Test-Path $target) { continue }
    $path = (Root "sh $Mod/ui.sh stage $name") | Select-Object -First 1
    if ($path -ne "/data/local/tmp/tt-pull/$name") { Say "准备 $name 失败"; $bad++; continue }
    $part = Join-Path $Dest ".$name.part"
    & $Adb -s $serial pull $path $part 2>$null | Out-Null
    $ok = (Test-Path $part) -and ((Get-FileHash -Algorithm SHA256 -Path $part).Hash.ToLower() -eq $sha)
    if ($ok) {
        Move-Item -Force $part $target
        Set-Content -Path "$target.sha256" -Value "$sha  $name" -Encoding ASCII
        Say ("已拷到电脑并核对：{0}（{1} MB）" -f $name, [math]::Floor($kb / 1024))
        $got++
    } else {
        Remove-Item -Force $part -ErrorAction SilentlyContinue
        Say "拷贝或核对失败：$name（下次再试）"
        $bad++
    }
}
Root "sh $Mod/ui.sh unstage" | Out-Null
Get-ChildItem -Path $Dest -Filter '.*.part' -Force -ErrorAction SilentlyContinue | Remove-Item -Force

# ---------- 电脑上的分层保留（规则在手机上算） ----------
$k = $Keep -split '\s+'
if ($k.Count -ne 3) { $k = @('14', '8', '24') }
$local = @(Get-ChildItem -Path $Dest -Filter '*.tar.gz' | Where-Object { $_.Name -match '^(tt-default-user|sillydroid|termux-st)-[0-9]{8}-[0-9]+\.tar\.gz$' } | ForEach-Object { $_.Name })
if ($local.Count -gt 0) {
    foreach ($row in (Root ("sh $Mod/ui.sh plan {0} {1} {2} {3}" -f $k[0], $k[1], $k[2], ($local -join ' ')))) {
        $r = $row -split ' '
        if ($r.Count -eq 3 -and $r[0] -eq 'drop' -and $r[2] -match '^(tt-default-user|sillydroid|termux-st)-[0-9-]+\.tar\.gz$') {
            $f = Join-Path $Dest $r[2]
            if (Test-Path $f) { Remove-Item -Force $f, "$f.sha256" -ErrorAction SilentlyContinue; Say "按分层保留清掉电脑上的旧备份：$($r[2])" }
        }
    }
}

Set-Content $pruneFile ("{0} {1}" -f (Get-Date -Format 'yyyyMMdd'), (Local-Count))
if ($bad -eq 0) {
    Set-Content (Join-Path $Dest '.last-sync') (Now-Epoch)
    Root "sh $Mod/ui.sh mark-pulled $HostName" | Out-Null; Set-Content (Join-Path $Dest '.last-mark') (Now-Epoch)
    if ($got -eq 0 -and -not $Quiet) { Write-Host '电脑上已经是最新的' }
    Finish 0
}
Stale-Check
Finish 1
