---
name: radxa-kernel-deployer

description: 自动化将本地构建的 Linux 内核 `.deb` 包传输到 Radxa 设备并在远端安装与验证的可复用工作流。
---

**特性**：
- 自动从 `debian/changelog` 检测版本
- 传输/SSH 连接自动重试（指数退避）
- sudo 命令默认使用 `ssh -tt` 避免 tty 问题
- 设备重启后自动等待恢复（指数退避轮询）

范围与假设
--
- 作用域：工作区级（保存于仓库内，供本地 agent 使用）。
- 默认远端用户名：`radxa`。
- 默认远端密码：`radxa`（若不正确，agent 会提示用户输入或建议使用 SSH key）。
- 假设目标设备运行 Debian/Ubuntu 系列，支持 `ssh`/`scp`、`sudo`、`apt`、`dpkg`。
- 假设构建产物位于上一层目录（`..`），通常形如 `../linux-*-<version>_*.deb`，且仅上传/安装 image 与 headers 实包。

输入（可选参数）
--
- `hosts`: 单个 IP/hostname 或逗号分隔的主机列表。首个主机在本会话内使用后会被记为默认主机，后续操作可省略再输入。
- `user`: 远端用户名（默认 `radxa`）。
- `password`: 远端密码（默认 `radxa`）。
- `remote_dir`: 远端接收目录（默认 `~`）。
- `reboot_after_install`: 是否在安装后自动重启（默认：`true`，安装完成后自动重启）。

重要：版本检测与包匹配
--
为了避免包含虚包（metapackages）或错误版本，推荐从仓库的 `debian/changelog` 中读取版本号并据此定位上层目录中的真实 `.deb` 文件。

示例（Shell 片段，用于从 `debian/changelog` 读取版本并在上层目录匹配 image/header）：

```sh
# 提取版本（优先使用 dpkg-parsechangelog，若不存在用 sed 回退）
if [ -f debian/changelog ]; then
  version=$(dpkg-parsechangelog --show-field Version 2>/dev/null || sed -n '1p' debian/changelog | sed -E 's/^[^ ]+ \(([^)]+)\).*/\1/')
else
  echo "debian/changelog 未找到，请指定版本或把 .deb 放到可查找的位置。"
  exit 1
fi

# 在上层目录查找 image/header（优先精确前缀，若未找到则回退到通配匹配）
image_deb=$(ls ../linux-image*"${version}"* 2>/dev/null | head -n1 || true)
header_deb=$(ls ../linux-headers*"${version}"* 2>/dev/null | head -n1 || true)
if [ -z "$image_deb" ] || [ -z "$header_deb" ]; then
  # 回退：任意包含版本号的 linux-*.deb
  fallback=$(ls ../linux-*"${version}"* 2>/dev/null | tr '\n' ' ')
  if [ -z "$fallback" ]; then
    echo "未在上一层目录找到匹配版本 ${version} 的 .deb 文件。"
    exit 1
  fi
  echo "找到回退匹配： $fallback"
  debs=( $fallback )
else
  debs=( "$image_deb" "$header_deb" )
fi

echo "将部署以下包： ${debs[*]}"
```

输出
--
- 传输与安装的 stdout/stderr 日志。
- 成功/失败状态码与建议的下一步操作。
- 安装后验证结果（`dpkg -l`、`uname -r` 等）。

工作流步骤（逐步）
--
1. 从 `debian/changelog` 读取版本号（见上方片段），构建用于匹配上层目录 `.deb` 的 glob。
2. 在上层目录（`..`）定位 image/header 实包；优先查找 `linux-image*${version}*` 与 `linux-headers*${version}*`，若未找到则回退到包含版本号的 `linux-*${version}*`。
3. 验证包（可选）：`sha256sum`。
4. 将包传到远端（示例，仅 image 与 headers）

```sh
# 使用重试函数传输（推荐）
retry_scp ../linux-image*"${version}"* ../linux-headers*"${version}"* ${user}@${host}:${remote_dir}

# 备选：常规（交互式）方式
scp ../linux-image*"${version}"* ../linux-headers*"${version}"* ${user}@${host}:${remote_dir}

# 备选：非交互（使用 sshpass，但不重试）
sshpass -p "${password}" scp -o StrictHostKeyChecking=no ../linux-image*"${version}"* ../linux-headers*"${version}"* ${user}@${host}:${remote_dir}
```

若出现 `Permission denied`：retry_scp 会自动重试 3 次，仍失败则提示用户检查网络/认证或改用 SSH key（`ssh-copy-id`）。

5. 在远端安装包

**推荐：使用 sudo_remote 函数（默认使用 -tt）**

```sh
INSTALL_CMD="echo ${password} | sudo -S dpkg -i ${remote_dir}/linux-image*${version}* ${remote_dir}/linux-headers*${version}* || (echo ${password} | sudo -S apt -f install -y)"
sudo_remote "${user}@${host}" "${INSTALL_CMD}"
```

**说明**：`sudo_remote` 默认使用 `ssh -tt` 强制分配伪终端，避免 sudo 因无 tty 而失败。

常见错误与自动处理：
- 依赖问题：`apt -f install -y` 自动修复

（可选）如果环境支持更安全的无密码 sudo 或 SSH key，优先使用那种方式以避免在命令行传递密码。

6. 安装后验证

```sh
ssh ${user}@${host} 'dpkg -l | grep linux-image'
ssh ${user}@${host} 'dpkg -l | grep linux-headers'
ssh ${user}@${host} 'ls -l /boot | tail -n 20'
ssh ${user}@${host} 'uname -r'
```

7. 重启设备并再次验证（默认：自动重启）

```sh
# 重启命令（自动处理 tty 问题）
sudo_remote "${user}@${host}" "reboot"

# 等待设备恢复（使用指数退避轮询）
wait_for_device "${user}@${host}"

# 重启后验证
sshpass -p "${password}" ssh -o StrictHostKeyChecking=no ${user}@${host} 'uname -r'
```

决策点与分支逻辑
--
- **SCP 传输失败**：自动重试最多 3 次（间隔 2s），仍失败则提示用户检查网络/认证。
- **SSH 连接失败**：自动重试最多 3 次（间隔 5s），支持跳过并记录失败主机。
- **sudo 安装失败（无 tty）**：默认使用 `ssh -tt` 强制分配伪终端，避免此问题。
- **包安装失败（依赖或冲突）**：自动执行 `sudo apt -f install -y`，仍失败则回退并报告错误。
- **设备重启后网络恢复**：使用指数退避轮询（初始 10s，最多 5 次，总计约 190s），避免过早探测导致 "no route to host"。
- **重启命令本身失败**：若 `sudo reboot` 因 tty 问题失败，自动使用 `ssh -tt` 重试。
- 架构不匹配：在远端先运行 `dpkg --print-architecture`，若与包 arch 不符则中止。
- 会话主机记忆：首次在本会话中指定 `hosts` 后，agent 会把此主机设为本会话默认目标，后续操作可省略 `hosts` 参数。
- 自动重启策略：默认启用自动重启；如需禁用，请在调用时传入 `reboot_after_install=false`。

---

**重试命令模板（可直接嵌入脚本）**

```sh
# === SCP 传输重试 ===
retry_scp() {
  local max_attempts=3
  local delay=2
  for i in $(seq 1 $max_attempts); do
    if sshpass -p "${password}" scp -o StrictHostKeyChecking=no "$@"; then
      return 0
    fi
    echo "[SCP] 第 ${i} 次尝试失败，等待 ${delay}s 后重试..."
    sleep $delay
    delay=$((delay * 2))  # 指数退避
  done
  echo "[SCP] 重试 ${max_attempts} 次后仍失败"
  return 1
}

# === SSH 连接重试 ===
retry_ssh() {
  local max_attempts=3
  local delay=5
  for i in $(seq 1 $max_attempts); do
    if sshpass -p "${password}" ssh -o StrictHostKeyChecking=no "$@"; then
      return 0
    fi
    echo "[SSH] 第 ${i} 次尝试失败，等待 ${delay}s 后重试..."
    sleep $delay
    delay=$((delay * 2))
  done
  echo "[SSH] 重试 ${max_attempts} 次后仍失败"
  return 1
}

# === 远端 sudo 命令（默认使用 -tt 强制伪终端）===
sudo_remote() {
  local host="$1"
  local cmd="$2"
  # 默认使用 -tt 强制分配伪终端，避免 sudo 因无 tty 而失败
  sshpass -p "${password}" ssh -tt -o StrictHostKeyChecking=no "${host}" "bash -lc '${cmd}'"
}

# === 设备重启后等待恢复 ===
wait_for_device() {
  local host="$1"
  local max_attempts=5
  local delay=10
  for i in $(seq 1 $max_attempts); do
    if sshpass -p "${password}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${host}" "echo ok" > /dev/null 2>&1; then
      echo "[wait_for_device] 设备已恢复（第 ${i} 次尝试）"
      return 0
    fi
    echo "[wait_for_device] 等待设备上线...（${i}/${max_attempts}，${delay}s）"
    sleep $delay
    delay=$((delay + (delay / 2)))  # 递增退避
  done
  echo "[wait_for_device] 设备在 ${max_attempts} 次尝试后仍无响应"
  return 1
}
```

常见问题与排查提示
--
- `dh: error: Unknown sequence .github/local/rules.local`：这是打包日志中出现的仓库特定警告/错误，若包最终生成并进入 `.deb`，部署步骤可继续；若打包失败，应检查 `debian/rules` 中是否包含不兼容的 include，并在打包时修正。
- `Permission denied`（scp/ssh）：retry_scp/retry_ssh 会自动重试 3 次，仍失败则提示用户确认密码正确或改用 SSH key（`ssh-copy-id`）。
- `a terminal is required`：`sudo_remote` 默认使用 `ssh -tt`，已避免此问题。
- `dpkg` 依赖问题：自动通过 `apt -f install -y` 修复。
- `No route to host`（重启后）：`wait_for_device` 使用指数退避轮询等待，最多约 190s。若仍失败，检查设备是否正常启动或网络配置。
- 重启卡住：有些设备重启较慢，增加 `wait_for_device` 的 `max_attempts` 或 `delay`。

质量标准 / 完成检查
--
- 目标主机成功接收 image 与 header `.deb`（retry_scp 返回 0，或最多 3 次重试后报告失败）。
- 远端 `dpkg -i` 成功（retry_sudo 自动处理 tty 问题），或 `apt -f install -y` 修复依赖后成功。
- 安装后 `dpkg -l | grep linux-image` 与 `dpkg -l | grep linux-headers` 显示已安装的新版本。
- 如果进行了重启：wait_for_device 成功检测到设备恢复，且 `uname -r` 显示预期内核版本。

示例交互提示（可用于在 Copilot/agent 中触发此技能）
--
- 部署到单台主机（只上传 image 与 headers，自动重启）:

```
部署工作区上层目录内匹配版本的 linux-image*.deb 和 linux-headers*.deb 到 192.168.33.221，使用默认密码 radxa，安装后自动重启
```

- 批量部署并自动重启：

```
部署工作区上层目录内匹配版本的 linux-image*.deb 和 linux-headers*.deb 到 hosts.txt 列表中的所有设备，使用默认密码 radxa，安装后自动重启
```

示例（你的命名约定）
--
如果包名为 `../linux-*-6.18.2-4-qcom_6.18.2-4_arm64.deb`，脚本会将 `${version}` 解析为 `6.18.2-4` 并匹配上述文件。

后续可选扩展
--
- 将该流程封装为可复用脚本或 ansible playbook（支持并发部署、失败重试与回滚）。
- 将构建 + 打包 + 部署接入 CI（构建产物自动上传并触发部署）。
- 支持 SSH key 管理与更安全的凭据存储。

版权与注意事项
--
此技能模板仅描述操作流程与自动化策略；在生产环境使用前务必确认目标设备与服务可用性，并对关键操作（如重启）获得明确授权。

-- END --
