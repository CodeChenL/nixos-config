#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: generate-fixtures.sh OUTPUT_DIR" >&2
  exit 2
fi

command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null
out="$1"
width="${WIDTH:-1280}"
height="${HEIGHT:-720}"
fps="${FPS:-30}"
duration="${DURATION:-6}"
force="${FORCE:-0}"
resolution_matrix="${RESOLUTION_MATRIX:-0}"
mkdir -p "$out"
source_filter="testsrc2=size=${width}x${height}:rate=${fps}:duration=${duration}"
gop="$fps"

encode() {
  local output="$1"
  shift
  if [[ -s "$output" && "$force" != 1 ]]; then
    return
  fi
  ffmpeg -hide_banner -loglevel warning -y -f lavfi -i "$source_filter" -an "$@" "$output"
}

encode "$out/h264-high.mp4" -c:v libx264 -preset veryfast -profile:v high -level:v 3.1 -pix_fmt yuv420p -g "$gop" -movflags +faststart
encode "$out/hevc-main.mp4" -c:v libx265 -preset ultrafast -profile:v main -pix_fmt yuv420p -g "$gop" -tag:v hvc1 -movflags +faststart
encode "$out/hevc-main10.mp4" -c:v libx265 -preset ultrafast -profile:v main10 -pix_fmt yuv420p10le -g "$gop" -tag:v hvc1 -movflags +faststart
encode "$out/vp9-profile0.webm" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -profile:v 0 -pix_fmt yuv420p -g "$gop" -b:v 0 -crf 32
encode "$out/vp9-profile2.webm" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -profile:v 2 -pix_fmt yuv420p10le -g "$gop" -b:v 0 -crf 32

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$resolution_matrix" != 1 ]]; then
  exec env PYTHONPATH="$skill_dir" python3 -m firefox_qa.build_manifest "$out"
fi

encode_resolution() {
  local output="$1"
  local input="$2"
  shift 2
  if [[ -s "$output" && "$force" != 1 ]]; then
    return
  fi
  ffmpeg -hide_banner -loglevel warning -y -f lavfi -i "$input" -an "$@" "$output"
}

generate_resolution() {
  local tag="$1"
  local matrix_width="$2"
  local matrix_height="$3"
  local matrix_fps="$4"
  local matrix_source="testsrc2=size=${matrix_width}x${matrix_height}:rate=${matrix_fps}:duration=${duration}"

  encode_resolution "$out/h264-high-$tag.mp4" "$matrix_source" \
    -c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p -g "$matrix_fps" \
    -x264-params "keyint=$matrix_fps:min-keyint=$matrix_fps:scenecut=0" \
    -movflags +faststart
  encode_resolution "$out/hevc-main-$tag.mp4" "$matrix_source" \
    -c:v libx265 -preset ultrafast -profile:v main -pix_fmt yuv420p -g "$matrix_fps" \
    -tag:v hvc1 -movflags +faststart
  encode_resolution "$out/hevc-main10-$tag.mp4" "$matrix_source" \
    -c:v libx265 -preset ultrafast -profile:v main10 -pix_fmt yuv420p10le -g "$matrix_fps" \
    -tag:v hvc1 -movflags +faststart
  encode_resolution "$out/vp9-profile0-$tag.webm" "$matrix_source" \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
    -profile:v 0 -pix_fmt yuv420p -g "$matrix_fps" -b:v 0 -crf 32
  encode_resolution "$out/vp9-profile2-$tag.webm" "$matrix_source" \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
    -profile:v 2 -pix_fmt yuv420p10le -g "$matrix_fps" -b:v 0 -crf 32
}

generate_resolution 1080p30 1920 1080 30
generate_resolution 1080p60 1920 1080 60
generate_resolution 4k30 3840 2160 30
generate_resolution 4k60 3840 2160 60

env PYTHONPATH="$skill_dir" python3 -m firefox_qa.build_manifest "$out"
exec env PYTHONPATH="$skill_dir" python3 -m firefox_qa.build_manifest \
  "$out" --resolution-matrix "$duration"
