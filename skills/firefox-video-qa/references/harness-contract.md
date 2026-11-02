# Harness contract

## Canonical manifest v1

manifest 是 UTF-8 JSON object：`{"schema_version":1,"scenarios":[...]}`。每个 scenario
必须且只能包含以下字段：

```json
{
  "id": "hevc-main10-seek",
  "mode": "seek",
  "trace_profile": "evidence",
  "media_path": "/absolute/fixtures/hevc-main10.mp4",
  "sha256": "64-lowercase-hex",
  "mime": "video/mp4;codecs=hvc1.2.4.L93.B0",
  "container": "mp4",
  "codec": "hevc",
  "profile": "Main 10",
  "bit_depth": 10,
  "chroma": "4:2:0",
  "width": 1280,
  "height": 720,
  "fps": 30.0,
  "duration": 6.0,
  "expected_frames": 180,
  "expected_output": "P010",
  "seek_target": 4.0,
  "dropped_threshold": null
}
```

`id` 匹配 `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`。`mode` 为 `full|seek`；full 的
`seek_target` 必须为 null，seek 必须为正数。`trace_profile` 为
`evidence|performance`。路径必须绝对且 normalized，不允许 symlink media。输出为
`NV12|P010|P010LE`。所有数字为正数，dropped threshold 可为 null 或非负整数。

## Page result v1

POST body 固定包含 scenario/token/mode、terminal state、current/duration、presented frames、
post-seek presentation、RVFC callbacks、capabilities、quality 和 error。每个 quality metric
编码为 `{"state":"unavailable|null|zero|nonzero","value":null|N}`；state/value 必须一致。
callbacks 最多 10000 项。server body 默认最多 1 MiB，只允许 exact scenario/mode/token，
且 `result.json` 只能原子创建一次。

## Timeline v1

`timeline.json` 保留按原始日志 sequence 排序的关键事件，并输出 playback tracking IDs、
RDD decoder instances、全部 hardware PTS 及 hardware chain booleans。raw logs 永远保留在
`decoder-logs.tar`；normalized timeline 不替代 raw evidence。

## Preflight 与 process identity

远端在创建 profile、启动 Firefox 前先做 rootless `before` snapshot。可见外部 process 持有
`/dev/videoN`，或本次 UID 存在无法读取 identity 的 opaque process，都产生
`outcome.json` `status=BLOCKED` 并以退出码 3 结束，不启动浏览器、不发送任何 signal。
`/dev/dri/renderD*` 只表示 render node，不阻断 decoder preflight。

Firefox parent identity 除 boot ID、PID、start time、profile、token、SID、PGID 外，还固定
实际 `/proc/<pid>/exe` 路径和该 ELF 的 GNU Build ID（`.note.gnu.build-id`）。TERM、KILL、
删除前都重新读取 exe 与 Build ID；任何不匹配都拒绝信号和删除并保留 run root。

## Trace profile 与退出码

`evidence` profile 使用 0.1s monitor 间隔和完整 decoder/FFmpeg/libva/DMA-BUF log；
`performance` profile 使用 1.0s 间隔和更低日志量，但其 timing/dropped 数据仍需预声明
threshold 才能 PASS。退出码：`0` 仅当 `overall=PASS`；`3` 为 preflight BLOCKED；
其余非零为 FAIL/INCONCLUSIVE/harness 错误。退出码不覆盖 `verdict.json` 的具体原因。

## Transport 与 cleanup

所有 SSH command 使用 argv 构建、`ssh -n`、`BatchMode=yes`、有界 connect timeout，且不
通过 stdin 发送 manifest。SCP 只传固定 harness files、当前 scenario media/manifest 和
单个 allowlisted evidence archive。目标、token、remote root 都先匹配严格 grammar。

每场景一个随机 root、token、Firefox parent、profile 和 session。没有任何 `pkill`、process
name kill、recursive evidence copy 或外部 owner kill。身份不完整时保留 remote root；
`transport.json.remote_directory_retained=true` 是清理失败证据，不是可忽略 warning。

Python implementation 位于 `firefox_qa/` package。`scripts/*.sh` 只计算 skill root、设置
固定 `PYTHONPATH` 并调用 `python3 -m firefox_qa.<entrypoint>`，因此可从任意 cwd 运行。
远端只复制 `TRANSFER_FILES` 声明的 stdlib-only import closure，不复制 tests 或开发依赖。
