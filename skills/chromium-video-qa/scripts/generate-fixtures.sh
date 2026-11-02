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

encode() {
  local output="$1"
  shift
  if [[ -s "$output" && "$force" != 1 ]]; then
    echo "reuse $output"
    return
  fi
  ffmpeg -hide_banner -loglevel warning -y "$@" "$output"
}

source_filter="testsrc2=size=${width}x${height}:rate=${fps}:duration=${duration}"
gop="$fps"

for profile in baseline main high; do
  name="$profile"
  [[ "$profile" == baseline ]] && name=constrained-baseline
  keyframe_args=()
  if [[ "$profile" == baseline ]]; then
    keyframe_args=(-force_key_frames "expr:gte(t,$duration-1/$fps)")
  fi
  encode "$out/h264-$name.mp4" \
    -f lavfi -i "$source_filter" -an \
    "${keyframe_args[@]}" \
    -c:v libx264 -preset veryfast -profile:v "$profile" -level:v 3.1 \
    -pix_fmt yuv420p -g "$gop" \
    -x264-params "keyint=$gop:min-keyint=$gop:scenecut=0" \
    -movflags +faststart
done

encode "$out/hevc-main.mp4" \
  -f lavfi -i "$source_filter" -an \
  -c:v libx265 -preset ultrafast -profile:v main -pix_fmt yuv420p \
  -x265-params "log-level=error:keyint=$gop:min-keyint=$gop:scenecut=0" \
  -tag:v hvc1 -movflags +faststart

encode "$out/hevc-main10.mp4" \
  -f lavfi -i "$source_filter" -an \
  -c:v libx265 -preset ultrafast -profile:v main10 -pix_fmt yuv420p10le \
  -x265-params "log-level=error:keyint=$gop:min-keyint=$gop:scenecut=0" \
  -tag:v hvc1 -movflags +faststart

encode "$out/hevc-main-still-picture.mp4" \
  -f lavfi -i "testsrc2=size=${width}x${height}:rate=1" -an -frames:v 1 \
  -c:v libx265 -preset ultrafast -profile:v mainstillpicture -pix_fmt yuv420p \
  -x265-params "log-level=error:total-frames=1" \
  -tag:v hvc1 -movflags +faststart

encode "$out/vp9-profile0.webm" \
  -f lavfi -i "$source_filter" -an \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
  -profile:v 0 -pix_fmt yuv420p -g "$gop" -b:v 0 -crf 32

encode "$out/vp9-profile2.webm" \
  -f lavfi -i "$source_filter" -an \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
  -profile:v 2 -pix_fmt yuv420p10le -g "$gop" -b:v 0 -crf 32

require_field() {
  local file="$1"
  local field="$2"
  local expected="$3"
  local actual
  actual="$(ffprobe -v error -select_streams v:0 \
    -show_entries "stream=$field" -of default=nw=1:nk=1 "$file")"
  [[ "$actual" == "$expected" ]] || {
    echo "$file: expected $field=$expected, got $actual" >&2
    exit 3
  }
}

require_field "$out/h264-constrained-baseline.mp4" profile 'Constrained Baseline'
require_field "$out/h264-main.mp4" profile Main
require_field "$out/h264-high.mp4" profile High
require_field "$out/hevc-main.mp4" profile Main
require_field "$out/hevc-main10.mp4" profile 'Main 10'
require_field "$out/hevc-main-still-picture.mp4" profile 'Main Still Picture'
require_field "$out/vp9-profile0.webm" profile 'Profile 0'
require_field "$out/vp9-profile2.webm" profile 'Profile 2'
for file in h264-constrained-baseline.mp4 h264-main.mp4 h264-high.mp4 \
    hevc-main.mp4 hevc-main-still-picture.mp4 vp9-profile0.webm; do
  require_field "$out/$file" pix_fmt yuv420p
done
for file in hevc-main10.mp4 vp9-profile2.webm; do
  require_field "$out/$file" pix_fmt yuv420p10le
done

manifest="$out/manifest.tsv"
{
  printf '# id\tmode\tlocal_media\tmime\tcodec\tprofile\tbit_depth\tpixel\thold\n'
  printf 'h264-constrained-baseline\tfull\t%s\t%s\tH264\tconstrained-baseline\t8\tPIXEL_FORMAT_NV12\t1\n' \
    "$(realpath "$out/h264-constrained-baseline.mp4")" \
    'video/mp4;codecs=avc1.42C01F'
  printf 'h264-main\tfull\t%s\t%s\tH264\tmain\t8\tPIXEL_FORMAT_NV12\t1\n' \
    "$(realpath "$out/h264-main.mp4")" 'video/mp4;codecs=avc1.4D401F'
  printf 'h264-high\tfull\t%s\t%s\tH264\thigh\t8\tPIXEL_FORMAT_NV12\t1\n' \
    "$(realpath "$out/h264-high.mp4")" 'video/mp4;codecs=avc1.64001F'
  printf 'hevc-main\tfull\t%s\t%s\tHEVC\tmain\t8\tPIXEL_FORMAT_NV12\t1\n' \
    "$(realpath "$out/hevc-main.mp4")" 'video/mp4;codecs=hvc1.1.6.L93.B0'
  printf 'hevc-main10\tfull\t%s\t%s\tHEVC\tmain10\t10\tPIXEL_FORMAT_P010LE\t1\n' \
    "$(realpath "$out/hevc-main10.mp4")" 'video/mp4;codecs=hvc1.2.4.L93.B0'
  printf 'hevc-main-still-picture\tfull\t%s\t%s\tHEVC\tmain-still-picture\t8\tPIXEL_FORMAT_NV12\t0\n' \
    "$(realpath "$out/hevc-main-still-picture.mp4")" \
    'video/mp4;codecs=hvc1.3.4.L93.B0'
  printf 'vp9-profile0\tfull\t%s\t%s\tVP9\tprofile0\t8\tPIXEL_FORMAT_NV12\t1\n' \
    "$(realpath "$out/vp9-profile0.webm")" \
    'video/webm;codecs=vp09.00.10.08'
  printf 'vp9-profile2\tfull\t%s\t%s\tVP9\tprofile2\t10\tPIXEL_FORMAT_P010LE\t1\n' \
    "$(realpath "$out/vp9-profile2.webm")" \
    'video/webm;codecs=vp09.02.10.10'
  printf 'hevc-main10-seek\tseek\t%s\t%s\tHEVC\tmain10\t10\tPIXEL_FORMAT_P010LE\t1\n' \
    "$(realpath "$out/hevc-main10.mp4")" 'video/mp4;codecs=hvc1.2.4.L93.B0'
} >"$manifest"

: >"$out/ffprobe.txt"
while IFS=$'\t' read -r id _mode media _; do
  [[ "$id" == \#* ]] && continue
  printf '%s\t' "$id" >>"$out/ffprobe.txt"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,pix_fmt,width,height,r_frame_rate \
    -of compact=p=0 "$media" >>"$out/ffprobe.txt"
done <"$manifest"

generate_resolution_matrix() {
  local -a tags=(1080p30 1080p60 4k30 4k60)
  local -a widths=(1920 1920 3840 3840)
  local -a heights=(1080 1080 2160 2160)
  local -a frame_rates=(30 60 30 60)
  local -a h264_levels=(4.0 4.2 5.1 5.2)
  local -a h264_level_ids=(40 42 51 52)
  local -a h264_codecs=(avc1.640028 avc1.64002A avc1.640033 avc1.640034)
  local -a vp9_levels=(40 41 50 51)
  local matrix_manifest="$out/manifest-resolution.tsv"
  local matrix_probe="$out/ffprobe-resolution.txt"
  local index tag matrix_width matrix_height matrix_fps matrix_filter matrix_gop

  for index in "${!tags[@]}"; do
    tag="${tags[$index]}"
    matrix_width="${widths[$index]}"
    matrix_height="${heights[$index]}"
    matrix_fps="${frame_rates[$index]}"
    matrix_filter="testsrc2=size=${matrix_width}x${matrix_height}:rate=${matrix_fps}:duration=${duration}"
    matrix_gop="$matrix_fps"

    encode "$out/h264-high-$tag.mp4" \
      -f lavfi -i "$matrix_filter" -an \
      -c:v libx264 -preset veryfast -profile:v high \
      -level:v "${h264_levels[$index]}" -pix_fmt yuv420p -g "$matrix_gop" \
      -x264-params "keyint=$matrix_gop:min-keyint=$matrix_gop:scenecut=0" \
      -movflags +faststart
    encode "$out/vp9-profile0-$tag.webm" \
      -f lavfi -i "$matrix_filter" -an \
      -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
      -profile:v 0 -pix_fmt yuv420p -g "$matrix_gop" -b:v 0 -crf 32
    encode "$out/vp9-profile2-$tag.webm" \
      -f lavfi -i "$matrix_filter" -an \
      -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 \
      -profile:v 2 -pix_fmt yuv420p10le -g "$matrix_gop" -b:v 0 -crf 32

    require_field "$out/h264-high-$tag.mp4" codec_name h264
    require_field "$out/h264-high-$tag.mp4" profile High
    require_field "$out/h264-high-$tag.mp4" pix_fmt yuv420p
    require_field "$out/h264-high-$tag.mp4" width "$matrix_width"
    require_field "$out/h264-high-$tag.mp4" height "$matrix_height"
    require_field "$out/h264-high-$tag.mp4" r_frame_rate "$matrix_fps/1"
    require_field "$out/h264-high-$tag.mp4" level "${h264_level_ids[$index]}"

    require_field "$out/vp9-profile0-$tag.webm" codec_name vp9
    require_field "$out/vp9-profile0-$tag.webm" profile 'Profile 0'
    require_field "$out/vp9-profile0-$tag.webm" pix_fmt yuv420p
    require_field "$out/vp9-profile0-$tag.webm" width "$matrix_width"
    require_field "$out/vp9-profile0-$tag.webm" height "$matrix_height"
    require_field "$out/vp9-profile0-$tag.webm" r_frame_rate "$matrix_fps/1"

    require_field "$out/vp9-profile2-$tag.webm" codec_name vp9
    require_field "$out/vp9-profile2-$tag.webm" profile 'Profile 2'
    require_field "$out/vp9-profile2-$tag.webm" pix_fmt yuv420p10le
    require_field "$out/vp9-profile2-$tag.webm" width "$matrix_width"
    require_field "$out/vp9-profile2-$tag.webm" height "$matrix_height"
    require_field "$out/vp9-profile2-$tag.webm" r_frame_rate "$matrix_fps/1"
  done

  {
    printf '# id\tmode\tlocal_media\tmime\tcodec\tprofile\tbit_depth\tpixel\thold\n'
    for index in "${!tags[@]}"; do
      tag="${tags[$index]}"
      printf 'h264-high-%s\tfull\t%s\tvideo/mp4;codecs=%s\tH264\thigh\t8\tPIXEL_FORMAT_NV12\t1\n' \
        "$tag" "$(realpath "$out/h264-high-$tag.mp4")" "${h264_codecs[$index]}"
    done
    for index in "${!tags[@]}"; do
      tag="${tags[$index]}"
      printf 'vp9-profile0-%s\tfull\t%s\tvideo/webm;codecs=vp09.00.%s.08\tVP9\tprofile0\t8\tPIXEL_FORMAT_NV12\t1\n' \
        "$tag" "$(realpath "$out/vp9-profile0-$tag.webm")" "${vp9_levels[$index]}"
    done
    for index in "${!tags[@]}"; do
      tag="${tags[$index]}"
      printf 'vp9-profile2-%s\tfull\t%s\tvideo/webm;codecs=vp09.02.%s.10\tVP9\tprofile2\t10\tPIXEL_FORMAT_P010LE\t1\n' \
        "$tag" "$(realpath "$out/vp9-profile2-$tag.webm")" "${vp9_levels[$index]}"
    done
  } >"$matrix_manifest"

  : >"$matrix_probe"
  while IFS=$'\t' read -r id _mode media _; do
    [[ "$id" == \#* ]] && continue
    printf '%s\t' "$id" >>"$matrix_probe"
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,profile,pix_fmt,width,height,r_frame_rate,level \
      -of compact=p=0 "$media" >>"$matrix_probe"
  done <"$matrix_manifest"
}

if [[ "$resolution_matrix" == 1 ]]; then
  generate_resolution_matrix
fi

sha256sum "$out"/*.mp4 "$out"/*.webm >"$out/SHA256SUMS"
printf '%s\n' "$manifest"
