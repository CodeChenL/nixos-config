---
name: radxa-kernel-deployer
description: 自动化将本地构建的 Linux 内核 `.deb` 包传输到 Radxa 设备并在远端安装、修复 DKMS 状态并验证的可复用工作流。
keywords:
  - radxa
  - deploy
  - kernel
  - dkms
  - ssh
  - scp
  - apt
  - deb
  - remote
---

## 前置条件

| 项目 | 值 |
|------|-----|
| 目标系统 | Debian/Ubuntu 系（需 `ssh`/`scp`/`sudo`/`apt`/`dpkg`） |
| 构建产物位置 | 上层目录 `../`，匹配 `linux-image*<version>*.deb` 和 `linux-headers*<version>*.deb` |
| 默认凭证 | 用户 `radxa`，密码 `radxa` |
| 安装的包 | 仅 `linux-image` 和 `linux-headers` 实包 |
| DKMS 状态 | 安装前后注册模块的并集，逐一核对每个目标 release/架构的 installed 状态；缺失时显式指定模块、版本、内核和架构修复 |
| 运行方式 | **绝对禁止**以任何后台方式运行此 skill；必须前台同步运行并等待部署与验证完成 |

## 调用方式

```sh
# 标准部署（安装后自动重启）
./skills/radxa-kernel-deployer/scripts/deploy.sh --hosts 192.168.1.100

# 自定义凭证
./skills/radxa-kernel-deployer/scripts/deploy.sh --hosts 192.168.1.100 --user myuser --password mypass

# 多主机部署（逗号分隔）
./skills/radxa-kernel-deployer/scripts/deploy.sh --hosts 192.168.1.100,192.168.1.101

# 不重启
./skills/radxa-kernel-deployer/scripts/deploy.sh --hosts 192.168.1.100 --no-reboot
```

脚本需在内核源码仓库根目录（含 `debian/changelog`）执行，构建产物须已在 `../` 中。

本机还需 `dpkg-deb`、`tar` 和 Bash 4+。文件名只用于筛选 `.deb` 候选，脚本通过包的
`Package`/`Version` 元数据核对包类型和 changelog 版本，再通过
`dpkg-deb --fsys-tarfile | tar -tf -` 读取 image 内的 `boot/vmlinuz-<release>` 或
`[usr/]lib/modules/<release>/`，得到实际目标 release。每个 release 必须有 headers 包内的
`usr/src/linux-headers-<release>/Makefile` 或 `[usr/]lib/modules/<release>/build` 匹配。
不能识别的实包、元包、缺失 headers、非法 release 或版本不匹配均在传输前失败；不会退回安装
`linux-libc-dev` 等其他包。Debian 包版本不等于内核 release，不能用版本文件名或远端 `uname -r` 替代。

传输使用支持 `scp -s` 的 OpenSSH 客户端及远端 SFTP 子系统，强制 SFTP，不回退到会经
远端 shell 展开路径的旧 SCP 协议。安装参数逐项编码，`sudo -S bash -c` 的命令整体再次编码；
空格、百分号、单双引号和 shell 元字符均作为路径数据传递，不作为命令执行。

`dpkg -i` 失败时仍允许 `apt -f install -y` 修复，但 apt 成功不代表部署成功：随后逐个查询
所选包的 `dpkg-query` 元数据，要求 `Package`、`Version` 精确一致，`Status` 必须为
`install ok installed`。目标包被 apt 删除、版本错误、仅 unpacked 或查询失败都会终止部署。
每个目标 release 还必须有非空 `/boot/vmlinuz-<release>`，以及 headers 根目录或
`[usr/]lib/modules/<release>/build/` 下存在的 `Makefile`；断链不能满足该项检查。
这仅验证 headers 的路径存在，不保证头文件完整、配置正确或任意外部模块可编译。
有注册 DKMS 模块时，另外要求这些模块的目标安装验证成功；无模块时不声称验证了可构建性。

DKMS 使用远端 `uname -m` 获取架构。安装前后的所有注册模块/版本（包括 added、built）均为
必须验证的集合；每个目标内核都要求对应架构的 `installed` 记录。缺失项执行
`sudo dkms install -m <module> -v <version> -k <release> -a <arch>`，然后重新读取状态，
逐项验证，旧内核记录、built 状态或仅非空输出不能算成功。已健康添加的目标记录不触发修复。
所有插入 DKMS 命令的参数先通过字符白名单检查。无 DKMS 或无注册模块时正常跳过；
探测/状态命令失败、未知格式或带警告的状态行会明确失败，不会假装没有模块。
支持现代 `module/version` 和旧版 `module, version` 状态格式。模块/版本并集是保守策略，
不自动判断哪个旧版本已被替代，也不静默忽略它们。若已注册旧模块版本不支持
新内核，部署会失败，需先由操作者清理不再需要的注册版本或修复其兼容性。

最终 SSH 查询失败会终止部署。默认重启时，重启命令仅允许成功或 SSH 断开（255），但断开
本身不是成功证据：必须等待设备可连接，再读取 `uname -r`，要求其精确属于包内容推导的目标
release 集合，并重新验证目标包和 image/headers 路径。等待超时、SSH 失败、旧内核或仅前缀匹配
均失败。`--no-reboot` 允许继续运行旧内核，不代表已验证新内核启动；脚本也不通过 boot ID
证明发生过一次新启动，只验证重启请求后的可达性、运行内核和包状态。

## 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--hosts` | 必填 | IP/hostname，逗号分隔 |
| `--user` | `radxa` | 远端用户名 |
| `--password` | `radxa` | 远端密码 |
| `--remote_dir` | `~` | 远端接收目录 |
| `--no-reboot` | - | 安装后不重启 |

## 脚本文件

| 文件 | 职责 |
|------|------|
| `scripts/deploy.sh` | 主入口：版本检测→定位包→传输→安装→DKMS 检查/修复→验证→重启 |
| `scripts/helpers.sh` | 辅助函数：retry_scp、retry_ssh、sudo_remote、wait_for_device |
| `scripts/installation.sh` | 精确包清单、安装参数编码、包/image/headers 验证及运行内核查询 |

## 错误处理

| 场景 | 脚本内处理 |
|------|-----------|
| SCP 传输失败 | retry_scp 重试 3 次（指数退避 2s/4s/8s） |
| SSH 连接失败 | retry_ssh 重试 3 次（指数退避 5s/10s/20s） |
| sudo 密码输入 | sudo_remote 使用 `ssh -T`，通过 stdin 传递给 `sudo -S` |
| dpkg 依赖冲突 | `apt -f install -y` 修复后仍须通过所有所选包的精确安装状态验证 |
| DKMS 失效 | 对每个缺失目标执行带 `-m/-v/-k/-a` 的 install；重新读取状态并逐项核对 installed，失败则不重启 |
| 重启后网络未恢复 | wait_for_device 轮询（10s/15s/22s/33s/49s） |
| 多主机部分失败 | 记录失败主机，继续其余部署，最终汇总报告 |

## 输出

- 传输/安装/验证的 stdout/stderr 日志
- 全部成功 exit 0，部分失败 exit 1 并列出失败主机
- 安装状态验证、当前 `uname -r` 和规范化的 DKMS 状态；失败输出具体包或 release

## 离线回归测试

```sh
bash skills/radxa-kernel-deployer/scripts/test-dkms.sh
bash skills/radxa-kernel-deployer/scripts/test-installation.sh
```

测试仅在临时目录创建包内容样本，通过 Bash 函数替换 `sshpass`、`dpkg-deb` 和
`dpkg-parsechangelog`，同步执行部署入口；不运行真实 SSH、SCP、sudo、安装或重启。
`test-transport.sh` 提供共享 mock；对 SSH/sudo 的嵌套命令实际启动隔离 shell 解码，再执行
mock dpkg/query 和临时目录路径检查。测试核对最终 dpkg argv 和无害注入哨兵没有被创建。
安装测试包含原有 DKMS 用例，并覆盖路径编码、apt 删除目标、精确包版本/状态、远端路径缺失、
最终 SSH 失败、重启等待失败、重启后错误内核和包状态变化。

## 约束

- **绝对禁止**使用任何后台运行方式调用此 skill，包括 `run_in_background=true`、异步 task 或其他后台执行包装；必须前台运行并等待整个部署、重启与验证流程完成
