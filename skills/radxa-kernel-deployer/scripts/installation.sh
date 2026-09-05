#!/usr/bin/env bash

selected_package_manifest() {
  local deb package version
  for deb in "$@"; do
    package=$(dpkg-deb -f "$deb" Package) || return 1
    version=$(dpkg-deb -f "$deb" Version) || return 1
    [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || return 1
    valid_dkms_token "$version" || return 1
    printf '%s\t%s\n' "$package" "$version"
  done
}

install_selected_packages() {
  local host="$1" directory="$2" deb args=""
  shift 2
  for deb in "$@"; do
    args+=" $(shell_quote "${directory}/${deb##*/}")"
  done
  sudo_remote "$host" "dpkg -i --${args} || apt -f install -y" || {
    echo "[FAIL] 安装失败: $host" >&2; return 1;
  }
}

verify_selected_packages() {
  local host="$1" manifest="$2" targets="$3" package version actual expected release
  local format='${Package}\t${Version}\t${Status}\n'
  while IFS=$'\t' read -r package version; do
    actual=$(sudo_remote "$host" "LC_ALL=C dpkg-query -W -f=$(shell_quote "$format") -- $(shell_quote "$package")") || {
      echo "[FAIL] 无法查询目标包: $package" >&2; return 1;
    }
    expected=$(printf '%s\t%s\tinstall ok installed' "$package" "$version")
    [[ "$actual" == "$expected" ]] || {
      echo "[FAIL] 目标包未精确安装: $package ($version): $actual" >&2; return 1;
    }
  done <<< "$manifest"
  while IFS= read -r release; do
    valid_dkms_token "$release" || return 1
    sudo_remote "$host" "test -s /boot/vmlinuz-${release} && { test -f /usr/src/linux-headers-${release}/Makefile || test -f /lib/modules/${release}/build/Makefile || test -f /usr/lib/modules/${release}/build/Makefile; }" || {
      echo "[FAIL] 目标内核 image/headers 路径验证失败: $release" >&2; return 1;
    }
  done <<< "$targets"
}

remote_running_kernel() {
  sshpass -e ssh -o StrictHostKeyChecking=no "$1" 'uname -r' || {
    echo "[FAIL] 无法读取运行内核: $1" >&2; return 1;
  }
}
