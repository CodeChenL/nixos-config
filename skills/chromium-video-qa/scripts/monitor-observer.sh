#!/usr/bin/env bash
set -euo pipefail

duration="$1"
target="$2"
token="$3"
root="$4"
device="$5"
shift 5
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf -v command 'bash -s -- snapshot %q %q %q' "$token" "$root" "$device"
stopping=0
trap 'stopping=1' TERM
while (( SECONDS < duration && stopping == 0 )); do
  if ! sample="$(timeout --kill-after=2 10 "$@" "$target" "$command" <"$script_dir/remote-guard.sh")"; then
    printf 'UNKNOWN\n'
    exit 1
  fi
  printf '%s\n' "$sample"
  sleep 0.2
done
