# Chromium 硬件视频 HIL 判据

## 身份门

每轮测试都重新记录：

- Chromium 包版本、二进制版本和 ELF Build ID；
- 目标 OS、架构、kernel、glibc、Mesa；
- Wayland/X11 会话和 Chromium 实际启动 flags；
- 解码设备名称、广告 codec/profile/raw format；
- 测试样片的 SHA-256 与 ffprobe codec/profile/pixel format。
- CDP `SystemInfo.getInfo` 的 GPU feature status；若 `videoDecoding` 非空，同时记录其
  profile 与范围。部分 Linux V4L2 构建会返回空数组，空数组不能推翻实际设备/HIL
  证据。

旧报告只可用来设计场景，不能替代当前 Build ID 的运行证据。如果检测到已有用户
Chromium 或目标解码设备已被任何进程占用，停止测试，不要 kill、复用 profile 或与
另一个 HIL 并发争用设备。

## 所有权与失败关闭

- preflight 完成后才以 `mktemp -d /tmp/chromium-video-qa.XXXXXXXXXXXX` 创建 0700
  目录并写入随机 128-bit owner token。没有路径覆盖入口；本轮创建标志、精确路径、
  非 symlink 目录/owner/profile、owner token 必须同时匹配，才允许删除。
- Chromium 在独立 setsid 会话中启动，记录 session ID。清理检查整个会话与精确
  `--user-data-dir=` argv，不使用子串匹配或仅依赖进程名。启动状态不明、进程仍存活
  或所有权验证失败时保留目录并报告失败；脚本不向任何远端进程发送 kill。
- 使用 Chromium 的 `--remote-debugging-port=0` 和本轮 profile 的 DevToolsActivePort，
  不接受远端端口或附加 flags 覆盖。SSH 使用私有 control socket、
  `ExitOnForwardFailure=yes`；存活进程和 control-master ready 同时成立后才请求 CDP。
  本地端口冲突直接中止，不探测占据端口的浏览器。
- CDP version 中 browser WebSocket path 必须等于 DevToolsActivePort。连接后及关闭前
  都验证 `Browser.getBrowserCommandLine` 的唯一精确 profile 参数、启动 URL 和
  `--enable-automation`，并要求恰好一个页面，其 URL 与带 run token 的预期 URL 完全相同。
  URL 已导航、重复页面、其他 profile、无法读取 argv 都禁止发送协议 `Browser.close`。
  只对通过验证的浏览器关闭；未知实例仅调用 connectOverCDP 客户端的 Playwright
  `browser.close()` 断开连接。该行为与直接发送 CDP `Browser.close` 不同。
- 权限不再靠文档约定或 unprivileged fuser 的“空输出”判断。启动前、arm、ready、
  monitor、postclose 与删除前均调用固定只读 observer；它先证明观察权限，再生成完整
  样本。root 能力不完整、hidepid/subset、不同或嵌套 namespace、任一存活进程无法读取
  cmdline/stat/线程 fd/mappings 都返回 UNKNOWN。只有确认进程已消失才可忽略读取失败。
  sudo/SSH 失败、stderr、缺少完整样本、任意 owner 残留都不能通过；不杀外部 owner。

## 特权只读 Observer 的部署契约

`scripts/observer.py` 是需要管理员另行安装的源文件，本 skill 不自动部署或提权写入。
经当前请求明确授权后，管理员可将其安装为 root:root 0755 的
`/usr/local/libexec/chromium-qa-observer`；该文件及所有父目录不得为 symlink，也不得
允许 group/other 写入。使用绝对解释器 `/usr/bin/python3 -IB`（Python 3.10+ 标准库，
隔离模式且禁止 bytecode 写入），
目标不具备该路径时必须先进行经审查的系统集成，不能回退到用户可控制的解释器。
只允许测试用户无交互 sudo 执行这个固定 helper；不要授予通用 shell/python sudo 或
SETENV。浏览器与 remote-guard 拒绝 UID 0；sudo 只用于 proc/device 的读取和 namespace ioctl。

管理员还必须在真实 host 的初始 namespace 中建立 root:root 0644、非 symlink 的固定文件
`/etc/chromium-qa-observer.namespaces`，其全部父目录同样禁止 group/other 写入。内容依次是
host 的 `/proc/1/ns/pid`、`/proc/1/ns/user` 的 readlink 值和
`/proc/sys/kernel/random/boot_id`，三个 whitespace 分隔字段。不得在容器里采集后自称
host；重启后由管理员重新采集。该 root-owned 记录绑定观察目标，不提供路径覆盖入口。
缺失、过期、namespace/boot 不匹配都阻断。`NS_GET_PARENT` 返回 EPERM 可能表示父
namespace 不可见，因此绝不单凭 EPERM 或完整 uid_map 宣称已在 host 初始 namespace。

helper 不接受任意操作、任意文件路径、命令字符串或可信度覆盖变量。它不 delete、
kill、打开视频设备进行 I/O，也不读取 `.owner` 来授权 root 删除目录。
目录身份、token、创建标志、session 文件仍由普通用户的 remote-guard 校验；删除前
必须重新成功取得特权只读进程快照，失败则保留目录并写 FAIL。

运行时证明包括 EUID 0、隔离 Python、固定 root-owned 安装、完整初始 uid_map、
CAP_DAC_READ_SEARCH/CAP_SYS_PTRACE/CAP_SYS_ADMIN、root-owned host namespace/boot
记录匹配、NS_GET_PARENT 拒绝可见父 namespace，以及 observer、调用者、host init 的
PID namespace 一致。CAP_SYS_ADMIN
只用于 namespace 层级证明及受保护映射读取，helper 不修改 namespace 或系统配置。
拒绝 hidepid/subset proc 挂载；逐进程读取 stat/cmdline、所有线程的 fd 表和 map_files，
防止权限静默隐藏、线程私有 fd 表或关闭 fd 后仍存在的设备映射被当成空闲。
存活用户态进程的空 cmdline（非 kernel thread/已退出状态）和仍存在但目标被隐藏的
descriptor 也属于 UNKNOWN，不按“空输出”放行。
LSM 即使在 root/capability 门通过后仍拒绝读取，也会使整个样本 UNKNOWN。

preflight 的空基线以完整样本中没有 owner、没有已有 Chromium 为准。postclose 必须恢复
无 owner，并独立确认本轮 session/profile 进程为空。`probe-target.sh` 的 fuser 输出仅用于
能力发现时的诊断，不能作为运行/清理授权。读取是有时间跨度的采样，不是冻结全系统的
原子快照；检测到同一 PID 启动时间或 SID 变化也返回 UNKNOWN。

## Monitor 格式与 HOLD

每次 observer 输出完整、缓冲后的 TSV 样本：

```text
BEGIN  sample_id  pid_namespace  recorded_session
P      sample_id  pid  start_time  session  is_gpu  exact_profile_match  is_chromium
O      sample_id  pid  start_time
END    sample_id
```

实际字段分隔符是 tab，sample_id 是每次新生成的 UUID hex。缺少 END、未知行、跨样本
ID 或 owner 的 PID/start_time 未出现在同次 P 记录中，均判为不完整，不接受已有部分证据。
HOLD=1 必须在同次完整样本中找到 `P.session == recorded_session`、`is_gpu == 1`
且有匹配 O 记录的进程。is_gpu 来自精确 `--type=gpu-process` argv；不使用进程名或
profile 子串归属判断。无 profile 的 GPU child 可以满足占用门，外部 GPU/普通同组进程/
无 owner/复用 PID/跨样本匹配均不能满足。占用门通过仍不代表硬件输出 PASS。
停止 monitor 时只向本轮监控 shell 发送 TERM，等待当前有界采样完成后退出，不截断
正在读取的样本。每次采样上限 10 秒，超时/非零退出仍失败；记录 monitor.status，
异常退出不能凭先前的完整样本冒充观察成功。

## 能力集合

“支持的所有格式”定义为三个集合的交集：

1. 目标运行时通过 v4l2-ctl 或 GStreamer V4L2 element 广告；
2. 当前 Chromium 能解析容器和 codec；
3. 有可验证 profile、位深与 chroma 的样片。

按语义去重 profile 别名，例如 H.264 baseline 编码器通常实际产生 constrained
baseline。仅在 bitstream 约束确实不同且能生成样片时增加单独场景。

`generate-fixtures.sh` 的 constrained-baseline canonical 样片以 IDR 结束，用来隔离
profile/输出格式能力。若要验证 decoder drain，还应另加一个以 P 参考帧结束的合法
样片；后者失败必须单列为 EOS/drain 缺陷，不能反过来伪称 profile 完全不支持。

对每种压缩 codec 至少覆盖一个 8-bit 场景；若设备广告 10-bit/P010，还要覆盖对应
10-bit profile。矩阵至少产生一次 seek/重新协商场景。厂商压缩 raw format 若只能
作为 TRY_FMT candidate，应记录接受/拒绝结果；只有最终可渲染并输出时才算浏览器
输出覆盖。

## 每场景 PASS 条件

以下为完整 HIL 证明要求，不代表当前 runner 能自动满足。当前 runner **不会产生
硬解 PASS**：没有针对目标 Build ID、decoder/player 身份和播放时间段验证的
CAPTURE dequeue/output 采集器。其余门全部通过仍写 `INCONCLUSIVE`，退出码 1；
任何播放/探测/释放失败写 FAIL。保留 verbose log 供后续审查，不用初始化、TRY_FMT、
Chosen format、软件解码帧或未验证的 output 文本推断硬件输出。未来解除该限制前必须
提供真实目标日志/trace、格式语义和针对 init→fallback、零输出、无关 player 的回归。

- 页面到达 ended，而不是 media-error、play-error 或 timeout；
- duration/currentTime 合理，总帧和呈现帧非零；
- corruptedVideoFrames 为零；
- MediaCapabilities/canPlayType 结果被记录，但不能代替播放；
- 播放期间 /dev/video* 由 Chromium GPU 进程持有；
- manifest 中的样片 SHA-256、ffprobe codec/profile 与页面 URL 能绑定输入，Chromium
  日志中出现 V4L2 stateful decoder，并记录 TRY_FMT、Chosen CAPTURE format 和实际
  dequeue；
- 最终 PIXEL_FORMAT 与 manifest 期望一致；
- seek 场景产生 seeked，重新协商后仍到 EOS；
- CDP Browser.close 后无测试 Chromium、无 video 设备用户，runtime 恢复空闲。

若 `/sys/class/video4linux/videoN/device/power/runtime_status` 存在，场景开始前与结束后都
等待它回到 `suspended`，防止前一场景的 codec 状态污染后一场景；没有 runtime PM
节点的平台可将 `RUNTIME_STATUS_REMOTE=-`，仍必须验证进程和设备句柄释放。

单帧 still-picture 场景可能短到 observer 轮询无法采样；此时只有同时具备明确的 V4L2
初始化、CAPTURE dequeue/output 日志和页面帧证据，才可替代瞬时设备占用采样。

## 错误分类

- harness：URL 未引用、CDP/tunnel、样片丢失、测试依赖或脚本错误；
- unsupported：驱动、浏览器或样片集合没有交集；
- decode：媒体错误、零帧、损坏帧或错误 pixel format；
- graphics-import：解码成功但 dmabuf/ANGLE/Vulkan 导入失败；
- cleanup：测试进程、设备句柄、profile、tunnel 或临时目录残留。

保留首个错误，修复 harness 后从失败场景重跑；不要用后续成功掩盖首次失败。

## 产物

每个 scenario 至少保存：

- driver.json 与 driver.stderr；
- system-info.json（含 Chromium 的 videoDecoding profile 列表）；
- Chromium verbose log；
- 设备/process monitor；
- prelaunch/postclose 状态；
- playing/EOS screenshot（单帧场景至少 EOS）；
- manifest、probe 输出、样片 hash/ffprobe；
- 汇总表，明确 PASS、FAIL、INCONCLUSIVE、UNSUPPORTED、BLOCKED；当前自动硬解无 PASS。
- remote-root、DevToolsActivePort、CDP version、hardware-evidence 原因文本，以及
  preexisting/postclose observer 样本的 `.status` 与 `.stderr`、monitor.stderr/monitor.status。

## 隔离回归与边界

在仓库根执行 `node --test skills/chromium-video-qa/scripts/*.test.js`。
测试用例覆盖已有目录/路径穿越/错误 token/symlink/不明启动状态的拒删、存活 session
与 profile 进程的拒删、已有 Chromium 的 preflight 中止、真实本地端口冲突、
loopback HTTP/WebSocket CDP 上的精确 browser/profile/URL 关闭门、初始化/软件回退/
零输出/伪造 output 文本不可 PASS，以及 postclose owner/探测失败和进程残留。
SSH、SCP、媒体 driver 使用确定性本地替身；真实目标、视频设备和媒体解码均未执行。
WebSocket 测试使用最小 CDP fixture，不替代实际 Playwright+Chromium 的集成验证。
测试临时目录、子进程和监听 socket 在 finally 中回收。fixture 脚本仅供测试，禁止用作
真实 HIL transport。无 Node 外部依赖；Linux 侧需 bash、setsid、curl、timeout；
目标另需 sudo、固定路径的 root-owned observer 和隔离 Python 3.10+。
`test_observer.py` 用 pytest 的临时 proc fixture 和受控 I/O 错误验证权限门、cmdline
不可读与已消失的区别、线程 fd/map_files、PID 复用、hidepid、capabilities 和 namespace。
用 `bash skills/chromium-video-qa/scripts/test-observer.sh` 运行，包装器为每轮创建私有
pytest basetemp 并在退出时回收，不写 bytecode/cache，不使用真实 sudo 或视频设备。

未覆盖的 HIL：真实 Chromium 的 DevToolsActivePort/argv 行为、SSH forwarding、GPU
输出与 dmabuf 导入、CAPTURE 关联、目标 observer 的真实权限/LSM 可见性和 runtime PM。报告必须保留这些
缺口，不能用本地回归通过替代硬件支持结论。CDP/启动异常时可保留本轮浏览器和目录，
日志报告其位置，由操作者检查后处理；不自动 kill 以追求“清理成功”。

报告必须分别陈述：构建完成、包身份、部署状态、单元测试、HIL、清理状态。
