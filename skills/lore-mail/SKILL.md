---
name: lore-mail
description: >
  通过 b4 与 lei 直接搜索、查看、下载 lore.kernel.org / public-inbox
  邮件列表内容的工作流。适用于 Linux kernel patch/thread 调研、补丁串下载、
  邮件上下文查看；默认不建立本地镜像或全文索引。
metadata: { "openclaw": { "emoji": "✉️", "requires": { "bins": ["b4", "lei"]}}}
---

# lore.kernel.org 邮件列表访问

本 skill 用于让 agent 在不建立本地镜像、不建立本地全文索引的前提下，直接使用 `lei` 远程查询 lore.kernel.org，并使用 `b4` 按 Message-ID 或 public-inbox URL 下载、查看、整理邮件线程和补丁串。

## 核心原则

| 场景 | 默认工具 | 说明 |
|------|----------|------|
| 搜索邮件、补丁、讨论 | `lei q` | 远程查询 `https://lore.kernel.org/all`，输出 JSONL/mbox/Maildir |
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
- 下载内容放入 `/tmp/opencode` 或用户指定目录，避免污染仓库。
- 运行 `b4 shazam`、`git am`、`git apply` 等会修改工作树的命令前，必须得到用户明确授权。
- 对搜索条件加时间范围、列表、文件名或主题约束，避免误拉大量邮件。

## 前置检查

```sh
command -v lei && lei q --help
command -v b4 && b4 --version
```

若需要存放下载结果，先确认目录存在：

```sh
mkdir -p /tmp/opencode/lore
```

## 搜索工作流

### 1. 远程搜索并输出 JSONL

优先用 JSONL，因为每行包含 `m` (Message-ID)、`s` (Subject)、`f` (From)、`t` (To)、`c` (Cc)、`dt`、`rt`、`refs` 等字段，便于后续选择 Message-ID。

远程查询优先使用简单、可拆分的条件。lore 的远端查询后端有时会在复杂组合上返回 HTTP 500，尤其是 `l:` 列表限定、精确日期范围、括号内 `OR`、带引号的 `s:"[PATCH"` 等混用时。默认先按主题、作者、收件人或相对时间窗口拆成多条简单查询；拿到 JSONL 后再在本地过滤、聚合和去重。

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS'
```

示例：按主题和作者搜索。

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  's:"selftests/harness" AND f:keescook AND rt:2020-03-01..2020-04-01'
```

示例：按补丁触及文件搜索。

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'dfn:drivers/gpu/drm/* AND rt:1.month.ago..'
```

示例：复杂调研时，先做宽但简单的远端查询，再用本地工具过滤输出。不要把所有条件都塞进 lore 查询表达式。

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  's:qcom rt:1.week.ago..' \
  | jq -r 'select(.s | test("PATCH|RFC|RESEND|PULL")) | [.rt, .f[0][0], .s, .m] | @tsv'
```

### 2. 常用查询语法

| 前缀 | 含义 | 示例 |
|------|------|------|
| `s:` | Subject | `s:"memory leak"` |
| `f:` | From | `f:torvalds` |
| `t:` | To | `t:linux-kernel` |
| `c:` | Cc | `c:stable` |
| `l:` | List-ID | `l:linux-kernel.vger.kernel.org` |
| `b:` | 正文 | `b:"regression"` |
| `d:` | Date | `d:2024-01-01..2024-02-01` |
| `rt:` | Received time | `rt:1.month.ago..` |
| `dfn:` | patch 中的文件名 | `dfn:kernel/sched/*` |
| `dfhh:` | diff hunk header / 函数名 | `dfhh:schedule_*` |
| `dfa:` | patch 添加的行 | `dfa:"foo"` |
| `dfb:` | patch 删除/上下文相关正文 | `dfb:"bar"` |

复杂查询可以使用 `AND`、`OR` 和括号，但只在简单查询不足以收敛结果时使用。若远端返回 HTTP 500，立刻拆分为多条简单查询，并把列表/主题/时间等二次筛选放到本地处理。

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  '(dfn:drivers/net/* OR l:netdev.vger.kernel.org) AND rt:2.weeks.ago..'
```

### 3. 直接输出 mbox

用于快速查看搜索命中的原始邮件，不需要 `b4`：

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f mboxrd \
  'SEARCH_TERMS'
```

### 4. 输出为临时 Maildir

用于把查询结果交给邮件客户端或后续工具处理：

```sh
rm -rf /tmp/opencode/lore/maildir
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o /tmp/opencode/lore/maildir -f maildir \
  'SEARCH_TERMS'
```

## 查看与下载工作流

### 1. 下载完整线程为 mbox

从 `lei` JSONL 输出中取 `m` 字段作为 Message-ID：

```sh
b4 mbox -C -o /tmp/opencode/lore '<message-id>'
```

也可以用完整 lore URL：

```sh
b4 mbox -C -o /tmp/opencode/lore 'https://lore.kernel.org/lkml/<message-id>/#t'
```

`-C` 表示跳过 b4 本地缓存，强制取新结果。

### 2. 下载完整线程到 stdout

适合立即阅读或管道处理：

```sh
b4 mbox -C -o - '<message-id>'
```

### 3. 只下载单封邮件

当 thread 很长但只需要某一封邮件时使用：

```sh
b4 mbox -C --single-message -o - '<message-id>'
```

保存到目录：

```sh
b4 mbox -C --single-message -o /tmp/opencode/lore '<message-id>'
```

### 4. 生成可 git-am 的补丁包

用于 patch series。该命令只生成文件，不修改当前 git 分支：

```sh
b4 am -C -o /tmp/opencode/lore '<message-id>'
```

输出通常包含：

- `*.cover`
- `*.mbx`
- 命令提示中的 `git am /path/to/*.mbx`

除非用户明确要求，不要自动执行 `git am`。

### 5. 选择补丁版本或子集

指定版本：

```sh
b4 am -C -v 3 -o /tmp/opencode/lore '<message-id>'
```

只取某些 patch：

```sh
b4 am -C -P 1,3-5 -o /tmp/opencode/lore '<message-id>'
```

只取给定 Message-ID 对应的 patch：

```sh
b4 am -C -P _ -o /tmp/opencode/lore '<message-id>'
```

### 6. 比较补丁版本

```sh
b4 diff '<message-id-of-newer-version>'
```

如果需要指定版本或范围，先查看 `b4 diff --help`，再执行。

## 推荐端到端流程

### 搜索并下载 thread

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS'

b4 mbox -C -o /tmp/opencode/lore '<message-id-from-lei-output>'
```

### 搜索并生成 patch series

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'dfn:path/to/file.c AND s:PATCH AND rt:1.year.ago..'

b4 am -C -o /tmp/opencode/lore '<message-id-from-lei-output>'
```

### 预览命中，再决定下载

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'SEARCH_TERMS'
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

```sh
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
| 结果太多 | 加 `rt:`、`l:`、`dfn:`、`f:` 或更具体主题 |
| lore 远端返回 HTTP 500 | 立即拆查询：去掉括号和 `OR`，避免 `l:` 与复杂主题/精确日期混用，改用 `s:qcom rt:1.week.ago..`、`c:linux-arm-msm rt:1.week.ago..` 这类简单查询；之后用本地 `jq`/脚本过滤、聚合、去重 |
| `b4` 下载 thread 错误 | 确认 Message-ID 是否包含尖括号，尝试去掉 `< >` |
| `b4 am` 选错版本 | 使用 `-v N` 指定版本，或用 `-c` 检查新版本 |
| thread 太长 | 用 `--single-message` 只取单封，或用 `lei` 先筛选 |
| 网页被 Anubis 拦截 | 不使用浏览器抓取，继续使用 `lei`/`b4` 的 public-inbox 接口 |

## 已验证示例

远程查询：

```sh
lei q --no-local \
  -I https://lore.kernel.org/all \
  --no-save --no-import-remote \
  -o - -f jsonl \
  'm:20200313231252.64999-1-keescook@chromium.org'
```

下载线程：

```sh
b4 mbox -C -o /tmp/opencode/lore \
  '20200313231252.64999-1-keescook@chromium.org'
```

生成可 `git am` 的补丁包：

```sh
b4 am -C -o /tmp/opencode/lore \
  '20200313231252.64999-1-keescook@chromium.org'
```
