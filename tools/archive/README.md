# 历史现场检查脚本

这些脚本完整移自 `tools/`，归档于 2026-09-16，改为 `.txt` 防止被测试发现器执行。它们包含作者专属目录/主机、按端口终止进程、旧 query-token API 或旧 UI/CDP 假设，**不是当前可执行测试，也不要改后缀后直接运行**。

| 原入口 | 当前替代或验证边界 |
| --- | --- |
| `check-panel.ps1` | `node tools/check-server.js` 的隔离 HTTP 契约检查 |
| `check-ports.ps1` | `powershell -File tools/check-launcher-contracts.ps1` 的进程所有权与端口检查 |
| `check-tray.ps1` | 后端 API / 启动器契约检查；实际托盘 UI 仍需单独人工验收 |
| `check-filter-cdp.js` | `node tools/check-ui.js` 的模型与假 DOM 交互检查 |
| `check-local-card.ps1`、`check-local-card.js` | `node tools/check-ui.js`；真实浏览器外观与键盘路径不据此宣称通过 |

历史正文同步远端已完成的个人路径清理，不恢复被移除的隐私信息；只用于理解过去的测试设计。当前验证命令、敏感数据规则和发布要求见[贡献指南](../../CONTRIBUTING.md)。
