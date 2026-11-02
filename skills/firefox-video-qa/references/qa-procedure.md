# Linux Firefox 视频解码 QA 流程

## 1. 本地身份门

先建立 canonical JSON manifest，再运行 `scripts/validate-manifest.sh`。校验完成前不得执行
probe 之外的目标连接，尤其不得先复制样片后补 hash。每个场景必须绑定绝对媒体路径、
SHA-256、MIME/container、codec/profile、bit depth/chroma、width/height/fps/duration、
expected frames/output、mode、seek target 和可选 dropped threshold。

已有样片必须满足同一契约；文件名、旧报告和 encoder 参数都不能替代当前 ffprobe。
生成标准样片可使用 `scripts/generate-fixtures.sh`，其输出由 package 内的 manifest builder
再次校验。

1080p/4K 压力矩阵必须显式启用：

```sh
RESOLUTION_MATRIX=1 scripts/generate-fixtures.sh <fixture-dir>
```

该命令先维持原有 6 场景 `manifest.json`，再额外生成 canonical
`manifest-resolution.json`。后者包含 H.264 High、HEVC Main、HEVC Main10、VP9 Profile 0
和 VP9 Profile 2 与 1080p30、1080p60、4k30、4k60 的笛卡尔积，共 20 个 full/evidence
场景；4k 固定为 3840x2160。`DURATION` 同时控制标准与分辨率 fixture，默认 6 秒。
运行该矩阵前应单独执行
`scripts/validate-manifest.sh <fixture-dir>/manifest-resolution.json`，不得以标准 manifest 的
校验结果替代。

本地和远端 Python harness 都要求 Python 3.12+（transfer package 使用 3.12 的 `type`
语句）。从 skill 根运行
`uv run --project . pytest -q`，uv 按 `uv.lock` 创建隔离环境并安装已声明的 pytest；不得依赖
系统 pytest 或残留 `.venv`。Ruff 与 BasedPyright 是开发机静态工具，不是远端运行依赖。

## 2. Runtime probe

`scripts/probe-target.sh TARGET FIREFOX` 通过 `ssh -n` 采集 JSON：OS/kernel/arch、Firefox
路径与版本、ELF notes、`/sys/class/video4linux` 设备、`vainfo`、`v4l2-ctl` 和工具可用性。
不得为 probe 安装工具。缺少某项时将对应能力标为未知；不要用源码能力表替代 runtime。

执行矩阵必须是以下三者交集：

1. 当前 Firefox 能解析的 container/codec；
2. 目标 runtime 实际广告的 decoder/profile/output；
3. 已通过 manifest 校验的 fixture。

交集为空时报告 `UNSUPPORTED`；缺工具、显示会话或样片时报告 `BLOCKED`。

## 3. 场景生命周期

`run-matrix.sh` 只串行调用 scenario。每次运行：

1. 本地再次验证完整 manifest，保证第一次 SSH 前 hash 与 ffprobe 已通过；
2. 远端以 `mktemp` 创建 `/tmp/firefox-video-qa.XXXXXXXXXXXX`，写入 128-bit token 和 boot ID；
3. 只复制固定 harness files、单个 scenario manifest 和单个 media；
4. 远端再次验证 hash/ffprobe；创建独立 0700 profile 前先做 rootless before snapshot，可见
   外部 `/dev/videoN` owner 或同 UID opaque process 时写 `outcome.json` 并以 `BLOCKED`
   退出，不启动浏览器、不发送 signal；
5. loopback server 使用随机端口，Firefox 以 `--no-remote --new-instance --profile` 和新
   `setsid` 启动；stdin 为 `/dev/null`；身份捕获会等待进程镜像变为传入 FIREFOX 路径的
   basename 后才绑定 exe/Build ID（NixOS wrapper `bin/firefox` 会 exec
   `lib/firefox/firefox`）；wrapper exec 不同名的二进制时必须改传真实 ELF 路径；
6. 页面按媒体状态到 EOS/错误/timeout，不用固定 sleep 判断播放完成；
7. rootless observer 保存 before/during/after process/device snapshot；
8. 生成 raw decoder archive、normalized timeline、cleanup 和 multi-axis verdict；
9. 只复制 allowlist，随后执行 fail-closed 删除门。

允许透传的远端环境变量仅限显示/session 项：`DISPLAY`、`WAYLAND_DISPLAY`、
`XDG_RUNTIME_DIR`、`XDG_SESSION_TYPE`、`DBUS_SESSION_BUS_ADDRESS` 和
`MOZ_ENABLE_WAYLAND`。不接受任意 Firefox flags。

## 4. 页面与 result server

页面记录 `getVideoPlaybackQuality()` 的 API availability，并把每个 metric 明确编码为
`unavailable`、`null`、`zero` 或 `nonzero`。`requestVideoFrameCallback` 保存 media time
和 presented frame number；seek 场景必须在 `seeked` 后出现 `mediaTime >= seek_target`。

页面只向 `127.0.0.1` POST 一次。endpoint 与 body 都携带随机 token。server 限制 body
大小，严格校验 scenario/mode/result schema，使用 `O_EXCL` 原子创建 `result.json`；重复
POST 返回 409，错误 token/schema 被拒绝。

## 5. Timeline 与 fallback

保留全部 raw MOZ_LOG，并生成 sequence-ordered `timeline.json`。分析只接受
`ChannelDecoder-*` playback tracking；`MediaCapabilities-*` 和启动期软件 codec probe
属于 capability noise。硬件 PASS 需要：

- playback tracking 先于 hardware codec selection；
- RDD `MediaPDecoder` instance 与 `IsHardwareAccelerated=true`；
- VA-API frame 到 full terminal PTS，seek 时还要覆盖 seek target 后到 terminal PTS；
- 同一运行 session 的 RDD 持有 `/dev/videoN`；
- RDD maps 同时出现 `libavcodec`、`libva` 和 V4L2 VA driver；
- expected output 的 DMA-BUF import 和 renderer zero-copy import；
- playback window 内没有 error、`HardwareDecoderNotAllowed` 或软件 reconstruction。

`ProcessFlush()` 单独不是 fallback。seek 后继续出现目标 VA-API frames 是恢复；只有 flush
与 error、hardware disallow 或 playback software reconstruction 组合才是 fallback。
软件 capability probe 单独出现也不是 fallback。

## 6. Evidence 与 performance profile

`evidence` profile 启用完整 decoder/FFmpeg/libva/DMA-BUF logs 和高频 rootless snapshot，
其 timing、CPU 和 dropped metrics 均标为 instrumented，不可产生 performance PASS。
`performance` profile 降低日志量，但仍保留硬件身份门；只有 manifest 在运行前声明
`dropped_threshold`，且实际 dropped frames 不超过该值，performance 才能 PASS。

阈值必须来自产品要求或事先批准的基线，不能在看到结果后补写。性能 PASS 不能替代
hardware_path、rendering 或 quality。

## 7. Cleanup

浏览器 parent identity 固定为 boot ID、PID、start time、profile、token、SID、PGID，以及
实际 `/proc/<pid>/exe` 和该 ELF 的 GNU Build ID。TERM 前重新读取全部字段（含 exe/Build
ID）；5 秒后仍存活时，KILL 前再读一次。只向通过验证的独立 PGID 发信号。若 parent 已自然
退出，不发送信号。

删除前再次验证 run root owner、token、boot、stored profile，并确认 parent 不存活、记录
SID/PGID 无成员。任何同用户 process 不透明、PID reuse、start-time mismatch、token/profile
不符或残留 process 都拒绝删除。绝不终止外部 process。保留的精确路径写入
`transport.json`，cleanup 轴不得 PASS。

退出码 0 只表示 `overall=PASS`。任一 FAIL/INCONCLUSIVE、harness 错误、证据复制失败或
清理拒绝均返回非零；不得用退出码覆盖 `verdict.json` 的具体原因。
