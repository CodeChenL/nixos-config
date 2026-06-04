---
name: radxa-packager
description: Radxa Linux 内核 Debian 包编译打包工作流。
---

## 前置条件

| 项目 | 值 |
|------|-----|
| 核心约束 | 编译验证**只能**通过 `make deb`，禁止 minimal validation |
| 原因 | `debian/patches` 和 `Makefile` 包含必要操作 |
| 并发控制 | 必须使用 `flock`，同一时间仅允许一个 `make deb` 实例 |
| 运行方式 | **绝对禁止**以任何后台方式运行此 skill；必须前台同步运行并等待完成 |

## 调用方式

```sh
# 标准构建
./skills/radxa-packager/scripts/build.sh

# 清理后构建
./skills/radxa-packager/scripts/build.sh --clean

# 带测试构建
./skills/radxa-packager/scripts/build.sh --test

# 清理 + 测试
./skills/radxa-packager/scripts/build.sh --clean --test
```

脚本自动检测环境：在容器内直接执行 `make deb`，在 Host 上通过 `devcontainer exec` 执行。

## 脚本文件

| 文件 | 职责 |
|------|------|
| `scripts/build.sh` | 环境检测 + flock 并发控制 + make deb 构建 |

## 构建产物

生成在仓库上一级目录（`../`）：
- `linux-image-<version>_arm64.deb`
- `linux-headers-<version>_arm64.deb`
- `linux-libc-dev-<version>_arm64.deb`
- `*.changes`、`*.buildinfo`

## 版本检测

```sh
version=$(dpkg-parsechangelog --show-field Version 2>/dev/null || sed -n '1p' debian/changelog | sed -E 's/^[^ ]+ \(([^)]+)\).*/\1/')
```

## Makefile 目标

| 目标 | 说明 |
|------|------|
| `make deb` | 完整构建 Debian 包（主入口） |
| `make test deb` | 先运行测试再构建 |
| `make clean` | 清理构建产物 |
| `make dch` | 更新 debian/changelog |
| `make devcontainer_setup` | 安装容器内构建依赖（首次启动自动执行） |

## 约束

- `CUSTOM_DEBUILD_ENV` 默认 `DEB_BUILD_OPTIONS='parallel=1'`
- `debuild` 使用 `--no-lintian`，lintian 检查在 lintian-hook 中执行（error/warning 级别）
- 包签名已禁用（`--no-sign`）
- **绝对禁止**使用任何后台运行方式调用此 skill，包括 `run_in_background=true`、异步 task 或其他后台执行包装；必须前台运行并等待整个构建流程完成
