# TT 守护（KernelSU 模块）

为手机上的 SillyTavern 类应用提供数据保护和运行诊断：自动备份、校验、分层保留、同步到电脑（Mac / Windows）、一键恢复、异常通知；附带保活设置。离线运行。

支持的酒馆（自动检测，未安装或没有数据的跳过）：

| 酒馆 | 包名 | 数据位置 | 备份内容 |
|---|---|---|---|
| TauriTavern（TT） | `com.tauritavern.client` | `Android/data/…/data` | `default-user`、`extensions`、`_cm_archive`、`_css`、`_tauritavern` |
| SillyDroid | `com.jm.sillydroid` | `/data/data/com.jm.sillydroid/files/android-tavern/data/server` | `config`、`data`、`extensions`、`plugins` |
| SillyTavern（Termux） | `com.termux` | `~/SillyTavern`（Termux 主目录） | `config.yaml`、`data`、`plugins`、`public/scripts/extensions/third-party` |

所有酒馆都不备份 `secrets.json`、`cookie-secret.txt`（密钥）、酒馆自带备份、缩略图、缓存、日志、`node_modules`。

## 定位

TT 的后端在 App 进程内。2.3.0 起生成回复时自带前台服务，不会被 Android 冻结；空闲时被冻结属于正常省电，不影响数据。因此对 TT，本模块以**数据安全和诊断**为主，保活设置作为补充。

SillyDroid 和 Termux 中的 SillyTavern 是常驻的 node 服务，需要保活：检测到它们时，模块同样设置电池优化白名单和允许后台运行（记录原值，卸载时还原）。实测 Termux 在后台下载时被冻结，连接中断。

实测（OnePlus PLC110 / Android 16 / KernelSU 3.3.0）：一天内 TT 的 8 次重启均为 `am force-stop`（电脑端工具触发），没有系统查杀。

## 功能

| 类别 | 内容 |
|---|---|
| 备份 | 数据有变化时最多每 6 小时一次；生成中、开机未解锁、存储空间不足时不备份。完成后立即校验（完整读取、确认不含 `secrets.json`），并写 `.sha256`。 |
| 备份范围 | `default-user`（聊天、角色卡、世界书、设置）、`extensions`、`_cm_archive`、`_css`、`_tauritavern`。不含任何位置的 `secrets.json`（API 密钥）、TT 自带备份、缩略图、日志、缓存。 |
| 实时副本 | TT 每次生成结束后立即复制变化的文件，其余情况每 5 分钟检查一次。只复制变化的文件、不删除，不含密钥。放在 `/data/adb/tt-backups/live`。用于弥补两次完整备份之间的改动；可在界面中从实时副本恢复。 |
| 断电与低电量 | 备份写入存储后才改名；开机后校验最新备份，损坏的隔离并通知；恢复中途断电，开机后通知并给出恢复前备份；电量低于 15% 且未充电时提前备份一次，并拒绝恢复。 |
| 分层保留 | 最新一份和近 2 天全部保留；之后每天 / 每周 / 每月各留最新一份（默认 7 天 / 4 周 / 6 个月）。系统时间异常跳变时不删除。恢复前自动保存的备份单独保留最新 3 份。每份约 45 MB，总占用约 1 GB。 |
| 存储位置 | 默认 `/data/adb/tt-backups`（仅 root 可读）；可切换到「内部存储/Documents/TauriTavern-backup」。卸载模块时私密备份移至共享位置。 |
| 同步到电脑 | 电脑端定时任务每 30 分钟从手机拉取新备份并核对 sha256，电脑上按 14 天 / 8 周 / 24 个月保留。手机端超过 3 天未同步时提醒。 |
| 恢复 | 界面或电脑菜单中选择备份，按文件名自动识别酒馆。校验 sha256、检查空间、加锁，恢复前自动保存当前数据；备份之后新建的内容不删除；密钥不受影响；属主和 SELinux 标签按原目录还原（含 App 私有目录的分类号）。酒馆运行时拒绝恢复（不会强制停止）。 |
| 异常通知 | 生成中被冻结、进程退出、网络受限、电池过热；备份连续失败、超过 2 天未备份、存储空间不足；TT 崩溃（同时保存崩溃记录）。 |
| 诊断 | 冻结 / 解冻记录、退出原因（ApplicationExitInfo）、每日统计、温度（电池 / 处理器 / 主板）、TT 与 WebView 版本变化、自检、导出诊断包。 |
| 保活设置 | 电池优化白名单、允许后台运行、待机分组不低于「活跃」；每 10 分钟核对；卸载时还原为安装前的值。 |
| 其他 | 生成中被系统结束时自动重开 TT（最近任务中划掉的除外，10 分钟内最多一次）；每天清理 TT 自身 30 天前的运行日志和错误记录。 |

## 界面

KernelSU 管理器 → 模块 → 点击「TT 守护」打开。首屏显示运行状态、最近备份、电脑同步和 TT 状态；备份列表、恢复、诊断（统计、退出记录、占用空间、自检、导出诊断包）、设置、日志依次展开。设置即时生效，无需重启。

模块卡片上的「执行」按钮输出同样信息的文本版本。

## 安装与更新

支持的 Root 管理器：KernelSU、KernelSU Next、SukiSU Ultra、APatch（可直接打开界面）；Magisk 需另装 WebUI X 等应用打开界面，「执行」按钮需 Magisk 28 以上。实测环境为 KernelSU。
已发布到 GitHub Releases，模块中配置了 `updateJson`，可在管理器中直接更新。

1. 构建：`zsh build-ksu-module.sh`（先运行全部测试），产物为 `dist/claudemax-tt-keepalive-<版本>.zip`。电脑端「安卓保活模块」菜单会构建并推送到手机的「下载」。
2. 手机：KernelSU 管理器 → 模块 → 从本地安装 → 选择 zip → 重启。升级时保留原值、状态、统计、设置和日志。
3. KernelSU 的模块更新需要重启才会生效，这是 KernelSU 的机制；界面和设置的改动不需要重启。

卸载：在 KernelSU 管理器中删除模块并重启。开机完成后还原保活设置；解锁后把私密备份移到「内部存储/Documents/TauriTavern-backup」并发送通知。

## 电脑端同步

电脑上安装一次后，手机连上电脑（数据线或无线调试）即自动同步；也可以在手机界面中点击「立即同步到电脑」，电脑在一分钟内完成。之后无需在电脑上操作。

一次性安装：在模块仓库的 `pc` 文件夹中双击 `安装自动备份（Mac）.command` 或 `安装自动备份（Windows）.cmd`。

前提：手机已开启 USB 调试或无线调试，KernelSU 中已授予 Shell（`com.android.shell`）root 权限。注意：授权后，任何被手机信任的电脑都可以通过 adb 获得 root。

**Mac**

```bash
zsh pc/install-mac.sh
```

每分钟运行一次 `pc/pull-backups.sh`（launchd，登录时也运行）；未连接手机或没有新内容时立即退出。备份保存在 `tavern/phone-backups/tt`，可用 `TT_PHONE_BACKUP_DIR` 修改。卸载：`zsh pc/install-mac.sh --uninstall`。

**Windows**（PowerShell 5.1，Windows 10 / 11 自带，不需要管理员权限）

```powershell
powershell -ExecutionPolicy Bypass -File pc\install-windows.ps1
```

每分钟运行一次 `pc\pull-backups.ps1`（任务计划，登录时也运行，`conhost --headless` 启动不显示窗口）；未连接手机或没有新内容时立即退出。备份保存在「文档\TT-phone-backups」，可用 `-Dest` 修改。adb 查找顺序：`-Adb` 参数、`tavern\tools\platform-tools\adb.exe`、PATH。卸载：加 `-Uninstall`。

两个平台共用同一套逻辑：只拉取电脑上没有的备份，经手机中转目录 `adb pull`（二进制安全），核对 sha256 后才保存；保留规则由手机端计算（`ui.sh plan`）；全部成功后通知手机「已同步」；连续 3 天未同步时发送系统通知；运行记录在备份目录的 `pull.log`。

## 数据目录

模块的日志、状态、统计、设置、崩溃记录保存在 `/data/adb/tt-guard`（仅 root 可读），不在模块目录中，更新模块时不会丢失；卸载时删除。在 KernelSU 管理器中禁用模块后，模块停止一切操作，直到重新启用。

## 设置

保存在 `/data/adb/tt-guard/config.txt`，可在界面中修改。值必须是数字；无效的值按默认值处理，并在自检中列出。

| 键 | 默认 | 说明 |
|---|---|---|
| `backup` | 1 | 自动备份 |
| `backup_hours` | 6 | 数据有变化时的最短备份间隔（小时） |
| `backup_private` | 1 | 1 = 私密存储，0 = 共享存储 |
| `keep_days` / `keep_weeks` / `keep_months` | 7 / 4 / 6 | 分层保留 |
| `mac_alert_days` | 3 | 超过几天未同步到电脑时提醒，0 = 关闭 |
| `auto_reopen` | 1 | 生成中被系统结束时自动重开 TT |
| `notify` | 1 | 异常通知，0 = 仅记录日志 |
| `cleanup_days` | 30 | 清理 TT 自身多少天前的日志，0 = 不清理 |
| `temp_alert` | 45 | 生成中电池温度提醒阈值（°C），0 = 关闭 |
| `live` | 1 | 实时副本 |
| `live_minutes` | 5 | 实时副本的检查间隔（分钟）；TT 生成结束后立即复制 |

## 手动恢复

1. 在最近任务中关闭 TT。
2. 用有 root 权限的文件管理器解压备份（`.tar.gz`），得到 `default-user` 等目录。
3. 复制回 `内部存储/Android/data/com.tauritavern.client/data/`，文件属主改为 TT 的 uid。
4. API 密钥不在备份中，换机或重装后需重新填写。

## 开发与发布

目录：

| 路径 | 内容 |
|---|---|
| `ksu-tt-keepalive/` | 模块本体：`common.sh` 公共函数，`service.sh` 常驻循环，`ui.sh` 界面与电脑端调用的命令，`restore.sh` 恢复，`action.sh` 执行按钮，`uninstall.sh`，`customize.sh`，`retention.awk` 保留规则，`webroot/index.html` 界面 |
| `pc/` | 电脑端：`pull-backups.sh`（Mac）、`pull-backups.ps1`（Windows）及安装脚本 |
| `tests/` | `run.sh` 全部测试；`cases.sh` 模块测试（dash / sh / ksh 各运行一遍）；`pc-cases.zsh` 电脑端测试；`run-on-phone.sh` 在手机的 mksh 和 busybox ash 上运行模块测试 |

约定：

- 测试用 PATH 中的假命令替代 `dumpsys`、`am`、`cmd`、`pm`、`logcat`、`getprop`、`df` 等，模块脚本不做任何修改即可测试；样例数据取自真机，位于 `tests/fixtures/`。
- 脚本只使用 POSIX sh 语法（手机上由 busybox ash 或 mksh 运行）；函数若要避免修改调用方的同名变量，写成子 shell 函数 `f() ( … )`。
- 用户可见文案：标准化、简洁，不使用口语。
- 发布：修改 `module.prop` 的 `version` 和 `versionCode` → 写 `CHANGELOG.md` → `sh tests/run.sh` → `ADB=… ANDROID_SERIAL=… zsh tests/run-on-phone.sh` → `zsh build-ksu-module.sh`。
- 排查问题：界面「诊断 → 导出诊断包」生成 `内部存储/Download/tt-guard-diag-*.tar.gz`，内含模块日志、状态、设置、自检结果和设备信息，不含聊天数据。

## 安全说明

- 作用范围：只操作 `com.tauritavern.client`；未安装 TT 时不做任何修改。
- root 用途：执行上述 Android 命令；读取 cgroup、温度传感器和系统日志；打包、校验、恢复 TT 数据；以 shell 身份（`su 2000`）发送通知；自动重开时 `am start` TT。不写 `/proc`，不写 cgroup，不解冻进程，不修改全局冻结器设置、SELinux 策略或系统属性。
- 数据：不联网；备份不含 `secrets.json`，默认只有 root 可读；诊断包不含聊天数据。
- 输入：界面传入的开关名和值只接受白名单和数字；备份文件名只接受 `tt-default-user-*.tar.gz` 格式且不含 `..` 和 `/`；恢复前检查压缩包内只有允许的目录、没有 `..`。
- 资源：TT 运行时每 15 秒检查一次（空闲冻结时降为 60 秒且不调用 `dumpsys`）；备份约 2 秒，最低优先级。
- 回滚：删除模块并重启。
