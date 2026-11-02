# Rootless-only 迁移回归记录

## 范围

本轮将 Chromium QA 的唯一运行模式迁移为 target-user rootless workflow。已删除旧 observer
实现、权限测试 wrapper、privilege mock 和旧 monitor 名称；没有保留 alternate privileged
path。没有连接目标、访问真实 video device、安装组件、构建浏览器或修改系统配置。

## TDD red

先替换/新增 rootless schema、安全和 matrix 测试，再修改 production code。初次定向执行中：

- 旧 parser 对全部 `ROOTLESS_OBSERVATION_V1` 用例失败；
- 去掉 privilege mock 后，旧 guard 的正常 cleanup 和 process residue 测试失败；
- missing/malformed result 仍退出 0，summary 会补写 PASS；
- production script 静态检查命中旧 helper command。

这些失败分别锁定 observation contract、rootless lifecycle、aggregation fail-closed 和无
privilege dependency 四个迁移目标。

## 已验证行为

| 场景 | 新行为 |
| --- | --- |
| traversal、错误 token、symlink owner/profile | 拒绝删除，外部 sentinel 保留 |
| launch pending、错误 session、PID reuse | identity gate 返回失败并保留目录 |
| live exact profile/SID residue | 不 kill；process 存活时拒删，退出后才允许删除 |
| profile prefix lookalike | 不按子串归属，允许安全删除本轮空目录 |
| ROOTLESS_OBSERVATION_V1 incomplete/duplicate/cross-sample/parent mismatch | parser fail closed |
| same-session GPU fd owner | `HW_PATH_OBSERVED`；outsider/non-GPU/no owner 不成立 |
| visible Chromium 或 device fd owner、设备节点不可读 | preflight `OVERALL_BLOCKED`，不 create/launch |
| 外部同 UID 进程不可读（non-dumpable KWin/polkit/sshd） | 记录盲区，不阻断 preflight/monitor/cleanup；`GLOBAL_IDLE_UNKNOWN` 不变 |
| 本轮 session/profile 或无法归类的 opacity | `HW_PATH_UNKNOWN`/`OWNED_CLEANUP_FAIL`，保留目录 |
| close 前 boot/PID/start/SID/profile identity 变化 | 不执行 Browser.close，目录保留，cleanup FAIL |
| postclose residue、本轮 opacity 或拒删 | `OWNED_CLEANUP_FAIL`，不发送外部 kill |
| missing/malformed/symlink/inconsistent result | matrix `OVERALL_FAIL`，不存在默认 PASS |
| 正常 rootless execution | `GLOBAL_IDLE_UNKNOWN`、`OVERALL_INCONCLUSIVE_ROOTLESS`、退出 1 |
| init/output-like log | 不升级 overall；明确 software fallback 为 FAIL |

## 无法读取同 UID 进程的语义

真实桌面（KDE）上 KWin、polkit agent 和 SSH session 进程通常是 non-dumpable 的：`/proc/PID/fd`
存在但 `readlink`/`stat` 返回 EACCES。rootless 模式必须把这类外部进程的不可读记录当作
"看不到"，而不是"不存在"或"必须阻断"：它不影响本轮 preflight、monitor 和 cleanup，但会在
报告中保留为观察盲区，并且 `GLOBAL_IDLE` 恒为 `GLOBAL_IDLE_UNKNOWN`。只有设备节点不可读、
可见冲突、本轮 session/profile 进程不可读或无法归类的不可读记录才阻断或失败。
`evaluate_processes`（shell）与 `scopes()`（Node）必须保持同一分类规则，`processes.test.js`
锁定两者的奇偶性。

## 结论边界

rootless observation 只能证明 target UID 可见的本轮 GPU/session process 曾持有 video fd，并
验证本轮 process/profile cleanup。它不能排除 other-UID hidden owner，所以 GLOBAL_IDLE 永远
UNKNOWN。当前还缺少 Build-ID-validated、playback-correlated CAPTURE/dequeue/output collector；
因此即使 playback、positive fd ownership 和 cleanup 都成功，也只能得到
`OVERALL_INCONCLUSIVE_ROOTLESS`，不能报告 overall hardware PASS。

最终隔离验证为 62/62 Node tests 通过；全部 shell 通过 `bash -n` 与 shellcheck，全部
JavaScript 通过 `node --check`，`git diff --check` 无错误。Markdown 未配置 LSP；shell、
JavaScript 和 YAML 的已修改文件没有 error/warning（CommonJS conversion hint 除外）。
