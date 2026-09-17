# 配置参考

[返回首页](../README.md) · [快速上手](quickstart.md) · [日常操作](operations.md)

实例配置使用 JSON；CLI、面板 API 与 SSH 发现使用同一解析与校验规则。实际验证范围见 [implementation-plan](implementation-plan.md)。配置不要包含密码、私钥内容或 API key。

## 找到实际使用的文件

CLI 按下列顺序选路径；显式参数和环境变量优先，其后才寻找存在的文件：

| 优先级 | 来源 | 用途 |
| --- | --- | --- |
| 1 | `-Config` 指定路径 | 单次调用或隔离测试 |
| 2 | `DSH_LAUNCHER_CONFIG` | 切换配置上下文 |
| 3 | 启动器目录的 `hosts.json` | 个人配置，通常被 Git 忽略 |
| 4 | 启动器目录的 `.dshproj.json` | 可审查后共享的团队配置 |
| 5 | 用户目录的 `.dsh-launcher/hosts.json` | 全局个人配置及无配置时的默认位置 |

选定路径不存在时，在内存中使用仅含 `local` 的默认配置；不会退回另一配置，也不因 `list` 或 `plan` 创建配置文件。登记或编辑时才保存，使用同目录临时文件和原子替换。默认本地工作目录是用户目录；显式指定的目录不存在会拒绝启动，不静默换目录。

面板后端记录配置与 SSH 上下文，参数继续传给子命令。不能靠一次 CLI 的 `-Config` 切换已运行的面板：先在原上下文执行 `app -Stop`，再用新参数启动。

## 最小本机配置

<augment_code_snippet mode="EXCERPT">
````json
{
  "version": 1,
  "instances": [
    { "name": "local", "kind": "local", "port": 3080 }
  ]
}
````
</augment_code_snippet>

运行时不只从 PATH 查找；已安装的受管 Node 优先，dsh 也会按可用安装位置查找。实际选择用 `node-path` 查看，不要用某个终端的版本输出代替启动器选择。

## 实例字段

| 字段 | 范围 | 含义与注意事项 |
| --- | --- | --- |
| `name` | 全部 | 稳定机器标识，用于 `-Target`、状态记录和 API；不要用显示名称代替或随意改名 |
| `displayName` | 全部 | 可选的人类名称，支持中文；不改变 `name` |
| `kind` | 全部 | `local` 或 `remote`；远端 profile 默认展开为 `remote` |
| `enabled` | 全部 | `false` 时不参加默认目标选择；不自动停止进程，不是权限开关 |
| `description` | 全部 | 实例说明 |
| `port` | 本地 | dsh 监听端口，默认 3080 |
| `workdir` | 全部 | 本地启动目录；远端使用服务器上的绝对目录，修改后显式 `install` 重新部署服务定义，再重启生效 |
| `sshHost` | 远端 | SSH 别名或 `user@host`；优先复用 SSH config |
| `remotePort` | 远端 | 远端 loopback 服务端口，默认 3080 |
| `localPort` | 远端 | 本机隧道端口，默认 3099；与其他程序冲突时可能另选并记录实际端口 |
| `profile` | 远端 | 引用 `profiles` 中的连接默认值 |
| `sshUser`、`sshPort`、`identityFile`、`jumpHost` | 远端 | 统一用于命令、探测、隧道的 SSH 覆盖；密钥只提供文件路径 |
| `runAsUser` | 远端 | 可选切换服务用户；需要预先配置的非交互 sudo 与目标用户 systemd 环境，不等同于 SSH 登录用户 |
| `dshVersion` | 全部 | 可选完整固定版本；安装、检查、计划和升级统一解析，不被 latest 覆盖 |
| `autoInstall` | 远端 | 默认 `true`；`false` 禁止 `start` 自动安装软件/部署服务，显式 `install`、`upgrade` 仍可执行 |
| `stopRemoteService` | 远端 | 默认 `true`；`false` 时停止只断隧道，`remote-only` 可构成预期成功 |

实例名使用字母、数字、`_`、`-`、`.`、`@`，不得使用路径或 Windows 保留名；最多 120 字符，禁止 `..`。端口为 1–65535 整数，布尔字段必须是 JSON 布尔值，固定版本不能是范围。校验重复标识、启用实例的本地端口冲突、profile 引用和版本格式。

同一已知 SSH 用户连接只允许登记一个远端服务，因为 unit 固定为 `dsh-web.service`。不同别名是否最终指向同一账户无法离线证明，需使用者避免重复。安装、启动和共享本地运行时限制见[日常操作](operations.md)。

## 共享连接与个人覆盖

`profiles` 保存共用连接默认值，`userProfiles` 按操作系统用户名选择个人覆盖，实例再补充端口等信息。以下仅示意结构，用户名与主机名均为示例：

<augment_code_snippet mode="EXCERPT">
````json
{
  "version": 1,
  "profiles": [{ "name": "prod", "sshHost": "prod", "remotePort": 3080 }],
  "userProfiles": { "alice": { "prod": { "sshUser": "alice" } } },
  "instances": [{ "name": "prod", "profile": "prod", "localPort": 3099 }]
}
````
</augment_code_snippet>

合并优先级为**实例字段 → 个人覆盖 → 共用 profile**；`list`、面板与生命周期命令使用同一规范化结果。可以共享连接约定，但不要提交未审查的个人主机信息、身份文件路径或任何密钥材料。

## 环境与 SSH 来源

| 来源 | 含义 |
| --- | --- |
| `DSH_LAUNCHER_CONFIG` | 实例配置路径；不在报告中输出真实配置内容 |
| `-SshConfigPath`、`DSH_SSH_CONFIG` | SSH 发现与执行上下文；优先级为参数、环境、用户 `.ssh/config` |
| `DSH_HOME` | dsh 自身的数据目录；不是面板状态目录 |
| `DSH_NODE_MIRROR` | 本机受管 Node 的目录或 URL 来源，提供压缩包和校验清单；不替代 dsh 的 npm 来源 |

发现别名不执行连接，也不验证认证。首次使用前请手工核对服务器指纹；所有 SSH 执行路径使用严格主机校验，不自动接受未知指纹。

本机受管 Node 位于 `%LOCALAPPDATA%/dsh-deck/node/`，配置、运行时和状态可能写在仓库外；“单一配置入口”不表示所有数据都只写在一个目录。敏感文件边界见[安全与隐私](security.md)。

## 登记、修改与移除

面板“添加服务器”与 CLI `add` 只登记连接。可在实例详情中编辑、停用、移除登记；需手工改文件时先暂停相关操作并保留配置备份，不用删除运行状态代替修改配置。

| 入口 | 约定 |
| --- | --- |
| CLI `edit`，参数 `-Target`、`-Patch` | JSON 补丁只允许 `displayName`、`description`、`workdir`、`enabled`、`dshVersion`、`autoInstall`、`stopRemoteService` |
| CLI `remove`，参数 `-Target` | 仅取消登记，不卸载软件、不删除用户数据；存在受管进程时拒绝 |
| CLI `ssh-hosts` | 在同一配置上下文中发现 SSH 别名；不是连通性验证 |
| POST `/api/instances/:name/config` | 使用同一白名单与校验保存实例字段 |
| POST `/api/instances/:name/remove` | 与 CLI 移除边界一致 |

停用、移除和停止进程是不同动作。修改工作目录、显示名称或版本固定也不代表运行中的进程已经采用新配置；应根据操作结果确认是否需要后续重启。
