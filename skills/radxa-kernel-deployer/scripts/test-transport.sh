#!/usr/bin/env bash

sshpass() {
  local command="${!#}"
  if [[ "$2" == scp ]]; then
    [[ "$3" == -s ]] || return 94
    printf 'scp %s\n' "$*" >> "$TEST_ROOT/commands"
    return 0
  fi
  if [[ "${3:-}" == -T ]]; then
    bash -c "$command"
  elif [[ "$command" == 'echo ok' ]]; then
    return "${WAIT_EXIT:-0}"
  elif [[ "$command" == 'uname -r' ]]; then
    if [[ -f "$TEST_ROOT/rebooted" ]]; then
      [[ "${POST_SSH_EXIT:-0}" == 0 ]] || return "$POST_SSH_EXIT"
      printf '%s\n' "${BOOT_KERNEL:-6.1.99-radxa}"
    else
      [[ "${FINAL_SSH_EXIT:-0}" == 0 ]] || return "$FINAL_SSH_EXIT"
      printf '5.10-old\n'
    fi
  else
    printf 'Unexpected SSH command: %s\n' "$command" >&2; return 93
  fi
}
sudo() {
  local password command="${!#}"
  IFS= read -r password
  [[ "$password" == "$SSHPASS" && "$1" == -S && "$2" == bash && "$3" == -c && "$#" == 4 ]] || return 95
  mock_remote "$command"
}
mock_remote() {
  local command="$1" count status
  printf '%s\n' "$command" >> "$TEST_ROOT/commands"
  case "$command" in
    *'command -v dkms'*)
      if [[ -f "$TEST_ROOT/installed" ]]; then return "${PROBE_AFTER_EXIT:-${PROBE_EXIT:-0}}"; fi
      return "${PROBE_EXIT:-0}" ;;
    *'LC_ALL=C dkms status'*)
      count=$(<"$TEST_ROOT/count")
      count=$((count + 1))
      printf '%s\n' "$count" > "$TEST_ROOT/count"
      [[ "$count" != "${STATUS_FAIL_AT:-0}" ]] || { printf 'status failed\n' >&2; return 7; }
      case "$count" in
        1) status=$BEFORE ;;
        2) status=$AFTER ;;
        *) status=$FINAL ;;
      esac
      printf '%s\n' "$status" ;;
    'uname -m') printf '%s\n' "${MOCK_ARCH:-aarch64}" ;;
    'dkms install -m '*) return "${INSTALL_EXIT:-0}" ;;
    'dpkg -i '*|'LC_ALL=C dpkg-query '*|'test -s '*|'printf '*) bash -c "$command" ;;
    reboot) touch "$TEST_ROOT/rebooted"; return "${REBOOT_EXIT:-0}" ;;
    *) printf 'Unexpected sudo command: %s\n' "$command" >&2; return 93 ;;
  esac
}
dpkg() {
  [[ "$1" == -i && "$2" == -- ]] || return 96
  shift 2
  printf '%s\0' "$@" > "$TEST_ROOT/dpkg-argv"
  touch "$TEST_ROOT/installed"
  return "${DPKG_EXIT:-0}"
}
apt() {
  [[ "$*" == '-f install -y' ]] || return 97
  touch "$TEST_ROOT/apt-ran"
  return "${APT_EXIT:-0}"
}
dpkg-query() {
  local package="${!#}" status='install ok installed' version=1.2-3
  [[ "$1" == -W && "$2" == '-f=${Package}\t${Version}\t${Status}\n' && "$3" == -- && "$#" == 4 ]] || return 98
  [[ "${QUERY_EXIT:-0}" == 0 ]] || return "$QUERY_EXIT"
  if [[ "$package" == "${BAD_PACKAGE:-none}" ]]; then
    status=${QUERY_STATUS:-deinstall ok config-files}
    version=${QUERY_VERSION:-1.2-3}
  fi
  if [[ -f "$TEST_ROOT/rebooted" && "${POST_PACKAGE_MISSING:-false}" == true ]]; then return 1; fi
  printf '%s\t%s\t%s\n' "$package" "$version" "$status"
}
test() {
  [[ "$#" == 2 && "$2" == /* ]] || return 99
  if [[ "${MISSING_IMAGE:-false}" == true && "$2" == /boot/* ]]; then return 1; fi
  if [[ "${MISSING_HEADERS:-false}" == true && "$2" != /boot/* ]]; then return 1; fi
  builtin test "$1" "$TEST_ROOT/remote$2"
}
sleep() { :; }
export -f sshpass sudo mock_remote dpkg apt dpkg-query test sleep
