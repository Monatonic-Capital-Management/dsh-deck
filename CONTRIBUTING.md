# 贡献指南

[首页](README.md) · [架构](docs/architecture.md) · [实施与验收](docs/implementation-plan.md)

## 开始之前

这是 Windows 本地控制工具，不是 dsh 的替代实现。请先理解拟修改的用户路径和[命令效果](docs/operations.md)，再修改对应模块。

保留零第三方运行时依赖。为面板本身无需安装 npm 包；`dsh` 是被管理的软件，不是面板依赖。

## 源码约定

- `dsh.ps1` 是 CLI 入口，生命周期与配置逻辑按职责放入 `launcher/`；后端不重新实现 dsh 启停。
- `app/server.js` 负责 HTTP 组合，后端纯逻辑放入 `app/lib/`；UI 样式、交互和纯状态逻辑分开维护。
- `.ps1` 必须保留 UTF-8 BOM，兼容 PowerShell 5.1；远端 `.sh` 使用 LF。
- Bash 模板优先用 PowerShell 单引号 here-string，参数和 SSH 参数集中构造。
- 注释解释约束，不重复描述代码；历史故障说明移入有日期的档案。
- 变更输出必须带真实结果，诊断不得污染 JSON stdout，也不得包含凭据。

模块导入不得创建运行目录、监听端口或访问主机；使用工厂、纯函数和依赖注入测试真实模块。

## 安全的本地检查

以下检查默认离线，实际运行结果记录在实施记录中：

<augment_code_snippet mode="EXCERPT">
````powershell
node tools/check-ui.js
node tools/check-status-cache.js
node tools/check-stop-contract.js
node tools/check-no-deps.js
node tools/check-docs.js
node tools/check-server.js
node tools/check-source.js
````
</augment_code_snippet>

这些检查不应自动发现正在运行的面板或用户主机。后端测试通过可注入替身覆盖 HTTP、鉴权、错误处理和操作结果；界面模型直接导入测试，不复制一套实现。

Windows 沙箱检查：

<augment_code_snippet mode="EXCERPT">
````powershell
powershell -NoProfile -File tools/check-launcher-contracts.ps1
powershell -NoProfile -File tools/check-app-stop.ps1
powershell -NoProfile -File tools/check-local-install.ps1
powershell -NoProfile -File tools/check-node-bootstrap.ps1
powershell -NoProfile -File tools/check-remote-node.ps1
````
</augment_code_snippet>

`powershell -NoProfile -File tools/fix-bom.ps1 -Check` 只检查当前源文件的 BOM 与语法；去掉 `-Check` 才会修复 BOM。pre-commit 使用只读工作树检查，不再自动修复或 `git add`，避免把未暂存改动带入提交；CI 再验证提交内容。

运行前必须确认测试只操作独立临时目录、合成安装包和受控进程。不能继承真实配置、账户 key、默认浏览器或 SSH 主机；失败输出也不能打印运行时认证数据。不要为了让测试通过弱化业务断言。

## 变更验收

1. 为行为修复增加能看到原缺陷的回归测试。
2. 先运行相关测试，再运行整组离线检查；PowerShell 同时校验 BOM 与 5.1 语法。
3. 更新受影响的配置、操作或安全参考，不把未来能力写成已经交付。
4. 运行资源有改动时重建 EXE，并验证资源与源码一致：

<augment_code_snippet path="tools/build-exe.ps1" mode="EXCERPT">
````powershell
.\tools\build-exe.ps1 -Verify
````
</augment_code_snippet>

构建会替换仓库中的生成物 `Start.exe`，不会安装 Node 或 dsh。`powershell -NoProfile -File tools/check-package.ps1` 只验证提交的 EXE，不先重建掩盖漂移；还会在临时目录验证独立提取、缺失模块与等长内容损坏恢复。CI 对资源漂移、文档错误和 shellcheck 警告失败，而非仅打印提醒。

浏览器交互、干净 Windows 首次启动与真实 systemd 环境属于另外的验收层。只运行源码检查或替身测试时，明确标记这些项目未验证，不能据此宣称整条用户路径通过。

## 报告问题

提供操作步骤、预期与实际结果、Windows/PowerShell/Node/dsh 版本和无敏感信息的错误摘要。不要附原始 `state/`、日志、浏览器 profile、账户资料、SSH 私钥、认证 URL 或 Cookie；完整要求见[安全与隐私](docs/security.md)。

旧测试设计和环境故障记录见[历史贡献指南](docs/archive/2026-09-16-contributing.md)、[历史经验](docs/archive/2026-09-16-lessons.md)与[已归档的现场脚本](tools/archive/README.md)。历史复现命令不应直接在日常工作环境执行。
