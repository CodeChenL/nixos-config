---
name: chromium-video-qa
description: >
  在 Linux 目标机上发现并验证 Chromium 硬件视频解码能力。通过 manifest
  覆盖浏览器、内核解码器和测试样片的能力交集，核验 codec/profile/位深、输出
  pixel format、设备占用、播放语义、seek 和清理证据；不负责构建或隐式部署。
---

# Chromium 视频硬件解码 QA

默认把目标机和用户现有会话视为只读。不得擅自安装包、重启、改系统配置、复用用户
profile，或杀掉已有浏览器；已有进程占用解码设备时也不得并发运行。需要部署时必须
由当前请求明确授权。凭据不得写入产物。

场景启动和目录删除均强制使用管理员预装的只读 helper
`/usr/local/libexec/chromium-qa-observer`，以 `sudo -n` 调用。它必须具备初始 host
PID/user namespace 中的 root 观察权限、所需 capabilities 和完整可读 proc；
同时匹配管理员在真实 host 上保存的 `/etc/chromium-qa-observer.namespaces` 与当前 boot，
不能用环境变量声明“已可信”。helper 缺失、sudo 被拒或任一仍存活进程不可读时阻断。
浏览器与带 owner token 的目录清理仍以普通测试用户执行，不授权 root 删除或 kill。
安装与最小权限说明见 references/qa-procedure.md；脚本不会自动安装 helper 或修改 sudoers。

工具、网页夹具、manifest 规范和完整判据都在本 skill 内；不得依赖某次下载目录中的
副本。执行时：

1. 先运行 scripts/probe-target.sh，发现目标实际广告的 decoder、profile 和 raw
   format；缺少 v4l2-ctl 时使用 GStreamer provider，不把源码能力表当运行时证据。
2. 按 references/manifest.md 建立“驱动广告能力 ∩ Chromium 支持 ∩ 可验证样片”
   的矩阵。需要标准样片时运行 scripts/generate-fixtures.sh。
3. 使用 scripts/run-matrix.sh；它调用同目录下的 run-scenario.sh、
   drive-video-qa.js 和 ../assets/video-qa.html。详细判据见
   references/qa-procedure.md。
4. 每个支持项都必须有浏览器 EOS、非零帧、零损坏帧、V4L2/GPU 设备占用、实际输出
   pixel format 与 teardown 证据。枚举但不能设置、浏览器不支持或缺合规样片的项，
   必须标为明确边界，不能标为 PASS。

不要把进程退出码、ENUM_FMT、软件解码成功或旧版本 HIL 单独当作硬件支持证明。

当前脚本没有针对目标 Build ID 验证过的、与播放关联的 CAPTURE/output 证据采集器。
因此即使播放与清理均成功，自动硬解结论也只能是 `INCONCLUSIVE`（非零退出码）；
初始化、format 文本或任意自称 output 的日志均不能升级为 PASS。失败的播放、
设备探测或 teardown 则为 FAIL。不得为获得绿灯临时添加日志成功正则。

运行脚本通过环境变量接收目标，不绑定板卡、发行版、固定账户或 UID：`TARGET_HOST`
必填，`TARGET_USER` 默认本地同名账户；远端 Chromium 路径和 runtime dir 自动发现，
也可与 `SSHPASS`、`VIDEO_DEVICE_REMOTE`、Wayland、Mesa、本地 `CDP_LOCAL_PORT` 一起覆盖。
禁止 `REMOTE_ROOT`、`CDP_REMOTE_PORT` 和非空 `CHROMIUM_EXTRA_FLAGS` 覆盖；远端目录由
mktemp 创建，远端调试端口由 Chromium 自动分配。样片生成
只依赖 ffmpeg/ffprobe；浏览器驱动需要 Node.js 22+ 能解析 `playwright`。先读
references/manifest.md；部署或更换浏览器包仍需当前请求授权。

隔离回归：`node --test skills/chromium-video-qa/scripts/*.test.js`。仅运行本地 mock、
临时目录与 loopback HTTP/WebSocket CDP，不连接目标、不访问视频设备，结束后清理。
observer 的权限与 proc 读取单测另用
`bash skills/chromium-video-qa/scripts/test-observer.sh`（需 pytest）。
其 proc 数据为临时 fixture，权限/namespace 为单测替身，不执行 sudo 或真实设备 HIL。
