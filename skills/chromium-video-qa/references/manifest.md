# HIL manifest

`scripts/run-matrix.sh` 接受 UTF-8 TSV。首行可为注释，字段依次为：

1. `id`：字母、数字、点、下划线或短横线；
2. `mode`：`full` 或 `seek`；
3. `local_media`：本地样片绝对路径；
4. MIME/contentType；不用时填 `-`；
5. `codec`：ffprobe 确认的输入 codec；
6. `expected_profile`：输入报告标签；
7. `bit_depth`：输入报告标签；
8. `expected_pixel_format`：例如 `PIXEL_FORMAT_NV12` 或 `PIXEL_FORMAT_P010LE`；
9. `require_device_hold`：`1` 表示期望在同一个完整 rootless sample 中看到本轮 SID 的
   GPU process 持有目标 video fd；`0` 允许短样片没有命中轮询。

第 9 列只控制 positive ownership 是否是该场景的预期，不改变安全门。PID/start/SID 必须
在同次 `ROOTLESS_OBSERVATION_V1` sample 中关联；外部 SID、非 GPU、无 fd owner、PID reuse、
跨 sample 都不能产生 `HW_PATH_OBSERVED`。没有 positive observation 时写
`HW_PATH_NOT_OBSERVED`；设备级、本轮或无法归类的 opacity 写 `HW_PATH_UNKNOWN` 并失败；
外部同 UID 进程不可读只记为盲区（`GLOBAL_IDLE` 已固定 UNKNOWN），不影响判定。

示例：

```text
# id mode local_media mime codec profile bit_depth pixel hold
h264-high full /abs/h264-high.mp4 video/mp4;codecs=avc1.64001F H264 high 8 PIXEL_FORMAT_NV12 1
hevc-main10 full /abs/hevc-main10.mp4 video/mp4;codecs=hvc1.2.4.L93.B0 HEVC main10 10 PIXEL_FORMAT_P010LE 1
hevc-main10-seek seek /abs/hevc-main10.mp4 video/mp4;codecs=hvc1.2.4.L93.B0 HEVC main10 10 PIXEL_FORMAT_P010LE 1
```

实际文件使用 tab 分隔。`generate-fixtures.sh` 会生成可直接编辑的 `manifest.tsv`；先依据
`probe-target.sh` 删除不在能力交集中的行。codec/profile/bit depth 是输入标签，不是硬件
输出认证；第 8 列文本命中也不能替代 Build-ID-validated playback-correlated output evidence。

## 分辨率矩阵

标准生成命令的行为及 `manifest.tsv` 行保持不变。需要额外覆盖分辨率和帧率时使用显式开关：

```sh
RESOLUTION_MATRIX=1 scripts/generate-fixtures.sh OUTPUT_DIR
```

生成器会另外写出 `manifest-resolution.tsv` 和 `ffprobe-resolution.txt`。前者固定为 12 行：
`h264-high`、`vp9-profile0`、`vp9-profile2` 三个 family，分别覆盖 `1080p30`、
`1080p60`、`4k30`、`4k60`；对应尺寸为 1920x1080 和 3840x2160。ID 和文件名均为
`<family>-<tag>`，所有场景使用 `mode=full`、`require_device_hold=1`。`SHA256SUMS` 覆盖标准
和分辨率矩阵生成的全部 media。

VP9 Profile 2 保留在该矩阵中用于 capability/fallback 验证。先前目标上的 Chromium 152
会将其回退到 software，因此该行用于记录浏览器边界和防止误报，不表示预期 hardware
decode；仍应以当前 Build ID、驱动广告和实际播放证据裁决。

单场景 result 的十列依次为：`id`、`PLAYBACK_*`、`HW_PATH_*`、`OWNED_CLEANUP_*`、
`GLOBAL_IDLE_UNKNOWN`、`OVERALL_*`、codec、profile、bit depth、pixel。当前正常
overall 是 `OVERALL_INCONCLUSIVE_ROOTLESS`（退出 1）或能力交集外的 `OVERALL_UNSUPPORTED`
（浏览器构建不支持该容器/codec，matrix 记为 UNSUPPORTED 且不计失败）；`OVERALL_FAIL` 退出 1，
阻断退出 3。matrix 要求普通文件、恰好一行、十列、ID/标签/状态/退出码一致；缺失或
malformed result 写 `OVERALL_FAIL`，永远不补写 PASS。

矩阵目标是能力覆盖，不是 profile 名字穷举。Chromium 未单列的 constrained profile 应按
bitstream 语义归入对应 profile；驱动未广告、浏览器容器层不支持或没有合规样片的格式，
应在排除表中记录依据，不能写成已执行结果。
