# 快速上手

[返回首页](../README.md) · [配置参考](configuration.md) · [日常操作](operations.md)

先让本机实例可用，再按需添加远端。本文描述当前源码的使用方式；验证环境和未验收场景见 [implementation-plan](implementation-plan.md)。

## 1. 准备环境

- Windows 10/11 x64、Windows PowerShell 5.1；命令示例从完整仓库根目录执行。
- 面板后端需要 Node.js 18+；运行 dsh 需要可用的 Node.js 22.19.0+。仅能输出版本号不代表运行时完整可用。
- Chrome 或 Edge 用于独立应用窗口；没有时使用默认浏览器。
- 本项目后端只用 Node 内置模块，不需要为仓库执行 npm 安装。dsh 本身和 Node 并未内置在面板中。

`Start.exe` 内含启动器模块、面板与远端脚本，但不含 Node/dsh。复制 EXE 单独运行时会把资源提取到用户缓存；不能把它理解为不需要运行时的单文件应用。发布资源检查见[贡献指南](../CONTRIBUTING.md)。

## 2. 检查并准备本机运行时

查询启动器实际选择的 Node，不会下载软件：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command node-path
````
</augment_code_snippet>

缺少可用 Node 或 dsh 时，可明确选择安装。这一步会联网、写入用户级运行时目录或 npm 全局目录，不是只读检查：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command install -Target local
````
</augment_code_snippet>

已有可用 dsh 不应靠反复安装来切换版本；版本变更见[日常操作](operations.md)。只想准备 Node 时，已有 `node-path` 的 `-Ensure` 选项；加上它就允许下载，不能当作查询。

缺少可用 Node 时，启动面板会失败并退出非零，给出上述显式安装指引；双击入口不会静默下载安装。

## 3. 打开面板和本机实例

双击完整仓库中的 `Start.exe` 或 `Start.cmd`，或运行：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command app
````
</augment_code_snippet>

没有配置文件时，在内存中使用仅含 `local` 的默认登记，默认保存位置是用户目录下的 `.dsh-launcher/hosts.json`；只有登记或编辑才保存配置。打开面板、运行实例仍会写入运行状态；不能把运行应用当成只读查看。

打开面板与启动 dsh 是两件事。在本机卡片选择启动；也可在准备好运行时后执行：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command start -Target local -NoOpen
.\dsh.ps1 -Command open -Target local
````
</augment_code_snippet>

确认打开的是所需实例和工作目录。缺依赖时卡片提供安装/诊断路径；操作结果保留在任务区，失败或部分成功不会计作全部成功。常规输出与复制地址会脱敏，但不要分享运行时文件和完整入口，见[安全与隐私](security.md)。

## 4. 按需登记远端

远端需要 Linux、可用的 systemd 用户服务，以及已由你配置好的 SSH 登录方式。连接信息优先放在 SSH config 中，不把私钥或密码写进实例配置。

下面只登记别名为 `prod` 的实例，不表示服务器已经安装或启动：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command add -SshHost prod
````
</augment_code_snippet>

再阅读[配置参考](configuration.md)中的 `autoInstall`、`stopRemoteService` 和版本固定，以及[日常操作](operations.md)中的安装/启动边界。

远端 `start` 仅在 `autoInstall` 允许时自动准备软件与服务；显式 `install` 只准备，不启动服务。面板操作前显示同源计划，包括安装和重启范围。一个远端用户账户只管理一个 `dsh-web.service`，不要用多个 SSH 别名重复登记同一服务。

## 5. 结束使用

停止本机 dsh 会中断其运行中的工作；关闭面板窗口则不等于停止后台服务。按需要分别执行：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command stop -Target local
.\dsh.ps1 -Command app -Stop
````
</augment_code_snippet>

`app` 的 `-Stop` 针对面板后端和窗口，不是“停止全部实例”。若曾启用托盘，它由 `tray-stop` 单独管理；远端停止范围取决于 `stopRemoteService`，见[日常操作](operations.md)。

下一步：[维护实例配置](configuration.md) · [排查问题](operations.md) · [安全地报告问题](../CONTRIBUTING.md)
