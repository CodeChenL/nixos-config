#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_HOST:?set TARGET_HOST}"
TARGET_USER="${TARGET_USER:-$(id -un)}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-7}"
VIDEO_DEVICE_REMOTE="${VIDEO_DEVICE_REMOTE:-/dev/video0}"

[[ "$VIDEO_DEVICE_REMOTE" =~ ^/dev/video[0-9]+$ ]] || {
  echo "VIDEO_DEVICE_REMOTE must be a /dev/videoN path" >&2
  exit 2
}

ssh_args=(
  -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
  -o StrictHostKeyChecking=accept-new
)
if [[ -n "${SSHPASS:-}" ]]; then
  command -v sshpass >/dev/null
  ssh_cmd=(sshpass -e ssh "${ssh_args[@]}")
else
  ssh_cmd=(ssh "${ssh_args[@]}")
fi

remote_command="VIDEO_DEVICE=$VIDEO_DEVICE_REMOTE bash -s"
"${ssh_cmd[@]}" "${TARGET_USER}@${TARGET_HOST}" "$remote_command" <<'REMOTE'
set -euo pipefail

echo "=== identity ==="
printf "arch="
dpkg --print-architecture 2>/dev/null || uname -m
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  printf "os=%s\n" "$PRETTY_NAME"
fi
printf "kernel="
uname -r
printf "glibc="
getconf GNU_LIBC_VERSION 2>/dev/null || true
if command -v chromium >/dev/null; then
  chromium --version || true
elif [[ -x /usr/lib/chromium/chromium ]]; then
  /usr/lib/chromium/chromium --version || true
fi
if [[ -x /usr/lib/chromium/chromium ]]; then
  readelf -n /usr/lib/chromium/chromium 2>/dev/null |
    awk '/Build ID/ {print "build_id=" $3}'
fi
dpkg-query -W -f='package=${Package}\tversion=${Version}\n' \
  chromium chromium-common chromium-sandbox libgl1-mesa-dri 2>/dev/null || true

echo "=== session safety ==="
id
find /run/user -maxdepth 2 -type s -name 'wayland-*' -print 2>/dev/null || true
pgrep -a -x chromium || true

echo "=== video devices ==="
for device in /sys/class/video4linux/video*; do
  [[ -e "$device" ]] || continue
  printf "%s\t" "${device##*/}"
  cat "$device/name"
done
fuser -v /dev/video* 2>&1 || true

if command -v v4l2-ctl >/dev/null; then
  echo "=== v4l2 compressed output ==="
  v4l2-ctl -d "$VIDEO_DEVICE" --list-formats-out-ext
  echo "=== v4l2 raw capture ==="
  v4l2-ctl -d "$VIDEO_DEVICE" --list-formats-ext
  echo "=== v4l2 controls ==="
  v4l2-ctl -d "$VIDEO_DEVICE" --list-ctrls-menus
elif command -v gst-inspect-1.0 >/dev/null; then
  echo "=== GStreamer V4L2 decoders ==="
  decoder_elements="$(
    gst-inspect-1.0 2>/dev/null |
      sed -n 's/^video4linux2:  \(v4l2[^:]*dec\):.*/\1/p'
  )"
  printf "%s\n" "$decoder_elements"
  while IFS= read -r element; do
    [[ -n "$element" ]] || continue
    echo "--- $element ---"
    gst-inspect-1.0 "$element" 2>/dev/null |
      sed -n '/SINK template:/,/Element Properties:/p' |
      grep -E 'SINK template|SRC template|video/x-|profile:|format:|drm-format:' ||
      true
  done <<<"$decoder_elements"
else
  echo "No v4l2-ctl or gst-inspect-1.0 available" >&2
  exit 4
fi
REMOTE
