#!/usr/bin/env bash

scan_descriptors() {
  local fddir="$1" device_id="$2"
  local line mode devid errs
  local -a descriptors stats
  descriptor_owner=0
  descriptor_opacity=0
  shopt -s nullglob
  descriptors=( "$fddir"/* )
  shopt -u nullglob
  (( ${#descriptors[@]} > 0 )) || return 0
  mapfile -t stats < <(LC_ALL=C stat -Lc '%f %t:%T' -- "${descriptors[@]}" 2>/dev/null)
  for line in "${stats[@]}"; do
    read -r mode devid <<<"$line"
    [[ "$mode" =~ ^[0-9a-fA-F]+$ ]] || continue
    if (( (16#$mode & 16#f000) == 16#2000 )) && [[ "$devid" == "$device_id" ]]; then
      descriptor_owner=1
    fi
  done
  errs="$(LC_ALL=C stat -Lc %f -- "${descriptors[@]}" 2>&1 >/dev/null)" || true
  [[ "$errs" != *"Permission denied"* ]] || descriptor_opacity=1
}

evaluate_processes() {
  local kind pid field7 field8
  local run_session="$1"
  declare -A observed_session=() observed_profile=()
  while IFS=$'\t' read -r kind _ pid _ _ _ field7 field8 _ _ _; do
    [[ "$kind" == P || "$kind" == U ]] || continue
    if [[ "$kind" == P ]]; then
      observed_session["$pid"]="$field7"
      observed_profile["$pid"]="$field8"
      [[ "$field7" != "$run_session" && "$field8" != 1 ]] || printf '%s\n' "$pid"
    elif [[ "$pid" != 0 ]]; then
      [[ -n "${observed_session[$pid]:-}${observed_profile[$pid]:-}" ]] || return 3
      [[ "${observed_session[$pid]:-0}" != "$run_session" && "${observed_profile[$pid]:-0}" != 1 ]] || return 3
    fi
  done
}

split_words() {
  local value
  local -a parts
  process_words=()
  for value in "${process_args[@]}"; do
    read -ra parts <<<"$value"
    process_words+=("${parts[@]}")
  done
}

[[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]] || return 0

set -euo pipefail

action="${1:-}"
token="${2:-}"
root="${3:-}"
argument="${4:--}"
[[ "$(id -u)" != 0 ]] || exit 2
[[ "$token" =~ ^[a-f0-9]{32}$ ]] || exit 2

read_stat() {
  local entry="$1" line rest
  local -a stat_fields
  line="$(<"$entry/stat")" || return 1
  rest="${line##*) }"
  read -ra stat_fields <<<"$rest"
  [[ ${#stat_fields[@]} -ge 20 && "${stat_fields[1]}" =~ ^[0-9]+$ &&
     "${stat_fields[3]}" =~ ^[0-9]+$ && "${stat_fields[19]}" =~ ^[0-9]+$ ]] || return 1
  stat_state="${stat_fields[0]}"
  stat_parent="${stat_fields[1]}"
  stat_session="${stat_fields[3]}"
  stat_start="${stat_fields[19]}"
}

read_args() {
  local entry="$1"
  process_args=()
  mapfile -d '' -t process_args <"$entry/cmdline" || return 1
  if [[ ${#process_args[@]} -eq 0 && "$stat_state" != Z && "$stat_state" != X ]]; then
    return 1
  fi
}

rootless_snapshot() {
  local device="$1" session="$2" profile="$3"
  local sample boot namespace uid device_id='' entry pid owner parent_start
  local exact_profile gpu chromium fd_owner opaque
  sample="$(tr -d - < /proc/sys/kernel/random/uuid)" || return 3
  boot="$(< /proc/sys/kernel/random/boot_id)" || return 3
  namespace="$(readlink /proc/$$/ns/pid)" || return 3
  uid="$(id -u)"
  printf 'ROOTLESS_OBSERVATION_V1\n'
  printf 'BEGIN\t%s\t%s\t%s\t%s\t%s\n' "$sample" "$boot" "$namespace" "$uid" "$session"
  if [[ "$device" != - ]]; then
    if [[ ! "$device" =~ ^/dev/video[0-9]+$ ]] ||
        ! device_id="$(stat -Lc '%t:%T' -- "$device" 2>/dev/null)"; then
      printf 'U\t%s\t0\tdevice-unreadable\nEND\t%s\n' "$sample" "$sample"
      return 0
    fi
  fi
  declare -A same_uid=()
  while read -r owner path; do
    [[ "$owner" != "$uid" ]] || same_uid["${path##*/}"]=1
  done < <(LC_ALL=C stat -Lc '%u %n' -- /proc/[0-9]* 2>/dev/null) || true
  for entry in /proc/[0-9]*; do
    [[ -d "$entry" ]] || continue
    pid="${entry##*/}"
    [[ -v "same_uid[$pid]" ]] || continue
    if ! read_stat "$entry"; then
      [[ -d "$entry" ]] && printf 'U\t%s\t%s\tstat-unreadable\n' "$sample" "$pid"
      continue
    fi
    local start="$stat_start" process_session="$stat_session" parent="$stat_parent"
    parent_start=0
    if [[ "$parent" != 0 && -d "/proc/$parent" ]] && read_stat "/proc/$parent"; then
      parent_start="$stat_start"
    fi
    if ! read_stat "$entry" || [[ "$stat_start" != "$start" || "$stat_session" != "$process_session" ]]; then
      [[ -d "$entry" ]] && printf 'U\t%s\t%s\tidentity-changed\n' "$sample" "$pid"
      continue
    fi
    if ! read_args "$entry"; then
      [[ -d "$entry" ]] && printf 'U\t%s\t%s\tcmdline-unreadable\n' "$sample" "$pid"
      continue
    fi
    exact_profile=0
    gpu=0
    chromium=0
    split_words
    for value in "${process_words[@]}"; do
      [[ "$profile" != - && "$value" == "--user-data-dir=$profile" ]] && exact_profile=1
      [[ "$value" == --type=gpu-process ]] && gpu=1
    done
    if [[ ${#process_words[@]} -gt 0 ]]; then
      case "${process_words[0]##*/}" in
        chromium|chromium-browser|chrome|google-chrome|google-chrome-stable) chromium=1 ;;
      esac
    fi
    fd_owner=0
    opaque=0
    if [[ "$device" != - ]] &&
        { [[ "$session" == 0 ]] || [[ "$process_session" == "$session" ]] || [[ "$exact_profile" == 1 ]]; }; then
      if [[ ! -r "$entry/fd" || ! -x "$entry/fd" ]]; then
        opaque=1
      else
        scan_descriptors "$entry/fd" "$device_id"
        [[ "$descriptor_owner" == 0 ]] || fd_owner=1
        [[ "$descriptor_opacity" == 0 ]] || opaque=1
      fi
    fi
    if ! read_stat "$entry" || [[ "$stat_start" != "$start" || "$stat_session" != "$process_session" ]]; then
      [[ -d "$entry" ]] && printf 'U\t%s\t%s\tidentity-changed\n' "$sample" "$pid"
      continue
    fi
    printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sample" "$pid" "$start" "$parent" "$parent_start" "$process_session" \
      "$exact_profile" "$gpu" "$chromium" "$fd_owner"
    [[ "$opaque" == 0 ]] || printf 'U\t%s\t%s\tfd-unreadable\n' "$sample" "$pid"
  done
  printf 'END\t%s\n' "$sample"
}

if [[ "$action" == preflight ]]; then
  [[ -z "$root" ]] || exit 2
  rootless_snapshot "$argument" 0 -
  exit
fi

if [[ "$action" == create ]]; then
  [[ -z "$root" ]] || exit 2
  umask 077
  root="$(mktemp -d /tmp/chromium-video-qa.XXXXXXXXXXXX)"
  printf '%s\n' "$token" >"$root/.owner"
  mkdir "$root/profile" "$root/media"
  printf '%s\n' "$root"
  exit
fi

[[ "$root" =~ ^/tmp/chromium-video-qa\.[A-Za-z0-9]{12}$ ]] || exit 2
[[ -d "$root" && ! -L "$root" && -O "$root" ]] || exit 2
[[ -f "$root/.owner" && ! -L "$root/.owner" ]] || exit 2
[[ "$(<"$root/.owner")" == "$token" ]] || exit 2
[[ -d "$root/profile" && ! -L "$root/profile" && -O "$root/profile" ]] || exit 2

read_run_identity() {
  local version extra
  [[ -f "$root/.browser-identity" && ! -L "$root/.browser-identity" ]] || return 1
  IFS=$'\t' read -r version run_boot run_pid run_start run_session run_token run_profile extra \
    <"$root/.browser-identity" || return 1
  [[ "$version" == ROOTLESS_RUN_V1 && -z "$extra" &&
     "$run_boot" =~ ^[0-9a-f-]{36}$ && "$run_pid" =~ ^[1-9][0-9]*$ &&
     "$run_start" =~ ^[1-9][0-9]*$ && "$run_session" =~ ^[1-9][0-9]*$ &&
     "$run_token" == "$token" && "$run_profile" == "$root/profile" ]] || return 1
}

validate_record() {
  local require_live="$1" owner value found=0
  read_run_identity || return 3
  [[ "$(< /proc/sys/kernel/random/boot_id)" == "$run_boot" ]] || return 3
  if [[ ! -d "/proc/$run_pid" ]]; then
    [[ "$require_live" == 0 ]] || return 3
    return 0
  fi
  owner="$(stat -Lc %u -- "/proc/$run_pid" 2>/dev/null)" || return 3
  [[ "$owner" == "$(id -u)" ]] || return 3
  read_stat "/proc/$run_pid" || return 3
  [[ "$stat_start" == "$run_start" && "$stat_session" == "$run_session" ]] || return 3
  read_args "/proc/$run_pid" || return 3
  split_words
  for value in "${process_words[@]}"; do
    [[ "$value" == "--user-data-dir=$run_profile" ]] && found=1
  done
  [[ "$found" == 1 ]] || return 3
}

run_processes() {
  local observation
  if [[ -e "$root/.launch-pending" && ! -e "$root/.browser-identity" ]]; then
    return 3
  fi
  if [[ ! -e "$root/.browser-identity" ]]; then
    [[ ! -e "$root/.session" ]] || return 3
    observation="$(rootless_snapshot - 0 "$root/profile")" || return 3
    evaluate_processes 0 <<<"$observation"
    return
  fi
  validate_record 0 || return 3
  observation="$(rootless_snapshot - "$run_session" "$run_profile")" || return 3
  evaluate_processes "$run_session" <<<"$observation"
}

case "$action" in
  arm)
    [[ ! -e "$root/.launch-pending" && ! -e "$root/.browser-identity" ]] || exit 3
    : >"$root/.launch-pending"
    ;;
  record)
    [[ -f "$root/.launch-pending" && ! -L "$root/.launch-pending" && "$argument" =~ ^[1-9][0-9]*$ ]] || exit 3
    run_pid="$argument"
    for _ in {1..100}; do
      if [[ -d "/proc/$run_pid" ]] && read_stat "/proc/$run_pid" && read_args "/proc/$run_pid"; then
        matched=0
        split_words
        for value in "${process_words[@]}"; do
          [[ "$value" == "--user-data-dir=$root/profile" ]] && matched=1
        done
        if [[ "$matched" == 1 ]]; then
          run_boot="$(< /proc/sys/kernel/random/boot_id)"
          printf 'ROOTLESS_RUN_V1\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$run_boot" "$run_pid" "$stat_start" "$stat_session" "$token" "$root/profile" \
            >"$root/.browser-identity.tmp"
          mv -T -- "$root/.browser-identity.tmp" "$root/.browser-identity"
          printf '%s\n' "$stat_session" >"$root/.session"
          rm -- "$root/.launch-pending"
          exit
        fi
      fi
      sleep 0.05
    done
    exit 3
    ;;
  session)
    read_run_identity || exit 3
    printf '%s\n' "$run_session"
    ;;
  validate) validate_record 1 || exit 3 ;;
  snapshot)
    read_run_identity || exit 3
    validate_record 0 || exit 3
    rootless_snapshot "$argument" "$run_session" "$run_profile"
    ;;
  processes) run_processes ;;
  ready)
    validate_record 1 || exit 3
    [[ -f "$root/profile/DevToolsActivePort" && ! -L "$root/profile/DevToolsActivePort" ]] || exit 3
    cat "$root/profile/DevToolsActivePort"
    ;;
  remove)
    remaining="$(run_processes)" || exit 3
    [[ -z "$remaining" ]] || exit 3
    rm -rf --one-file-system -- "$root"
    ;;
  *) exit 2 ;;
esac
