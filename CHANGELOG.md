# 更新记录

## 1.4（2026-09-26）

- 新增：**每天备份 TT 数据**到「内部存储/Documents/TauriTavern-backup」，留最近 7 份（约 45 MB 一份，2 秒左右）。不含 API 密钥（`secrets.json`）、TT 自己的备份、缩略图、日志和临时文件；生成中不备份，失败 1 小时后重试。卸载模块不删备份。
- 新增：TT **生成回复到一半被系统杀掉**（内存不够、厂商清理等，不是你划掉或强制停止）时**自动重新打开 TT**，10 分钟内最多一次。
- 新增：生成中**网络被系统限制**时提醒一次。
- 新增：**每天统计**生成次数和时长、冻结次数、被系统结束 / 被强制停止次数（`stats.txt`，留 8 天）；当天生成累计满 5 小时提醒一次（Android 15 起这类后台生成每 24 小时最多约 6 小时）。
- 新增：TT 被系统杀掉时，从系统日志里找出是谁动的手（ColorOS 的 athena / hans、lmkd 等）记一行。
- 新增：TT 升级、重装时记一行。
- 新增：开关文件 `config.txt`（备份、备份份数、自动重开、通知），改完不用重启。
- 「执行」按钮：今天的统计、最近 7 天的表、退出原因汇总、备份情况、开关。
- 日志改成留最近 7 天（原来只有 200 行）。
- 测试：130 项，Mac 上 dash / sh / ksh，手机上真正的 mksh 和 busybox ash 都跑（`tests/run-on-phone.sh`）。
- 没做：通知点一下打开 TT——系统不允许命令行发的通知带跳转（shell 身份拿不到 PendingIntent）。

## 1.3.1（2026-09-26）

- 修：KernelSU 启动脚本时 umask 是 0，`state.txt` 被建成人人可写（`rw-rw-rw-`）；现在脚本开头设 `umask 022`。`/data/adb` 本来只有 root 能进，没有实际风险。

## 1.3（2026-09-26）

实测（OnePlus PLC110 / Android 16）后重新定位：TT 2.3.0 生成回复时自己开前台服务（`AiGenerationForegroundService`，dataSync），系统优先级约 200，不会被 Android 冻结；空闲时被冻结是正常省电，不影响回复。今天 TT 的 8 次重启全是「强制停止」（电脑上的 `am force-stop`），没有一次是系统查杀。所以 1.3 把重点放在「看清楚、出事告诉你」。

- 新增：TT 进程没了时，读系统的退出记录（ApplicationExitInfo），把原因翻成人话记进 `service.log`（强制停止 / 内存不够 / 厂商清理 / 崩溃 / ANR …）。第一次运行不补记以前的。
- 新增：TT **正在生成回复**时被冻结或进程没了，发一条通知（以 shell 身份 `cmd notification post`，root 直接发会被系统丢掉；同一次生成只提醒一次）。冻结记录里标出「正在生成回复」。
- 「执行」按钮：新增 是否在生成、网络是否被限制、今天冻结次数（生成中几次）、最近 3 次退出原因；去掉 `/proc` 的 oom_score_adj。
- 去掉：写 `/proc/<pid>/oom_score_adj`（系统决定冻结和查杀都不看它，还会改回去）；`am set-inactive`（卸载时没法还原，而且 `set-standby-bucket` 已经够了）。
- 升级时把 `state.txt`（退出记录读到哪）也带到新版本。
- 公共函数挪到 `common.sh`；新增 `tests/`（dash / sh / ksh 各跑一遍，假命令模拟 dumpsys / am / cmd），`build-ksu-module.sh` 先跑测试再打包。
- 从 SillyTavern-ClaudeMax 扩展仓库（`launcher/android`）独立出来，以后在这里开发；扩展的「安卓保活模块」菜单从这里打包。

## 1.2（扩展仓库 e8c672d）

记录装模块前的原值（prior.txt）、卸载时还原；后台时把 oom_score_adj 降到 250；15 秒检查；白名单 / 后台运行丢了自动补；只在被降到「活跃」以下时拉回待机分组；冻结 / 解冻记日志；附带 Magisk 用的 META-INF。
