#!/usr/bin/env bash

set -u

budget=${LORE_MAIL_PREVIEW_TIMEOUT:-45s}
limit=${LORE_MAIL_PREVIEW_LIMIT:-30}
kill_after=${LORE_MAIL_PREVIEW_KILL_AFTER:-1s}
producer=$(</dev/stdin)
status_file=
timeout_marker=

# shellcheck disable=SC2329
cleanup() {
  if [[ -n $status_file ]]; then
    rm -f -- "$status_file"
  fi
  if [[ -n $timeout_marker ]]; then
    rm -f -- "$timeout_marker"
  fi
}

trap cleanup EXIT

status_file=$(mktemp "${TMPDIR:-/tmp}/lore-mail-preview.XXXXXX") || exit $?
timeout_marker=$(mktemp "${TMPDIR:-/tmp}/lore-mail-preview-timeout.XXXXXX") || exit $?

# shellcheck disable=SC2016
timeout --kill-after="$kill_after" "$budget" bash -c '
  set -o pipefail

  producer=$1
  limit=$2
  status_file=$3
  status_capture=$4
  timeout_marker=$5
  trap "printf 1 > \"\$timeout_marker\"; while :; do sleep 1; done" TERM

  (
    eval "$producer$status_capture"
    printf "%s\n" "${producer_statuses[@]}" > "$status_file"
    write_status=$?
    if (( write_status != 0 )); then
      exit "$write_status"
    fi

    for (( stage = 0; stage < ${#producer_statuses[@]}; stage += 1 )); do
      status=${producer_statuses[stage]}
      if (( status != 0 && status != 141 )); then
        exit "$status"
      fi
    done

    exit 0
  ) | head -n "$limit"
  pipeline_statuses=("${PIPESTATUS[@]}")
  producer_status=${pipeline_statuses[0]}
  head_status=${pipeline_statuses[1]}

  if (( head_status != 0 )); then
    printf "preview pipeline stage 1 with status %d\n" "$head_status" >&2
    exit "$head_status"
  fi

  if [[ ! -s $status_file ]]; then
    printf "preview pipeline stage 0 with status 1\n" >&2
    exit 1
  fi

  stage=0
  while IFS= read -r status; do
    if (( status != 0 && status != 141 )); then
      printf "preview pipeline stage %d with status %d\n" "$stage" "$status" >&2
      exit "$status"
    fi
    stage=$((stage + 1))
  done < "$status_file"

  if (( producer_status != 0 && producer_status != 141 )); then
    printf "preview pipeline stage 0 with status %d\n" "$producer_status" >&2
    exit "$producer_status"
  fi
' bash "$producer" "$limit" "$status_file" $'\nproducer_statuses=("${PIPESTATUS[@]}")' "$timeout_marker"
timeout_status=$?

if (( timeout_status == 137 )) && [[ -s $timeout_marker ]]; then
  timeout_status=124
fi

if (( timeout_status == 124 )); then
  printf 'preview pipeline timed out with status 124\n' >&2
fi

exit "$timeout_status"
