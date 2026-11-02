# Linux evidence 与报告

## 其他平台（手动）

可执行 harness 目前只覆盖 Linux。其他桌面/移动平台按下面的证据来源手动执行同一套
结论层级（能力上报、decoder 初始化、持续硬解、渲染、清理分别陈述），无法确认硬件
backend 时保持 INCONCLUSIVE：

- Windows：Firefox PlatformDecoderModule/MediaDecoder 日志、decoder 硬件标志、
  D3D11/DXVA device/texture 创建与失败、与 Firefox 进程关联的 GPU Video Decode engine
  计数器；必要时补充 ETW/GPUView。
- macOS：decoder 日志与硬件标志、VideoToolbox session/pixel buffer/IOSurface 输出、
  powermetrics 或 Instruments 中与被测进程关联的媒体/GPU 证据。
- Android：decoder 日志、MediaCodec codec 名、logcat、codec service 状态与页面时间线。

每个平台都要同时采集页面 EOS/帧/错误指标和设备或 surface 证据，并按 PID 与 decoder
实例关联；仅设备占用或初始化成功不能升级为硬件 PASS。

## Evidence allowlist

远端 `evidence.tar` 只能包含以下固定成员：

- `scenario.json`、`runtime.json`、`outcome.json`、`result.json`；
- `firefox.stdout`、`firefox.stderr`、`decoder-logs.tar`；
- `observe-before.jsonl`、`observe-during.jsonl`、`observe-after.jsonl`；
- `cleanup.json`。

本地另外生成 `probe.json`、`transport.json`、`timeline.json`、`verdict.json` 和 matrix
`summary.json`。`decoder-logs.tar` 只包含 run root 顶层、名称严格匹配
`decoder.log(.child-N).moz_log` 的 raw files。不得递归复制 profile，也不得收集 cookies、
Glean、sessionstore、history、cache、credentials 或用户 URL。

## Rootless snapshots

JSONL process record 包含 phase、completeness、PID/start time/SID、Firefox role、可见
`/dev/videoN`/`/dev/dri/renderDN` fd 和媒体 library maps。before/after 还记录可见的外部
device owners，但不记录它们的 argv。rootless 观察无法突破 hidepid/LSM；任何本次 session
的不透明状态使 cleanup 或 hardware evidence 非 PASS，不能用“空输出”当作空闲证明。

## 六轴 verdict

| 轴 | PASS | FAIL | INCONCLUSIVE |
|---|---|---|---|
| `hardware_path` | playback-correlated hardware chain 全部成立 | 明确 fallback/decode/import error | 缺任一正证据 |
| `rendering` | 有 RVFC frame，full/seek 达标并到 EOS | media/play error | frame callback、seek 后呈现或 EOS 不足 |
| `quality` | corrupted metric 明确为 zero | corrupted > 0 | metric null/undefined/API unavailable |
| `cleanup` | browser/session/profile/temp root 全部释放 | 残留或身份不符 | `/proc`/identity 不透明而保留 |
| `performance` | performance profile 且预声明 threshold 内 | 超过 threshold | 无 threshold 或 evidence profile instrumented |
| `overall` | 所有 required axes PASS | 任一 required axis FAIL | 否则 |

`droppedVideoFrames` 是 performance 数据，不是 corruption。没有预声明 threshold 时，即使
为零也不能把 performance 自动升级为 PASS。`corruptedVideoFrames=null` 必须保留为
quality INCONCLUSIVE。

preflight 发现可见外部 `/dev/videoN` owner 或本 UID process opacity 时，harness 写
`outcome.json`（`status=BLOCKED`）并以 exit 3 结束，不产生 verdict；报告必须原样列出该
BLOCKED 原因，不得把“未运行”写成 PASS。

## 报告要求

报告按 scenario 列出 Firefox/version/Build ID、media hash/ffprobe identity、trace profile、
tracking ID、decoder instance、RDD/device/maps、first/seek/terminal hardware PTS、DMA-BUF
import、页面 EOS/frame metrics、fallback、cleanup 和六轴 verdict。结论必须指向 raw evidence
位置，不以 grep count 代替 timeline。

首次失败与后续重试必须分别保留。共享设备 owner、rootless visibility 限制、缺失工具和
未执行的安装/部署/重启/系统修改应显式列出。机器 verdict 与叙述不一致时，以更保守的
结论为准并修复 harness；不得手工把缺失证据改成 PASS。

完成运行中的 Firefox 155.0.1 示例应报告：`hardware_path=PASS`、`rendering=PASS`、
`quality=INCONCLUSIVE`、`cleanup=PASS`、`performance=INCONCLUSIVE`、
`overall=INCONCLUSIVE`，原因分别是 corruption metric 为 null 且 dropped threshold 未预声明。
