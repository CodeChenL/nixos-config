# Chromium rootless 视频 HIL 判据

## 身份与 preflight

每轮记录 Chromium 包版本、binary version、ELF Build ID、OS/kernel/glibc/Mesa、display
session、实际 flags、video device、广告 codec/profile/raw format，以及样片 SHA-256 和
ffprobe 信息。旧报告只能用于设计场景，不能替代当前 Build ID 的运行证据。

preflight 以 `TARGET_USER` 运行。它拒绝 UID 0，并扫描该 UID 可见的 procfs 与 `/dev/videoN`
fd：可见的已有 Chromium 或 owner 立即 `OVERALL_BLOCKED`，目标 video 节点不可读同样阻断，
不创建 run 目录、不 kill、不复用 profile。其他同 UID 进程不可读（例如 non-dumpable 的
KWin/polkit/sshd）不阻断，只记为观察盲区。其他 UID 可能隐藏，因此空的可见集合只表示
preflight 范围内没有冲突，不能声明 global idle。

## Run ownership

- `mktemp -d /tmp/chromium-video-qa.XXXXXXXXXXXX` 创建私有目录；随机 128-bit token、精确
  pathname、owner marker、目录 owner 和非 symlink profile 都必须匹配。
- `arm` 写 `.launch-pending`。Chromium 在独立 setsid session 启动后，`record` 等待精确
  `--user-data-dir=`，写入 `ROOTLESS_RUN_V1` 的 boot ID、PID、start time、SID、token 和
  profile，再清除 pending。pending、半写 identity、错误 token 或 PID reuse 都拒绝清理。
- `ready`、关闭前 `validate`、postclose process scan 和 `remove` 都重新读取 boot ID、
  PID/start/SID、exact profile 与 token。身份变化时不发送 `Browser.close`；未知/存活 residue
  时保留目录。远端浏览器和外部进程从不接收 signal。`snapshot` 允许浏览器自然退出后继续
  采集（postclose device 释放检查），但仍校验存活时的完整身份；`ready`/`validate` 仍是
  live 强制门。
- `--remote-debugging-port=0` 由 Chromium 选择端口。DevToolsActivePort 必须是本轮 profile
  的 regular non-symlink file，browser WebSocket path 必须精确匹配。SSH tunnel 使用私有
  control socket 和 `ExitOnForwardFailure=yes`；本地端口冲突时不探测已有服务。
- CDP 连接后与关闭前都要求唯一精确 `--user-data-dir=...`、`--enable-automation`、唯一 run
  URL 和恰好一个页面。wrong profile、URL prefix/substring、导航、重复页面或 argv opacity
  都不得发送协议级 `Browser.close`，只断开本地 CDP client。

## ROOTLESS_OBSERVATION_V1

每次采样独立版本化，tab-separated schema 为：

```text
ROOTLESS_OBSERVATION_V1
BEGIN  sample_id  boot_id  pid_namespace_label  target_uid  recorded_session
P      sample_id  pid  start_time  parent_pid  parent_start_time  session  exact_profile  is_gpu  is_chromium  fd_owner
U      sample_id  pid_or_zero  opacity_reason
END    sample_id
```

`sample_id` 是 32 位 hex，boot ID 和 PID namespace label 将样本绑定到目标启动实例及观察
视图。`P` 只描述 target UID 的可见进程；所有 boolean 是 `0/1`。GPU role 仅来自精确
`--type=gpu-process`，profile 仅接受完整 argv element，Chromium role 仅接受已知 executable
basename。fd owner 由同次读取的 character-device major/minor 匹配得到。读取前后必须保持
PID start/SID；重复 PID、parent start mismatch、跨 sample、缺 END 或未知 record 都使样本
无效。

`U` 保留 `device-unreadable`、`stat-unreadable`、`cmdline-unreadable`、`identity-changed`、
`fd-unreadable` 等 opacity，并按作用域分类：`pid 0` 是设备级；有同 sample `P` 记录且
`session == recorded_session` 或 `exact_profile=1` 的是本轮作用域；有 `P` 记录但两者都不
匹配的是外部作用域；没有对应 `P` 记录的无法归类。仍存在的同 UID 进程不可读时绝不解释为
absent。设备级、本轮和无法归类的 opacity 使 monitor `complete`/`hold`/cleanup 失败（保留
目录）；外部作用域是已记录盲区，与 `GLOBAL_IDLE_UNKNOWN` 一致，不阻断也不失败。监控停止
只通知本轮 monitor shell，等待当前有界 sample 完成；截断 sample、transport/stderr/nonzero
或上述 gap 都不能凭先前 sample 通过。

positive HW path 要求同一个完整 sample 中 `P.session == recorded_session`、`is_gpu=1`、
`fd_owner=1`。GPU child 不必携带 profile；parent/session identity 仍被记录并校验。该证据只
证明 run-owned visible process 持有 fd，不证明 CAPTURE output，也不排除 hidden other-UID
owner。`GLOBAL_IDLE` 因而固定为 `GLOBAL_IDLE_UNKNOWN`。

## 多轴 verdict

machine result 必须同时给出：

- `PLAYBACK_PASS`：页面到 EOS，duration/currentTime 合理，decoded/presented frame 非零，
  corrupted frame 为零；seek 场景还必须有 `seeked`。否则 `PLAYBACK_FAIL`。
- `HW_PATH_OBSERVED`：上面的 positive fd ownership；没有命中为 `HW_PATH_NOT_OBSERVED`；
  设备级、本轮或无法归类的 opacity 为 `HW_PATH_UNKNOWN`；明确 software fallback 为
  `HW_PATH_FAIL`。外部作用域 opacity 不阻止 `HW_PATH_OBSERVED`。
- `OWNED_CLEANUP_PASS`：经关闭前 identity gate 后完成 Browser.close，本轮 SID/profile process
  为空、可见 target device owner 释放、runtime PM（若存在）恢复，并安全删除 token 目录。
  residue、本轮或无法归类的 opacity、拒删为 `OWNED_CLEANUP_FAIL`；外部作用域不影响。
- `GLOBAL_IDLE_UNKNOWN`：rootless 模式恒定值，不能改成 PASS。
- `PLAYBACK_UNSUPPORTED`/`OVERALL_UNSUPPORTED`：页面在加载媒体元数据前报
  `MEDIA_ERR_SRC_NOT_SUPPORTED`（error 4），即当前浏览器构建不支持该容器/codec
  （例如 Chromium 152 的 HEVC）。该场景记入排除表，不算 FAIL；cleanup 仍需 PASS。
- `OVERALL_INCONCLUSIVE_ROOTLESS`：playback 与 owned cleanup PASS，HW path 为 OBSERVED 或
  NOT_OBSERVED，且无 definite failure。任一确定错误为 `OVERALL_FAIL`；preflight conflict 为
  `OVERALL_BLOCKED`。

所有 overall 状态均非零退出。runner 不存在 `OVERALL_PASS`，matrix 也不接受该值。

## Hardware output 上限

完整硬件输出证明还要求当前 Build ID、decoder/player identity 和播放时间窗口绑定的
CAPTURE dequeue/output collector，并验证最终 pixel format、frame output、dmabuf/import 和
fallback timeline。当前 runner 没有该 collector。因此 V4L2 initialize、TRY_FMT、Chosen
format、任意 output-like log、ENUM_FMT、MediaCapabilities 或 playback success 都不能升级
overall。明确 playback error、software fallback、wrong format（若由可信 output collector
确定）仍是 FAIL；证据缺失不是 PASS。

## 能力集合与产物

“支持的所有格式”是目标 runtime 广告、当前 Chromium 可解析格式和具备可验证 profile/
bit depth/chroma 样片的交集。每种压缩 codec 至少覆盖一个 8-bit 场景；广告 10-bit/P010 时
覆盖对应场景；矩阵至少包含一次 seek。still-picture 太短而没采到 fd owner 时只能写
`HW_PATH_NOT_OBSERVED`，不能由日志替代。

每个 scenario 至少保存 driver JSON/stderr、SystemInfo、Chromium log、rootless monitor、
preflight/postclose sample 及 status/stderr、runtime PM、截图、remote root、launch PID、
DevToolsActivePort、CDP version、hardware limitation reason 和十列 result。matrix 保存 manifest、
probe、fixture metadata 与包含五个 verdict axes 的 summary。

## 隔离回归

在仓库根执行：

```sh
node --test skills/chromium-video-qa/scripts/*.test.js
```

回归覆盖 path/token/root/profile symlink、launch pending、exact profile 与 SID residue、profile
lookalike、PID reuse、live identity record/validate、sample truncation/parent identity/opacity、
owner correlation、可见 preflight conflicts、cleanup retention、CDP browser/profile/URL/page gate、
close 前 identity change、缺失/畸形 result 和无远端 process kill。测试只运行 local mock、
普通用户子进程和 loopback HTTP/WebSocket，不连接目标、不执行真实 HIL。

未覆盖的 HIL 必须在报告中保留：真实 SSH forwarding、目标 Chromium/Playwright、实际 video
fd/CAPTURE、dmabuf/import、other-UID hidden owners、runtime PM 与 LSM/procfs 限制。rootless
回归通过不能替代硬件支持结论。
