---
name: radxa-kernel-deployer
description: 自动化将本地构建的 Linux 内核 `.deb` 包传输到 Radxa 设备并在远端安装与验证的可复用工作流。
---

## 前置条件

| 项目 | 值 |
|------|-----|
| 目标系统 | Debian/Ubuntu 系（需 `ssh`/`scp`/`sudo`/`apt`/`dpkg`） |
| 构建产物位置 | 上层目录 `../`，匹配 `linux-image*<version>*.deb` 和 `linux-headers*<version>*.deb` |
| 默认凭证 | 用户 `radxa`，密码 `radxa` |
| 安装的包 | 仅 `linux-image` 和 `linux-headers` 实包 |
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
| `scripts/deploy.sh` | 主入口：版本检测→定位包→传输→安装→验证→重启 |
| `scripts/helpers.sh` | 辅助函数：retry_scp、retry_ssh、sudo_remote、wait_for_device |

## 错误处理

| 场景 | 脚本内处理 |
|------|-----------|
| SCP 传输失败 | retry_scp 重试 3 次（指数退避 2s/4s/8s） |
| SSH 连接失败 | retry_ssh 重试 3 次（指数退避 5s/10s/20s） |
| sudo 无 tty | sudo_remote 强制 `ssh -tt` |
| dpkg 依赖冲突 | `apt -f install -y` 自动修复 |
| 重启后网络未恢复 | wait_for_device 轮询（10s/15s/22s/33s/49s） |
| 多主机部分失败 | 记录失败主机，继续其余部署，最终汇总报告 |

## 输出

- 传输/安装/验证的 stdout/stderr 日志
- 全部成功 exit 0，部分失败 exit 1 并列出失败主机
- 安装后 `dpkg -l` 和 `uname -r` 结果

## 约束

- **绝对禁止**使用任何后台运行方式调用此 skill，包括 `run_in_background=true`、异步 task 或其他后台执行包装；必须前台运行并等待整个部署、重启与验证流程完成
