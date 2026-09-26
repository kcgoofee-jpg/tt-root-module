# Windows 上测试 pc/pull-backups.ps1：假 adb（tests/win-fake-adb.cmd → Git Bash）模拟手机，手机那头跑真的 ui.sh。
# 用法（GitHub Actions 的 windows-latest，Windows PowerShell 5.1）：powershell -File tests\win-cases.ps1
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$T = Join-Path $env:RUNNER_TEMP ("tt-win-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $T | Out-Null
$u = { param($p) $p -replace '\\', '/' }
$phone = Join-Path $T 'phone'; $mod = Join-Path $phone 'mod'; $bk = Join-Path $phone 'bk'
New-Item -ItemType Directory -Force -Path $mod, $bk, (Join-Path $phone 'data\default-user') | Out-Null
Copy-Item (Join-Path $Root 'ksu-tt-keepalive\*') $mod -Recurse
$env:PHONE_MOD = & $u $mod; $env:TT_MODDIR = & $u $mod; $env:TT_GUARD_DIR = & $u $mod
$env:PRIVATE_BK = & $u $bk; $env:FAKE_PULL = & $u (Join-Path $phone 'tt-pull'); $env:TT_DATA = & $u (Join-Path $phone 'data')
$env:FAKE_SERIAL = 'USB123'
$Adb = Join-Path $Root 'tests\win-fake-adb.cmd'
$Dest = Join-Path $T '电脑 上的 备份'
$bash = 'C:\Program Files\Git\bin\bash.exe'
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++ } else { $script:fail++; Write-Host "  x $name" } }
function Mkbk([string]$stamp) {
    & $bash -c "cd '$($env:PRIVATE_BK)' && n=tt-default-user-$stamp.tar.gz && echo 'data $stamp' | gzip > `$n && sha256sum `$n > `$n.sha256"
}
function Run { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'pc\pull-backups.ps1') -Dest $Dest -Adb $Adb -Quiet; $LASTEXITCODE }

$d0 = (Get-Date).ToString('yyyyMMdd'); $d1 = (Get-Date).AddDays(-1).ToString('yyyyMMdd')
$env:FAKE_SERIAL = ''
Check '没连上手机：退出码 2' ((Run) -eq 2)
$env:FAKE_SERIAL = 'USB123'
Mkbk "$d0-120000"; Mkbk "$d1-080000"
$r = Run
Check "成功（退出码 $r）" ($r -eq 0)
$f0 = Join-Path $Dest "tt-default-user-$d0-120000.tar.gz"
Check '两份都拷到了（路径有空格和中文）' ((Test-Path $f0) -and (Test-Path (Join-Path $Dest "tt-default-user-$d1-080000.tar.gz")))
$want = if (Test-Path "$f0.sha256") { ((Get-Content "$f0.sha256") -split '\s+')[0] } else { '' }
$got = if (Test-Path $f0) { (Get-FileHash $f0 -Algorithm SHA256).Hash.ToLower() } else { 'none' }
Check 'sha256 对得上（二进制安全）' ($want -eq $got)
Check '手机记下已同步' ([string](Get-Content (Join-Path $mod 'state.txt') -Raw -ErrorAction SilentlyContinue) -match 'mac_pulled=')
Check '再跑一次：成功' ((Run) -eq 0)
Mkbk "$d0-200000"
$env:FAKE_CORRUPT = '1'
$r = Run
Check "拷坏了：退出码 1，不留坏文件（$r）" (($r -eq 1) -and -not (Test-Path (Join-Path $Dest "tt-default-user-$d0-200000.tar.gz")))
$env:FAKE_CORRUPT = ''
Run | Out-Null
Check '下次重拷成功' (Test-Path (Join-Path $Dest "tt-default-user-$d0-200000.tar.gz"))
Check '没有残留的锁' (-not (Test-Path (Join-Path $Dest '.pull.lock')))
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'pc\install-windows.ps1'), [ref]$null, [ref]$e) | Out-Null
Check '安装脚本语法' ($e.Count -eq 0)
Write-Host "通过 $pass，失败 $fail"
if ($fail) { Get-Content (Join-Path $Dest 'pull.log') -ErrorAction SilentlyContinue | Select-Object -Last 30; exit 1 }
