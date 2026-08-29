#!/usr/bin/env bash

set -uo pipefail

budget=${LORE_MAIL_PREVIEW_TIMEOUT:-45s}
limit=${LORE_MAIL_PREVIEW_LIMIT:-30}
kill_after=${LORE_MAIL_PREVIEW_KILL_AFTER:-1s}
producer=$(cat)

timeout --kill-after="$kill_after" "$budget" \
  bash -o pipefail -c "$producer" | head -n "$limit"
statuses=("${PIPESTATUS[@]}")
producer_status=${statuses[0]}
head_status=${statuses[1]}

if (( head_status != 0 )); then
  printf 'preview output failed with status %d\n' "$head_status" >&2
  exit "$head_status"
fi

case $producer_status in
  0|141)
    exit 0
    ;;
  124|137)
    printf 'preview pipeline timed out with status 124\n' >&2
    exit 124
    ;;
  *)
    printf 'preview producer failed with status %d\n' "$producer_status" >&2
    exit "$producer_status"
    ;;
esac
