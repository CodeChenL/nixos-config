#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: run-scenario.sh ID MODE MEDIA MIME CODEC PROFILE BIT_DEPTH PIXEL HOLD" >&2
  exit 2
fi

id="$1"
mode="$2"
media="$3"
mime="$4"
expected_codec="$5"
profile="$6"
bit_depth="$7"
expected_pixel="$8"
require_device_hold="$9"

[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "invalid scenario id: $id" >&2
  exit 2
}
[[ "$mode" == full || "$mode" == seek ]] || {
  echo "invalid mode: $mode" >&2
  exit 2
}
[[ -f "$media" ]] || {
  echo "missing media: $media" >&2
  exit 2
}
[[ "$require_device_hold" == 0 || "$require_device_hold" == 1 ]] || {
  echo "HOLD must be 0 or 1" >&2
  exit 2
}

: "${TARGET_HOST:?set TARGET_HOST}"
TARGET_USER="${TARGET_USER:-$(id -un)}"
CHROMIUM_BIN="${CHROMIUM_BIN:-}"
XDG_RUNTIME_DIR_REMOTE="${XDG_RUNTIME_DIR_REMOTE:-}"
WAYLAND_DISPLAY_REMOTE="${WAYLAND_DISPLAY_REMOTE:-wayland-0}"
MESA_DRIVER="${MESA_DRIVER:-}"
CDP_LOCAL_PORT="${CDP_LOCAL_PORT:-9222}"
if [[ -v REMOTE_ROOT || -v CDP_REMOTE_PORT || -n "${CHROMIUM_EXTRA_FLAGS:-}" ]]; then
  echo "REMOTE_ROOT, CDP_REMOTE_PORT and CHROMIUM_EXTRA_FLAGS overrides are not allowed" >&2
  exit 2
fi
CDP_WAIT_SECONDS="${CDP_WAIT_SECONDS:-30}"
SCENARIO_TIMEOUT_SECONDS="${SCENARIO_TIMEOUT_SECONDS:-60}"
PAGE_TIMEOUT_MS="${PAGE_TIMEOUT_MS:-45000}"
QA_DRIVER_TIMEOUT_MS="${QA_DRIVER_TIMEOUT_MS:-60000}"
SEEK_AT="${SEEK_AT:-2}"
SEEK_TO="${SEEK_TO:-4}"
KEEP_REMOTE="${KEEP_REMOTE:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/chromium-video-qa-results}"
NODE_BIN="${NODE_BIN:-node}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-7}"
VIDEO_DEVICE_REMOTE="${VIDEO_DEVICE_REMOTE:-/dev/video0}"
RUNTIME_STATUS_REMOTE="${RUNTIME_STATUS_REMOTE:-/sys/class/video4linux/${VIDEO_DEVICE_REMOTE##*/}/device/power/runtime_status}"

[[ "$VIDEO_DEVICE_REMOTE" =~ ^/dev/video[0-9]+$ ]] || {
  echo "VIDEO_DEVICE_REMOTE must be a /dev/videoN path" >&2
  exit 2
}
for dependency in curl scp setsid ssh timeout; do
  command -v "$dependency" >/dev/null || {
    echo "missing local dependency: $dependency" >&2
    exit 2
  }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
target="${TARGET_USER}@${TARGET_HOST}"
remote_root=
created=0
run_token="$("$NODE_BIN" -e 'process.stdout.write(require("node:crypto").randomBytes(16).toString("hex"))')"

mkdir -p "$OUTPUT_DIR"
prefix="$OUTPUT_DIR/$id"
rm -f -- "$prefix-result.tsv"
ssh_args=(
  -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=no
  -o ControlPath=none
)
if [[ -n "${SSHPASS:-}" ]]; then
  command -v sshpass >/dev/null
  ssh_cmd=(sshpass -e ssh "${ssh_args[@]}")
  scp_cmd=(sshpass -e scp "${ssh_args[@]}")
else
  ssh_cmd=(ssh "${ssh_args[@]}")
  scp_cmd=(scp "${ssh_args[@]}")
fi

remote() {
  "${ssh_cmd[@]}" "$target" "$@"
}

if [[ -z "$CHROMIUM_BIN" ]]; then
  CHROMIUM_BIN="$(remote '
    if test -x /usr/lib/chromium/chromium; then
      printf %s /usr/lib/chromium/chromium
    else
      command -v chromium
    fi
  ')"
fi
if [[ -z "$XDG_RUNTIME_DIR_REMOTE" ]]; then
  XDG_RUNTIME_DIR_REMOTE="/run/user/$(remote 'id -u')"
fi
remote "test -x $(printf '%q' "$CHROMIUM_BIN") && test \"\$(id -u)\" -ne 0 &&
  command -v sudo >/dev/null && command -v timeout >/dev/null &&
  command -v setsid >/dev/null"

quote() {
  printf '%q' "$1"
}

guard() {
  remote "bash -s -- $(quote "$1") $(quote "$run_token") $(quote "$remote_root") $(quote "${2:--}")" \
    <"$script_dir/remote-guard.sh"
}

device_snapshot() {
  guard snapshot "$VIDEO_DEVICE_REMOTE" >"$1" 2>"$1.stderr"
}

device_idle() {
  local status=0
  device_snapshot "$1" || status=$?
  printf '%s\n' "$status" >"$1.status"
  [[ "$status" == 0 && ! -s "$1.stderr" ]] &&
    "$NODE_BIN" "$script_dir/check-observation.js" idle "$1" "$run_session"
}

wait_runtime_idle() {
  local path_q
  [[ "$RUNTIME_STATUS_REMOTE" != - ]] || return 0
  path_q="$(quote "$RUNTIME_STATUS_REMOTE")"
  remote "if test -r $path_q; then
    for attempt in \$(seq 1 50); do
      status=\$(cat $path_q)
      test \"\$status\" = suspended && break
      sleep 0.1
    done
    cat $path_q
  fi"
}

tunnel_pid=
monitor_pid=
monitor_rc=0
tunnel_socket=
stop_group() {
  local pid="$1"
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
stop_monitor() {
  kill -TERM "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || monitor_rc=$?
}
cleanup() {
  if [[ -n "$monitor_pid" ]]; then
    stop_monitor
  fi
  if [[ -n "$tunnel_pid" ]]; then
    stop_group "$tunnel_pid"
  fi
  if [[ "$created" == 1 && "$KEEP_REMOTE" != 1 ]]; then
    if ! guard remove; then
      echo "cleanup refused; retained owned run directory: $remote_root" >&2
      printf '%s\tFAIL\t%s\t%s\t%s\t%s\n' \
        "$id" "$expected_codec" "$profile" "$bit_depth" "$expected_pixel" \
        >"$prefix-result.tsv"
    fi
  fi
  [[ -z "$tunnel_socket" ]] || rm -f -- "$tunnel_socket"
}
trap cleanup EXIT

observer_status=0
remote "sudo -n -- /usr/local/libexec/chromium-qa-observer snapshot \
  \"\$(readlink /proc/\$\$/ns/pid)\" $VIDEO_DEVICE_REMOTE 0 -" \
  >"$prefix-preexisting-video.txt" 2>"$prefix-preexisting-video.txt.stderr" || observer_status=$?
printf '%s\n' "$observer_status" >"$prefix-preexisting-video.txt.status"
if [[ "$observer_status" != 0 || -s "$prefix-preexisting-video.txt.stderr" ]] ||
    ! "$NODE_BIN" "$script_dir/check-observation.js" preflight "$prefix-preexisting-video.txt" 0; then
  echo "privileged observer unavailable, opaque, or target busy; refusing $id" >&2
  exit 3
fi
runtime_before="$(wait_runtime_idle)"
if [[ -n "$runtime_before" ]]; then
  printf '%s\n' "$runtime_before" >"$prefix-prelaunch-runtime.txt"
  if [[ "$runtime_before" != suspended ]]; then
    echo "video runtime did not become suspended before $id" >&2
    exit 3
  fi
fi

remote_root="$(guard create)"
[[ "$remote_root" =~ ^/tmp/chromium-video-qa\.[A-Za-z0-9]{12}$ ]] || exit 4
created=1
printf '%s\n' "$remote_root" >"$prefix-remote-root.txt"
remote_media="$remote_root/media/$id.${media##*.}"
"${scp_cmd[@]}" "$skill_dir/assets/video-qa.html" \
  "$target:$remote_root/video-qa.html"
"${scp_cmd[@]}" "$media" "$target:$remote_media"

remote_log="$remote_root/$id-chromium.log"
url="$("$NODE_BIN" -e '
  const [root, id, mode, media, mime, timeoutMs, seekAt, seekTo, run] = process.argv.slice(1);
  const url = new URL("file://" + root + "/video-qa.html");
  url.search = new URLSearchParams({id, mode, src: "file://" + media, mime, timeoutMs, seekAt, seekTo, run});
  process.stdout.write(url.href);
' "$remote_root" "$id" "$mode" "$remote_media" "$mime" "$PAGE_TIMEOUT_MS" "$SEEK_AT" "$SEEK_TO" "$run_token")"

launch="exec env"
launch+=" XDG_RUNTIME_DIR=$(quote "$XDG_RUNTIME_DIR_REMOTE")"
launch+=" WAYLAND_DISPLAY=$(quote "$WAYLAND_DISPLAY_REMOTE")"
if [[ -n "$MESA_DRIVER" ]]; then
  launch+=" MESA_LOADER_DRIVER_OVERRIDE=$(quote "$MESA_DRIVER")"
fi
launch+=" $(quote "$CHROMIUM_BIN")"
flags=(
  --ozone-platform=wayland
  --use-gl=angle
  --use-angle=gles
  "--enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL"
  --ignore-gpu-blocklist
  --remote-debugging-address=127.0.0.1
  --remote-debugging-port=0
  --enable-automation
  "--user-data-dir=$remote_root/profile"
  --no-first-run
  --no-default-browser-check
  --autoplay-policy=no-user-gesture-required
  --enable-logging=stderr
  --v=1
  "--vmodule=v4l2_stateful_video_decoder=4,v4l2_device=3,video_decoder_pipeline=2"
  --disable-component-update
)
for flag in "${flags[@]}"; do
  launch+=" $(quote "$flag")"
done
launch+=" $(quote "$url")"
launch="printf '%s\\n' \"\$\$\" >$(quote "$remote_root/.session"); $launch"
launch="nohup setsid bash -c $(quote "$launch")"
launch+=" >$(quote "$remote_log") 2>&1 < /dev/null & echo \$!"

guard arm
remote "$launch" >"$prefix-launch-pid.txt"

ready=0
for ((i = 0; i < CDP_WAIT_SECONDS * 5; ++i)); do
  if guard ready >"$prefix-active-port.txt"; then
    mapfile -t active_port <"$prefix-active-port.txt"
    if [[ "${active_port[0]:-}" =~ ^[0-9]+$ && "${active_port[1]:-}" =~ ^/devtools/browser/[A-Za-z0-9-]+$ ]]; then
      ready=1
      break
    fi
  fi
  sleep 0.2
done
[[ "$ready" == 1 ]] || exit 4
CDP_REMOTE_PORT="${active_port[0]}"
run_session="$(guard session)"
tunnel_socket="/tmp/chromium-qa-$run_token.sock"
setsid "${ssh_cmd[@]}" -N -S "$tunnel_socket" -M \
  -o ExitOnForwardFailure=yes -o ControlPersist=no \
  -L "127.0.0.1:$CDP_LOCAL_PORT:127.0.0.1:$CDP_REMOTE_PORT" "$target" \
  >"$prefix-tunnel.log" 2>&1 &
tunnel_pid=$!

setsid bash "$script_dir/monitor-observer.sh" "$SCENARIO_TIMEOUT_SECONDS" \
  "$target" "$run_token" "$remote_root" "$VIDEO_DEVICE_REMOTE" "${ssh_cmd[@]}" \
  >"$prefix-monitor.log" 2>"$prefix-monitor.stderr" &
monitor_pid=$!

ready=0
for ((i = 0; i < CDP_WAIT_SECONDS * 5; ++i)); do
  kill -0 "$tunnel_pid" 2>/dev/null || break
  if "${ssh_cmd[@]}" -S "$tunnel_socket" -O check "$target" 2>/dev/null &&
    curl --max-time 2 -fsS "http://127.0.0.1:$CDP_LOCAL_PORT/json/version" \
      >"$prefix-cdp-version.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
if [[ "$ready" != 1 ]]; then
  echo "CDP did not become ready for $id" >&2
  exit 4
fi

set +e
CDP_URL="http://127.0.0.1:$CDP_LOCAL_PORT" \
QA_EXPECTED_URL="$url" QA_RUN_TOKEN="$run_token" \
QA_PROFILE="$remote_root/profile" QA_BROWSER_PATH="${active_port[1]}" \
QA_DRIVER_TIMEOUT_MS="$QA_DRIVER_TIMEOUT_MS" \
NODE_PATH="${NODE_PATH:-}" \
timeout --foreground "$SCENARIO_TIMEOUT_SECONDS" \
  "$NODE_BIN" "$script_dir/drive-video-qa.js" "$prefix" "$mode" \
  >"$prefix-driver.json" 2>"$prefix-driver.stderr"
driver_rc=$?
set -e

stop_monitor
printf '%s\n' "$monitor_rc" >"$prefix-monitor.status"
monitor_pid=
stop_group "$tunnel_pid"
tunnel_pid=

"${scp_cmd[@]}" "$target:$remote_log" "$prefix-chromium.log"
sleep 1
guard processes >"$prefix-postclose-process.txt"
device_released=0
if device_idle "$prefix-postclose-video.txt"; then
  device_released=1
fi
wait_runtime_idle >"$prefix-postclose-runtime.txt"

result=INCONCLUSIVE
echo "No build-validated playback-correlated CAPTURE/output evidence collector; hardware result INCONCLUSIVE" \
  >"$prefix-hardware-evidence.txt"
if [[ "$driver_rc" -ne 0 ]]; then
  result=FAIL
fi
if ! grep -Fq 'v4l2_stateful_video_decoder.cc' "$prefix-chromium.log"; then
  echo "V4L2 stateful decoder was not observed" >&2
  result=FAIL
fi
if [[ "$expected_pixel" != - ]] &&
    ! grep -Fq "format:$expected_pixel" "$prefix-chromium.log"; then
  echo "expected pixel format not found in log: $expected_pixel" >&2
  result=FAIL
fi
if [[ "$monitor_rc" != 0 || -s "$prefix-monitor.stderr" ]] ||
    ! "$NODE_BIN" "$script_dir/check-observation.js" complete "$prefix-monitor.log" "$run_session"; then
  echo "monitor observation incomplete" >&2
  result=FAIL
fi
if [[ "$require_device_hold" == 1 ]] &&
    ! "$NODE_BIN" "$script_dir/check-observation.js" hold "$prefix-monitor.log" "$run_session"; then
  echo "same-sample session GPU device ownership not observed" >&2
  result=FAIL
fi
if [[ -s "$prefix-postclose-process.txt" ]]; then
  echo "QA Chromium remained after Browser.close" >&2
  result=FAIL
fi
if [[ "$device_released" != 1 ]]; then
  echo "device owners remain or postclose observer failed; baseline was empty" >&2
  result=FAIL
fi
if [[ -s "$prefix-postclose-runtime.txt" ]] &&
    ! grep -qx suspended "$prefix-postclose-runtime.txt"; then
  echo "video runtime did not suspend after Browser.close" >&2
  result=FAIL
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$id" "$result" "$expected_codec" "$profile" "$bit_depth" "$expected_pixel" \
  >"$prefix-result.tsv"
[[ "$result" == PASS ]]
