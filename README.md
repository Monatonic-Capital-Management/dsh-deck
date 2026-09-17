# dsh-deck

Windows 上的本地与远程 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 实例控制台。

把打开 dsh 前的环境准备、服务管理、SSH 隧道和地址获取集中到一个面板。它不是 dsh 本身，也不读取或复制 dsh 的私有会话数据库。

> 本轮已完成核心契约、模块化和交互改造，离线验收记录见[实施记录](docs/implementation-plan.md)。真实 SSH、浏览器和干净 Windows 首次使用仍需现场验收；历史档案不代表当前生产状态。

## 先选你的路径

| 你要做什么 | 从这里开始 |
| --- | --- |
| 第一次在本机使用 | [快速上手](docs/quickstart.md) |
| 添加服务器或使用团队配置 | [配置参考](docs/configuration.md) |
| 启停、安装、升级或恢复故障 | [日常操作](docs/operations.md) |
| 理解设计或参与开发 | [架构](docs/architecture.md) · [贡献指南](CONTRIBUTING.md) |
| 提交问题、分享诊断信息 | [安全与隐私](docs/security.md) |

## 运行要求

| 项目 | 要求 |
| --- | --- |
| 桌面 | Windows 10/11 x64、Windows PowerShell 5.1 |
| 面板运行时 | Node.js 18+；运行 dsh 需要 Node.js 22.19+ |
| 窗口 | Chrome 或 Edge；可退回默认浏览器 |
| 远端（可选） | Linux、systemd 用户服务、已可用的 SSH 认证 |

应用没有第三方运行时依赖，不需要 `npm install` 来安装面板。**零依赖不代表不需要 Node，也不代表 dsh 已经安装。**

## 本机开始

已有 Node 时，双击仓库中的 **`Start.exe`**；`Start.cmd` 是不依赖编译二进制的入口。默认只有一个本地实例。

完全没有 Node，或需要安装 dsh 时，先阅读[安装会修改什么](docs/quickstart.md)，再明确执行：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command install -Target local
.\dsh.ps1 -Command app
````
</augment_code_snippet>

安装不会替你开始工作：在面板中启动实例，再打开 dsh。关闭面板窗口不会停止 dsh 或后台服务；如何退出见[日常操作](docs/operations.md)。

## 添加远端

先确保对应 SSH 别名可以连接，再在面板选择“添加服务器”，或使用命名参数：

<augment_code_snippet path="dsh.ps1" mode="EXCERPT">
````powershell
.\dsh.ps1 -Command add -SshHost prod
.\dsh.ps1 -Command start -Target prod
````
</augment_code_snippet>

`add` 只登记连接。远端 `start` 在允许自动准备时可能安装软件和部署服务；在受限主机上先了解 `autoInstall` 的作用。安装、启动、升级的具体范围以[命令效果表](docs/operations.md)为准。

## 核心边界

- 控制 API 和 dsh 均留在 loopback，远端通过 SSH 隧道访问，不提供公网控制面。
- CLI 和面板共享启动器逻辑；操作逐实例报告结果，旧探测不覆盖较新的操作状态。
- 安装与升级是明确操作，不因打开面板而自动升级。
- 配置不存储 SSH 私钥或 API key；**运行时文件和日志仍可能涉及认证信息**，不要直接上传。
- 没有遥测；版本检查、余额查询、下载安装和远端操作有各自的外联行为，详见安全文档。

## 维护与路线

[贡献指南](CONTRIBUTING.md)列出离线测试与发布检查。[路线图](docs/roadmap.md)只记录后续工作；[历史档案](docs/archive/README.md)保留过去的故障与调查，不承担当前使用说明。

## License

[MIT](LICENSE) © Monotonic Capital Management
