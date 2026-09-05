#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"
source "${SCRIPT_DIR}/installation.sh"

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

# 将明文密码注入到 SSHPASS 环境变量，供 sshpass -e 读取
# 这样密码不会出现在 /proc/<pid>/cmdline 中
export SSHPASS="${PASSWORD}"

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
  local deb
  local -a found=()
  for deb in ../linux-image*"${version}"*.deb ../linux-headers*"${version}"*.deb; do
    [[ -f "$deb" ]] && found+=("$deb")
  done
  [[ ${#found[@]} -gt 0 ]] || { echo "ERROR: 未找到版本 ${version} 的 .deb" >&2; return 1; }
  printf '%s\n' "${found[@]}"
}

# === 步骤 3-6: 部署单台主机 ===
deploy_one() {
  local host="$1" targets="$2" debs_str="$3" manifest="$4"
  local -a debs
  mapfile -t debs <<< "$debs_str"
  local has_dkms=false dkms_before="" probe_status arch=""

  echo "=== 部署 ${host} ==="

  # 将 ~ 解析为绝对路径，避免 sudo 下 ~ 展开到 /root
  local remote_dir="$REMOTE_DIR"
  if [[ "$remote_dir" == "~" || "$remote_dir" == "~/"* ]]; then
    remote_dir="/home/${USER}${remote_dir:1}"
  fi

  if remote_has_dkms "${USER}@${host}"; then
    has_dkms=true
    dkms_before=$(remote_dkms_status "${USER}@${host}") || return 1
    arch=$(sudo_remote "${USER}@${host}" "uname -m") || return 1
    valid_dkms_token "$arch" || return 1
    echo "[DKMS] 安装前状态: ${dkms_before:-<无 DKMS 模块>}"
  else
    probe_status=$?
    [[ "$probe_status" -eq 3 ]] || { echo "[FAIL] DKMS 探测失败: ${host}" >&2; return 1; }
  fi

  # 传输
  retry_scp "${debs[@]}" "${USER}@${host}:${remote_dir}" || { echo "[FAIL] 传输失败: ${host}"; return 1; }

  # 安装
  install_selected_packages "${USER}@${host}" "$remote_dir" "${debs[@]}" || return 1
  verify_selected_packages "${USER}@${host}" "$manifest" "$targets" || return 1

  if [[ "$has_dkms" == false ]]; then
    if remote_has_dkms "${USER}@${host}"; then
      has_dkms=true
      arch=$(sudo_remote "${USER}@${host}" "uname -m") || return 1
      valid_dkms_token "$arch" || return 1
    else
      probe_status=$?
      [[ "$probe_status" -eq 3 ]] || { echo "[FAIL] DKMS 探测失败: ${host}" >&2; return 1; }
    fi
  fi
  if [[ "$has_dkms" == true ]]; then
    ensure_target_dkms "${USER}@${host}" "$dkms_before" "$targets" "$arch" || return 1
  fi

  # 安装后验证
  local running reboot_status
  running=$(remote_running_kernel "${USER}@${host}") || return 1
  echo "[INFO] 当前运行内核: $running"

  # 重启
  if [[ "$REBOOT" == "true" ]]; then
    echo "[INFO] 重启 ${host}..."
    if sudo_remote "${USER}@${host}" "reboot"; then
      reboot_status=0
    else
      reboot_status=$?
      [[ "$reboot_status" -eq 255 ]] || { echo "[FAIL] 重启命令失败: $host" >&2; return 1; }
    fi
    wait_for_device "${USER}@${host}" || return 1
    running=$(remote_running_kernel "${USER}@${host}") || return 1
    [[ $'\n'"$targets"$'\n' == *$'\n'"$running"$'\n'* && -n "$running" ]] || {
      echo "[FAIL] 重启后内核不属于目标集合: $running" >&2; return 1;
    }
    verify_selected_packages "${USER}@${host}" "$manifest" "$targets" || return 1
  fi

  echo "[OK] ${host} 部署完成"
}

# === 主流程 ===
version=$(detect_version)
echo "[INFO] 检测到版本: ${version}"

debs_str=$(locate_debs "$version")
echo "[INFO] 部署包: ${debs_str}"
mapfile -t debs <<< "$debs_str"
targets=$(target_kernel_releases "$version" "${debs[@]}")
manifest=$(selected_package_manifest "${debs[@]}")
echo "[INFO] 目标内核 release: ${targets}"

IFS=',' read -ra host_list <<< "$HOSTS"
failed_hosts=()

for host in "${host_list[@]}"; do
  host=$(echo "$host" | xargs)  # trim
  if ! deploy_one "$host" "$targets" "$debs_str" "$manifest"; then
    failed_hosts+=("$host")
    echo "[WARN] ${host} 部署失败，继续下一个"
  fi
done

if [[ ${#failed_hosts[@]} -gt 0 ]]; then
  echo "[FAIL] 以下主机部署失败: ${failed_hosts[*]}"
  exit 1
fi

echo "[DONE] 所有主机部署成功"
