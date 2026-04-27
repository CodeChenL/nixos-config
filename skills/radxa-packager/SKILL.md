---
name: radxa-packager
description: package radxa debian packages
---

## 编译与打包工作流

**核心原则**：编译验证**只能**通过 `make deb` 进行，不得使用最小化验证（minimal validation），因为 `Debian/patches` 和 `Makefile` 包含必要的操作与修改。

### 在 Host 上运行（使用 Dev Container）

当在 host 机器上执行编译/打包任务时，**必须**通过 devcontainer 执行，以确保构建环境一致性：

```sh
# 基本编译打包（带并发控制）
devcontainer exec --workspace-folder ./ bash -c "flock /tmp/.radxa-packager-make-deb.lock make deb"

# 如需先清理再构建（带并发控制）
devcontainer exec --workspace-folder ./ bash -c "flock /tmp/.radxa-packager-make-deb.lock bash -c 'make clean && make deb'"

# 仅测试验证（不生成最终包，带并发控制）
devcontainer exec --workspace-folder ./ bash -c "flock /tmp/.radxa-packager-make-deb.lock make test deb"
```

**说明**：
- `--workspace-folder ./` 指向当前仓库根目录
- devcontainer 镜像为 `mcr.microsoft.com/devcontainers/base:trixie`（Debian Trixie），内含 Nix/direnv/devenv 工具链
- 容器首次启动会自动执行 `make devcontainer_setup`（安装 crossbuild-essential-arm64、binfmt-support、qemu-user-static 等依赖）

### 在 Dev Container 内部运行

若已在 devcontainer 内部（如 VS Code Remote-Containers 或直接在容器 shell 中），直接执行：

```sh
make deb
```

### 并发控制（防止多个 make deb 同时运行）

**重要**：`make deb` 是资源密集型操作，多个实例同时运行会导致构建失败或系统资源耗尽。运行 `make deb` 前**必须**检查并等待其他实例完成。

#### 锁机制实现

使用 `flock` 命令实现文件锁，确保同一时间只有一个 `make deb` 实例运行：

```sh
# 使用 flock 获取锁，如果锁被占用则等待
LOCK_FILE="/tmp/.radxa-packager-make-deb.lock"
flock "$LOCK_FILE" bash -c 'make deb'

# 带超时的锁（等待 30 分钟，超时则失败）
LOCK_FILE="/tmp/.radxa-packager-make-deb.lock"
flock --timeout 1800 "$LOCK_FILE" bash -c 'make deb'

# 在 devcontainer 中使用
devcontainer exec --workspace-folder ./ bash -c "flock /tmp/.radxa-packager-make-deb.lock make deb"
```

#### 检查锁状态

```sh
# 检查是否有其他 make deb 正在运行
LOCK_FILE="/tmp/.radxa-packager-make-deb.lock"
if flock -n "$LOCK_FILE" true 2>/dev/null; then
    echo "No make deb running, safe to proceed"
else
    echo "Another make deb is running, waiting..."
    # 等待锁释放
    flock "$LOCK_FILE" bash -c 'echo "Lock acquired, starting make deb"; make deb'
fi
```

#### 在 Skill 中自动应用

当用户请求运行 `make deb` 时，**必须**使用以下模式：

```sh
# 标准模式（无限等待锁）
flock /tmp/.radxa-packager-make-deb.lock make deb

# 带超时模式（推荐，避免无限等待）
flock --timeout 1800 /tmp/.radxa-packager-make-deb.lock make deb
```

**锁文件位置**：`/tmp/.radxa-packager-make-deb.lock`
- 使用 `/tmp` 确保系统重启后自动清理
- 隐藏文件（`.` 前缀）避免意外删除
- 描述性命名避免与其他项目冲突

### 构建产物

`make deb` 完成后，`.deb` 包会生成在**仓库的上一级目录**（`../`），形如：
- `linux-image-<version>_arm64.deb`
- `linux-headers-<version>_arm64.deb`
- `linux-libc-dev-<version>_arm64.deb`
- `*.changes` / `*.buildinfo` 文件

### 版本检测

从 `debian/changelog` 读取版本号：

```sh
version=$(dpkg-parsechangelog --show-field Version 2>/dev/null || sed -n '1p' debian/changelog | sed -E 's/^[^ ]+ \(([^)]+)\).*/\1/')
```

### 相关 Makefile 目标

| 目标 | 说明 |
|------|------|
| `make deb` | 完整构建 debian 包（推荐） |
| `make test deb` | 先运行测试再构建 |
| `make clean` | 清理构建产物 |
| `make dch` | 更新 debian changelog |
| `make devcontainer_setup` | 安装容器内构建依赖 |

### 注意事项

- `CUSTOM_DEBUILD_ENV` 默认设置 `DEB_BUILD_OPTIONS='parallel=1'`，如需并行构建可覆盖此变量
- `debuild` 使用 `--no-lintian` 但会在 lintian-hook 中运行 lintian 检查（error/warning 级别）
- 包签名已禁用（`--no-sign`）
