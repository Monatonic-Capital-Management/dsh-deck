# 日常操作与恢复

[返回首页](../README.md) · [快速上手](quickstart.md) · [配置参考](configuration.md) · [安全与隐私](security.md)

本文说明当前命令效果和恢复路径。实际验证环境与未验收场景见 [implementation-plan](implementation-plan.md)。

## 先确认目标和影响

使用命名参数，变更命令尽量显式指定 `-Target`。实例名来自配置的 `name`，不是 SSH 地址或显示名称；多个目标可用逗号分隔。未指定目标的生命周期命令通常选择全部启用实例，不适合作为排障第一步。

先查看登记信息，再针对一个实例探测：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command list
.\dsh.ps1 -Command status -Target local
````
</augment_code_snippet>

`status` 可能联网探测并读取版本；`-NoProbe` 跳过本地 HTTP 活性检查，**不是离线开关，不跳过远端 SSH/服务健康检查**。常规输出不展示入口认证参数，仍可能包含主机名和路径，不直接上传。未启用实例不自动探测；状态可保留已知本地进程以提供停止入口。

## 启动、停止和打开

| 命令 | 用途与边界 |
| --- | --- |
| `app` | 打开面板后端和窗口；不等于启动全部 dsh |
| `add` | 登记远端连接；不安装软件或启动服务 |
| `start` | 启动所选实例；本地不自动安装，远端按 `autoInstall` 决定是否自动准备软件和服务 |
| `open` | 打开已运行实例；不是安装或启动命令 |
| `stop` | 停止本地受管服务；远端断开隧道，并按配置决定是否停止服务 |
| `restart` | 停止后再启动，可能中断工作；不是无影响的刷新 |
| `tray`、`tray-start` | 启用托盘；不是纯状态查询 |
| `tray-stop` | 停止托盘进程；不等于停止所有实例 |
| `menu` | 终端交互入口；`tray-loop` 是内部进程入口，不用于日常操作 |

`app` 的 `-Stop` 只关闭面板后端及窗口；失败时应保留用于识别后端的状态文件。不要通过删除 `state/` 强行“重置”，这可能使仍运行的进程失去管理记录。

健康实例重复 `start` 保留现有服务；远端按 systemd cgroup 归属判断子进程，本地核对 dsh 入口、参数、进程时间和配置上下文。不接管无法证明属于 dsh 的进程，不按端口或 `node` 名称直接强杀。

`stopRemoteService:false` 表示远端停止仅断开隧道，保留服务，`remote-only` 可以是预期成功；远端不可达时仍可完成本机受管隧道停止。停用登记不停止进程，已有受管本地进程或隧道仍有停止入口。

## 安装与升级

| 操作 | 实际效果 | 不代表什么 |
| --- | --- | --- |
| `install` | 准备可用 Node/dsh 与远端服务定义；已有可用 dsh 不替换版本 | 不启动服务，不是升级命令 |
| 远端 `start` | 在允许时补齐软件/服务，再启动并验证 | 不是纯粹的状态查看 |
| `autoInstall:false` | 禁止 `start` 自动安装软件或部署服务 | 不禁止显式 `install`、`upgrade` |
| `upgrade` | 按固定版本或 latest 变更并验证；远端按原运行状态决定是否重启 | 不保证原子替换或失败回滚 |

安装可能下载 Node、运行 npm、写入用户级目录并部署 systemd 用户服务。linger 能否启用取决于远端权限，不能承诺所有主机都免权限配置、退出登录后仍可运行。安装和服务启动应分开确认。

检查版本及预览已有升级入口：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command check
.\dsh.ps1 -Command upgrade -Target prod -DryRun
````
</augment_code_snippet>

`check` 不执行升级，但会探测实例并查询 npm registry。`-DryRun` 返回只读计划，可能联网，不变更软件或服务。安装、检查、预览和升级统一解析 `dshVersion`；固定版本不会被 latest 覆盖，也可能要求回到较低的固定版本。

本地实例共享 Node/dsh 安装；升级前需先停止使用它的相关实例，固定版本冲突或影响无法确认时拒绝变更。分别报告已安装版本与正在运行版本；修改固定版本不代表运行中的进程已更新。

仅在确认目标版本、受影响实例和停机窗口后，才移除预览命令的 `-DryRun` 执行升级。升级可能中断运行中的工作；**不保证原子回滚**。失败后先确认安装与运行状态，再决定恢复或重试，不要连续执行全量升级。

## 计划与机器可读结果

操作前可查看与执行共用解析规则的计划：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command plan -Action upgrade -Target prod -Json
````
</augment_code_snippet>

`plan` 支持 `start`、`install`、`upgrade`，返回 `ok` 与 `plans`。每项包含目标实例、类型、动作、目标版本，以及 `changesSoftware`、`restartsService`、`requiresConfirmation`、`summary`、`steps`、`warnings`；只预览，不安装或启停服务，可能需要探测和版本查询。

结果约定：

- `list`、`status`、`url` 保留实例数据；实例生命周期、安装/升级、编辑/移除等变更命令返回 `ok`、`action`、`results`、`rows`。
- 每个 result 包含 `name`、`ok`、`errorCode`、`message`；任一目标失败应使命令退出非零，成功数按实际结果统计。
- HTTP 操作保留 `ok`、`code`、`errorCode`、`message`、`instance`。HTTP 200 或子进程退出零都不能单独代表业务成功。
- 预览与执行必须使用同一计划来源；超时应说明是否仍有后台变更，不提供无法终止底层任务的“取消”。

旧自动化调用方需迁移到逐实例结果，不能继续把状态数组或 HTTP 200 当作成功。被阻塞的计划仍带具体 `summary/errorCode`，CLI 退出非零，面板保留原因与恢复路径。`edit`、`remove`、`ssh-hosts` 见[配置参考](configuration.md)。

## 排查与恢复

| 现象 | 下一步 |
| --- | --- |
| 面板打不开、缺 Node | 用 `node-path` 检查实际运行时；明确选择本机 `install`，确认后端就绪 |
| dsh 已安装但不能运行 | 先检查 Node 版本与可用性；重复 npm 安装未必能修好运行时 |
| `port-busy` 或外部进程 | 核实归属或改用空闲端口；不要按进程名批量结束 Node |
| `unreachable` | 区分 DNS、SSH 认证、主机指纹、网络超时；主机指纹变化先核实，不绕过检查 |
| `remote-only` | 先确认是否有意只断隧道；启动可为健康服务恢复隧道而不重启服务 |
| `tunnel-only`、`unhealthy` | 隧道或服务进程存在不代表健康；可诊断、停止或明确重启 |
| 状态过期或探测失败 | 查看最近成功/尝试时间，再针对单实例刷新；不要把旧状态当刚完成的探测 |
| 升级失败 | 分清已安装/正在运行版本与服务状态；保留用户数据，按报错选择恢复方式 |

`doctor` 会检查本机并探测配置主机，不是离线检查。`logs` 支持 `-Lines` 和 `-Follow`，后者持续到 Ctrl-C；显示层默认脱敏，仍需审核后提取摘要。`url` 重新读取当前入口，默认输出去认证参数的地址；应使用 `open` 完成需要鉴权的打开动作，而非分享入口。`balance` 会访问账户接口，`-Refresh` 绕过缓存；更改系统环境变量后退出并重开面板。

页面分别呈现最后成功探测时间 `probedAt`、最近尝试时间 `attemptedAt` 和 `statusError`；失败保留旧结果但不刷新成功时间。任务区保留本次页面会话的结果与部分失败计数，不只依赖 toast；它不是跨重启持久日志。重建或替换面板文件前先退出面板后端，避免同时运行新旧代码。

仍需帮助时，按[贡献指南](../CONTRIBUTING.md)报告最小复现；不要附原始状态、日志、认证 URL 或账户资料。
