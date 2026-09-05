# 平台证据与报告格式

只读取并执行当前目标平台对应的小节。工具缺失时选择已有的等价只读证据；不要为了
QA 擅自安装软件。

## Linux

先辨认 Firefox 实际选择的 backend，例如 FFmpeg/V4L2-M2M、VA-API、Vulkan Video、
软件 FFmpeg 或其他发行版模块。常用证据包括：

- RDD/GPU/content 进程的命令行、父子关系和已映射媒体库；
- `/dev/video*`、`/dev/dri/render*` 的测试前、中、后使用者；
- `v4l2-ctl`、GStreamer capability、`vainfo` 或等价运行时枚举；
- V4L2 format/source-change、queue/dequeue、DMA-BUF export/import 日志；
- VA-API/Vulkan device、surface 和 frame export/import 日志；
- 可用时的 runtime PM、tracepoint、debugfs 或性能计数器。

设备节点编号、驱动名、raw format、sysfs 路径和 compositor 均需运行时发现，不得写死
为某块板卡。`about:support` 的 Hardware Supported、wrapper 初始化成功和一次
`/dev/video` 占用都不是持续硬解证明。

Linux 多进程日志可能在同一行交错。按 PID 和 PTS 交叉核对页面 `OnVideoDecoded`、
VideoSink 和 backend frame 日志；保留原始文件，并在计数差异是日志拼接而非丢帧时
明确说明依据。

## Windows

辨认 Firefox 是否使用 Windows Media Foundation、D3D11/DXVA 或软件 decoder。组合：

- Firefox PlatformDecoderModule/MediaDecoder 日志；
- decoder description、硬件标志、D3D device/texture 创建与失败；
- Firefox 进程级 GPU Video Decode engine；
- 必要时使用 ETW、GPUView、Windows Performance Recorder 或厂商计数器；
- 页面帧、错误、EOS 和 fallback 时间线。

任务管理器中的 Video Decode 曲线只是佐证。必须关联到被测 Firefox 进程和播放窗口，
并排除其他浏览器或播放器。

## macOS

辨认 VideoToolbox/Apple decoder 与软件路径。组合：

- Firefox decoder 日志和硬件标志；
- VideoToolbox session、pixel buffer/IOSurface 输出和错误；
- Activity Monitor、`powermetrics` 或 Instruments 中与 Firefox 对应的媒体/GPU 证据；
- 页面帧、错误、EOS 和 fallback 时间线。

需要提权的工具必须先取得授权。仅看到低 CPU 或 IOSurface 不足以证明指定 codec 的
硬件 decoder 持续工作。

## Android 及其他平台

Android 通常关联 Firefox decoder 日志、MediaCodec codec 名、`logcat`、codec service
和页面证据。其他平台先从当前 Firefox 源码和运行时确定 backend，再选择对应的系统
观测工具；不要把某个平台的日志关键字或设备模型推广为通用规则。

## Fallback 判定

以下组合是强 fallback 证据：

```text
hardware decoder 初始化成功
→ 首包/首帧错误或 surface import 失败
→ flush/shutdown
→ HardwareDecoderNotAllowed 或 software decoder 初始化
→ 后续页面继续播放
```

以下事件单独出现时不能判 fallback：

- capability probe 创建并销毁 decoder；
- seek 或 EOS 时 `ProcessFlush()`；
- 一次 `IsHardwareAccelerated=false`，但无法关联到实际播放实例；
- 软件 decoder 与硬件 probe 的交错日志；
- 硬件设备仍被其他进程持有。

## 建议的报告表

| 场景 | Firefox/库身份 | 输入身份 | 能力 | backend 初始化 | 持续硬解 | 页面/EOS | 帧与错误 | 并发/重试 | 清理 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|

每个结论使用以下之一：

- `PASS`：持续硬件解码、渲染和清理全部成立；
- `FAIL`：产品或集成行为不满足场景；
- `UNSUPPORTED`：能力交集明确为空；
- `BLOCKED`：缺权限、fixture 或可用运行环境；
- `INCONCLUSIVE`：证据不足以区分硬件和软件。

报告末尾分别列出：

1. 已验证事实及原始证据；
2. 仅由能力表或源码推断、尚未运行验证的事项；
3. 首次失败与每次重试的差异；
4. 外部并发负载；
5. 未执行的安装、部署、重启或系统修改；
6. 清理后的进程、端口、设备和 profile 状态。
