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
for artifact in ffprobe.txt SHA256SUMS; do
  [[ -f "$fixture_dir/$artifact" ]] &&
    cp "$fixture_dir/$artifact" "$output_dir/$artifact"
done

"$script_dir/probe-target.sh" >"$output_dir/probe.txt" 2>&1
summary="$output_dir/summary.tsv"
printf 'id\tstatus\tmode\tcodec\tprofile\tbit_depth\tpixel\texit_code\n' >"$summary"

failed=0
blocked=0
while IFS=$'\t' read -r id mode media mime codec profile bit_depth pixel hold; do
  [[ -z "$id" || "$id" == \#* ]] && continue

  rm -f "$output_dir/$id-result.tsv"
  set +e
  OUTPUT_DIR="$output_dir" "$script_dir/run-scenario.sh" \
    "$id" "$mode" "$media" "$mime" "$codec" "$profile" \
    "$bit_depth" "$pixel" "$hold" </dev/null
  rc=$?
  set -e

  status=PASS
  if [[ "$rc" -eq 3 ]]; then
    status=BLOCKED
    blocked=1
  elif [[ "$rc" -ne 0 ]]; then
    status=FAIL
    failed=1
  fi
  if [[ -f "$output_dir/$id-result.tsv" ]]; then
    read -r _ status _ <"$output_dir/$id-result.tsv"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$status" "$mode" "$codec" "$profile" "$bit_depth" \
    "$pixel" "$rc" >>"$summary"

  [[ "$blocked" == 0 ]] || break
done <"$manifest"

cat "$summary"
[[ "$failed" == 0 && "$blocked" == 0 ]]
