# HIL manifest

scripts/run-matrix.sh 接受 UTF-8 TSV。首行可为注释，字段依次为：

1. id：只允许字母、数字、点、下划线和短横线；
2. mode：full 或 seek；
3. local_media：本地样片绝对路径；
4. MIME/contentType；不用时填 -；
5. codec：由 ffprobe 确认的输入 codec，作为报告标签；不用时填 -；
6. expected_profile：报告标签；不用时填 -；
7. bit_depth：报告标签；
8. expected_pixel_format：例如 PIXEL_FORMAT_NV12 或 PIXEL_FORMAT_P010LE；
9. require_device_hold：1 要求特权只读 observer 在同次采样中捕获记录的 setsid 会话内
   GPU 子进程的设备占用；无需该子进程携带 profile 或名为 chromium。
   PID 与启动时间必须匹配，外部会话、无 owner、跨样本关联均拒绝。0 仅豁免瞬时占用采样，
   不豁免与播放关联的硬件 CAPTURE/output 证据。

无论 HOLD 是 0 还是 1，特权观察完整性都是启动、监控和清理的强制门，不可豁免。

当前自动结果最多是 INCONCLUSIVE：尚无经过目标 Build ID 验证的硬件输出证据解析器。
第 8 列 format 文本命中、第 9 列为 0、EOS/非零帧均不能解除该限制。codec/profile/
bit_depth 仍是输入报告标签，不是硬件输出认证。INCONCLUSIVE 与 FAIL 都返回非零，
矩阵保留 result.tsv 的具体状态并以失败退出；不能按退出码 0 的旧假设补写 PASS。

示例：

    # id	mode	local_media	mime	codec	profile	bit_depth	pixel	hold
    h264-high	full	/abs/h264-high.mp4	video/mp4;codecs=avc1.64001F	H264	high	8	PIXEL_FORMAT_NV12	1
    hevc-main10	full	/abs/hevc-main10.mp4	video/mp4;codecs=hvc1.2.4.L93.B0	HEVC	main10	10	PIXEL_FORMAT_P010LE	1
    hevc-main10-seek	seek	/abs/hevc-main10.mp4	video/mp4;codecs=hvc1.2.4.L93.B0	HEVC	main10	10	PIXEL_FORMAT_P010LE	1

generate-fixtures.sh 会生成一份可直接使用的 manifest.tsv。先根据 probe-target.sh 的
运行结果删除不在能力交集中的行，或添加平台专用样片；不要把未执行的行标成通过。

矩阵的目标是能力覆盖，不是 profile 名字穷举。Chromium 的 H.264 profile 枚举没有
单独的 constrained-baseline/constrained-high 项，因此分别由它的 baseline/high
语义覆盖；报告同时保留 ffprobe 看到的真实 bitstream profile，不能把 alias 写成一条
额外的虚假 PASS。驱动没有广告的 codec，以及 Chromium 容器层不支持的格式，也应在
排除表中说明依据。
