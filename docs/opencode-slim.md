# OpenCode Slim

OpenCode 使用 `oh-my-opencode-slim` 替代 OMO；宿主为 **opencode-v2 2.2.5**（Nix 自打包
`overlays/pkgs/opencode-v2`）。上游 issue #51541（toggle 类模型无推理变体，含全部 MiMo）
未修，mimo 字节补丁已**放弃**：MiMo 按模型默认档位使用（fallback 链不写 variant），
待上游修复后直接升级获得变体。插件固定为 3.0.6 源码构建。系统已升级到 OpenCode v2；
V1 桌面客户端（opencode-desktop）仍保留，但它与 V2 共用全局配置且兼容层会拒绝
`permissions` 段（详见文末"已知问题"）。

## 配置

- `home/chen/opencode.nix`：服务端与 TUI 插件注册、provider、MCP、记忆插件和后台任务环境变量。
- `home/chen/opencode-slim.nix`：Slim 角色、模型链、fallback 和并行设置。
- `overlays/pkgs/oh-my-opencode-slim/default.nix`：固定源码、依赖、构建和回归测试（当前无上游补丁）。

主代理为 `orchestrator`，不固定主会话模型，保留用户通过模型选择器选择的模型。
仅使用 slim 内置 5 角色（**不自定义 agent**）：角色提示词由 slim 自动注入，配置只负责模型。
每个角色保留跨 provider 的备用模型链。

模型阵容按**首发模型**分五套 **preset**（`preset` 为默认激活），**按需分配**：
`oracle` 是重推理岗、家族 head 首发；`designer`/`fixer`/`observer` 要的是快与
视觉（Kimi K3.1 系含图像输入），统一 Kimi K3.1 Pro Highspeed 首发，其中
`designer` 的家族 head 上到**第 2 首发位**（设计判断受益强模型）；`explorer`
是检索岗、走检索链首发。`opus55` 里 Opus 占家族套的第 2 首发位（designer =
K31→Opus→Sol），gpt 模型（Sol）落第 3 位；`fixer`/`observer` 跟随家族套的
K31→gpt 次序（Opus→K31→Sol）。

| preset | `oracle` | `designer` | `fixer`/`observer` | 说明 |
| --- | --- | --- | --- | --- |
| `opus55` | Opus 5.5 max → K31 | K31 → Opus 5.5 max → Sol | Opus 5.5 max → K31 → Sol | 思考深度经 `output_config.effort` 可调（无需 -thinking 模型） |
| `astra`（默认） | Astra xhigh → K31 | K31 → Astra xhigh | K31 → Sol xhigh | 重推理家族 |
| `astra-fast` | Astra Fast xhigh → K31 | K31 → Astra Fast xhigh | K31 → Sol xhigh | astra 的 -fast 通道变种 |
| `sol` | Sol xhigh → K31 | K31 → Sol xhigh | K31 → Sol xhigh | Sol 家族 |
| `sol-fast` | Sol Fast xhigh → K31 | K31 → Sol Fast xhigh | K31 → Sol xhigh | sol 的 -fast 通道变种 |

fast 变种相对基础套只把家族模型 ID 加 `-fast` 后缀（同家族 -fast 通道），模型与
思考档位不变、尾巴不变。`designer` 第 2 位是家族 head；`fixer`/`observer` 第 2 位
固定 GPT-6.1 Sol xhigh（跨家兜底：kimi 失败先落 Sol 重推理档；`opus55` 中按家族
套 K31→gpt 次序落第 3 位）。随后统一 MiMo → DeepSeek → MiniMax（MiMo 2.6 Pro
接替原 K3.1 Pro 的中段槽位，MiniMax 收尾）；`oracle` 次位 Kimi K3.1 Pro Highspeed
后同尾；`explorer` 保持检索型尾巴（DeepSeek→Luna-fast→MiMo→MiniMax）。
`orchestrator` 主模型始终由 `/model` 手选，其 fallback 链为 claude → astra →
sol → k31 → 通用兜底（不随 preset 切换）。

切换：`/preset opus55|astra|astra-fast|sol|sol-fast`（当前会话即时生效，只影响
子代理推理设置）或 `OH_MY_OPENCODE_SLIM_PRESET=<name>`；改配置的 `preset` 值
影响之后的新会话。

| 原有用途 | Slim 角色 |
| --- | --- |
| 主会话协调 | `orchestrator` |
| 代码探索、外部资料 | `explorer`（`librarian` 是其别名） |
| 常规实现、设计、视觉分析 | `fixer`、`designer`、`observer` |
| 架构咨询 | `oracle` |

后台并发默认最多 4 个任务。2 小时是任务的**总运行时间上限**，并非无活动超时；
超时或取消后保留子会话，使用 `task_status` 查看、`task_result` 取结果、`task_revive` 续接。
`maxSessionsPerAgent = 4` 控制保留池，不是另一个并发上限。

fallback 允许一次宿主重试后切换模型，后续切换间隔 500ms。
V1 内部完成通知和自动继续优先沿用已切换的模型；新的用户轮次可重新选择。
PR #1415 为 v2 启用宿主 retry hook 切档，v2 的 abort 加 prompt 重放路径仍关闭。
Slim 的错误分类和重试策略与旧 OMO 不完全相同，旧配置中的 HTTP 状态列表和冷却参数没有同名直译。

配置由 Home Manager 生成，为只读文件。`/preset` 只做会话级切换；其"写入/保存
preset"功能不适用于这份声明式配置，持久修改模型分工请编辑 Nix 配置。主会话的
模型选择器不受影响。
V1 通过 `skills.paths` 加载 Slim 内置 skills，用户的 `.agents/skills` 和 `.claude/skills` 继续由原配置提供。
opencode-mem、Ghidra、Konnect 保留。Council 未配置，自动终端分屏默认关闭。
桌面伴随进程的打包、配置与素材工程已全部移除。

## 生效

待运行中的任务完成后，在仓库根目录执行：

```sh
sudo nixos-rebuild switch --flake .#ChenIdeaCentre
systemctl --user restart opencode-web
```

独立 OpenCode TUI 也需要退出重开。终端环境没有重新登录时，使用：

```sh
OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true OPENCODE_ENABLE_EXA=1 opencode
```

继续旧会话时，将主代理切换为 `orchestrator`。旧 OMO 的 agent 名称和 `background_*` 工具不再注册。
Home Manager 切换会移除旧 `.omo/omo.jsonc` 的托管链接；opencode-mem 数据不做删除或迁移。
会话/凭据方面：V2 首次启动执行一次性的 V1→V2 迁移（含 `import_legacy_credentials`，读取
auth.json 入库）。Home Manager 现在通过 `home/chen/opencode-sync-credentials.py` 调用 V2
官方凭据 API，同步运行时读取的 `secrets/opencode/{and,deepseek,kimi,xiaomi,minimax}.key`
（anthropic 与 openai 共用 Sub2API 网关的 `and.key`）；
不再重写 auth.json，也不要求未使用的 vamrs 两个 key 文件存在。

## 已知问题（review 发现，待处理）

1. **V1 桌面客户端与 V2 配置共用**：`opencode-desktop` 1.18.34 读取同一份全局配置，其兼容层
   拒绝 `permissions` 段并退回空配置（插件、代理端点等丢失）。需隔离 V1 配置，或停用/迁移桌面端。
2. **V2 凭据同步已修复，仍需刷新运行中服务**：每次 activation 在本机随机端口启动密码保护的
   临时 V2 服务，通过 `/api/credential` 创建并原子激活新密钥，回读校验后只清理旧的
   `Home Manager: …` 托管账户；重复执行不增殖账户。迁移后的轮换、首启后补 secrets 均支持。
   `auth import` 虽支持 stdin，但跳过已有 ID、保留原活动账户，不能单独用于轮换。
   密钥不进入 argv、日志或 Nix store；数据库/sidecar 为 0600，数据目录为 0700。
   缺失文件逐项告警并保留原账户（删除 secrets **不等于撤销授权**）；空/不可读文件或 API
   故障使 activation 失败，禁止静默宣称成功。各供应商单独切换，并非跨供应商事务，失败可重试。
   同步不重启已有服务、不加载项目插件；完成后应按上文重启服务及独立 TUI，避免其他进程的
   模型缓存仍使用旧连接。只管理默认本地数据库（尊重 `XDG_DATA_HOME`，拒绝 `OPENCODE_DB`
   覆盖）；不更新远端服务、V1 auth.json，也不删除迁移/手工/OAuth 账户，旧非托管密钥需自行清理。
   该 API 契约已在 2.2.5 上重跑（2026-11-01），升级宿主时须重跑隔离回归：

   ```sh
   OPENCODE_TEST_BINARY="$(nix build .#nixosConfigurations.ChenIdeaCentre.pkgs.opencode-v2 --no-link --print-out-paths)/bin/opencode" \
     python3 home/chen/opencode-sync-credentials.test.py
   ```

3. **codex-desktop-api-key 的 divider 性能补丁在新版 bundle 上被跳过**（上游 resizer 契约变化），
   pointermove 的布局写回未被节流；需适配新契约或明确接受该性能降级。
