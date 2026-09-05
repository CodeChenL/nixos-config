---
name: firefox-video-qa
description: >
  对任意桌面或移动平台上的实际 Firefox 构建执行视频解码 QA，区分能力上报、
  decoder 初始化、持续硬件解码、渲染、性能和软件回退。适用于验证硬件视频解码、
  codec/profile/位深矩阵、排查首帧后 fallback，以及对浏览器或媒体栈修改做真实播放
  验收；不负责未经授权的安装、部署、系统配置修改或电源操作。
---

# Firefox 视频解码 QA

目标是证明指定 Firefox 二进制在指定运行环境中完成了真实视频解码，而不是仅证明
`about:support`、MediaCapabilities、驱动枚举或 decoder 初始化成功。

执行 QA 时必须读取 [references/qa-procedure.md](references/qa-procedure.md)。确定目标
平台后，再读取
[references/evidence-and-reporting.md](references/evidence-and-reporting.md)，仅执行对应平台
小节。

## 证据门

按以下层次分别给结论，不得互相替代：

1. Firefox 能解析容器和 codec；
2. 浏览器和操作系统上报可用 decoder；
3. 目标 decoder 初始化成功；
4. 整个场景持续使用硬件 backend，没有重建为软件 decoder；
5. 页面实际呈现到目标时间或 EOS，帧数和错误指标合理；
6. 场景结束后测试进程、设备句柄、端口、profile 和临时文件被正确清理。

只有第 4、5、6 项同时成立，才可报告“硬件解码 QA 通过”。单帧硬件输出、短暂设备
占用、`IsHardwareAccelerated=true` 或 `Hardware Supported` 均不够。

## 执行原则

- 测试用户指定或当前实际使用的 Firefox 二进制，记录版本、Build ID、来源和实际加载
  的媒体库。不要用 Playwright 自带的定制 Firefox 代替被测系统 Firefox。
- 每个 codec/profile/位深场景使用新的 Firefox 父进程和隔离 profile，避免静态能力缓存、
  decoder 状态、service worker 或前一场景的崩溃恢复污染后续结果。
- 测试矩阵取“Firefox 可解析能力、平台运行时 decoder 能力、可验证样片”三者交集。
  不支持或缺样片的项目明确标为 `UNSUPPORTED` 或 `BLOCKED`，不得伪造 PASS。
- 为每个场景绑定样片哈希与解析结果；至少记录 codec、profile、位深、chroma、分辨率、
  帧率、时长和期望帧数。
- 同时采集页面、Firefox decoder 日志和平台硬件证据，并按 PID、decoder 实例和时间线
  关联。多进程日志可能交错，保留原始日志，不仅依赖 grep 计数。
- `ProcessFlush()` 可能来自 seek、EOS 或失败；只有结合 decoder error、
  `HardwareDecoderNotAllowed`、软件 decoder 重建或硬件设备提前释放，才能判为 fallback。
- 正确性通过后才测吞吐、CPU/GPU 占用、功耗或 dropped frames；性能指标不能证明解码
  backend 身份。

## 安全边界

- 默认不修改用户 profile、系统 Firefox、系统媒体库、浏览器策略、驱动或内核，不安装
  包，不重启、不登出、不刷写、不执行电源操作。需要这些动作时先取得当前请求的明确
  授权。
- 只终止本次 QA 创建、且能通过命令行和 profile 路径复核的精确父 PID；禁止使用
  `pkill firefox`、模糊进程匹配或终止已有浏览器/HIL。
- 测试前、中、后记录共享解码设备或 GPU 的其他使用者。若用户允许并行 HIL，可保留
  并发但必须标记污染窗口，并用全新 profile 重跑可疑失败；不得杀掉外部占用者。
- 凭据、cookie、用户 URL、私有媒体和 profile 内容不得进入报告。远端测试使用调用方
  已授权的连接方式，不把密码写入脚本或产物。
- 若媒体测试触发内核错误、设备失联或系统卡死，停止新增负载并按用户已有恢复流程
  处理；本 skill 不授予重启或断电权限。

## 交付

报告必须给出场景矩阵和原始证据位置，并分别陈述：运行时身份、能力上报、decoder
初始化、持续硬件解码、渲染结果、性能结果、重试/并发条件和清理状态。无法确认硬件
backend 时报告 `INCONCLUSIVE`，不要把软件播放成功写成硬解通过。
