---
name: chromium-video-qa
description: >
  以目标普通用户身份发现并验证 Linux Chromium 视频解码路径。通过 manifest 覆盖
  浏览器、内核 decoder 和样片的能力交集，核验播放、设备占用、输出边界与清理；
  不负责构建、部署或系统集成。
---

# Chromium 视频硬件解码 QA

这是完全 rootless 的工作流。浏览器、观察和清理全部以 `TARGET_USER` 运行，不安装
系统 helper，不要求 capabilities，不证明 host namespace，也不修改目标配置。Chromium
和 `remote-guard.sh` 都拒绝 UID 0。不得复用用户 profile、杀已有浏览器或设备 owner；
检测到可见的已有 Chromium、设备占用或目标 video 节点不可读时，在创建 run 目录前阻断。
其他同 UID 进程不可读（例如 non-dumpable 的 KWin/polkit/sshd）只记为已知盲区，不阻断，
因为它本来就落在 `GLOBAL_IDLE_UNKNOWN` 里。

执行顺序：

1. 先读 `references/manifest.md`，运行 `scripts/probe-target.sh`，获得目标实际广告的
   decoder、profile 和 raw format；源码能力表不能代替运行时证据。
2. 取“驱动广告能力 ∩ Chromium 支持 ∩ 可验证样片”建立 manifest。需要标准样片时运行
   `scripts/generate-fixtures.sh`。
3. 使用 `scripts/run-matrix.sh`。它调用 `run-scenario.sh`、`drive-video-qa.js`、
   `close-owned-browser.js` 和 `assets/video-qa.html`。
4. 保留播放、`ROOTLESS_OBSERVATION_V1`、CDP、Chromium log、runtime PM 与 cleanup 产物，
   按 `references/qa-procedure.md` 的多轴状态解释结果。

样片生成器默认行为保持为标准矩阵。额外生成 1080p/4K、30/60 fps 的压力矩阵时显式运行：

```sh
RESOLUTION_MATRIX=1 scripts/generate-fixtures.sh OUTPUT_DIR
```

该选项新增独立的 `manifest-resolution.tsv`，包含 H.264 High、VP9 Profile 0 和 VP9
Profile 2 各四种分辨率/帧率组合，共 12 个 `full`、`hold=1` 场景；不会改写标准
`manifest.tsv` 的行。VP9 Profile 2 即使在先前目标 Chromium 上回退到 software，仍保留为
capability/fallback 边界场景，不代表预期硬解成功。

rootless 观察只声明目标 UID 可见范围。它记录 sample ID、boot ID、PID namespace label、
目标 UID、SID，以及每个同 UID 进程的 PID/start/parent identity、SID、exact profile、
GPU/Chromium role、video fd owner 和 opacity reason。可见的 run-owned GPU/session 进程持有
`/dev/videoN` 才能产生 `HW_PATH_OBSERVED`。不可读记录按作用域分类：本轮 session/profile
进程或无法归类的记录是 gap，使 hardware/cleanup 非 PASS；其他同 UID 进程的不可读原因只
记录为已知盲区。其他 UID 的隐藏 owner 无法排除，因此 `GLOBAL_IDLE` 永远是
`GLOBAL_IDLE_UNKNOWN`。

run 目录由 `mktemp` 创建，绑定随机 owner token、精确路径和非 symlink marker/profile。
启动先进入 `.launch-pending`，随后记录 `ROOTLESS_RUN_V1` 的 boot/PID/start/SID/token/profile。
ready、关闭前、进程检查和 removal 都重新验证这些字段。任何复用 PID、改变 SID/profile、
不透明状态或 owned residue 都会保留目录；脚本不向远端浏览器或外部 owner 发送 signal。
CDP 还必须匹配 DevToolsActivePort browser path、精确 command line/profile/run URL 和唯一页面。

单场景 machine result 固定包含 `PLAYBACK`、`HW_PATH`、`OWNED_CLEANUP`、`GLOBAL_IDLE` 和
`OVERALL`。正常正向结果为：

```text
PLAYBACK_PASS  HW_PATH_OBSERVED  OWNED_CLEANUP_PASS  GLOBAL_IDLE_UNKNOWN  OVERALL_INCONCLUSIVE_ROOTLESS
```

没有 positive fd ownership 时为 `HW_PATH_NOT_OBSERVED`，仍不能变成 PASS。播放错误、明确
software fallback、观察不透明或 owned residue 产生 `OVERALL_FAIL`；可见冲突产生
`OVERALL_BLOCKED`。`INCONCLUSIVE_ROOTLESS` 与 FAIL/BLOCKED 均返回非零。matrix 对缺失、
symlink、畸形或与 manifest/退出码不一致的 result fail closed，不存在默认 PASS。

当前 runner 没有针对目标 Chromium Build ID 验证、且与本次播放时间段和 decoder identity
绑定的 CAPTURE/dequeue/output collector。初始化成功、format 字符串、设备枚举或任意自称
output 的日志都不能升级 overall。因此该 rootless workflow 永不报告 overall hardware PASS。

`TARGET_HOST` 必填，`TARGET_USER` 默认本地同名账户。可覆盖 Chromium 路径、runtime dir、
`VIDEO_DEVICE_REMOTE`、Wayland、Mesa 和本地 `CDP_LOCAL_PORT`；禁止 `REMOTE_ROOT`、
`CDP_REMOTE_PORT` 和非空 `CHROMIUM_EXTRA_FLAGS`。远端调试端口由 Chromium 自动分配。
浏览器驱动需要本地 Node.js 22+ 和可由 Node 解析的 Playwright（`playwright` 或
`playwright-core`，后者无需下载浏览器）；目标只需普通用户可用的 bash、setsid、
timeout、procfs 与 Chromium。部署或更换浏览器包仍需当前请求明确授权。

隔离回归：

```sh
node --test skills/chromium-video-qa/scripts/*.test.js
```

测试仅使用临时目录、普通用户子进程与 loopback mock CDP/transport，不连接目标、不访问
真实视频设备、不安装组件。完整边界与产物见 `references/qa-procedure.md`。
