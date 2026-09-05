#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/test-dkms.sh"
BEFORE=$OLD AFTER=$TARGET FINAL=$TARGET

for suffix in 'space dir' 'percent%s%n' "single'quote" 'meta;touch SENTINEL' \
  '$(touch SENTINEL)' 'double"quote`touch SENTINEL`'; do
  TEST_REMOTE_DIR="$TEST_ROOT/$suffix"
  run_case "quoted-directory-$suffix" 0 0
  installed_paths=()
  while IFS= read -r -d '' argument; do installed_paths+=("$argument"); done < "$TEST_ROOT/dpkg-argv"
  [[ "${installed_paths[0]}" == "$TEST_REMOTE_DIR/linux-image-board_1.2-3_arm64.deb" ]]
  [[ "${installed_paths[1]}" == "$TEST_REMOTE_DIR/linux-headers-board_1.2-3_arm64.deb" ]]
  [[ "${#installed_paths[@]}" == 2 && ! -e "$TEST_ROOT/source/SENTINEL" ]]
done
unset TEST_REMOTE_DIR
image_name='linux-image quote%"'"'"';touch SENTINEL;$(touch SENTINEL)_1.2-3_arm64.deb'
mv "$TEST_ROOT/linux-image-board_1.2-3_arm64.deb" "$TEST_ROOT/$image_name"
run_case quoted-package-filename 0 0
IFS= read -r -d '' argument < "$TEST_ROOT/dpkg-argv"
[[ "$argument" == "/home/radxa/$image_name" && ! -e "$TEST_ROOT/source/SENTINEL" ]]
mv "$TEST_ROOT/$image_name" "$TEST_ROOT/linux-image-board_1.2-3_arm64.deb"

DPKG_EXIT=1; export DPKG_EXIT
run_case apt-repair-keeps-exact-packages 0 0
[[ -f "$TEST_ROOT/apt-ran" ]]
BAD_PACKAGE=linux-image-board; export BAD_PACKAGE
run_case apt-removes-image-rejected 1 0 '目标包未精确安装'
BAD_PACKAGE=linux-headers-board
run_case apt-removes-headers-rejected 1 0 '目标包未精确安装'
unset BAD_PACKAGE
APT_EXIT=1; export APT_EXIT
run_case apt-repair-failure 1 0 '安装失败'
unset DPKG_EXIT APT_EXIT
QUERY_EXIT=1; export QUERY_EXIT
run_case package-query-failure 1 0 '无法查询目标包'
unset QUERY_EXIT
BAD_PACKAGE=linux-image-board QUERY_STATUS='install ok installed' QUERY_VERSION=0.9
export BAD_PACKAGE QUERY_STATUS QUERY_VERSION
run_case wrong-package-version-rejected 1 0 '目标包未精确安装'
QUERY_VERSION=1.2-3 QUERY_STATUS='install ok unpacked'
run_case unpacked-is-not-installed 1 0 '目标包未精确安装'
QUERY_STATUS='hold ok installed'
run_case non-install-selection-rejected 1 0 '目标包未精确安装'
unset BAD_PACKAGE QUERY_STATUS QUERY_VERSION
MISSING_IMAGE=true; export MISSING_IMAGE
run_case remote-image-missing 1 0 '路径验证失败'
unset MISSING_IMAGE
MISSING_HEADERS=true; export MISSING_HEADERS
run_case remote-headers-missing 1 0 '路径验证失败'
unset MISSING_HEADERS
FINAL_SSH_EXIT=255; export FINAL_SSH_EXIT
run_case final-ssh-failure 1 0 '无法读取运行内核'
unset FINAL_SSH_EXIT
TEST_REBOOT=true
run_case reboot-target-kernel 0 0
REBOOT_EXIT=255; export REBOOT_EXIT
run_case reboot-disconnect-with-verified-recovery 0 0
WAIT_EXIT=255; export WAIT_EXIT
run_case reboot-disconnect-without-recovery 1 0 '无响应'
unset WAIT_EXIT REBOOT_EXIT
REBOOT_EXIT=1; export REBOOT_EXIT
run_case reboot-command-failure 1 0 '重启命令失败'
unset REBOOT_EXIT
POST_SSH_EXIT=255; export POST_SSH_EXIT
run_case postreboot-ssh-failure 1 0 '无法读取运行内核'
unset POST_SSH_EXIT
BOOT_KERNEL=5.10-old; export BOOT_KERNEL
run_case postreboot-old-kernel-rejected 1 0 '不属于目标集合'
BOOT_KERNEL='6.1.99-radxa-extra'
run_case postreboot-prefix-match-rejected 1 0 '不属于目标集合'
unset BOOT_KERNEL
POST_PACKAGE_MISSING=true; export POST_PACKAGE_MISSING
run_case postreboot-package-query-failure 1 0 '无法查询目标包'
unset POST_PACKAGE_MISSING
printf '%s total regression cases passed; nested shells exercised, no devices or network accessed.\n' "$passed"
