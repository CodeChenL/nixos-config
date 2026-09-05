#!/usr/bin/env bash
# radxa-kernel-deployer 辅助函数库
# 由 deploy.sh source 引入
#
# 安全说明：所有 sshpass 调用通过 -e 参数从 SSHPASS 环境变量读取密码，
# 避免密码出现在进程命令行（/proc/*/cmdline）中被其他用户窥探。
# 使用前请确保：
#   1. PASSWORD 已导出到 SSHPASS（见 deploy.sh）
#   2. shell 历史中不含 PASSWORD 明文

retry_scp() {
  local max=3 delay=2
  for i in $(seq 1 $max); do
    sshpass -e scp -s -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SCP] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SCP] 重试${max}次后仍失败" >&2; return 1
}

retry_ssh() {
  local max=3 delay=5
  for i in $(seq 1 $max); do
    sshpass -e ssh -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SSH] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SSH] 重试${max}次后仍失败" >&2; return 1
}

sudo_remote() {
  local host="$1" cmd="$2"
  # sshpass -e 用 SSHPASS 完成 SSH 登录；printf 再把同一个密码喂给远端 sudo -S。
  # 注意：用 -T（禁用 PTY）确保 stdin 正确转发给 sudo；-tt 会接管 stdin 导致密码丢失。
  printf '%s\n' "${SSHPASS}" | \
  sshpass -e ssh -T -o StrictHostKeyChecking=no "${host}" \
    "sudo -S bash -c $(shell_quote "$cmd")"
}

shell_quote() {
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}

remote_has_dkms() {
  local host="$1"
  sudo_remote "$host" "if command -v dkms >/dev/null 2>&1; then exit 0; else exit 3; fi"
}

remote_dkms_status() {
  local host="$1"
  local status
  status=$(sudo_remote "$host" "LC_ALL=C dkms status") || {
    echo "[FAIL] 无法读取 DKMS 状态: ${host}" >&2; return 1;
  }
  printf '%s\n' "$status" | parse_dkms_status
}

remote_dkms_install() {
  local host="$1" module="$2" version="$3" release="$4" arch="$5" value
  for value in "$module" "$version" "$release" "$arch"; do
    valid_dkms_token "$value" || return 1
  done
  sudo_remote "$host" "dkms install -m ${module} -v ${version} -k ${release} -a ${arch}"
}

valid_dkms_token() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+~:-]*$ ]] || {
    echo "[FAIL] 非法 DKMS 参数: $1" >&2; return 1;
  }
}

target_kernel_releases() (
  set -o pipefail
  local expected_version="$1" deb package version paths path release
  local images="" headers="" found
  shift
  for deb in "$@"; do
    package=$(dpkg-deb -f "$deb" Package) || return 1
    version=$(dpkg-deb -f "$deb" Version) || return 1
    [[ "$version" == "$expected_version" ]] || {
      echo "[FAIL] 包版本不匹配: $deb ($version)" >&2; return 1;
    }
    case "$package" in
      linux-image-*|linux-headers-*) ;;
      *) echo "[FAIL] 非内核实包: $deb ($package)" >&2; return 1 ;;
    esac
    paths=$(dpkg-deb --fsys-tarfile "$deb" | tar -tf -) || return 1
    found=false
    while IFS= read -r path; do
      path=${path#./}
      release=""
      case "$package:$path" in
        linux-image-*:boot/vmlinuz-*) release=${path#boot/vmlinuz-} ;;
        linux-image-*:lib/modules/*|linux-image-*:usr/lib/modules/*)
          release=${path#*lib/modules/}; release=${release%%/*} ;;
        linux-headers-*:usr/src/linux-headers-*/Makefile)
          release=${path#usr/src/linux-headers-}; release=${release%/Makefile}
          [[ "$release" != */* ]] || continue ;;
        linux-headers-*:lib/modules/*/build|linux-headers-*:usr/lib/modules/*/build)
          release=${path#*lib/modules/}; release=${release%/build}
          [[ "$release" != */* ]] || continue ;;
      esac
      [[ -n "$release" ]] || continue
      valid_dkms_token "$release" || return 1
      found=true
      if [[ "$package" == linux-image-* ]]; then
        images+="$release"$'\n'
      else
        headers+="$release"$'\n'
      fi
    done <<< "$paths"
    [[ "$found" == true ]] || {
      echo "[FAIL] 包中没有可验证的内核 release: $deb" >&2; return 1;
    }
  done
  [[ -n "$images" && -n "$headers" ]] || {
    echo "[FAIL] 必须提供 image 和 headers 实包" >&2; return 1;
  }
  while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    [[ $'\n'"$headers" == *$'\n'"$release"$'\n'* ]] || {
      echo "[FAIL] 目标内核缺少匹配 headers: $release" >&2; return 1;
    }
  done <<< "$images"
  printf '%s' "$images" | LC_ALL=C sort -u
)

parse_dkms_status() {
  local line module version release arch state
  local token='([a-zA-Z0-9][a-zA-Z0-9._+~:-]*)'
  local full short
  full="^${token}[/,] *${token}, *${token}, *${token}: (installed|built)$"
  short="^${token}[/,] *${token}: (added)$"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ $full ]]; then
      module=${BASH_REMATCH[1]} version=${BASH_REMATCH[2]}
      release=${BASH_REMATCH[3]} arch=${BASH_REMATCH[4]} state=${BASH_REMATCH[5]}
    elif [[ "$line" =~ $short ]]; then
      module=${BASH_REMATCH[1]} version=${BASH_REMATCH[2]}
      release=- arch=- state=${BASH_REMATCH[3]}
    else
      echo "[FAIL] 无法解析 DKMS 状态: $line" >&2; return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$module" "$version" "$release" "$arch" "$state"
  done
}

ensure_target_dkms() {
  local host="$1" before="$2" targets="$3" arch="$4"
  local after expected module version release record repaired=false
  valid_dkms_token "$arch" || return 1
  after=$(remote_dkms_status "$host") || return 1
  echo "[DKMS] 安装后状态: ${after:-<无 DKMS 模块>}"
  expected=$(printf '%s\n%s\n' "$before" "$after" | awk 'NF {print $1 "\t" $2}' | LC_ALL=C sort -u)
  if [[ -z "$expected" ]]; then
    echo "[DKMS] 无注册模块，跳过修复"
    return 0
  fi
  while IFS=$'\t' read -r module version; do
    while IFS= read -r release; do
      valid_dkms_token "$release" || return 1
      record=$(printf '%s\t%s\t%s\t%s\tinstalled' "$module" "$version" "$release" "$arch")
      if [[ $'\n'"$after"$'\n' != *$'\n'"$record"$'\n'* ]]; then
        echo "[DKMS] 修复 ${module}/${version}: ${release} (${arch})"
        remote_dkms_install "$host" "$module" "$version" "$release" "$arch" || {
          echo "[FAIL] DKMS install 失败: $host" >&2; return 1;
        }
        repaired=true
      fi
    done <<< "$targets"
  done <<< "$expected"
  if [[ "$repaired" == true ]]; then
    after=$(remote_dkms_status "$host") || return 1
    echo "[DKMS] 修复后状态: ${after:-<无 DKMS 模块>}"
  fi
  while IFS=$'\t' read -r module version; do
    while IFS= read -r release; do
      record=$(printf '%s\t%s\t%s\t%s\tinstalled' "$module" "$version" "$release" "$arch")
      [[ $'\n'"$after"$'\n' == *$'\n'"$record"$'\n'* ]] || {
        echo "[FAIL] DKMS 未安装到目标内核: ${module}/${version}, ${release}, ${arch}" >&2
        return 1
      }
    done <<< "$targets"
  done <<< "$expected"
  echo "[DKMS] 所有模块已验证安装到目标内核: $targets"
}

wait_for_device() {
  local host="$1" max=5 delay=10
  for i in $(seq 1 $max); do
    echo "[wait] 等待上线 ${i}/${max}（${delay}s）" >&2; sleep $delay; delay=$((delay + delay / 2))
    sshpass -e ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${host}" "echo ok" >/dev/null 2>&1 && \
      { echo "[wait] 设备已恢复（第${i}次）"; return 0; }
  done
  echo "[wait] ${max}次尝试后无响应" >&2; return 1
}
