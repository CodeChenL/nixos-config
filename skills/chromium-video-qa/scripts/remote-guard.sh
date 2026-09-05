#!/usr/bin/env bash
set -euo pipefail

action="$1"
token="$2"
[[ "$(id -u)" != 0 ]] || exit 2
[[ "$token" =~ ^[a-f0-9]{32}$ ]] || exit 2
if [[ "$action" == create ]]; then
  umask 077
  root="$(mktemp -d /tmp/chromium-video-qa.XXXXXXXXXXXX)"
  printf '%s\n' "$token" >"$root/.owner"
  mkdir "$root/profile" "$root/media"
  printf '%s\n' "$root"
  exit
fi

root="$3"
[[ "$root" =~ ^/tmp/chromium-video-qa\.[A-Za-z0-9]{12}$ ]] || exit 2
[[ -d "$root" && ! -L "$root" && -O "$root" ]] || exit 2
[[ -f "$root/.owner" && ! -L "$root/.owner" ]] || exit 2
[[ "$(cat "$root/.owner")" == "$token" ]] || exit 2
[[ -d "$root/profile" && ! -L "$root/profile" ]] || exit 2

session_id() {
  local session=0
  if [[ -e "$root/.launch-pending" && ! -e "$root/.session" ]]; then
    return 2
  fi
  if [[ -e "$root/.session" ]]; then
    [[ -f "$root/.session" && ! -L "$root/.session" ]] || return 2
    session="$(cat "$root/.session")"
    [[ "$session" =~ ^[1-9][0-9]*$ ]] || return 2
  fi
  printf '%s\n' "$session"
}

observe() {
  local session namespace
  session="$(session_id)" || return 3
  namespace="$(readlink /proc/$$/ns/pid)" || return 3
  sudo -n -- /usr/local/libexec/chromium-qa-observer \
    "$1" "$namespace" "$2" "$session" "$root/profile"
}

processes() {
  local observed pid
  observed="$(observe processes -)" || return 3
  [[ "${observed%%$'\n'*}" == OBSERVER_V1 ]] || return 3
  observed="${observed#OBSERVER_V1}"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3
    printf '%s\n' "$pid"
  done <<<"$observed"
}

case "$action" in
  arm)
    processes >/dev/null || exit 3
    touch "$root/.launch-pending"
    ;;
  session) session_id ;;
  snapshot) observe snapshot "$4" ;;
  processes) processes ;;
  ready)
    remaining="$(processes)" || exit 3
    [[ -n "$remaining" ]] || exit 3
    [[ -f "$root/profile/DevToolsActivePort" && ! -L "$root/profile/DevToolsActivePort" ]] || exit 3
    cat "$root/profile/DevToolsActivePort"
    ;;
  remove)
    remaining="$(processes)" || exit 3
    [[ -z "$remaining" ]] || exit 3
    rm -rf --one-file-system -- "$root"
    ;;
  *) exit 2 ;;
esac
