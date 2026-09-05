# Firefox V4L2-M2M / FFmpeg DRM-PRIME 交接

日期：2026-09-04

用途：交给 OpenCode 继续完成 FFmpeg 打包、兼容性收敛和部署前验证。

## 1. 当前结论

Q6B 上 Firefox 155 的硬件视频能力上报正常，但 Ubuntu 主线 FFmpeg 8.0.1 与 Firefox
V4L2 backend 的帧输出契约不兼容：

```text
Ubuntu FFmpeg *_v4l2m2m
  -> 普通 NV12/P010 MMAP AVFrame

Firefox V4L2 path
  -> 无条件把 AVFrame.data[0] 当 AVDRMFrameDescriptor
  -> DMA-BUF 导入失败
  -> NS_ERROR_DOM_MEDIA_DECODE_ERR
  -> HardwareDecoderNotAllowed
  -> 软件 FFmpeg fallback
```

这不是 Iris 无法解码。标准 FFmpeg CLI/API 已经证明 Iris 可以连续执行 H.264 和 VP9
硬解；问题发生在 FFmpeg 向 Firefox 交付 frame 的用户态契约。

已在目标机上构建并通过 `LD_LIBRARY_PATH` 隔离加载 Raspberry Pi FFmpeg 8 的 stateful
V4L2 DRM-PRIME 实现，再补三个针对 VP9、空 capture buffer 和 P010 的修复。最终 Firefox
真实播放矩阵全部通过：

| codec | fixture | 硬件输出 | 软件输出 | fallback/error | 结果 |
|---|---|---:|---:|---:|---|
| H.264 High | 1920x1080 60 fps，5 秒 | 300 | 0 | 0 | PASS |
| VP9 Profile 0 | 1920x1080 60 fps，5 秒 | 300 | 0 | 0 | PASS |
| HEVC Main 8-bit | 1920x1080 60 fps，5 秒 | 300 | 0 | 0 | PASS |
| HEVC Main10 | 1920x1080 60 fps，5 秒 | 300 | 0 | 0 | PASS，P010 zero-copy |

本轮只完成隔离原型验证，没有生成生产 `.deb`，没有替换系统 FFmpeg，没有修改 Firefox
或内核。所有临时源码、库、fixture、profile 和日志已清理；需要按本文重新构建。

## 2. 最后确认的运行时身份

这些值是交接时的已验证快照，继续工作前必须重新确认：

| 项目 | 值 |
|---|---|
| 目标 | Radxa Dragon Q6B；最后使用 `radxa@192.168.31.175` |
| OS | Ubuntu 26.04 |
| Kernel | `7.0.11-6-qcom` |
| Firefox | 155.0 |
| Firefox Build ID | `20260826195058` |
| Firefox SourceStamp | `21a0961191033207dc167b842f6c251f337b0e54` |
| 系统 FFmpeg | `7:8.0.1-3ubuntu2` |
| 系统 ABI | `libavcodec.so.62`、`libavutil.so.60` |
| Decoder device | `/dev/video0`，`Iris Decoder` |
| Encoder device | `/dev/video1`，`Iris Encoder` |
| Iris DT compatible | `qcom,sc7280-venus` |
| Iris firmware | `qcom/vpu/vpu20_p1_gen2_s6.mbn`，Gen2 |

不要把此前的 Iris Gen1 `V4L2_BUF_FLAG_KEYFRAME == HFI_BUFFERFLAG_DATACORRUPT` 修复用于
本问题。Q6B 运行的是 Gen2，而且该 Gen1 修复已经存在于当前 kernel 历史。

## 3. 操作和所有权边界

- 当前 Linux kernel 仓库不是本问题的修复落点；不要修改
  `drivers/media/platform/qcom/iris` 来伪造 DRM descriptor 或 timestamp。
- 本地和 `src` 工作树已有大量用户改动，必须保留；不得 reset、checkout 或清理无关
  untracked 文件。
- Chromium 视频 HIL 可能并行运行。不得 kill、暂停或复用它的 profile；若共享 decoder
  造成可疑失败，保存首次证据并用全新 Firefox profile 重跑。
- 只能终止本任务创建、且命令行中能核对隔离 profile 的精确 Firefox 父 PID；禁止
  `pkill firefox`、`pkill chromium` 或宽泛匹配。
- 未经明确授权不得安装包、替换系统库、重启、断电、刷写、提交、push 或部署。
- 不要在文档、脚本或日志中写入 SSH 密码。目标地址也要在每次执行前重新确认。
- 如果设备出现内核错误、失联或卡死，停止新增负载，按用户已有的硬件恢复流程处理；
  本交接不授予电源操作权限。

## 4. 已确认的 Firefox 代码路径

Firefox 源码重点：

```text
dom/media/platforms/ffmpeg/FFmpegVideoDecoder.cpp
  ChooseV4L2PixelFormat()
  InitV4L2Decoder()
  InitHWCodecContext()
  DoDecode()
  CreateImageV4L2()

dom/media/platforms/ffmpeg/FFmpegVideoFramePool.cpp
  FFmpegDescToVA()
  NV12/P010 DRM descriptor import

dom/media/MediaFormatReader.cpp
  hardware decode error -> HardwareDecoderNotAllowed fallback
```

`ChooseV4L2PixelFormat()` 只接受：

```cpp
case AV_PIX_FMT_DRM_PRIME:
  return AV_PIX_FMT_DRM_PRIME;
```

`CreateImageV4L2()` 却没有先检查 `mFrame->format`：

```cpp
AVDRMFrameDescriptor* desc =
    reinterpret_cast<AVDRMFrameDescriptor*>(mFrame->data[0]);
```

主线 FFmpeg `v4l2m2m` 完成 source change 后直接根据 V4L2 capture format 设置
`avctx->pix_fmt`，没有调用 Firefox 安装的 `get_format` callback。因此 Firefox 不能靠
`ChooseV4L2PixelFormat()` 把主线 wrapper 强制成 DRM PRIME。

Firefox fallback 已从源码和日志同时确认：硬件 decoder 返回
`NS_ERROR_DOM_MEDIA_DECODE_ERR` 时，`MediaFormatReader` 设置硬件禁用，shutdown/seek 后以
`HardwareDecoderNotAllowed` 创建软件 decoder。硬件 wrapper 初始化成功不是 probe 噪声，
但也不是持续硬解成功。

## 5. 主线 FFmpeg 的实机证据

### 5.1 输出格式

用一个直接链接目标机 `libavformat.so.62`、`libavcodec.so.62`、`libavutil.so.60` 的原生
driver 解同一 H.264 fixture：

```text
Using device /dev/video0
driver 'iris_driver' on card 'Iris Decoder'
requesting formats: output=H264/none capture=NV12/yuv420p

FRAME format=nv12(23)
data[0]=<Y plane mapping>
data[1]=<UV plane mapping>
```

把 driver 的 `get_format` 改成仅选择 DRM PRIME 也没有任何 callback 日志；结果仍为
NV12。这证明主线 wrapper 并不实现 Firefox 所依赖的 DRM negotiation。

### 5.2 时间基是独立缺陷

Firefox 的 `DoDecode()` 把 packet PTS、DTS、duration 写成微秒，但 V4L2
`avcodec_open2()` 前没有设置：

```text
AVCodecContext.time_base=0/1
AVCodecContext.pkt_timebase=0/1
```

主线 FFmpeg 因而把 capture timestamp 转回：

```text
AV_NOPTS_VALUE = -9223372036854775808
```

通过拦截 Firefox `FFmpegRuntimeLinker` 使用的 `PR_FindSymbol("avcodec_open2")`，只为
V4L2 wrapper 设置 `{1, 1000000}` 后：

```text
未设置：V4L2 first frame pts=AV_NOPTS_VALUE -> fallback
已设置：V4L2 first frame pts=0              -> 仍 fallback
```

所以缺失 timebase 确实是 bug，但不是 NV12/DRM 导入失败的根因。若选择 Firefox 普通
AVFrame copy fallback 路线，需要同时修 timebase；Raspberry Pi stateful wrapper 使用
内部 tracking number 保存并恢复 PTS，不依赖此 Firefox 修复。

### 5.3 Main10 的主线 FFmpeg 问题

系统 FFmpeg 对 HEVC Main10 最初请求 NV12，Iris source change 后实际给出：

```text
capture: P010
1920x1088
bytesperline=3840
sizeimage=6266880
```

由于 `v4l2_fmt.c` 缺少 P010 映射，随后产生 invalid AVFrame。Firefox 表现为首包
`ENOMEM` 或首帧后 fallback。这同样属于 FFmpeg 用户态格式映射，不应在 Iris 中修。

## 6. DRM-PRIME 正向对照

Firefox V4L2 支持来自 Mozilla Bug 1833354，实际契约与 Raspberry Pi FFmpeg 下游实现
一致：

- Mozilla：<https://bugzilla.mozilla.org/show_bug.cgi?id=1833354>
- Raspberry Pi stateful rework：
  <https://github.com/jc-kynesim/rpi-ffmpeg/commit/687ebb9a0d0f1e388c956ff5047f8ad35d24edd2>
- 验证使用分支：`jc-kynesim/rpi-ffmpeg` `dev/8.0/rpi_import_2`
- 验证基线 HEAD：`7320480555b2a7d6477c24349a655995617d6acb`

该实现增加：

```text
V4L2 capture MMAP
  -> VIDIOC_EXPBUF
  -> DMA-BUF fd
  -> AVDRMFrameDescriptor
  -> AV_PIX_FMT_DRM_PRIME
  -> Firefox DMABufSurfaceYUV zero-copy import
```

注意：`V4L2 stateful rework` 依赖该 fork 历史中的 weak-link、dmabuf 等支持代码。不要
假定单独 cherry-pick `687ebb9a...` 就能干净应用到 Ubuntu 源码；应先审计依赖，或者把
该分支作为移植参考。生产落点仍应是 Ubuntu FFmpeg 打包源码，而不是安装 Raspberry Pi
的二进制包。

不得用 Raspberry Pi Debian 7.1.5 包覆盖 Ubuntu FFmpeg 8：前者是
`libavcodec.so.61`，后者是 `libavcodec.so.62`。

## 7. 在 FFmpeg 8 基线上验证通过的补丁

以下 diff 是在 `dev/8.0/rpi_import_2` 上的验证增量。格式和命名应按最终 Ubuntu 移植
结果调整，但语义和回归测试必须保留。

### 7.1 VP9 `vpcC` 不得拼入 elementary stream

Firefox 给 VP9 的 12 字节 extradata 是 codec configuration record。fork 原逻辑把所有
非 H.264 extradata 拼到第一个 V4L2 packet 前，导致首个 VP9 keyframe 无效。表现为
直到第二个 keyframe（PTS 2.133 秒）才输出第一帧。

```diff
--- a/libavcodec/v4l2_m2m_dec.c
+++ b/libavcodec/v4l2_m2m_dec.c
@@
-    if (avctx->codec_id == AV_CODEC_ID_H264)
+    if (avctx->codec_id == AV_CODEC_ID_VP9)
+        len = 0;
+    else if (avctx->codec_id == AV_CODEC_ID_H264)
         len = h264_xd_copy(src_data, src_len, NULL);
     else
         len = src_len < 0 ? AVERROR(EINVAL) : src_len;
```

红绿证据：

```text
修复前：first output PTS=2133000，随后 ENOENT/fallback
修复后：first output PTS=0，完整播放到 PTS=4983000，无软件重建
```

### 7.2 非 LAST、非 draining 的空 capture buffer 不是 EOS

错误 VP9 keyframe 曾使 Iris 返回：

```text
bytesused=0
flags=0x4041（包含 ERROR，不包含 LAST）
draining=0
```

fork 原逻辑把任何空 capture buffer 设为 `flag_last`，随后等待不存在的 EOS event：

```text
Buffer empty
-> V4L2 capture poll event timeout
-> VIDIOC_DQEVENT: ENOENT
-> avcodec_send_packet error -2
-> Firefox software fallback
```

验证增量：

```diff
--- a/libavcodec/v4l2_context.c
+++ b/libavcodec/v4l2_context.c
@@
-        // Zero length cap buffer return == EOS
+        // An empty capture buffer only signals EOS while draining or with LAST.
         if ((is_mp ? buf.m.planes[0].bytesused : buf.bytesused) == 0) {
-            av_log(avctx, AV_LOG_DEBUG, "Buffer empty - reQ\n");
+            av_log(avctx, AV_LOG_DEBUG,
+                   "Buffer empty - reQ (flags=%#x, draining=%d)\n",
+                   buf.flags, m->draining);
             ff_v4l2_buffer_enqueue(avbuf);
-            ctx->flag_last = 1;
+            if (m->draining)
+                ctx->flag_last = 1;
+#ifdef V4L2_BUF_FLAG_LAST
+            if ((buf.flags & V4L2_BUF_FLAG_LAST) != 0)
+                ctx->flag_last = 1;
+#endif
             return AVERROR(EPIPE);
         }
```

后续较新的 RPi 分支已有“ERROR 空 buffer 不直接当 EOS”的部分变化，但仍需审计其是否
会把空错误 frame 交给调用方。本次验证版本选择重新入队并跳过，最终 EOS buffer 为
`draining=1`、带 LAST，正常结束。

### 7.3 增加 V4L2 P010 映射

```diff
--- a/libavcodec/v4l2_fmt.c
+++ b/libavcodec/v4l2_fmt.c
@@
     { AV_FMT(NV12), AV_CODEC(RAWVIDEO), V4L2_FMT(NV12) },
+#ifdef V4L2_PIX_FMT_P010
+    { AV_FMT(P010), AV_CODEC(RAWVIDEO), V4L2_FMT(P010) },
+#endif
```

### 7.4 生成 P010 DRM descriptor

```diff
--- a/libavcodec/v4l2_buffers.c
+++ b/libavcodec/v4l2_buffers.c
@@
+    case AV_PIX_FMT_P010:
+        layer->format = DRM_FORMAT_P010;
+
+        if (avbuf->num_planes > 1)
+            break;
+
+        layer->nb_planes = 2;
+        layer->planes[1].object_index = 0;
+        layer->planes[1].offset = avbuf->plane_info[0].bytesperline *
+            avbuf->context->format.fmt.pix.height;
+        layer->planes[1].pitch = avbuf->plane_info[0].bytesperline;
+        break;
```

并在该 FFmpeg 8 fork 的 wrapper pixel formats 中加入 P010：

```diff
--- a/libavcodec/v4l2_m2m_dec.c
+++ b/libavcodec/v4l2_m2m_dec.c
@@
         .p.pix_fmts = (const enum AVPixelFormat[]) {
             AV_PIX_FMT_DRM_PRIME,
+            AV_PIX_FMT_P010,
             AV_PIX_FMT_NV12,
             AV_PIX_FMT_YUV420P,
             AV_PIX_FMT_NONE,
         },
```

修复后实机日志：

```text
Source change: Fmt: P010
HWFramesContext set to p010le, 1920x1088
DMABufSurfaceYUV::ImportPRIMESurfaceDescriptor FOURCC 30313050
```

`0x30313050` 为 `DRM_FORMAT_P010`。

## 8. 对外接口和兼容性要求

这些小补丁不需要改变 FFmpeg 的公开 C 函数签名、结构体布局、SONAME 或 symbol
version，但 DRM export 会改变 `*_v4l2m2m` 的可观察 frame 语义：

```text
主线默认：AV_PIX_FMT_NV12/P010，data[] 为 CPU plane
DRM 模式：AV_PIX_FMT_DRM_PRIME，data[0] 为 AVDRMFrameDescriptor
```

所以系统级交付必须做到 DRM PRIME 为明确协商后的 opt-in：

- Firefox 设置 `get_format` 并明确选择 DRM PRIME，应得到 descriptor；
- 没有明确请求 DRM PRIME 的普通调用者，应继续得到主线 NV12/P010 行为；
- 检查 RPi fork 在候选列表中优先放 DRM PRIME 是否改变默认 `get_format` 结果；必要时
  调整候选顺序或增加显式选项；
- 不要把“SONAME 未变”误当成行为兼容。

生产构建必须从 Ubuntu `8.0.1-3ubuntu2` 的完整 Debian 打包配置出发。此前的隔离原型只
启用了 H.264、VP9、HEVC 和对应 wrapper，用来验证机制，绝不能安装为系统库。

系统级包必须保持：

```text
libavcodec.so.62
libavutil.so.60
原有导出符号和 symbol version
Ubuntu 原有 decoder/encoder/parser/BSF/filter 与外部依赖
Ubuntu 安全更新和包拆分
```

至少比较：

```bash
readelf --dyn-syms old/libavcodec.so.62 > old.symbols
readelf --dyn-syms new/libavcodec.so.62 > new.symbols
objdump -T old/libavcodec.so.62
objdump -T new/libavcodec.so.62
abidiff old/libavcodec.so.62 new/libavcodec.so.62
abidiff old/libavutil.so.60 new/libavutil.so.60
```

还要比较 `ffmpeg -decoders`、`-encoders`、`-bsfs` 和包依赖，防止完整功能集缩水。

## 9. 建议 OpenCode 的实施顺序

### 阶段 A：建立独立 FFmpeg 打包工作树

1. 获取 Ubuntu `ffmpeg 8.0.1-3ubuntu2` 对应 source package；
2. 记录原始 source、Debian patch series、构建配置和二进制 ABI；
3. 保留当前 kernel 与 `nixos-config` 的无关 dirty 修改；
4. 调研 RPi stateful rework 的依赖提交，形成可审计 Debian patch series；
5. 先添加能在无硬件环境运行的格式/descriptor 单元验证，再构建完整包。

不要把 RPi 二进制包或本次最小测试库复制到系统目录。

### 阶段 B：Firefox 私有库验证

在系统级替换前，把完整配置构建的补丁库安装到私有目录，例如：

```text
/usr/lib/firefox-v4l2/
  libavcodec.so.62
  libavutil.so.60
```

只为隔离 Firefox 设置：

```text
LD_LIBRARY_PATH=/usr/lib/firefox-v4l2
```

真机已确认 Firefox RDD 会继承该路径。启动后必须检查 RDD/GPU 进程实际 maps，证明加载
的是私有库。不要修改用户默认 Firefox launcher 或 desktop entry，除非用户另行授权。

### 阶段 C：完整 QA

使用 `/home/chen/nixos-config/skills/firefox-video-qa`，至少覆盖：

- H.264 High 8-bit；
- VP9 Profile 0 8-bit；
- HEVC Main 8-bit；
- HEVC Main10/P010；
- seek/flush/EOS；
- 一次较长循环或持续播放；
- 默认 FFmpeg 调用者不请求 DRM 时仍得到普通 AVFrame；
- 明确请求 DRM 时得到有效 descriptor；
- FFmpeg CLI 普通软件解码和 V4L2-M2M；
- GStreamer `gst-libav`、Showtime，以及其他实际依赖系统 FFmpeg 的应用；
- V4L2 encoder，因为 RPi rework 修改了 decoder/encoder 共用文件；
- Chromium HIL 独立结果，并确认 Chromium 是否实际映射系统 `libavcodec`。

并行 Chromium HIL 导致失败时，保留首次结果，用新 profile 重试。不得通过 kill Chromium
获得“干净环境”。

### 阶段 D：决定是否系统级发布

只有以下项目都通过，才考虑替换 Ubuntu 系统 FFmpeg 包：

- ABI/symbol/config 功能集合无非预期变化；
- DRM PRIME 明确 opt-in，普通调用者行为保持；
- Firefox 四 codec 矩阵、seek/EOS 和长测通过；
- FFmpeg CLI、GStreamer/Showtime、encoder 回归通过；
- 清理和异常恢复通过；
- 用户明确授权安装或部署。

## 10. Firefox QA 判据

每个场景使用新的 Firefox 父进程和 profile。记录：

```text
Firefox binary/version/Build ID
RDD/GPU PID 和实际 libavcodec/libavutil maps
fixture SHA-256 与 ffprobe 身份
about:support / MediaCapabilities（仅能力证据）
页面 currentTime/duration/ended/error
getVideoPlaybackQuality
hardware decoder 初始化和连续 frame 日志
surface/texture import
软件 decoder 是否重建
设备使用者 before/mid/after
EOS 与 cleanup
```

PASS 必须同时满足：

```text
页面实际到 EOS/目标时间
帧数合理且 corrupted=0
持续 hardware decoder
没有 HardwareDecoderNotAllowed/software rebuild
没有 decode/format/import error
精确清理本次 Firefox、profile、端口和设备句柄
```

`about:support: Hardware Supported`、`V4L2 FFmpeg init successful`、单帧输出、低 CPU、
一次 `/dev/video0` 占用均不能单独判 PASS。

## 11. 已走过且不应重复的错误方向

- 不要为当前问题修改 Iris Gen1 command flags；目标是 Gen2。
- 不要把 `AV_NOPTS_VALUE` 当作唯一 fallback 根因；修复 timebase 后仍会因 NV12/DRM
  契约不匹配回退。
- 不要仅根据 Firefox 最后一个 `IsHardwareAccelerated=false` 判断整段播放；必须按 decoder
  实例和时间线关联。但本次 H.264/VP9/HEVC stock 路径确实发生首帧后软件重建。
- 不要把 wrapper 初始化成功或 `about:support` 能力上报当作端到端支持。
- 不要安装 RPi 7.1.5 包覆盖 Ubuntu 8.0.1。
- 不要部署最小测试构建；它缺少大量系统 codec 和外部功能。
- 不要在当前 kernel 仓库中保存 FFmpeg 生产补丁。

## 12. 交接时的干净状态

完成调查后已确认：

```text
无本任务 Firefox
无本任务 SSH tunnel/自动化端口
/dev/video0、/dev/video1 无本任务占用
Iris runtime_status=suspended
无 D-state 进程
无 drivers/media/platform/qcom/iris diff
系统 Firefox/FFmpeg 未修改
无安装、部署、重启、提交或 push
```

临时 RPi FFmpeg 源码、构建目录和日志已经删除。继续工作时以本文列出的 commit、Ubuntu
source package 和新建的 QA skill 为可重建入口，不依赖 `/tmp` 中不存在的文件。
