# Firefox 视频解码 QA 流程

## 1. 建立身份和边界

每轮重新记录，不复用旧报告代替当前状态：

- Firefox 可执行文件的绝对路径、版本、Build ID、发行渠道和启动参数；
- OS、架构、内核、图形会话、显示服务器和远程/本地执行方式；
- Firefox 实际加载的媒体库及版本，而不是仅记录系统已安装包；
- 可用硬件 decoder、设备节点、驱动和平台 API；
- 是否有其他浏览器、转码任务或 HIL 正在共享解码器；
- 用户允许的操作，以及禁止安装、重启、kill、部署或改 profile 等边界。

在支持进程映射检查的平台，记录实际库路径。例如 Linux 可检查 RDD/GPU 进程的
`/proc/<pid>/maps`；其他平台使用对应的模块/映像检查工具。包版本不等于运行时库身份。

为本次运行建立精确的临时目录和 PID 清单。profile、日志、fixture 副本、自动化端口
和 tunnel 都要在创建前加入清理清单。

## 2. 建立能力矩阵

矩阵来自三个集合的交集：

1. Firefox 当前构建能够解析的 container/codec；
2. 当前平台在运行时提供的 decoder/profile/位深；
3. 有确定身份且可以合法使用的测试样片。

推荐字段：

| 字段 | 含义 |
|---|---|
| `id` | 稳定的场景名称 |
| `media` | 样片绝对路径或受控 URL |
| `sha256` | 样片内容身份 |
| `container` / `mime` | 容器和 MIME/codec string |
| `codec` / `profile` | bitstream 实际解析结果 |
| `bit_depth` / `chroma` | 位深和色度格式 |
| `size` / `fps` / `duration` | 解码负载 |
| `expected_frames` | 可比较的输入帧数 |
| `mode` | full、seek、loop、resolution-change 等 |
| `expected_output` | 平台相关的 raw/texture 格式，如 NV12、P010 |

使用 `ffprobe`、`mediainfo`、容器解析器或平台原生工具确认样片，不根据文件名猜 profile
和位深。若生成 fixture，在独立主机上生成并保留生成命令和哈希，不让被测解码路径同时
承担 fixture 生成。

普通正确性矩阵至少覆盖用户关心的每个 codec 的一个典型 8-bit 场景；平台广告 10-bit
时增加对应场景。seek、flush、EOS、分辨率变化和多流属于额外行为矩阵，按任务风险
选择，不为凑数量穷举 profile 名称。

## 3. 启动真实 Firefox

每个场景都启动新的被测 Firefox 父进程和新的 profile：

```text
firefox --no-remote --new-instance --profile <isolated-profile> <qa-url>
```

命令仅示意；按平台使用正确的可执行文件和参数。不得让自动化框架偷偷改用它自带的
Firefox。优先使用 Firefox Remote Agent/WebDriver BiDi、Marionette 或能够明确指定
被测二进制的 WebDriver。若 Playwright 只能驱动其定制 Firefox，则不要用它证明系统
Firefox 的媒体行为。

页面可以是受控的 loopback HTTP 页面或本地 fixture 页面。至少采集：

```js
const q = video.getVideoPlaybackQuality?.();
({
  currentTime: video.currentTime,
  duration: video.duration,
  ended: video.ended,
  readyState: video.readyState,
  networkState: video.networkState,
  errorCode: video.error?.code ?? null,
  errorMessage: video.error?.message ?? null,
  totalVideoFrames: q?.totalVideoFrames ?? null,
  droppedVideoFrames: q?.droppedVideoFrames ?? null,
  corruptedVideoFrames: q?.corruptedVideoFrames ?? null,
});
```

可用时用 `requestVideoFrameCallback` 记录呈现帧和 media time。MediaCapabilities、
`canPlayType()` 和 `about:support` 也要保存，但只能作为能力层证据。

等待媒体状态或 EOS，不使用固定睡眠代替状态判定。若目标是长测，则使用明确的播放
轮数、时长或帧数停止条件。

## 4. 收集 decoder 和平台证据

Firefox 的通用日志入口可从以下模块开始，并根据当前源码和平台增加实际存在的模块：

```text
PlatformDecoderModule:5
MediaDecoder:5
```

使用 FFmpeg 的 Linux 构建通常还需要：

```text
FFmpegVideo:5
FFmpegLib:5
Dmabuf:5
```

不要假定日志模块在所有版本和平台都同名；若没有输出，先核对当前 Firefox 源码或日志
模块注册，而不是把无日志解释为未使用硬件。

从日志中建立同一 decoder 实例的时间线：

```text
选择 backend
→ 初始化
→ 首包/首帧
→ 连续输出
→ seek/flush 或 EOS
→ shutdown
```

重点寻找：

- decoder 描述和进程位置（RDD、GPU、content、utility 等）；
- hardware accelerated 状态及其失败原因；
- packet/frame 错误、格式协商、surface/texture import；
- `HardwareDecoderNotAllowed` 或软件 decoder 重建；
- 首帧后硬件设备提前释放；
- 正常 EOS 与错误 flush 的顺序差异。

同时采集当前平台的硬件证据，具体选择见
[evidence-and-reporting.md](evidence-and-reporting.md)。设备占用只证明某进程打开了接口，
不能单独证明它持续解出了正在呈现的视频。

## 5. 判定场景

### PASS

同时满足：

- 页面无 media/play error，达到目标时间、帧数或 EOS；
- decoded/presented frame 数与 fixture 和场景合理一致；
- corrupted frame 为零，dropped frame 在事先声明的阈值内；
- decoder 日志和平台证据共同表明硬件 backend 持续工作；
- 没有在场景完成前重建为软件 decoder；
- 测试资源成功清理，共享设备恢复到基线或只剩测试前已有使用者。

### FAIL

包括 decode error、格式或 surface import 错误、首帧后软件回退、页面未前进、错误 EOS、
超出阈值的损坏/丢帧，或无法清理本次测试资源。

### UNSUPPORTED

能力交集明确为空，例如 Firefox 不支持容器、平台不广告该 profile，或输出格式无法被
当前 compositor 接受。必须给出所缺集合的证据。

### BLOCKED / INCONCLUSIVE

fixture、权限、显示会话、可观察性或共享硬件竞争使结论不可靠。播放软件成功不能把
此状态升级为硬件 PASS。

## 6. 重试和并发 HIL

先区分产品失败与 harness/环境失败。允许重试时：

1. 保存首次失败及其并发使用者、日志和时间戳；
2. 终止并清理本次创建的精确 Firefox 实例；
3. 使用全新 profile、日志前缀和 attempt ID；
4. 在干净窗口重跑，或明确记录用户允许的并发 HIL；
5. 报告首次失败和重试结果，不能用成功覆盖失败历史。

重试仅用于排除环境污染。相同产品错误稳定复现后应停止盲目重跑并进入根因调查。

## 7. 性能阶段

正确性 PASS 后再测：

- 实时倍率、启动延迟和 seek 恢复时间；
- 浏览器各进程 CPU 时间，而不是整机瞬时百分比；
- GPU/video engine、decoder utilization、频率和功耗；
- dropped/presented frames 与 compositor 丢帧；
- 多流、分辨率和帧率扩展点。

固定 governor、显示状态、窗口可见性和其他负载，或在报告中明确它们没有被控制。单纯
低 CPU 或 GPU 活跃都不能替代 decoder 身份证据。

## 8. 清理和最终复核

按创建清单逆序清理：

- 先核对父 PID 的命令行和隔离 profile，再终止该精确 PID；
- 等待其子进程退出，不使用模糊 `pkill`；
- 关闭本次创建的自动化端口、tunnel 和 loopback server；
- 删除精确的临时 profile、日志和 fixture 副本；
- 验证不存在本次 QA Firefox，设备句柄回到基线；
- 区分外部 HIL 占用和本次残留，不终止外部使用者；
- 若改过临时环境变量、偏好或策略，恢复并验证原值。

最终报告必须能让下一位执行者从二进制身份、fixture 哈希和原始证据重现同一结论。
