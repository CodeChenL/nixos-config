#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
for release in 6.1.99-radxa 6.2-other; do
  mkdir -p "$TEST_ROOT/remote/boot" "$TEST_ROOT/remote/usr/src/linux-headers-$release"
  printf 'image\n' > "$TEST_ROOT/remote/boot/vmlinuz-$release"
  touch "$TEST_ROOT/remote/usr/src/linux-headers-$release/Makefile"
done
mkdir -p "$TEST_ROOT/source/debian" "$TEST_ROOT/image/boot" \
  "$TEST_ROOT/headers/usr/src/linux-headers-6.1.99-radxa/arch/arm64"
touch "$TEST_ROOT/source/debian/changelog" \
  "$TEST_ROOT/linux-image-board_1.2-3_arm64.deb" \
  "$TEST_ROOT/linux-headers-board_1.2-3_arm64.deb" \
  "$TEST_ROOT/image/boot/vmlinuz-6.1.99-radxa" \
  "$TEST_ROOT/headers/usr/src/linux-headers-6.1.99-radxa/Makefile" \
  "$TEST_ROOT/headers/usr/src/linux-headers-6.1.99-radxa/arch/arm64/Makefile"

dpkg-parsechangelog() { printf '1.2-3\n'; }
dpkg-deb() {
  local kind=image
  [[ "$2" == *linux-headers* ]] && kind=headers
  case "$1" in
    -f)
      case "$3" in
        Package) printf '%s\n' "${PACKAGE_NAME:-linux-$kind-board}" ;;
        Version) printf '%s\n' "${PACKAGE_VERSION:-1.2-3}" ;;
        *) return 91 ;;
      esac ;;
    --fsys-tarfile)
      [[ "${BAD_ARCHIVE:-false}" == false ]] || return 2
      tar -cf - -C "$TEST_ROOT/$kind" . ;;
    *) return 92 ;;
  esac
}
source "$SCRIPT_DIR/test-transport.sh"
export -f dpkg-parsechangelog dpkg-deb

OLD='wifi/1.0, 5.10-old, aarch64: installed'
TARGET='wifi/1.0, 6.1.99-radxa, aarch64: installed'
export BEFORE AFTER FINAL
passed=0
run_case() {
  local name="$1" expected_exit="$2" expected_installs="$3" expected_message="${4:-}"
  local result=0 installs
  local -a options=(--hosts mock.invalid --remote_dir "${TEST_REMOTE_DIR:-~}")
  [[ "${TEST_REBOOT:-false}" == true ]] || options+=(--no-reboot)
  : > "$TEST_ROOT/commands"
  rm -f "$TEST_ROOT/installed" "$TEST_ROOT/rebooted" "$TEST_ROOT/apt-ran"
  printf '0\n' > "$TEST_ROOT/count"
  (cd "$TEST_ROOT/source" && bash "$SCRIPT_DIR/deploy.sh" "${options[@]}") \
    > "$TEST_ROOT/output" 2>&1 || result=$?
  installs=$(grep -c 'dkms install -m' "$TEST_ROOT/commands" || true)
  if [[ "$result" -ne "$expected_exit" || "$installs" -ne "$expected_installs" ]] || \
    { [[ -n "$expected_message" ]] && ! grep -Fq -- "$expected_message" "$TEST_ROOT/output"; }; then
    printf 'FAIL %s (exit=%s installs=%s)\n' "$name" "$result" "$installs"
    cat "$TEST_ROOT/output"
    exit 1
  fi
  if [[ "$installs" -gt 0 ]]; then
    grep -Fq 'dkms install -m wifi -v 1.0 -k 6.1.99-radxa -a aarch64' "$TEST_ROOT/commands"
  fi
  passed=$((passed + 1))
  printf 'PASS %s\n' "$name"
}

BEFORE=$OLD AFTER="$OLD"$'\n'"$TARGET" FINAL=$AFTER
run_case healthy-added-target 0 0
BEFORE=$OLD AFTER=$OLD FINAL="$OLD"$'\n'"$TARGET"
run_case unchanged-old-status-repaired 0 1
AFTER='' FINAL=$TARGET
run_case lost-status-repaired 0 1
AFTER=$OLD FINAL=$OLD
run_case old-kernel-only-after-repair 1 1 'DKMS 未安装到目标内核'
FINAL=''
run_case empty-after-repair 1 1 'DKMS 未安装到目标内核'
FINAL='wifi/1.0, 6.1.99-radxa, aarch64: built'
run_case built-is-not-installed 1 1 'DKMS 未安装到目标内核'
FINAL='wifi/1.0, 6.1.99-radxa, x86_64: installed'
run_case wrong-architecture-not-success 1 1 'DKMS 未安装到目标内核'
FINAL='wifi/2.0, 6.1.99-radxa, aarch64: installed'
run_case wrong-version-not-success 1 1 'DKMS 未安装到目标内核'
FINAL=$TARGET
INSTALL_EXIT=9; export INSTALL_EXIT
run_case install-command-failure 1 1 'DKMS install 失败'
unset INSTALL_EXIT
for phase in 1 2 3; do
  STATUS_FAIL_AT=$phase; export STATUS_FAIL_AT
  repairs=0; [[ "$phase" -ne 3 ]] || repairs=1
  run_case "status-failure-phase-$phase" 1 "$repairs" '无法读取 DKMS 状态'
done
unset STATUS_FAIL_AT
BEFORE='unrecognized output'
run_case malformed-before 1 0 '无法解析 DKMS 状态'
BEFORE=$OLD AFTER='wifi/1.0: broken'
run_case malformed-after 1 0 '无法解析 DKMS 状态'
AFTER=$OLD FINAL='bad output'
run_case malformed-repaired-status 1 1 '无法解析 DKMS 状态'
BEFORE='' AFTER='' FINAL=''
run_case no-registered-modules 0 0 '无注册模块'
BEFORE='' AFTER='wifi/1.0: added' FINAL=$TARGET
run_case newly-registered-module 0 1
BEFORE='wifi, 1.0, 5.10-old, aarch64: installed'
AFTER='wifi, 1.0: added' FINAL='wifi, 1.0, 6.1.99-radxa, aarch64: installed'
run_case legacy-dkms-format 0 1
BEFORE="$OLD"$'\n''gpu/2.0: added' AFTER=$OLD FINAL=$TARGET
run_case every-module-required 1 2 'gpu/2.0'
BEFORE=$OLD AFTER=$OLD FINAL=$TARGET
PROBE_EXIT=255; export PROBE_EXIT
run_case probe-transport-failure 1 0 'DKMS 探测失败'
PROBE_EXIT=3
run_case dkms-not-installed 0 0
PROBE_AFTER_EXIT=255; export PROBE_AFTER_EXIT
run_case post-install-probe-failure 1 0 'DKMS 探测失败'
PROBE_AFTER_EXIT=0
BEFORE='wifi/1.0: added' AFTER=$TARGET
run_case dkms-installed-with-kernel 0 1
unset PROBE_AFTER_EXIT
unset PROBE_EXIT
BEFORE=$OLD AFTER=$OLD FINAL=$TARGET
MOCK_ARCH='aarch64;false'; export MOCK_ARCH
run_case invalid-architecture 1 0 '非法 DKMS 参数'
unset MOCK_ARCH
BEFORE='wifi/1.0;false: added'
run_case unsafe-module-version 1 0 '无法解析 DKMS 状态'
BEFORE=$OLD
PACKAGE_VERSION=wrong; export PACKAGE_VERSION
run_case package-version-mismatch 1 0 '包版本不匹配'
[[ ! -s "$TEST_ROOT/commands" ]]
unset PACKAGE_VERSION
PACKAGE_NAME=linux-libc-dev; export PACKAGE_NAME
run_case unrelated-package-rejected 1 0 '非内核实包'
[[ ! -s "$TEST_ROOT/commands" ]]
unset PACKAGE_NAME
BAD_ARCHIVE=true; export BAD_ARCHIVE
run_case package-inspection-failure 1 0
[[ ! -s "$TEST_ROOT/commands" ]]
unset BAD_ARCHIVE
touch "$TEST_ROOT/image/boot/vmlinuz-6.1.99;false"
run_case unsafe-package-release 1 0 '非法 DKMS 参数'
[[ ! -s "$TEST_ROOT/commands" ]]
rm "$TEST_ROOT/image/boot/vmlinuz-6.1.99;false"
touch "$TEST_ROOT/image/boot/vmlinuz-6.2-other"
run_case missing-matching-headers 1 0 '缺少匹配 headers'
[[ ! -s "$TEST_ROOT/commands" ]]
mkdir -p "$TEST_ROOT/headers/usr/src/linux-headers-6.2-other"
touch "$TEST_ROOT/headers/usr/src/linux-headers-6.2-other/Makefile"
FINAL=$TARGET
run_case every-target-required 1 2 '6.2-other'
FINAL="$TARGET"$'\n''wifi/1.0, 6.2-other, aarch64: installed'
run_case multiple-targets-repaired 0 2
grep -Fq 'dkms install -m wifi -v 1.0 -k 6.2-other -a aarch64' "$TEST_ROOT/commands"
rm "$TEST_ROOT/image/boot/vmlinuz-6.2-other" "$TEST_ROOT/image/boot/vmlinuz-6.1.99-radxa"
run_case image-without-release-rejected 1 0 '没有可验证的内核 release'
[[ ! -s "$TEST_ROOT/commands" ]]
mkdir -p "$TEST_ROOT/image/usr/lib/modules/6.1.99-radxa"
AFTER=$TARGET
run_case modules-directory-release 0 0
rm "$TEST_ROOT/headers/usr/src/linux-headers-6.1.99-radxa/Makefile"
mkdir -p "$TEST_ROOT/headers/lib/modules/6.1.99-radxa"
ln -s /unused "$TEST_ROOT/headers/lib/modules/6.1.99-radxa/build"
run_case headers-build-link-release 0 0
bash "$SCRIPT_DIR/deploy.sh" --help > "$TEST_ROOT/help"
grep -q -- '--no-reboot' "$TEST_ROOT/help"
if bash "$SCRIPT_DIR/deploy.sh" --unknown > "$TEST_ROOT/bad-input" 2>&1; then exit 1; fi
printf 'PASS CLI help and bad input\n'
printf '%s regression cases passed; no devices or network accessed.\n' "$passed"
