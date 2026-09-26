# TauriTavern 后台保活（KernelSU 模块）

手机上的 TauriTavern（TT，`com.tauritavern.client`）退到后台时，系统可能冻结它、在内存紧张时杀掉它。这个模块只对 TT 做几件 Android 自带的事，并且把「TT 为什么停了」记清楚，生成回复中出事时发通知。

| 做什么 | 怎么做 | 卸载后 |
|---|---|---|
| 电池优化白名单：息屏打盹（Doze）时网络不断 | `dumpsys deviceidle whitelist +包名`，每 10 分钟核对，丢了就补（比如重装过 TT） | 还原成装模块前的样子（原来不在白名单就撤掉） |
| 允许后台运行 | `cmd appops set 包名 RUN_IN_BACKGROUND / RUN_ANY_IN_BACKGROUND allow`，同样每 10 分钟核对 | 还原成装模块前的值 |
| 待机分组不掉下去 | 只在被系统降到「活跃」（10）以下时 `am set-standby-bucket 包名 active`；在白名单里时是 5「豁免」，不去碰 | 模块改过的话还原成原来的分组 |
| 冻结记录（只看） | TT 被 Android（cgroup v2 `cgroup.events` 的 `frozen 1`）或 ColorOS（`/dev/freezer/frozen`）冻结、解冻时记一行，含冻了多久、当时是否在生成回复 | — |
| 退出原因（只看） | TT 进程没了时读 `dumpsys activity exit-info`，把原因翻成人话记一行 | — |
| 出事通知 | TT **正在生成回复**时被冻结或进程没了，发一条通知（同一次生成只提醒一次） | 发过的通知手动划掉 |

## 关于冻结和查杀（实测，OnePlus PLC110 / Android 16 / TT 2.3.0）

- 系统的后台冻结器开着：优先级（oom_adj）≥ 900（「缓存」）的应用会被冻结。电池白名单、待机分组「豁免」都**不**免冻结。
- TT 2.3.0 起，**生成回复时自己开前台服务**（`AiGenerationForegroundService`，通知「少女祈祷中 / 请勿划掉」），优先级约 200，不会被 Android 冻结；生成完就关。空闲时被冻结是正常省电，不影响回复，点开就解冻。
- Android 15 起，这类前台服务（dataSync）每 24 小时最多约 6 小时，超了系统会让它停。
- 按 AOSP 的实现，系统决定冻结谁、lmkd 决定先杀谁，都用系统自己记的优先级，不读 `/proc/<pid>/oom_score_adj`，所以 1.3 不再改它。
- Android 16 没有「单个应用免冻结」的正当开关，只能整机关冻结器（所有应用都更耗电）或强行解冻（和系统打架），这个模块都不做。
- ColorOS / OxygenOS 还有自家的后台管控（athena、hans）。另外到「设置 → 电池 → 应用耗电管理 → TauriTavern」打开「允许后台行为」「允许自启动」。

## 安装 / 升级

1. Mac 上运行 `zsh build-ksu-module.sh`（先跑单元测试），得到 `dist/claudemax-tt-keepalive-<版本>.zip`。酒馆工具的「安卓保活模块」菜单也是调这个脚本，并把 zip 推到手机的「下载」文件夹。
2. 手机：KernelSU 管理器 → 模块 → 从本地安装 → 选这个 zip → 重启。旧版本直接覆盖，原值、状态和日志会带过来。
3. 模块卡片上的「执行」按钮（`action.sh`，只读）显示：白名单、后台运行、待机分组、网络是否被限制、是否在生成回复、各进程是否被冻结、系统记的优先级、今天冻结了几次、最近 3 次退出原因、装模块前的原值、最近的日志。

卸载：KernelSU 管理器里删除模块并重启。`uninstall.sh` 在开机早期运行，那时系统服务还没起来，所以它先读出原值、在后台等开机完成后再还原白名单、后台运行和待机分组。模块只改过这三样。

Magisk：zip 里按 Magisk 文档带了 `META-INF`（安装器）和 `customize.sh`，理论上能用 Magisk 装，但只在 KernelSU 上测过。

## 开发

- `ksu-tt-keepalive/`：模块本体。`common.sh` 是共用函数，`service.sh` 开机后常驻，`action.sh` 是「执行」按钮，`uninstall.sh` 卸载时还原，`customize.sh` 升级时带上旧数据。
- `sh tests/run.sh`：在 Mac 上用 dash / sh / ksh 各跑一遍单元测试（手机上是 busybox ash 或 mksh）。用 PATH 里的假命令代替 dumpsys / am / cmd 等，模块脚本不改一行地被测；样例数据在 `tests/fixtures/`，取自真机输出。
- 版本号在 `ksu-tt-keepalive/module.prop`（`version` 和 `versionCode` 一起加），改动写进 `CHANGELOG.md`。

## 安全自查（1.3）

- **范围**：只动一个包名 `com.tauritavern.client`，写死在脚本里；没装 TT 时什么都不改。
- **权限用途**：root 只用来执行上表的 Android 命令、读 cgroup 状态文件，以及以 shell 身份（`su 2000`）发通知。不写 `/proc`、不写 cgroup、不解冻。
- **不做的事**：不联网、不下载、不含任何可执行文件或库；没有 `system/` 目录（不覆盖系统文件）；不改 SELinux 策略；不改系统属性（`resetprop`）；不改全局冻结器设置；不读取任何应用的数据或聊天内容；不装 LSPosed / Zygisk 钩子。
- **外部输入**：只读系统命令的输出；通知文字里的引号会被去掉再拼命令。日志只写模块自己目录里的 `service.log`（时间和发生了什么），超过 240 行只留最近 200 行；`prior.txt` 只记四个设置的原值；`state.txt` 只记退出记录读到哪个时间。
- **资源占用**：常驻一个 shell 循环：TT 开着时每 15 秒一次 `pidof`、一次 `dumpsys activity services`（只查 TT），读一两个 cgroup 文件；进程变化时读一次退出记录；TT 没开时每 60 秒一次；每 10 分钟核对一次白名单、后台运行和待机分组（只在不对时才改）。
- **副作用**：白名单和允许后台运行让 TT 息屏时网络不断，挂在后台时会比原来多耗一点电。
- **回滚**：删除模块并重启即可。
- 打包出的 zip 只有文本文件：`module.prop`、`common.sh`、`service.sh`、`uninstall.sh`、`action.sh`、`customize.sh`，以及 Magisk 用的 `META-INF/com/google/android/update-binary`、`updater-script`，安装前可以用任何文本编辑器看一遍。
