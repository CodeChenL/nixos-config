# 安全修复的隔离验证记录

## 第一轮命令与结果（历史）

- `node --test skills/chromium-video-qa/scripts/*.test.js`：31/31 通过，0 失败，退出 0，约 26 秒。
- `bash -n` 检查全部 5 个 shell 脚本；`node --check` 检查全部 6 个 JavaScript 文件，均退出 0。
- tmux 中执行 scenario `--help`：显示 9 参数 usage，退出 2，不接触目标。
- `ssh -G -o ControlMaster=no -o ControlPath=none -N -S /tmp/chromium-qa-validation.sock -M -o ExitOnForwardFailure=yes -o ControlPersist=no -L 127.0.0.1:19222:127.0.0.1:29222 localhost`：仅解析配置、不建立连接；确认 controlmaster true、exitonforwardfailure yes、独立 controlpath、loopback 转发和 controlpersist no。
- 修改后的 shell LSP 无诊断；JavaScript 无 error/warning，仅 CommonJS 风格 hint。
  Markdown 未配置 LSP，采用人工核对。

## 回归对应关系

旧行为来自本轮修改前通读的源代码；没有执行旧的危险删除或真实 Browser.close。
新行为由上述测试实际执行，不把预期判定或代码阅读冒充真实硬件验证。

| 旧漏洞场景 | 新执行结果 |
| --- | --- |
| REMOTE_ROOT 前缀接受已有目录、含 `..` 的路径，preflight EXIT 也触发删除 | 覆盖入口退出 2；已有合法形状目录无 owner、穿越、错误 token、symlink marker 均拒删；sentinel 保留 |
| Chromium preflight 或 fuser 异常仍可能清理用户指定目录 | preflight Chromium/设备 busy、stderr、设备丢失、SSH 错误、异常成功码均阻断，未发 create/remove |
| 仅 profile 子串筛选，进程或启动状态不明确也可清理 | 精确 argv/session 检查拒删；真实本地存活 profile/session 子进程未被 kill；不明 session 拒删 |
| 转发绑定失败后连接已有 CDP，再无条件 Browser.close | 真实占用 loopback 端口时 driver 未运行，已有 HTTP 服务收到零请求且保持监听 |
| 页面 URL 子串匹配允许其他 browser/profile/page 关闭 | HTTP browser ID 不匹配被拒；本地 WebSocket CDP 只有精确 profile+URL+唯一页面发出 Browser.close；其余仅断连 |
| 初始化后软件回退、无 CAPTURE 输出仍可能 PASS | 初始化、软件回退、无输出、未验证 output 文本四类，即使播放替身成功也都是 INCONCLUSIVE、退出 1 |
| postclose fuser 输出被保存但忽略 | owner 残留、stderr、返回 2/255、空输出但返回 0 均 FAIL；不发送任何远端 kill |
| 清理拒绝未写入 verdict | 保留目录、报告路径、result.tsv 写 FAIL |

## 未做与残余边界

未执行远端 SSH、真实视频设备操作、包安装、部署、构建或真实 Chromium/Playwright HIL。
场景集成测试替换 SSH/SCP/driver；关闭门测试通过真实 loopback HTTP/WebSocket 的最小
CDP fixture 调用生产所有权模块，浏览器页面列表由 fixture 提供，不等价于完整 Chromium。
所有测试临时目录、自己的子进程与 socket 都回收；无 index/history/commit/push 操作。

自动硬解 PASS 被有意关闭，直到目标构建有可信、播放相关的 CAPTURE/output 证据采集器。
本轮没有添加任意日志匹配规则来声称硬解成功。真实 SSH forwarding、DevToolsActivePort、
Browser.getBrowserCommandLine、CAPTURE/frame 关联、dmabuf、observer 权限/LSM 和 runtime PM
仍须独立 HIL。没有能够安全确认关闭的浏览器会被保留，不能把这种保留报告为清理成功。

## 第二轮：观察权限与 Session GPU 关联

红阶段命令：

```sh
node --test --test-name-pattern='incomplete observer sudo-denied|HOLD session correlation: gpu-child' skills/chromium-video-qa/scripts/scenario.test.js
```

修改前 0/2 通过：缺少可信 observer 的场景继续运行到退出 1，而不是 preflight 退出 3；
无 profile GPU child 的 HOLD 场景被误判为 FAIL。修复后两项均通过。

最终验证：

```sh
node --test skills/chromium-video-qa/scripts/*.test.js
nix-shell -p 'python3.withPackages (ps: [ ps.pytest ])' --run 'bash skills/chromium-video-qa/scripts/test-observer.sh'
```

- Node 48/48 通过，退出 0，约 49 秒；包含第一轮全部安全场景。
- Python 19/19 通过，退出 0；核心观察函数使用临时 proc/namespace/capability fixture。
- 全部 7 个 shell、10 个 JavaScript、2 个 Python 的语法检查通过。Python 使用 AST
  parse 而非生成 pyc，pytest 禁用 bytecode 与 cacheprovider。
  test-observer.sh 使用本轮 mktemp basetemp 和 EXIT 清理，避免共享 pytest 临时目录。
- 修改后的 shell/Python LSP 无诊断；JavaScript 无 error/warning，仅 CommonJS hint；
  Markdown 没有配置 LSP。

| 新场景 | 实际结果 |
| --- | --- |
| sudo 不可用、隐藏 process/owner、PID namespace 不匹配 | preflight 退出 3，未 create/arm/launch，driver 未运行 |
| 删除前 observer 不可信，普通用户观察结果为空 | 保留目录，拒绝删除 |
| postclose 才失去可信观察能力 | result.tsv 为 FAIL，目录保留 |
| 存活进程 cmdline 不可读或静默为空 | UNKNOWN；真正已消失的进程才忽略 |
| thread fd/map_files 不可读或 descriptor 目标隐藏 | UNKNOWN；线程私有 fd 与映射 owner 能被识别 |
| 缺 capabilities、hidepid、非初始 user/PID namespace、caller mismatch | 权限证明被拒绝 |
| NS_GET_PARENT 返回 EPERM，但 root-owned host/boot 记录不匹配 | 仍拒绝，不能把不可见父 namespace 当作初始 host |
| 环境变量自称 trusted 或提供其他 helper/proc 路径 | 生产 CLI 不接受该声明，退出 3，stdout 为空 |
| 记录 SID 中无 profile/进程名依赖的 GPU child 持有设备 | HOLD 门通过，总硬解仍 INCONCLUSIVE |
| outsider、同组非 GPU、无 owner、PID 复用、跨样本 owner | HOLD 拒绝或样本拒绝，总结果不能 PASS |

完整验证中还发现一次监控停止竞态。三个候选原因是停止时截断样本、没有取得首个样本、
fixture 中的进程读取失败；隔离重跑原用例通过，而确定性在途采样测试观察到 monitor
直接以 SIGTERM 退出，确认了停止语义缺陷。新增 `monitor.test.js` 在修复前失败，修复后
返回 0 且保留完整样本。现在只通知监控 shell 在当前有界采样结束后停止，保存 monitor
退出码；不重试失败测试、不放宽权限门、不忽略 UNKNOWN。

CLI 手工验证：tmux 中运行 monitor/observation 测试 7/7 通过、退出 0；普通用户直接
调用 observer 返回 `UNKNOWN: root and isolated no-bytecode Python required`、退出 3。

部署边界：本轮没有安装 `/usr/local/libexec/chromium-qa-observer`、创建真实 host scope
记录 `/etc/chromium-qa-observer.namespaces`、修改 sudoers、运行
真实 sudo 或远端/视频设备 HIL。固定 root-owned helper 必须由管理员另行授权部署，
缺少它时生产场景会阻断，而不是回退到不完整观察。只读 helper 不删除目录、不 kill，
普通用户的 token/创建标志仍是删除权限边界。Nix shell 仅临时提供本地 pytest 环境。
