---
name: lore-mail
description: >
  通过 b4 与 lei 直接搜索、查看、下载 lore.kernel.org / public-inbox
  邮件列表内容的工作流。适用于 Linux kernel patch/thread 调研、补丁串下载、
  邮件上下文查看；默认不建立本地镜像或全文索引。
metadata: { "openclaw": { "emoji": "✉️", "requires": { "bins": ["bash", "b4", "lei", "jq", "timeout", "head"]}}}
---

# lore.kernel.org 邮件列表访问

本 skill 用于让 agent 在不建立本地镜像、不建立本地全文索引的前提下，直接使用 `lei` 远程查询 lore.kernel.org，并使用 `b4` 按 Message-ID 或 public-inbox URL 下载、查看、整理邮件线程和补丁串。

## 核心原则

| 场景 | 默认工具 | 说明 |
|------|----------|------|
| 搜索邮件、补丁、讨论 | `lei q` | 优先 `-O` 具体 archive（如 `https://lore.kernel.org/linux-arm-msm/`），跨列表才用 `/all/`；输出 JSONL/mbox/Maildir |
| 获取完整讨论线程 | `b4 mbox` | 按 Message-ID 或 lore URL 下载 thread |
| 获取可应用补丁串 | `b4 am` | 生成可 `git am` 的 mbox 和 cover |
| 直接应用补丁串 | `b4 shazam` | 仅在用户明确要求应用 patch 时使用 |
| 比较补丁版本 | `b4 diff` | 需要已知某个版本的 Message-ID |

必须优先使用 `lei` + `b4`。不要默认使用 `public-inbox-clone`、`public-inbox-fetch`、`grokmirror` 或 `git clone --mirror`，除非用户明确要求本地镜像/索引。

## 安全与范围约束

- 不绕过 Anubis、验证码、Proof-of-Work 或站点反爬机制。
- 不默认全量下载 mailing list，不默认建立本地镜像。
- 不默认保存可 `lei up` 的持久搜索；使用 `--no-save`。
- 不默认导入远端消息到本地 lei store；使用 `--no-import-remote`。
- 不默认混入本地已有邮件结果；使用 `--no-local`。
- 默认搜索必须设置检索预算：用本 skill 的预览辅助脚本在独立进程组中以 45 秒 `timeout` 限制完整首轮管线；初始 TERM 后仍存活的进程组会在短暂宽限后收到 KILL，`head -n 30` 位于流式管道末端；只有用户明确要求穷举时才扩大预算。
- 不对 `https://lore.kernel.org/all/` 发起没有日期范围的开放查询。优先查询具体 archive；只能用 `/all/` 时，必须同时加 `rt:`/`d:` 和主题、作者、收件人或文件名约束之一。
- 首轮搜索不使用 `-t`/`--threads`。先选择 Message-ID，再用 `b4` 获取完整 thread。
- 下载内容放入 `/tmp/opencode` 或用户指定目录，避免污染仓库。
- 运行 `b4 shazam`、`git am`、`git apply` 等会修改工作树的命令前，必须得到用户明确授权。

## 前置检查

```bash
command -v bash
bash --version
command -v lei
lei q --help
command -v b4
b4 --version
command -v jq
command -v timeout
command -v head
```

若需要存放下载结果，先确认目录存在：

```bash
mkdir -p /tmp/opencode/lore
```

## JSONL 预览辅助脚本

从本 `SKILL.md` 所在目录执行 JSONL 预览。辅助脚本始终位于 `./scripts/preview.sh`，因此随 skill 递归复制后仍可按相对路径发现。调用形式为 `./scripts/preview.sh <<'BASH'`；它从 heredoc 接收生产者及可选 `jq` 管线，在独立进程组中施加默认的 45 秒预算与 30 条上限，并在短暂宽限后强制终止仍存活的后代。

## 搜索工作流

### 1. 先确定 archive 和时间窗口

`lei q` 的 HTTPS 远程查询即使指定 `-f jsonl`，也会从 public-inbox 的 `x=m` 接口接收并解析完整 mbox；JSONL 只是本地输出格式，不是轻量的远端元数据接口。命中几千条时，主要成本是服务端检索、整批邮件传输和本地解析，因此必须在远端查询阶段减少命中数。

优先把 `-O` 指向具体 archive，只在跨列表搜索或无法确定 archive 时使用 `/all/`。`-O` 表示只查询该 external；`-I` 只是额外包含它，可能同时查询已配置的其他 external。

```bash
# 已知目标列表时
-O https://lore.kernel.org/linux-arm-msm/

# 确实需要跨列表时
-O https://lore.kernel.org/all/
```

每次非精确 Message-ID 查询都要有有界时间范围：

- 默认从 `rt:1.year.ago..` 开始；命中过多时缩短到 3 个月或 1 个月，结果不足再扩到三年或更长。
- 已知版本或事件时间时使用闭区间，例如 `rt:2024-01-01..2024-04-01`。
- 跨多年历史调研按年、季度或月切片，先查最可能的区间；不要直接使用无起点的多年范围。
- 只有 `m:<exact-message-id>` 这类唯一键查询可以省略时间范围。

### 2. 默认执行有预算的 JSONL 预览

首轮默认最多预览 30 条、运行 45 秒。`head` 必须直接消费流式输出；达到 30 条后它会关闭管道，让 `lei`/`curl` 提前结束传输。`timeout` 防止复杂查询在第一条结果出来前长时间阻塞。

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O 'https://lore.kernel.org/<archive>/' \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS AND rt:1.year.ago..'
BASH
```

每行 JSON 包含 `m` (Message-ID)、`s` (Subject)、`f` (From)、`t` (To)、`c` (Cc)、`dt`、`rt`、`refs` 等字段。若输出正好达到 30 条，应先视为查询过宽并继续收窄，而不是立即提高上限。

当前已验证的 public-inbox 2.1.0 中，HTTPS 远端路径不会把 `-n`/`--limit` 或 `--offset` 传给 lore 的 mbox 查询，所以它们不能限制远端下载量。不要用 `lei q ... > all.jsonl` 后再 `head`，那会先等待完整结果。未来版本若声称支持远端 limit，必须先用宽查询实测后才能替换上述预算机制。

### 3. 在流中本地过滤，到量即停

远端保持简单查询，本地用逐行 `jq` 做二次筛选，并把 `head` 放在最后。这样只处理到获得足够候选结果为止。

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  's:qcom AND rt:1.year.ago..' \
  | jq -r '
    select(.s | test("PATCH|RFC|RESEND|PULL"; "i"))
    | [.rt, (.f[0][0] // .f[0][1] // ""), .s, .m]
    | @tsv
  '
BASH
```

预览管道中不要使用 `jq -s`、`sort` 等必须等到 EOF 才输出的命令，也不要先写完整临时文件；这些操作会失去提前断流的效果。

### 4. 渐进收窄或扩展

1. 先组合具体 archive、默认 1 年 `rt:` 窗口和一个高选择性条件，例如精确主题词、作者、`dfn:` 或芯片/子系统名。
2. 命中达到 30 条时，增加条件或缩短时间窗口，不要先提高 `head` 上限。
3. 命中不足时，每次只放宽一个维度，例如一年扩到三年，再扩到五年，以便知道是哪项约束引入噪声。
4. 跨多年搜索按时间切片顺序执行，找到目标 thread 后立即停止。只有用户明确要求完整统计或归档时，才保存全部切片并按 `m` 字段去重。
5. 首轮不加 `-t`/`--threads`；线程扩展可能把少量命中放大成大量邮件。选定 Message-ID 后交给 `b4 mbox`。

远程查询优先使用简单、可拆分的条件。lore 后端有时会在复杂组合上返回 HTTP 500，尤其是 `l:`、精确日期范围、括号内 `OR` 和带引号主题混用时。遇到 500 立即拆成多条简单查询，再做流式本地过滤。

示例：按主题和作者搜索一个已知时间段。

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  's:"selftests/harness" AND f:keescook AND rt:2020-03-01..2020-04-01'
BASH
```

示例：按补丁触及文件搜索近期邮件。

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'dfn:drivers/gpu/drm/* AND rt:1.year.ago..'
BASH
```

### 5. 常用查询语法

| 前缀 | 含义 | 示例 |
|------|------|------|
| `s:` | Subject | `s:"memory leak"` |
| `f:` | From | `f:torvalds` |
| `t:` | To | `t:linux-kernel` |
| `c:` | Cc | `c:stable` |
| `l:` | List-ID | `l:linux-kernel.vger.kernel.org` |
| `b:` | 正文 | `b:"regression"` |
| `d:` | Date | `d:2024-01-01..2024-02-01` |
| `rt:` | Received time | `rt:1.year.ago..` |
| `dfn:` | patch 中的文件名 | `dfn:kernel/sched/*` |
| `dfhh:` | diff hunk header / 函数名 | `dfhh:schedule_*` |
| `dfa:` | patch 添加的行 | `dfa:"foo"` |
| `dfb:` | patch 删除/上下文相关正文 | `dfb:"bar"` |

### 6. 直接输出 mbox

只在查询已经收敛、预计结果很少且确实需要每封邮件正文时使用。不要把 mboxrd 作为首轮搜索格式，也不要用 `head` 截断 mbox，否则可能得到不完整邮件。

```bash
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f mboxrd \
  'NARROW_SEARCH_TERMS AND rt:BOUNDED_RANGE'
```

### 7. 输出为临时 Maildir

只在用户需要把已收敛的结果集交给邮件客户端或后续工具时使用：

```bash
rm -rf /tmp/opencode/lore/maildir
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o /tmp/opencode/lore/maildir -f maildir \
  'NARROW_SEARCH_TERMS AND rt:BOUNDED_RANGE'
```

## 查看与下载工作流

### 1. 下载完整线程为 mbox

从 `lei` JSONL 输出中取 `m` 字段作为 Message-ID：

```bash
b4 mbox -C -o /tmp/opencode/lore '<message-id>'
```

也可以用完整 lore URL：

```bash
b4 mbox -C -o /tmp/opencode/lore 'https://lore.kernel.org/lkml/<message-id>/#t'
```

`-C` 表示跳过 b4 本地缓存，强制取新结果。

### 2. 下载完整线程到 stdout

适合立即阅读或管道处理：

```bash
b4 mbox -C -o - '<message-id>'
```

### 3. 只下载单封邮件

当 thread 很长但只需要某一封邮件时使用：

```bash
b4 mbox -C --single-message -o - '<message-id>'
```

保存到目录：

```bash
b4 mbox -C --single-message -o /tmp/opencode/lore '<message-id>'
```

### 4. 生成可 git-am 的补丁包

用于 patch series。该命令只生成文件，不修改当前 git 分支：

```bash
b4 am -C -o /tmp/opencode/lore '<message-id>'
```

输出通常包含：

- `*.cover`
- `*.mbx`
- 命令提示中的 `git am /path/to/*.mbx`

除非用户明确要求，不要自动执行 `git am`。

### 5. 选择补丁版本或子集

指定版本：

```bash
b4 am -C -v 3 -o /tmp/opencode/lore '<message-id>'
```

只取某些 patch：

```bash
b4 am -C -P 1,3-5 -o /tmp/opencode/lore '<message-id>'
```

只取给定 Message-ID 对应的 patch：

```bash
b4 am -C -P _ -o /tmp/opencode/lore '<message-id>'
```

### 6. 比较补丁版本

```bash
b4 diff '<message-id-of-newer-version>'
```

如果需要指定版本或范围，先查看 `b4 diff --help`，再执行。

## 推荐端到端流程

### 搜索并下载 thread

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O 'https://lore.kernel.org/<archive>/' \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS AND rt:BOUNDED_RANGE'
BASH

b4 mbox -C -o /tmp/opencode/lore '<message-id-from-lei-output>'
```

### 搜索并生成 patch series

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'dfn:path/to/file.c AND s:PATCH AND rt:1.year.ago..'
BASH

b4 am -C -o /tmp/opencode/lore '<message-id-from-lei-output>'
```

### 预览命中，再决定下载

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS AND rt:BOUNDED_RANGE'
BASH
```

检查输出里的：

- `m`: Message-ID，交给 `b4`
- `s`: Subject，判断是否为目标 thread/patch
- `f`: From，确认作者
- `rt`/`dt`: 时间
- `refs`: 线程引用关系

## 本地状态说明

这套工作流不是本地镜像/索引。`lei` 可能创建少量配置或 store 目录，例如：

- `~/.config/lei/config`
- `~/.local/share/lei/store`

使用 `--no-save --no-import-remote --no-local` 可避免保存查询、导入远端消息和混入本地结果，但仍可能保留少量运行状态。下载的邮件和补丁只应放到 `/tmp/opencode/lore` 或用户指定目录。

## 不使用的命令，除非用户明确要求

以下命令会建立镜像、索引或大量本地数据，默认不要使用：

```bash
public-inbox-clone ...
public-inbox-fetch ...
grokmirror ...
git clone --mirror https://lore.kernel.org/...
```

如用户明确要求离线全文搜索或长期归档，再说明空间成本和索引成本后执行。

## 故障处理

| 问题 | 处理 |
|------|------|
| `lei` 无结果 | 放宽时间范围，检查前缀，先用主题/作者搜索 |
| 命中太多/查询慢 | 缩小 `rt:` 窗口或换具体 archive，追加 `dfn:`、`f:`、更具体主题；用 `head -n 30` 提前断流，并由预览辅助脚本的进程组 timeout 兜底；不要依赖 `-n`/`--limit` 限制远端传输 |
| 命中不足 | 每次只放宽一个维度：先扩 `rt:` 窗口（1 年→3 年→5 年），再放宽主题；跨多年按时间切片 |
| lore 远端返回 HTTP 500 | 立即拆查询：去掉括号和 `OR`，避免 `l:` 与复杂主题/精确日期混用，改用 `s:qcom rt:1.week.ago..`、`c:linux-arm-msm rt:1.week.ago..` 这类简单查询；之后用流式 `jq` 过滤，到量即停 |
| `b4` 下载 thread 错误 | 确认 Message-ID 是否包含尖括号，尝试去掉 `< >` |
| `b4 am` 选错版本 | 使用 `-v N` 指定版本，或用 `-c` 检查新版本 |
| thread 太长 | 用 `--single-message` 只取单封，或用 `lei` 先筛选 |
| 网页被 Anubis 拦截 | 不使用浏览器抓取，继续使用 `lei`/`b4` 的 public-inbox 接口 |

## 已验证示例

远程查询：

```bash
./scripts/preview.sh <<'BASH'
lei q --no-local \
  -O https://lore.kernel.org/all/ \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'm:20200313231252.64999-1-keescook@chromium.org'
BASH
```

下载线程：

```bash
b4 mbox -C -o /tmp/opencode/lore \
  '20200313231252.64999-1-keescook@chromium.org'
```

生成可 `git am` 的补丁包：

```bash
b4 am -C -o /tmp/opencode/lore \
  '20200313231252.64999-1-keescook@chromium.org'
```
