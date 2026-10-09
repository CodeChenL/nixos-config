# opencode-approval

OpenCode v2 的「模型代审授权」插件：在工具动作执行前做三层裁决，参考 OpenAI Codex CLI
的 Guardian 审查器与 execpolicy 硬规则设计。模型层审查会携带**会话上下文**（最近消息摘要），
让"用户授权"维度可判定；`question` 工具中用户的作答也计入授权证据；被模型层拒绝的动作可经
`approval_appeal` 工具申请**行政复议**（再审）；子代理任务标为不可信来源，并附上父会话上下文。
零依赖纯 ESM，只用 Node 内置模块（`fs` / `path` / `os` / `crypto`）。

## 配置示例

构建产物是 npm tarball，在 opencode 配置里以 `file:` 引用：

```jsonc
{
  "plugins": [
    {
      "package": "opencode-approval@file:/nix/store/<hash>-opencode-approval-0.7.9.tgz",
      "options": {
        "reviewModel": { "providerID": "xiaomi-token-plan-cn", "id": "mimo-v2.6-pro" },
        "onFailure": "deny",
        "includeContext": true,
        "auditPath": "/home/you/.local/share/opencode/approval-audit.jsonl",
        "extraDeny": ["deploy-to-prod"],
        "extraAllow": ["git\\s+push\\s+origin\\s+feature"]
      }
    }
  ]
}
```

所有选项都可省略；`plugin/index.js` 通过 `ctx.permission.hook("evaluate", …)` 挂载，
原地修改 `input.effect` / `input.message` 即生效。`plugin/tui.js` 是 TUI 半
（slash 命令 + toast），通过 `exports["./tui"]` 由 TUI 自动加载。

## 选项表

| 选项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `reviewModel` | `{ providerID, id, variant? }` | `{ providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" }` | 审查用模型的**配置默认值**（在插件内部会话上以 kind=generate 调用）；会话内可用 `/approval-model` 动态切换 |
| `onFailure` | `"deny" \| "ask"` | `"deny"` | 审查失败时的落点：deny（fail-closed）或保留 ask |
| `fallbackModels` | `{ providerID, id, variant? }[]` | `[]` | 审查模型链的备用项：primary 失败（不可用/超时/输出非法）时按序降级；全链失败才 fail-closed。跨供应商填写可提升可用性 |
| `includeContext` | `boolean` | `true` | 是否把会话上下文摘要喂给审查模型（关闭则始终按"无上下文"审查） |
| `reviewViewLimit` | `number` | `60000` | 每块 ACTION JSON 字符预算（含 JSON 转义与字段归属，不含 prompt/会话上下文）；正数向下取整且至少 1，非法值回退默认。决定性全文优先，仍超限则按 256 字符重叠分块完整审查 |
| `idleTimeoutMs` | `number` | `30000` | 审查模型“无输出”超时（毫秒）：流式产出间隔超过该值即中断该次尝试、换下一个；持续有输出仍受单次尝试和整链预算封顶 |
| `attemptTimeoutMs` | `number` | `min(45000, deadlineMs / 2)`（整数、至少 1ms） | 单个模型尝试的总预算（毫秒），建会话、切模型、生成共用，不逐步重置；超限放弃该模型并转 fallback，且始终受本轮整链剩余预算约束 |
| `deadlineMs` | `number` | `90000` | 每轮审查链总预算（毫秒）：覆盖**准备阶段**（取上下文、建内部会话、切模型）与模型调用。预算耗尽不再启动剩余模型，自动以全新预算重试整链一次（含重新获取上下文）；两轮仍失败才按 `onFailure` 落点 |
| `priceTimeoutMs` | `number` | `5000` | 价格目录（models.dev）查询超时（毫秒）：只影响费用显示，超时/失败都绝不影响裁决，也不会堵住后续审查 |
| `breakerFailures` | `number` | `3` | 连续多少次整链失败触发熔断 |
| `breakerWindowMs` | `number` | `60000` | 熔断窗口（毫秒）：期间不再调用模型，全部按 `onFailure` 处理 |
| `mode` | `"review" \| "ask" \| "allow-all"` | `"review"` | **审批模式（配置默认）**：review=模型代审；ask=不调模型、把需要判断的动作交还用户确认；allow-all=除静态 deny 与灾难性硬拒绝外直接放行（未知动作/无法静态解析的命令仍审查）。`/approval-mode` 可持久化覆盖，跨节点/重启生效。确定性层在三种模式下均生效 |
| `allowAll` | `boolean` | — | `true` 等价于 `mode: "allow-all"`（兼容旧配置；与 `mode` 同时给出时以 `mode` 为准） |
| `auditPath` | `string` | `~/.local/share/opencode/approval-audit.jsonl` | 审计 JSONL 路径 |
| `statePath` | `string` | `~/.local/share/opencode/approval-state.json` | 模式状态 JSON 路径；相同路径的节点/进程共享模式，缺失、损坏或不可读时回退各节点配置默认 |
| `extraDeny` | `(string \| { name, regex, actions? })[]` | `[]` | **追加**拒绝规则（不区分大小写）；对象形式可命名，审计 rationale 显示该名字。默认只作用于命令/写类动作；`actions: ["grep", …]` 可**扩域**到指定的只读查询动作 |
| `extraAllow` | `(string \| { name, regex })[]` | `[]` | **追加**放行正则（不区分大小写） |
| `disabledRules` | `string[]` | `[]` | **删减**内置硬规则（按规则名，见下节清单）；被删规则不再拦截，动作转入后续层 |
| `ruleOverrides` | `{ [name]: { regex?: string, enabled?: boolean } }` | `{}` | **改写**内置硬规则：`regex` 替换匹配（仅正则型规则）、`enabled: false` 等价删减 |
| `fastpathExtra` | `string[]` | `[]` | 追加 fast-path 动作名（直接放行、不调模型） |
| `fastpathDisabled` | `string[]` | `[]` | 删减内置 fast-path 动作名 |

多块审查例外（初审与复议相同）：共享一次 `deadlineMs`，每块调用一次 primary；任何块
失败或超时立即 deny，不转 fallback、不重试，也不按 `onFailure:"ask"` 降级。
下述 fallback / 整链重试选项的恢复行为仅适用于单块动作。

注意：`extraDeny` / `extraAllow` 的匹配对象按**分域**构造——命令/查询域是
`JSON.stringify({action, resources})`，写/改域额外带 `paths`（metadata 里的文件路径）。
两者都**不扫描** patch/文件内容与 `message`（避免编辑含危险命令字样的文档时被硬规则误伤）；
匹配的不是原始命令，正则请勿使用 `^` / `$` 锚定。正则硬规则**额外**在"归一化执行文本"
（引号/转义还原后的执行值）上补一次匹配，见「引号/转义归一化」。

## 硬规则可配置（追加 / 删减）

内置硬拒绝规则（16 条，拥有稳定名字；审计 rationale 与 `ruleOverrides` 都用它）：

`rm-rf-root, rm-rf-home, rm-rf-glob, mkfs, dd-of-dev, fork-bomb, chmod-recursive-777-root,
overwrite-disk-device, pipe-download-to-shell, write-sensitive-path, git-force-push-main,
shutdown-reboot-halt, mkswap-swapoff, iptables-flush, chown-recursive-root, truncate-shred-device`

```jsonc
{
  "disabledRules": ["git-force-push-main"],                 // 删减：不再拦截（转入后续层）
  "ruleOverrides": {
    "mkfs": { "regex": "\\bmkfs(?:\\.[a-z0-9]+)?\\b" },     // 改写：仅正则型规则可覆盖
    "rm-rf-glob": { "enabled": false }                      // 停用（等价删减）
  },
  "extraDeny": [ { "name": "deploy-guard", "regex": "deploy-to-prod" } ], // 追加（可命名）
  "fastpathExtra": ["my-reader"],                           // fast-path 追加
  "fastpathDisabled": ["websearch"]                         // fast-path 删减
}
```

语义与安全边界：
- **硬规则按动作类别分域**（避免只读查询被误杀）：
  - **命令类规则**只对命令执行类动作（`bash/command/execute/shell`）的命令文本生效：
    `rm-rf-root, rm-rf-home, rm-rf-glob, mkfs, dd-of-dev, fork-bomb, chmod-recursive-777-root,
    pipe-download-to-shell, git-force-push-main, shutdown-reboot-halt, mkswap-swapoff,
    iptables-flush, chown-recursive-root, truncate-shred-device`；
  - **路径类规则**只对写/改类动作（`edit/write/patch`）的**路径字段**（resources 与
    `metadata.files[].path`，不含 patch 内容）生效：`write-sensitive-path`、`overwrite-disk-device`
    （后者在命令域仍匹配 `of=/dev/…` 形式）；命令域里的 `write-sensitive-path` 仍要求写迹象；
  - **只读查询类动作**（`read/grep/glob/websearch/list/question/skill/subagent/…`）**不做硬规则
    文本扫描**（回到 0.7.0 行为）：`grep "mkfs"`、`websearch "reboot stuck"`、路径/模式/agent id
    里含 `reboot|shutdown|halt|mkfs` 都不会被硬拒，走 fastpath 或模型层。
  - `extraDeny` 默认同上（命令/写类动作）；`actions: ["grep", …]` 显式**扩域**到指定只读动作，
    扩域拒绝同样先于 fastpath 放行。
- **执行位门控 + 归一化匹配**（G1/G2）：内置命令域子串规则只在**归一化执行视图**上匹配，
  且命中起点必须落在**真实执行位**——段首命令词 / 包装执行器（xargs/timeout/su/eval/…）
  解出的内层命令词 / `sh -c`、`eval`、`su -c` 等脚本参数内容的**嵌套命令词** / `` `cmd` ``、
  `$(cmd)` 命令替换内容 / 重定向运算符。**普通参数位（含未加引号参数）一律不是执行位**：
  `echo rm -rf /`、`echo mkfs note`、`printf '%s' "rm -rf /"`、`git commit -m "rm -rf /"`、
  `echo dd of=/dev/sda` 是文本提及，转模型层（不硬拒）；`rm -rf /`、`xargs rm -rf /`、
  `sh -c 'rm -rf /'`、`eval "rm -rf /"`、`sudo rm -rf /`、`dd … of=/dev/sda`（规则起点在
  命令词 `dd`）照常硬拒。token 还原真实执行值（`"a""b"`→`ab`、`\/`→`/`、`'x'`→`x`、
  ANSI-C `$'\xNN'`/`$'\NNN'` 解码），并做**词法路径归一化**（折叠重复 `/`、解析 `.`/`..`
  段）：`rm -rf //`、`///`、`/.`、`/./`、`/tmp/x/../..`、`"."`、`./` 与
  `rm -rf /. --no-preserve-root` 都归一到根目录语义并硬拒；`/tmp/x/..` 归一为 `/tmp`
  不命中（正确语义）。`sh${IFS}-c${IFS}…`、`reboot${IFS}-h` 按空白分词建模。
  归一化只作用于匹配，展示与审计文本仍是原样。用户 `extraDeny` 是**文本策略**，仍在
  原始 blob 上匹配（不受执行位门控影响）。
- **无法静态解析的变量展开**（G3）：命令词/脚本参数含 `$VAR`、`${VAR}` 且无法从同命令流的
  `VAR=value` 赋值静态解析时，**不做任何确定性放行**（硬放行白名单、fastpath、allow-all、
  extraAllow 一律跳过），必须进模型层。可解析的（如 `i=;sh $i-c reboot`）照常按展开后的
  执行值判定。
- **动作名归一化**：`String(action).trim().toLowerCase()`（`"bash "`、`"BASH"`、`"bash\t"`
  都当 `bash`）。分域是**白名单**：`query` = 已知只读动作（read/grep/glob/websearch/list/
  question/skill/subagent/…），`command` = bash/command/execute/shell，`write` =
  edit/write/patch/apply_patch；**未知名一律保守**——命令规则照扫 `resources`，且
  allow-all / 内置 fastpath 不放行（进模型层）。用户显式配置的 `fastpathExtra` /
  `extraAllow` 仍可放行自定义动作（options 兼容）。
- **删减 ≠ 放行**：被删规则不再拦截后，动作继续走后续层（硬放行 → `extraAllow` → 模型审查），
  即多一道模型判断而不是跳过审批；默认全部内置规则开启，fail-closed 语义不变。
- 配置错误尽早暴露：未知规则名、非法正则、对谓词规则做正则覆盖，都会在 setup 阶段直接抛错。
  **谓词型规则完整清单**：`write-sensitive-path`、`git-force-push-main`、`shutdown-reboot-halt`。
  它们不接受 `regex` 覆盖；可用 `enabled: false` / `disabledRules` 停用，或用 `extraDeny` 追加正则。
- 内置**硬放行**白名单（只读命令 / `git` 子命令 / `nix` 子集）不提供删减（安全方向），
  追加用 `extraAllow`。

## 三层裁决流程

> **定位声明**：确定性层是尽力而为的灾难兜底（fastpath / 硬放行 / 硬拒绝只求抓住灾难性动作，
> 不追求完备）；**review 模型是正式裁决者**——任何未被确定性层定论的
> 动作都交模型按上下文裁决，无法静态判定的形态一律转模型层（见「已知边界」）。



1. **显式策略优先**：`input.effect === "deny"` → 保持 deny，不审查、不调模型。
2. **硬拒绝（Mode B，确定性正则/谓词）**：对动作 JSON 整体匹配，
   先于所有放行路径检查，`fastpathExtra` 也不能覆盖拒绝。
   - **DENY 优先**（命中即 deny）：`rm -rf` 根/家目录/通配盘符、`mkfs`、`dd of=/dev/`、
     fork bomb、`chmod -R 777 /`、覆写 `/dev/sd*|/dev/nvme*` 等磁盘设备、`curl|sh`/`wget|sh`
     管道执行、写 `~/.ssh`/`~/.gnupg`/`/etc/shadow`/`/etc/passwd`、`git push --force` 到
     main/master、`shutdown|reboot|halt`（**仅本机直接执行命中**：引号感知分段后只看**段首命令位**——
     命令词取 basename（引号胶合与转义照常执行：`'reboot'`、`re"boot"`、`reboot""`、`rebo\ot`）、
     可带 `/usr/bin/` 等路径前缀；包装执行器（`sudo [-u user] [--]`、`doas`、`nohup`、`env`、
     `xargs [-0]`、`timeout N`、`su [user] -c`、`eval`、`busybox`、`watch`、`stdbuf …`）取内层命令，
     `systemctl reboot`/`telinit 6`/`init 0`、`sh -c '…'` 内层脚本与 `` `cmd` ``、`$(cmd)` 命令替换等价；
     **引号参数里的文本不是命令位**，
     `echo "notes; reboot"`、`rg '(reboot|halt)' notes.log` 一律不命中；`ssh 远端 reboot`
     与纯文本提及放行）、`mkswap`/`swapoff`、`iptables -F`、`chown -R` 根、
     `truncate`/`shred` 设备文件；再叠加 `extraDeny`。以上内置规则均可通过 `disabledRules` /
     `ruleOverrides` 删减或改写（见「硬规则可配置」一节）。
3. **确定性放行**（不调模型）：
   - **fast-path**：action ∈ `read, glob, grep, list, todowrite, question, skill,
     websearch, lsp, ide, subagent` → `allow`；`approval_appeal`
     （行政复议工具，受理与再审由工具自身逻辑把关）同样直接放行。
   - **命令白名单**：仅 `bash/command/execute/shell` 动作；`edit/write/patch` 等绝不凭资源中的命令文本硬放行。
     命令整体不含 shell 元字符 `;|&<>$\`()\n`、引号、转义、通配展开，且首词 ∈ 参数受限白名单
     （`ls, pwd, echo, cat, head, tail, wc, stat, file, which, rg, grep, find, fd, df, du,
     free, ps, date, uname, hostname, id, whoami, nproc, printenv, jq, diff, md5sum,
     sha256sum`；已删除可执行任意程序的 `env`）。`git` 仅 `status/diff/log/show` 的已知只读选项、
     `branch` 列表态（裸 `git branch`、`-r`/`-a`/`-vv`、`--list [pattern]`）、`remote` / `remote -v` / `remote --verbose` / `remote get-url`；`git branch <name>`、`-d/-D/-m/-M/--set-upstream-to/--edit-copy`、
      `remote add/remove/rename/set-url/set-head` 与一切未知选项转模型层。
     `find` 的 `-delete/-exec/-execdir/-ok/-okdir/-fprint*/-fls/-fprintf` 不放行（大小写不敏感）；
     `fd/rg/date/hostname/file` 同样限制执行或写入模式。`nix` 仅
     `eval` / `build --dry-run` / `flake metadata` / `flake show`；再叠加 `extraAllow`。
   - 其余进入模型层。deny 规则先于 allow 规则（fail-safe 方向）。
4. **模型层（Mode A）**：在插件内部会话上以 `kind=generate` 调用审查链
   （`ctx.session.generate`；内部会话由插件创建，不改动用户会话），prompt 包含：
   - **CONVERSATION CONTEXT**：该会话最近消息摘要（`includeContext` 默认开启；
     最近 12 条 / 3000 字符内的 user+assistant 摘要，并额外保留最多 6 条更早的用户
     消息——授权证据不易被助手消息挤出窗口；缓存新鲜度三重保障：事件订阅（用户消息/`question` 作答/消息更新到达即失效该会话缓存）、
      会话版本纳入键（`time.updated`/tokens/cost/消息计数任一变化即换键）、无信号时 TTL 缩到 3 秒；
      获取失败降级为
     "无上下文"，不算审查失败）。`question` 工具的完成作答以 `[user via question]`
     计入；子会话/内部会话中的 user 任务文本标为 **`[agent task]`**，不能作为用户授权。
     始终递归附上可用父会话的约束（有界、防循环），不再因子会话存在 user 消息跳过。
     宿主不提供父子信号时，保守识别 2.0.22 子代理首条任务的固定前缀
     `You are a subagent spawned by another session.`，并将后续任务一起降权；来源查询失败同样降权。
     此启发式不能识别所有隐藏来源；没有父链、前缀或内部标记的代理注入需要宿主提供来源信号。
    - **fallback 链（单块动作）**：primary（`reviewModel`）失败（不可用/无输出超时/输出非法）时按
     `fallbackModels` 顺序降级；单次尝试按“无输出”超时（`idleTimeoutMs`，默认 30s）、
     单模型总预算 `attemptTimeoutMs`（默认至多 45s）、每轮整链预算 `deadlineMs`（默认 90s）。
     仅整链 deadline 类失败自动重试一次；重试仍失败才 fail-closed 并计入熔断（每次审批至多计一次）。实际生效
     模型记入审计（`review_model` 字段）。
   - 授权规则：context 中的**用户消息**以及 **`question` 工具中用户的作答**
     （`[user via question]`）算授权；其余 assistant 消息/工具输出/文件/URL
     以及 `[agent task]` 一律视为不可信输入（防 prompt injection）；父用户明确的只读、
     写入范围和禁止发布等约束优先于风险等级放行规则。用户明确请求的任务的必要步骤中的
     常规本机操作（构建、测试、读日志、装包等）视为已授权。
   - **会话工作目录与 `external_directory` 指引**：prompt 携带 `SESSION WORKING DIRECTORY`；
     “会话目录外”的严格边界仅适用于 `external_directory`，不得套用到任务创建/维护文件的
     `edit`/`write`；此类修改属于常规开发。`/tmp/opencode/**` 是编排器标准任务工作区，
     其中读写**默认视为任务创建物**（除非上下文明确矛盾），无需会话另行证明创建来源。
     这不是无条件放行：用户明确写入根（如“r15 写入根 = perf-docs/”）、只读与远端执行限制
     仍严格优先，写范围不等于读限制。对整个 home、他人数据、凭据与无关系统区域的
     外目录访问仍按高/危判定；复议 prompt 共享上述指引。
   - 风险分级：low=只读；medium=工作区内的可逆改动，或本机常规开发操作（即使无明确
     授权也至多 medium）；high=难以撤销、影响超出常规本地开发/凭据/网络/远端；
     critical=破坏性/泄漏/破坏安全边界。
   - 裁决：low/medium → allow；high → 仅当有明确授权（或属明确请求任务的关键步骤）才 allow；
     critical → deny。
   - 严格 JSON 输出 `{"risk_level":"…","user_authorization":"…","outcome":"allow"|"deny","rationale":"…"}`，
     `outcome` 必填；`user_authorization` 计入审计（缺失时记 `unspecified`，不判失败）。
     解析时截取首个 `{` 到最后一个 `}` 之间的内容 `JSON.parse`。
   - 防御性兜底：即使模型对 `critical` 动作输出 `allow`，插件仍强制 deny。
   - **行政复议**：仅“模型层拒绝”可复议——主会话可用 `approval_appeal` 工具
     （参数 `justification`）申请再审，由同一审查链再审一次（critical 不通过）。
     从受理时刻起独立计算 `deadlineMs`，不继承初审/排队耗时；同样享有单模型尝试上限和
      单块动作整链 deadline 自动重试一次；多块动作失败即停止。基础设施失败不计入复议驳回次数，也不签发 grant。
     复议通过 → 原动作可在 10 分钟内以**完全相同的参数**重试并被一次性直接放行
     （`layer: "appeal"`，不再重复审查）；连续 3 次复议被驳回后本会话不再受理。
     指纹为 action、resources 与**完整 metadata（含 files[].path / patch 全文）**的规范 JSON SHA-256；
     同路径但修改内容不同必须重审。拒绝记录与复议 ACTION 同时保存指纹与原参数快照。
     复议、grant 签发/消费与模型审查共用串行队列，申请绑定拒绝代次，旧申请不能重签已消费的 grant。
     宿主不支持工具注册时复议功能不可用，不影响审批本身。

三种模式的裁决落点：`review` 走模型审查；`ask` 不调模型、把需要判断的动作交还用户确认；
`allow-all` 除显式 deny 与硬拒绝规则外一律直接 allow。确定性层（fastpath 只读 / 硬放行 /
硬拒绝）在三种模式下均生效——灾难性命令在任何模式下都会被硬拒绝。

## 已知边界（静态分析的固有局限）

以下形态**不做确定性判定**，一律转模型层（不硬放行、也不硬拒），由审查模型结合上下文裁决；
需要更严的用户可用 `extraDeny` 自行加规则：

- **变量目标**：`rm -rf "$TARGET"`、`sh -c "$SCRIPT"`、`$CMD --help` 的实际取值在运行时决定，
  静态分析不求解（见 G3）。
- **深层嵌套**：`xargs sh -c '…'` 这类"包装器 + 壳 + 脚本"的脚本内容只递归一层（脚本内的
  再嵌套包装器不再展开）；超过递归深度上限时按不可判定处理。
- **降级路径的 usage**：无法创建内部审查会话时退回 `ctx.generate.text`，该路径不产生
  `http.response` 观测，token/费用不计入审计与面板（与 0.7.x 一致）。
- **相对路径归一化**：`.`/`./`（当前目录自身）与 `/` 同等对待（都可能被 `rm -rf` 整树删除）；
  `/tmp/x/..` 归一为 `/tmp` 而不是根，`~/…`、含变量/通配的路径不做词法求解。
- **NBSP 分词**：NBSP（U+00A0）现按**保守方向**处理——不再当作 shell 分词空白
  （空白类为 POSIX IFS `[ \t\n\r\f\v]`），富文本粘贴进来的 NBSP 不会把一个词拆成
  命令与参数，相关文本交模型层判定，不进确定性层。
- **命令文本即判据**：硬规则只看 `action`/`resources`/写域路径字段，不读 patch/文件内容
  （编辑"描述危险命令的文档"不会被误伤）；因此把危险字样藏进文件内容的写操作只能靠
  模型层与压缩视图的"未审不放行"兜底。

## fail-closed 语义

- **插件内部异常/未决策**：`evaluate` 整体捕获未预期异常，强制 `deny` 并写
  `layer:"failure"`、`rationale:"plugin internal error: ..."`；不会因 hook 异常静默回落到人工窗。
  返回时未产生有效裁决也强制拒绝，理由为 `evaluate returned undecided`。
  两者不受 `onFailure:"ask"` 影响；显式 ask 模式及已配置的模型失败 ask 策略仍保留。
- **动作预算（默认 60000 字符，可配 `reviewViewLimit`）**：决定性字段优先完整保留，
  不再按 4000 字符截断。**只有顶层 `message`（宿主内建消息字段）**允许中段
  省略；`metadata.*`、`files[]` 等工具参数命名空间内的一切键（含 `description`/`message`/
  `title`/`summary` 与未知键、`Patch` 之类大小写伪装）都按决定性处理。
  装饰 message 必要时保留首尾各 80 字符，空间仍不足则省略整个装饰字段。
  超预算的 unified diff 只剥离计数完整 hunk 的未改上下文行，文件/hunk 头及增删行全部保留；
  畸形或未知 patch 格式不剥离。`COMPRESSION NOTICE` 明示装饰裁剪、上下文剥离数量，
  或分块进度；它不表示有决定性载荷被静默丢弃。
- **仍超预算则分块审查**：字段路径、offset/total 标明归属，长字符串相邻块重叠 256 字符，
  prompt 标注“第 i/N 块，共 N 块”。全块 allow 才放行，risk 取最大；任一块 deny/critical、
  失败或超时立即整体 deny（未审后块不再调用）。初审与复议同等待遇，复议未完成不签发 grant。
  `elidedCritical` 仅在无法构造/完成分块审查时为真；预算连字段结构与重叠都容不下也强制 deny。
  指纹始终覆盖原始全文（不受展示压缩影响）。重叠保证短跨界模式可见，但不保证模型能识别
  任意长距离、跨字段的语义关联；模型本身也可能误判。
- **deadline 覆盖准备阶段（单块动作）**：取上下文、工作目录、建内部会话、切模型与模型调用共享每轮
  `deadlineMs` 预算；建会话/切模型/生成还共用单模型 `attemptTimeoutMs`。每步启动前重算
  剩余额度，超时结果不采信。仅插件自身的整链 deadline 失败（包括准备耗尽预算）自动以
  全新 deadline 重试整链一次；每轮重新获取上下文并从 primary 开始，usage 跨轮累加。
  模型明确 deny/critical、非法输出、普通供应商错误，以及未耗尽整链预算的单次/idle 超时
  都不触发整链重试。最多两轮（默认审查预算合计 180s，另有有界的尽力取消/清理耗时）。
  价格目录查询另受 `priceTimeoutMs` 限时，只影响费用显示，不影响裁决。
- **超时取消与 usage 归属**：模型调用超时/失败后尽力调用宿主 `session.interrupt` 取消仍在
  运行的请求（宿主无该 API 时尽力而为）；usage 按**请求身份**归属——slot 在发起时绑定该尝试的
  内部会话 ID，响应到达时按身份领取，弃置请求撤销领取资格，迟到/重复响应直接丢弃（不按到达
  顺序猜归属，反向交错也不串单）。**每次 generate 换独立内部会话**（G6）：会话 ID 即请求身份，
  无复用，上一代迟到/重放响应领不到任何 slot；同一请求身份出现第二份响应（伪造/重放）时归属
  不确定，该次 usage **整体不采信**（宁可少报不虚报）。迟到的 `switchModel` 也不会污染后续
  尝试的模型选择。
  初审/复议成功或整链失败，都累计已捕获的各块/各次尝试 usage 并记录 token 与费用。
  阶梯价在输入量达到阈值时才切换；小输入使用基础档，不误取首个高价档。
- **授权撤回及时性**：上下文缓存由事件订阅（用户消息 / `question` 作答 / 消息更新）主动失效，
  并把会话版本（`time.updated` / tokens / cost / 消息计数）纳入缓存键；两者都不可用时 TTL
  缩短到 3 秒。撤回授权后的下一次审查一定看到最新约束。

- **审查失败**（模型“无输出”超时（默认 30s，可配 `idleTimeoutMs`，按流式产出间隔而非
  总时长）、单模型总预算超时（`attemptTimeoutMs`）、整链预算耗尽且重试失败
  （每轮默认 90s，可配 `deadlineMs`）、抛错、输出非法 JSON、缺
  `outcome`、`risk_level` 非法；
  `user_authorization` 缺失不算失败，记 `unspecified`）
  → `effect = "deny"`（`onFailure:"ask"` 时保留 `ask`），`message` 固定为：

  > Automatic approval review failed: `<原因>`. This is a review failure, not a determination
  > that the action is unsafe. Do not bypass the approval check; explain the situation and ask
  > the user for guidance.

- **熔断**：连续 3 次审查失败（可配 `breakerFailures`）→ 60 秒内不再调模型（可配
  `breakerWindowMs`），全部按 `onFailure` 策略处理
  （message 注明 `circuit breaker triggered`），期间每次写审计；窗口过后恢复，成功一次即清零计数。
- **审计日志**：每次裁决 append 一行 JSONL（硬拒绝的 `rationale` 对**经归一化命中**的
  明确标注 `（经归一化命中）`，避免按原字面查规则困惑；字面命中不加标注）：
  `{ts, sessionID, action, resources(短), layer: "setup"|"ask"|"fastpath"|"rule"|"allow-all"|"command"|"model"|"appeal"|"failure", effect, risk_level?, user_authorization?, review_model?, rationale?}`。
  setup 结束追加心跳：`layer:"setup", effect:"allow", rationale:"plugin active, mode=<...>, source=<...>"`，
  `resources` 记录节点工作目录（宿主提供时），不混入面板裁决/事件。心跳证明该节点曾完成加载，
  不代表插件永远在线；审计写入失败仍绝不影响裁决，因此无日志不能单独证明插件未加载。

## 会话内命令（/approval-model 与 /approval-mode，TUI）

审查模型链既可在配置里用 `reviewModel` + `fallbackModels` 设定，也可在会话内动态切换。
两个命令由包的 TUI 半（`tui.js`，经 `exports["./tui"]` 自动加载）注册为 TUI slash 命令：

- `/approval-mode`：toast 回显当前模式（allow-all / ask / review）、来源（配置默认 /
  持久化状态 / 本节点覆盖〔已持久化〕）及状态文件路径。
- `/approval-mode allow-all`（别名 `allow`）：切换为**全部允许**——除静态 deny 与灾难性
  硬拒绝外一律放行，跳过 fast-path 判定与模型审查。
- `/approval-mode ask`：切换为**人工确认**——不调模型审查，需要判断的动作交还给用户在
  TUI 里确认（只读快速路径与安全命令仍直接放行）。
- `/approval-mode review`：切换回模型审查。
- `/approval-mode default`（或 `reset`）：删除持久化状态、清除本节点覆盖；各共享节点恢复
  各自配置默认（`mode` / 兼容 `allowAll`）。

- `/approval-model`：toast 回显当前审查链与配置默认链。
- `/approval-model providerID/modelID[#variant] [备用模型...]`：切换审查模型链，
  空格分隔多个模型（第一个为 primary，其余按序 fallback），如
  `/approval-model openai/gpt-6-luna-fast#xhigh xiaomi-token-plan-cn/mimo-v2.6-pro`。
- `/approval-model default`（或 `reset`）：恢复配置默认链。

命令回显走 TUI toast，**不向会话注入任何消息、也不唤醒
模型会话**（实现：TUI 命令 → RPC `opencode-approval.mode/model`；RPC 注册失败时命令不可用，
但不影响审批功能本身）。**模型链**切换仍仅当前节点生效，重启恢复配置默认。
**模式**切换保存 `{ mode, setBy, sessionID, ts }`（无密钥/命令内容，`setBy` 固定为
`/approval-mode`）；同目录独占临时文件 + rename 原子替换，权限 `0600`，并发时最后写入获胜。
setup 初始读取；已加载节点在审批/查询时重读，外部切换、删除或损坏状态会清除旧本节点覆盖，
无需重启。新模式作用于下一次审批，不撤销已经开始的审查。写入/删除失败明确报错，
不切换内存模式、不声称已持久化。切换本身写审计（`layer: "command"`）。
共享状态会影响所有使用该路径的工作区；需要隔离时为各配置指定不同的绝对 `statePath`。

## TUI 展示（侧栏面板与提醒）

TUI 半还会在会话侧栏注册一个「Approval」面板，并推送裁决提醒：

- **面板**：当前模式与来源（review / ask / allow-all、配置默认 / 持久化 / 本节点覆盖）、审查模型链、
  最近 6 条裁决——**每条只占一行**（结果标记 / 判定层 / 动作摘要 / 所用审查模型；超出宽度
  由宿主截断）。**点击条目弹出详情**（完整字段：时间、动作、资源、风险、审查模型、
  上下文 / token / 费用、用户授权、拦截理由全文；`ctx 1.2k字 · ↑1.2k↓80t · $0.001360`
  中的 token/费用来自流式 usage 捕获，价格取 models.dev 目录，取不到则省略；Esc、点击
  esc 或点击背景关闭）。不含 fastpath 只读放行，避免淹没列表。
- **提醒**：`deny` 或审查失败时弹一条 toast，包含动作摘要与**拦截原因**（rationale）；
  `allow` 静默。
- **数据通道**：RPC `opencode-approval.status`（面板初值）+ 事件
  `opencode-approval.decision`（非 fastpath 裁决都会推送；模式/模型切换以
  `layer: "command"` 推送并触发状态刷新）。
- **Location 路由**：所有 RPC 调用都通过 `x-opencode-directory` 请求头携带当前工作目录
  （裸 `client.rpc.call` 只认 header；RequestOptions 的 `location` 字段是 typed 子客户端参数，
  在这里是死代码、已删除），优先取当前会话的 Location（`session.get`），回退 TUI 插件实例的
  `ctx.location`——否则服务端按自身 cwd（常常是 `/`）解析到错误的插件实例。decision 事件按
  Location 过滤，两个 Location 的裁决互不串扰；事件/请求缺少 Location 信息时不过滤（兼容旧宿主）。
- **渲染依赖**：面板元素通过 `render-lib.js` 的 `opentui:runtime-module:*` 虚拟标识
  复用宿主 OpenTUI 实例——npm 安装的插件不走宿主对「本地插件」的导入重写，必须显式
  引用虚拟模块（否则插件自带的 `@opentui/solid` 副本会因缺少宿主 RendererContext 报
  `No renderer found`）。宿主不提供该机制时面板自动禁用，命令与提醒不受影响。
- **流式观测**：审查调用在插件内部会话上以 `kind=generate` 发起，插件通过会话
  `http.response` 钩子包装该请求的响应流（原生与 AI-SDK 两条传输路径都经过这一 HTTP
  层）：①“无输出”看门狗——产出间隔超过 `idleTimeoutMs` 即中断该次尝试（按间隔而非
  总时长）；②usage 捕获——增量解析 SSE 里的 usage（OpenAI / Anthropic 风格；部分
  传输层读到 `[DONE]` 后会取消底层流，故随 chunk 增量上报），供面板显示 token 与费用
  （价格取 models.dev 目录）。仅内部审查会话的 generate 响应被处理，聊天等其他流量
  原样透传；无法创建内部会话时降级为 `ctx.generate.text`（无 usage、“无输出”超时
  退化为单模型/整链预算）。

## 构建与测试

```sh
nix-build -E 'let pkgs=import <nixpkgs> {}; in pkgs.callPackage ./overlays/pkgs/opencode-approval {}' --no-out-link
```

构建期执行 `node --check` 与 `node --test`（`tests/*.test.mjs`），产物为
`opencode-approval-<version>.tgz`。
