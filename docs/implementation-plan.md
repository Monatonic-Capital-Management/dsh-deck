# 产品化实施计划与验收记录

状态：阶段 0–3 的代码、文档与离线验收已完成；现场验收未执行。初始本地改造基线为 `f2e6fd5`，对应隐私清理后历史的 `011f08e`，记录日期：2026-09-16。复选框只表示其明确列出的实现/检查，不代表生产状态。

提交前远端新增 `0d9029f` 的隐私清理。本次交付以清理后的远端 `main` 为父历史，保留截图删除，并将个人路径清理同步到历史档案；不恢复被清理的旧历史。

## 产品边界

面向 Windows 单机与多机用户的本地 dsh 控制台。保留 loopback、SSH 隧道、用户主动安装/升级、零第三方运行时依赖；不增加托管控制面、不复制 dsh 私有会话格式、不为本次改造引入大型框架。浏览器和真实主机验收需要单独记录，不能用静态测试替代。

## 固定决策

1. **一个配置入口。** 先解析路径，再校验和展开 profile；CLI、面板、SSH 主机发现使用相同上下文。实例 `name` 是稳定机器标识，`displayName` 是可选的人类名称。配置校验字段、端口、重复标识和版本格式；配置写入采用同目录临时文件替换。
2. **结果可依赖。** `list/status/url` 保留实例数据；变更命令统一返回 `ok/action/results/rows`，每个 result 包含 `name/ok/errorCode/message`，失败退出非零。HTTP 操作保留 `ok/code/errorCode/message/instance`，不得以 HTTP 200 或进程退出码单独推断目标已达成。
3. **计划与执行同源。** 新增只读 `plan -Action start|install|upgrade -Target <name> -Json`；返回 `{ok, plans}`。每个计划至少含 `name/kind/action/targetVersion/changesSoftware/restartsService/requiresConfirmation/summary/steps/warnings`。UI 展示明确范围后再执行；不能承诺不会补装 Node 而实际安装。
4. **命令效果明确。** `install` 准备可用运行时、dsh 和远端服务定义，不启动服务、不自动替换已经可用的 dsh 版本；`start` 本地不自动安装，远端按 `autoInstall` 决定是否允许自动准备。`autoInstall:false` 禁止 start 自动安装软件或部署服务，显式 install/upgrade 仍是用户决策。`stop` 尊重 `stopRemoteService:false`，只断开隧道也可构成成功，必须说明范围。
5. **升级遵守固定版本。** 安装、检查、预览、升级共用目标版本解析。无法确定共享本地运行时的安全变更范围时拒绝并说明下一步；不声称具备原子回滚。已安装版本与正在运行版本分开表达，必要时明确需手动重启。
6. **进程所有权优先。** start 对健康实例幂等；远端按 service 归属判断，不因 shell 主 PID 与 node 子 PID 不同杀进程；不接管或终止无法证明属于 dsh 的本地进程。超时不得在无说明的情况下遗留后台变更。
7. **新状态不能倒退。** 较旧探测不能覆盖之后完成的操作。缓存分开记录成功时间与尝试时间，前端说明失败和过期，不把读取缓存的时间当作探测成功时间。
8. **最小化敏感数据。** 入口凭据由 URL fragment 进入页面内存并及时清理；API 使用请求头，换取同源 HttpOnly 会话 cookie 以支持刷新，不使用 localStorage 保存凭据。界面和诊断默认不显示认证参数，普通复制不携带 token。运行时文件、日志和账户数据不是问题报告附件；测试不得输出凭据。
9. **完整交付。** 打包清单覆盖全部运行模块及远端脚本，构建依据内容而非文件时间；独立 EXE 的资源一致性是门禁。
10. **能完成并恢复。** 提供持久可见的任务结果区、真实成功统计、单机环境引导、实例配置维护、中文文案、可访问对话框与窄窗口布局。不提供只有视觉效果而无法终止底层任务的取消按钮。

## 接口协作

- 页面静态资源不注入秘密；`POST /api/session` 以请求头凭据换取同源 HttpOnly、SameSite=Strict 会话 cookie。API 仍保留 Host/Origin 校验。
- 后端继续提供 `/api/instances`、单实例 `start/stop/restart/install/url/logs`、`/api/upgrade`、`/api/versions`、`/api/tray`、`/api/balance`、`/api/doctor`。
- 新增 `GET /api/instances/:name/plan?action=...` 返回单实例计划；`GET /api/upgrade?name=...` 返回升级计划列表。
- 新增 `POST /api/instances/:name/config`（白名单字段：displayName、description、workdir、enabled、dshVersion、autoInstall、stopRemoteService）与 `POST /api/instances/:name/remove`。移除仅取消登记，不卸载软件或删除用户数据；存在受管进程时拒绝。
- CLI 对应新增 `plan`、`edit -Patch <json>`、`remove`、`ssh-hosts`。保留现有命令与命名参数用法。
- 实例 API 增加 `displayName`、`probedAt`（最后成功时间）、`attemptedAt`、`statusError`、版本固定/目标信息；保留既有字段以便渐进迁移。
- 错误信息和任务结果必须先脱敏。UI busy 状态不能替代后端/CLI 的互斥和输入校验。

## 阶段与验收

### 0. 文档基线

- [x] 精简 README、贡献指南、架构、配置和路线图。
- [x] 归档 lessons 与上游历史行为报告及原 README/贡献/架构正文，保留原文与旧链接入口。
- [x] 增加操作/上手、安全参考与文档结构检查；链接、示例与命令检查通过。
- [x] 6 个作者现场环境/旧 CDP 检查脚本完整移入 `tools/archive/`，以 `.txt` 保存，防止默认执行。

### 1. 可信交付

- [x] 失败不报成功，业务结果与退出码贯通；升级尊重 pin。
- [x] 健康远端重复 start 不终止正常子进程；未知监听者拒绝接管/强杀。
- [x] 缓存竞态、失败新鲜度、配置上下文、SSH 覆盖与分类回归通过。
- [x] 安装计划与副作用一致；无 Node 的启动失败非零且有恢复指引。
- [x] 独立 EXE 运行资源完整且与源码一致，隔离提取与损坏恢复通过。

### 2. 可维护性

- [x] 配置、运行时、实例生命周期等职责拆成可独立检查的模块。
- [x] 后端缓存、进程执行和操作约束可注入替身并直接测试。
- [x] 测试默认离线、无真实状态；CI 配置已接入新增契约、打包与文档检查；离线验收时尚未实际触发 CI。
- [x] 源码 BOM/语法门禁支持只读检查；pre-commit 不再自动修复或暂存用户未暂存的内容。

### 3. 易用性

- [x] 预览可见，结果不依赖 toast，批量部分失败准确计数。
- [x] 远端部署/重启/停止范围明确；实例编辑、停用、移除路径完整。
- [x] 初次使用说明、配置空态、中文字段错误与恢复路径一致。
- [x] 键盘焦点、弹窗语义、状态播报及窄屏结构检查通过；不代替真实浏览器或屏幕阅读器验收。

## 验证记录

本地验证环境：Windows、Node `v24.13.1`、Windows PowerShell `5.1.26100.9444`、Git Bash；不新增第三方运行时依赖。以下命令均实际执行，最终退出码为 **0**。失败场景中的 `[fail]` 日志是负向用例的预期输出，最终断言无失败。

| 实际命令 | 结果 |
| --- | --- |
| `node tools/check-server.js` | 27 项通过；HTTP、认证、计划/结果与进程运行器 |
| `node tools/check-status-cache.js` | 32 项通过；TTL、并发、竞态、失效与失败新鲜度 |
| `node tools/check-ui.js` | 109 项通过；模型与假 DOM 用户路径，无浏览器连接 |
| `node tools/check-stop-contract.js` | 8 项通过；停止静态契约 |
| `node tools/check-source.js` | 2 项通过；只读门禁、显式修复、用户目录与暂存边界 |
| `node tools/check-no-deps.js` | 7 个运行模块无外部依赖 |
| `node tools/check-docs.js` | 17 篇文档、112 个内部链接、2 个 JSON 示例，无失败 |
| `powershell -NoProfile -File tools/check-launcher-contracts.ps1` | 65 项通过；模块无导入副作用、配置、SSH、计划、生命周期与 CLI |
| `powershell -NoProfile -File tools/check-app-stop.ps1` | 29 项通过；仅对沙箱后端执行真实停止 |
| `powershell -NoProfile -File tools/check-local-install.ps1` | 50 项通过；使用替身 npm/运行时，不安装主机软件 |
| `powershell -NoProfile -File tools/check-node-bootstrap.ps1` | 32 项通过；本地合成压缩包和校验清单 |
| `powershell -NoProfile -File tools/check-remote-node.ps1` | 21 项通过；Git Bash 合成远端、cgroup 与私有发布 |
| `powershell -NoProfile -File tools/fix-bom.ps1 -Check` | 21 个 PS1 文件；0 重写、0 语法错误、0 缺 BOM |
| `powershell -NoProfile -File tools/build-exe.ps1 -Verify` | 已重建 `Start.exe`；20 个运行资源、4 个构建记录与图标检查通过 |
| `powershell -NoProfile -File tools/check-package.ps1` | 24 个资源匹配；另有 3 项隔离提取/缺失/等长损坏恢复通过 |
| `node --check app/server.js` | 语法通过 |
| `bash -n remote/dsh-web-service.sh` | Bash 语法通过 |
| `sh -n .githooks/pre-commit` | Shell 语法通过 |
| `git diff --check` | 无空白错误 |

检查期间发现并修复：单次/批量 SSH 分类丢失、PowerShell Base64 参数解析、JSON Int64 配置版本兼容、失效计划丢失原因、停用实例隐藏停止入口、同名程序集干扰重建验证。最终只读集成复核未发现新的阻塞；其中发现的顶层计划异常原因丢失也已修复，并新增覆盖单实例与升级预览路由的回归。测试只清理其自身生成的合成临时目录，未清理用户状态。以上结果记录于提交前；后续提交、推送和 CI 状态以 Git 历史与对应运行记录为准。

## 发布后 CI 补充

首次推送 `b761442` 后的 [Actions 运行](https://github.com/Monatonic-Capital-Management/dsh-deck/actions/runs/35177396719) 未通过：失败步骤为 Windows 隔离源码检查与 Linux shellcheck。未将其当作通过结果。

后续修复保持门禁强度：测试显式在受限策略环境中启动仅本进程生效的 PowerShell 执行策略，不修改系统策略；远端脚本拆开 PATH 赋值与导出，消除 `SC2155`。

`30d8da1` 的 [CI 运行](https://github.com/Monatonic-Capital-Management/dsh-deck/actions/runs/35178192203) 中，Linux lint 和依赖检查通过；Windows 源码检查仍在约 33 秒后因子进程未返回退出码失败，不能将本机的执行策略复现当作 CI 超时的根因证明。进一步将测试的模块搜索限定为 PowerShell 内置模块，隔离 APPDATA/LOCALAPPDATA，隐藏子进程窗口，并在失败时只输出错误码、耗时及可执行文件存在性。保留原有超时和断言。

`afd7c83` 的 [CI 运行](https://github.com/Monatonic-Capital-Management/dsh-deck/actions/runs/35178812458) 已通过上述源码检查、启动器契约与 EXE 校验；后续 `app -Stop` 检查仅“没有重复后端”一项断言失败。该 runner 的用户临时路径包含 Windows 8.3 别名，测试按目录字符串统计进程，存在与 PowerShell 展开的路径不一致的风险。CI 改用 `RUNNER_TEMP` 作为测试 TEMP/TMP，原业务实现与断言不变。

`7664be5` 的 [CI 运行](https://github.com/Monatonic-Capital-Management/dsh-deck/actions/runs/35180034552) 为源码检查提供了明确诊断：可执行文件存在，首次检查在 30069ms 触发 `ETIMEDOUT`。对照 `afd7c83` 同一检查成功时三次启动共用 76 秒，单次 30 秒期限过紧。将这一测试子进程期限改为 90 秒，保持产品操作超时、所有断言与脱敏诊断不变；后续 CI 状态以对应提交的 Actions 记录为准。

## 切换与兼容性

- 使用新版前先结束面板中的进行中操作并退出旧面板；本轮未重启用户实际后端或实例。
- 旧自动化需要从状态数组迁移到逐实例结果；不能再只判断 HTTP 200。
- 更严格的名称、字段类型、重复端口/服务校验可能拒绝旧的非规范配置；不会静默改写配置。
- 旧运行记录缺少所有权证据时不会强行接管/结束进程；按错误提示核实，不删除整个 `state/` 解决。

## 尚未执行的验收

- **真实浏览器/辅助技术：** 首次打开与刷新、键盘完整路径、焦点返回、屏幕阅读器、320–480px 窗口、中文长字段和任务反馈。
- **真实 SSH/systemd：** 在明确指定的测试主机验证首次部署、健康重复启动、失联重连、只断隧道、远端工作目录与运行版本；不在生产会话上代测。
- **干净 Windows 与真实安装源：** 独立 EXE、无 Node、下载权限/代理/杀毒、真实 npm/dsh 版本组合；沙箱安装包不能替代这些结果。
- **其他运行时/CI：** 未在 Node 18 上执行；离线验收时没有触发或读取 GitHub Actions 结果，后续推送不代表 CI 已通过。本机无 shellcheck，只执行 Bash 语法检查，shellcheck 已配置为 CI 失败门禁。

上述场景需要明确的环境和操作授权后继续，不标作本轮已通过。
