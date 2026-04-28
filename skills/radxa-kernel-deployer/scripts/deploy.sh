#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# === 参数解析 ===
HOSTS="" USER="radxa" PASSWORD="radxa" REMOTE_DIR="~" REBOOT="true"

usage() {
  cat <<EOF
用法: $(basename "$0") --hosts <IP> [选项]

必填:
  --hosts <list>         IP/hostname，逗号分隔

可选:
  --user <name>          远端用户名 (默认: radxa)
  --password <pass>      远端密码 (默认: radxa)
  --remote_dir <dir>     远端接收目录 (默认: ~)
  --no-reboot            安装后不重启
  -h, --help             显示帮助
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)       HOSTS="$2"; shift 2 ;;
    --user)        USER="$2"; shift 2 ;;
    --password)    PASSWORD="$2"; shift 2 ;;
    --remote_dir)  REMOTE_DIR="$2"; shift 2 ;;
    --no-reboot)   REBOOT="false"; shift ;;
    -h|--help)     usage ;;
    *)             echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ -n "$HOSTS" ]] || { echo "ERROR: --hosts 必填"; exit 1; }

# === 步骤 1: 检测版本 ===
detect_version() {
  if [ -f debian/changelog ]; then
    dpkg-parsechangelog --show-field Version 2>/dev/null || \
      sed -n '1p' debian/changelog | sed -E 's/^[^ ]+ \(([^)]+)\).*/\1/'
  else
    echo "ERROR: debian/changelog 未找到" >&2; return 1
  fi
}

# === 步骤 2: 定位 .deb ===
locate_debs() {
  local version="$1"
  local image_deb header_deb
  image_deb=$(ls ../linux-image*"${version}"* 2>/dev/null | head -n1 || true)
  header_deb=$(ls ../linux-headers*"${version}"* 2>/dev/null | head -n1 || true)

  if [[ -n "$image_deb" && -n "$header_deb" ]]; then
    echo "$image_deb $header_deb"
  else
    local fallback
    fallback=$(ls ../linux-*"${version}"* 2>/dev/null | tr '\n' ' ')
    [[ -n "$fallback" ]] || { echo "ERROR: 上层目录未找到版本 ${version} 的 .deb" >&2; return 1; }
    echo "$fallback"
  fi
}

# === 步骤 3-6: 部署单台主机 ===
deploy_one() {
  local host="$1" version="$2" debs_str="$3"
  local -a debs=($debs_str)

  echo "=== 部署 ${host} ==="

  # 将 ~ 解析为绝对路径，避免 sudo 下 ~ 展开到 /root
  local remote_dir="$REMOTE_DIR"
  if [[ "$remote_dir" == "~" || "$remote_dir" == "~/"* ]]; then
    remote_dir="/home/${USER}${remote_dir:1}"
  fi

  # 传输
  retry_scp "${debs[@]}" "${USER}@${host}:${remote_dir}" || { echo "[FAIL] 传输失败: ${host}"; return 1; }

  # 安装
  local pkg_args
  pkg_args=$(printf "${remote_dir}/%s " "${debs[@]##*/}")
  sudo_remote "${USER}@${host}" "dpkg -i ${pkg_args} || apt -f install -y" || { echo "[FAIL] 安装失败: ${host}"; return 1; }

  # 安装后验证
  sshpass -p "${PASSWORD}" ssh -o StrictHostKeyChecking=no "${USER}@${host}" \
    'dpkg -l | grep -E "linux-image|linux-headers"; echo "---"; uname -r'

  # 重启
  if [[ "$REBOOT" == "true" ]]; then
    echo "[INFO] 重启 ${host}..."
    sudo_remote "${USER}@${host}" "reboot" || true
    wait_for_device "${USER}@${host}"
    sshpass -p "${PASSWORD}" ssh -o StrictHostKeyChecking=no "${USER}@${host}" 'uname -r'
  fi

  echo "[OK] ${host} 部署完成"
}

# === 主流程 ===
version=$(detect_version)
echo "[INFO] 检测到版本: ${version}"

debs_str=$(locate_debs "$version")
echo "[INFO] 部署包: ${debs_str}"

IFS=',' read -ra host_list <<< "$HOSTS"
failed_hosts=()

for host in "${host_list[@]}"; do
  host=$(echo "$host" | xargs)  # trim
  if ! deploy_one "$host" "$version" "$debs_str"; then
    failed_hosts+=("$host")
    echo "[WARN] ${host} 部署失败，继续下一个"
  fi
done

if [[ ${#failed_hosts[@]} -gt 0 ]]; then
  echo "[FAIL] 以下主机部署失败: ${failed_hosts[*]}"
  exit 1
fi

echo "[DONE] 所有主机部署成功"
