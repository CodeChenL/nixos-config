#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: run-matrix.sh MANIFEST.tsv [OUTPUT_DIR]" >&2
  exit 2
fi

manifest="$1"
output_dir="${2:-$PWD/chromium-video-qa-results}"
[[ -f "$manifest" ]] || {
  echo "missing manifest: $manifest" >&2
  exit 2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$output_dir"

awk -F '\t' '
  /^#/ || NF == 0 { next }
  NF != 9 { printf "manifest line %d has %d fields, expected 9\n", NR, NF > "/dev/stderr"; bad = 1 }
  $1 !~ /^[A-Za-z0-9._-]+$/ { printf "invalid id on line %d\n", NR > "/dev/stderr"; bad = 1 }
  seen[$1]++ { printf "duplicate id %s\n", $1 > "/dev/stderr"; bad = 1 }
  END { exit bad }
' "$manifest"

cp "$manifest" "$output_dir/manifest.tsv"
fixture_dir="$(cd "$(dirname "$manifest")" && pwd)"
for artifact in ffprobe.txt ffprobe-resolution.txt SHA256SUMS; do
  [[ -f "$fixture_dir/$artifact" ]] && cp "$fixture_dir/$artifact" "$output_dir/$artifact"
done

"$script_dir/probe-target.sh" >"$output_dir/probe.txt" 2>&1
summary="$output_dir/summary.tsv"
printf 'id\tplayback\thw_path\towned_cleanup\tglobal_idle\toverall\tmode\tcodec\tprofile\tbit_depth\tpixel\texit_code\n' >"$summary"

failed=0
blocked=0
while IFS=$'\t' read -r id mode media mime codec profile bit_depth pixel hold; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  result_file="$output_dir/$id-result.tsv"
  rm -f -- "$result_file"
  set +e
  OUTPUT_DIR="$output_dir" "$script_dir/run-scenario.sh" \
    "$id" "$mode" "$media" "$mime" "$codec" "$profile" \
    "$bit_depth" "$pixel" "$hold" </dev/null
  rc=$?
  set -e

  playback=PLAYBACK_UNKNOWN
  hw_path=HW_PATH_UNKNOWN
  owned_cleanup=OWNED_CLEANUP_UNKNOWN
  global_idle=GLOBAL_IDLE_UNKNOWN
  overall=OVERALL_FAIL
  valid=0
  if [[ -f "$result_file" && ! -L "$result_file" ]]; then
    mapfile -t result_lines <"$result_file"
    if [[ ${#result_lines[@]} -eq 1 ]]; then
      IFS=$'\t' read -r result_id playback hw_path owned_cleanup global_idle overall \
        result_codec result_profile result_bit_depth result_pixel extra <<<"${result_lines[0]}"
      if [[ -z "$extra" && "$result_id" == "$id" && "$result_codec" == "$codec" &&
          "$result_profile" == "$profile" && "$result_bit_depth" == "$bit_depth" &&
          "$result_pixel" == "$pixel" &&
          "$playback" =~ ^PLAYBACK_(PASS|FAIL|BLOCKED|UNKNOWN|UNSUPPORTED)$ &&
          "$hw_path" =~ ^HW_PATH_(OBSERVED|NOT_OBSERVED|FAIL|BLOCKED|UNKNOWN)$ &&
          "$owned_cleanup" =~ ^OWNED_CLEANUP_(PASS|FAIL|NOT_RUN|UNKNOWN)$ &&
          "$global_idle" == GLOBAL_IDLE_UNKNOWN &&
          "$overall" =~ ^OVERALL_(INCONCLUSIVE_ROOTLESS|FAIL|BLOCKED|UNSUPPORTED)$ ]]; then
        valid=1
      fi
    fi
  fi
  if [[ "$valid" != 1 ]]; then
    echo "missing or malformed scenario result: $id" >&2
    playback=PLAYBACK_UNKNOWN
    hw_path=HW_PATH_UNKNOWN
    owned_cleanup=OWNED_CLEANUP_UNKNOWN
    global_idle=GLOBAL_IDLE_UNKNOWN
    overall=OVERALL_FAIL
  elif [[ "$overall" == OVERALL_INCONCLUSIVE_ROOTLESS ]]; then
    if [[ "$rc" -eq 0 || "$playback" != PLAYBACK_PASS ||
        "$owned_cleanup" != OWNED_CLEANUP_PASS ||
        ! "$hw_path" =~ ^HW_PATH_(OBSERVED|NOT_OBSERVED)$ ]]; then
      overall=OVERALL_FAIL
    fi
  elif [[ "$overall" == OVERALL_BLOCKED ]]; then
    if [[ "$rc" -ne 3 || "$playback" != PLAYBACK_BLOCKED ||
        "$owned_cleanup" != OWNED_CLEANUP_NOT_RUN ]]; then
      overall=OVERALL_FAIL
    fi
  elif [[ "$overall" == OVERALL_UNSUPPORTED ]]; then
    if [[ "$rc" -ne 1 || "$playback" != PLAYBACK_UNSUPPORTED ]]; then
      overall=OVERALL_FAIL
    fi
  elif [[ "$rc" -eq 0 ]]; then
    overall=OVERALL_FAIL
  fi

  case "$overall" in
    OVERALL_BLOCKED) blocked=1 ;;
    OVERALL_INCONCLUSIVE_ROOTLESS|OVERALL_FAIL) failed=1 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$playback" "$hw_path" "$owned_cleanup" "$global_idle" "$overall" \
    "$mode" "$codec" "$profile" "$bit_depth" "$pixel" "$rc" >>"$summary"

  [[ "$blocked" == 0 ]] || break
done <"$manifest"

cat "$summary"
[[ "$failed" == 0 && "$blocked" == 0 ]]
