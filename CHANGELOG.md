# 更新记录

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
