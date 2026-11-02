---
name: firefox-video-qa
description: >
  对任意桌面或移动平台上的实际 Firefox 构建执行视频解码 QA，区分能力上报、
  decoder 初始化、持续硬件解码、渲染、性能和软件回退。适用于验证硬件视频解码、
  codec/profile/位深矩阵、排查首帧后 fallback，以及对浏览器或媒体栈修改做真实播放
  验收；不负责未经授权的安装、部署、系统配置修改或电源操作。
---

# Firefox 视频解码 QA

此 skill 为 Linux 提供可执行、target-agnostic 的 Firefox 视频解码 QA harness。它验证真实
Firefox binary 的播放路径，不使用 Playwright Firefox、geckodriver 或用户 profile。
其他桌面/移动平台按 [evidence-and-reporting.md](references/evidence-and-reporting.md) 的
手动证据小节采集等价证据。开始前必须读取 [qa-procedure.md](references/qa-procedure.md)、
[evidence-and-reporting.md](references/evidence-and-reporting.md) 和
[harness-contract.md](references/harness-contract.md)。

## 标准执行

1. 用 `scripts/generate-fixtures.sh <fixture-dir>` 生成标准 6 场景矩阵，或按 harness
   contract 提供已有 fixture 的 canonical `manifest.json`。
   需要压力分辨率矩阵时显式运行
   `RESOLUTION_MATRIX=1 scripts/generate-fixtures.sh <fixture-dir>`。该命令保留标准
   `manifest.json`，并额外生成 `manifest-resolution.json`：H.264 High、HEVC Main、
   HEVC Main10、VP9 Profile 0/2 分别覆盖 1080p30、1080p60、4k30 和 4k60，共 20 个
   full/evidence 场景。
2. 在任何 SSH 前运行 `scripts/validate-manifest.sh <manifest.json>`。它重新计算 SHA-256，
   并逐项核对 ffprobe 的 container、codec/profile、pixel format、位深/chroma、尺寸、
   fps、duration 和 frame count。
3. 运行 `scripts/probe-target.sh <user@host> <absolute-firefox-path>`，保存结构化 probe，
   人工确认“Firefox/container 能力、目标 runtime decoder、fixture”三者交集。
4. 串行运行：

```sh
scripts/run-matrix.sh MANIFEST USER@HOST /absolute/path/to/firefox OUTPUT_DIR \
  XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 MOZ_ENABLE_WAYLAND=1
```

每个场景都创建新的 Firefox parent、`setsid` session 和 0700 profile。SSH 始终使用
`-n`，manifest 通过独立文件传输，参数以 argv 安全引用；矩阵绝不并行。

## 判定契约

`verdict.json` 固定给出 `hardware_path`、`rendering`、`quality`、`cleanup`、
`performance` 和 `overall`。硬件路径 PASS 必须同时具备 playback `ChannelDecoder`
tracking ID、RDD decoder instance、目标 hardware codec、`IsHardwareAccelerated=true`、
直到 terminal/seek PTS 的 VA-API frame、RDD `/dev/videoN` owner、实际映射的
FFmpeg/libva/V4L2 driver、DMA-BUF import，以及无 playback fallback。

`corruptedVideoFrames > 0` 是 quality FAIL；`null`、undefined 或 API unavailable 是
INCONCLUSIVE。dropped frames 没有预声明 threshold 时 performance 不得 PASS。
evidence profile 的性能数据标为 `instrumented=true`，只作观察；performance profile
只有阈值已写入 manifest 且未超出时才能 PASS。任一 required axis 不 PASS 时 overall
不得 PASS。Firefox 155 的 `corruptedVideoFrames=null` 因此应得到 quality 和 overall
INCONCLUSIVE，而不是伪造 PASS。

## 安全边界

- 不安装或部署包，不修改系统 Firefox、媒体库、驱动、policy 或用户 profile。
- 每次 TERM、KILL 和目录删除前重新验证 boot ID、PID start time、精确 profile、随机
  token、SID、PGID，以及实际 `/proc/<pid>/exe` 与 ELF Build ID。验证失败或 `/proc`
  不透明时保留目录并报告 cleanup 非 PASS。
- 启动 Firefox 前做 rootless before snapshot；可见外部 `/dev/videoN` owner 或同 UID
  opaque process 时写 `outcome.json` 并以 `BLOCKED` 退出（exit 3），不启动、不 kill。
- 禁止 `pkill`、模糊匹配和外部 process kill。rootless observer 只读取可见的 process、
  fd 和 maps，不要求 sudo，也不把不可见状态升级为 PASS。
- 只回收 evidence allowlist；profile、cookies、Glean、sessionstore 和浏览历史永不复制。
- 凭据只能来自调用方 SSH 配置/agent，不接受密码参数，也不写入 artifacts。

本地确定性回归：`uv run --project . pytest -q` 运行 Python tests，
`node --test tests/telemetry.test.js` 运行页面 telemetry tests。静态门为
`basedpyright firefox_qa`、`ruff check firefox_qa` 和 `ruff format --check firefox_qa`。
这些测试不连接目标；真实硬件结论只能来自当前 binary/fixture 的 HIL artifacts。
