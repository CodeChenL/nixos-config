'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const generator = path.join(__dirname, 'generate-fixtures.sh');

function writeExecutable(file, contents) {
  fs.writeFileSync(file, contents, {mode: 0o700});
}

function normalizedManifest(file) {
  return fs.readFileSync(file, 'utf8').trim().split('\n').map((line) => {
    if (line.startsWith('#')) return line;
    const fields = line.split('\t');
    fields[2] = path.basename(fields[2]);
    return fields.join('\t');
  }).join('\n');
}

function makeFakeTools(bin) {
  writeExecutable(path.join(bin, 'ffmpeg'), `#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >>"$MOCK_FFMPEG_LOG"
printf '\\t%s' "$@" >>"$MOCK_FFMPEG_LOG"
printf '\\n' >>"$MOCK_FFMPEG_LOG"
output="\${!#}"
printf 'fixture\\n' >"$output"
`);

  writeExecutable(path.join(bin, 'ffprobe'), `#!/usr/bin/env bash
set -euo pipefail
file="\${!#}"
entries=
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -show_entries ]]; then
    entries="$2"
    shift 2
  else
    shift
  fi
done
base="$(basename "$file")"
printf '%s\\t%s\\n' "$base" "$entries" >>"$MOCK_FFPROBE_LOG"
codec=vp9
profile='Profile 0'
pix_fmt=yuv420p
width=1280
height=720
rate=30/1
level=31
case "$base" in
  h264-constrained-baseline.mp4) codec=h264; profile='Constrained Baseline' ;;
  h264-main.mp4) codec=h264; profile=Main ;;
  h264-*.mp4) codec=h264; profile=High ;;
  hevc-main10.mp4) codec=hevc; profile='Main 10'; pix_fmt=yuv420p10le ;;
  hevc-main-still-picture.mp4) codec=hevc; profile='Main Still Picture' ;;
  hevc-main.mp4) codec=hevc; profile=Main ;;
  vp9-profile2-*.webm|vp9-profile2.webm) profile='Profile 2'; pix_fmt=yuv420p10le ;;
esac
case "$base" in
  *-1080p30.*) width=1920; height=1080; rate=30/1; level=40 ;;
  *-1080p60.*) width=1920; height=1080; rate=60/1; level=42 ;;
  *-4k30.*) width=3840; height=2160; rate=30/1; level=51 ;;
  *-4k60.*) width=3840; height=2160; rate=60/1; level=52 ;;
esac
if [[ "\${MOCK_BAD_MATRIX_LEVEL:-0}" == 1 && "$base" == h264-high-1080p30.mp4 &&
    "$entries" == stream=level ]]; then
  level=31
fi
case "\${entries#stream=}" in
  codec_name) printf '%s\\n' "$codec" ;;
  profile) printf '%s\\n' "$profile" ;;
  pix_fmt) printf '%s\\n' "$pix_fmt" ;;
  width) printf '%s\\n' "$width" ;;
  height) printf '%s\\n' "$height" ;;
  r_frame_rate) printf '%s\\n' "$rate" ;;
  level) printf '%s\\n' "$level" ;;
  codec_name,profile,pix_fmt,width,height,r_frame_rate*)
    printf 'codec_name=%s|profile=%s|pix_fmt=%s|width=%s|height=%s|r_frame_rate=%s|level=%s\\n' \
      "$codec" "$profile" "$pix_fmt" "$width" "$height" "$rate" "$level"
    ;;
  *) printf 'unexpected show_entries: %s\\n' "$entries" >&2; exit 2 ;;
esac
`);

  writeExecutable(path.join(bin, 'sha256sum'), `#!/usr/bin/env bash
set -euo pipefail
for file in "$@"; do
  printf '%064d  %s\\n' 0 "$file"
done
`);
}

function runGenerator(output, bin, log, extraEnv = {}) {
  const result = spawnSync('bash', [generator, output], {
    encoding: 'utf8',
    timeout: 10000,
    env: {...process.env, PATH: bin + ':' + process.env.PATH,
      MOCK_FFMPEG_LOG: log, MOCK_FFPROBE_LOG: log + '.ffprobe', ...extraEnv},
  });
  assert.equal(result.status, 0, result.stderr);
}

function hasOption(args, option, value) {
  const index = args.indexOf(option);
  return index >= 0 && args[index + 1] === value;
}

test('resolution matrix is opt-in, deterministic, and preserves the default manifest', () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-fixtures-'));
  const bin = path.join(state, 'bin');
  const output = path.join(state, 'fixtures');
  const log = path.join(state, 'ffmpeg.log');
  fs.mkdirSync(bin);
  makeFakeTools(bin);

  try {
    runGenerator(output, bin, log);
    const defaultManifest = normalizedManifest(path.join(output, 'manifest.tsv'));
    assert.deepEqual(defaultManifest.split('\n').slice(1), [
      'h264-constrained-baseline\tfull\th264-constrained-baseline.mp4\tvideo/mp4;codecs=avc1.42C01F\tH264\tconstrained-baseline\t8\tPIXEL_FORMAT_NV12\t1',
      'h264-main\tfull\th264-main.mp4\tvideo/mp4;codecs=avc1.4D401F\tH264\tmain\t8\tPIXEL_FORMAT_NV12\t1',
      'h264-high\tfull\th264-high.mp4\tvideo/mp4;codecs=avc1.64001F\tH264\thigh\t8\tPIXEL_FORMAT_NV12\t1',
      'hevc-main\tfull\thevc-main.mp4\tvideo/mp4;codecs=hvc1.1.6.L93.B0\tHEVC\tmain\t8\tPIXEL_FORMAT_NV12\t1',
      'hevc-main10\tfull\thevc-main10.mp4\tvideo/mp4;codecs=hvc1.2.4.L93.B0\tHEVC\tmain10\t10\tPIXEL_FORMAT_P010LE\t1',
      'hevc-main-still-picture\tfull\thevc-main-still-picture.mp4\tvideo/mp4;codecs=hvc1.3.4.L93.B0\tHEVC\tmain-still-picture\t8\tPIXEL_FORMAT_NV12\t0',
      'vp9-profile0\tfull\tvp9-profile0.webm\tvideo/webm;codecs=vp09.00.10.08\tVP9\tprofile0\t8\tPIXEL_FORMAT_NV12\t1',
      'vp9-profile2\tfull\tvp9-profile2.webm\tvideo/webm;codecs=vp09.02.10.10\tVP9\tprofile2\t10\tPIXEL_FORMAT_P010LE\t1',
      'hevc-main10-seek\tseek\thevc-main10.mp4\tvideo/mp4;codecs=hvc1.2.4.L93.B0\tHEVC\tmain10\t10\tPIXEL_FORMAT_P010LE\t1',
    ]);
    assert.equal(fs.existsSync(path.join(output, 'manifest-resolution.tsv')), false);
    assert.equal(fs.existsSync(path.join(output, 'ffprobe-resolution.txt')), false);
    assert.equal(fs.readFileSync(log, 'utf8').trim().split('\n').length, 8);

    runGenerator(output, bin, log, {RESOLUTION_MATRIX: '1'});
    assert.equal(normalizedManifest(path.join(output, 'manifest.tsv')), defaultManifest);

    const tags = [
      ['1080p30', 1920, 1080, 30, '4.0', 'avc1.640028', '40'],
      ['1080p60', 1920, 1080, 60, '4.2', 'avc1.64002A', '41'],
      ['4k30', 3840, 2160, 30, '5.1', 'avc1.640033', '50'],
      ['4k60', 3840, 2160, 60, '5.2', 'avc1.640034', '51'],
    ];
    const expectedRows = [];
    for (const [tag, , , , , codec] of tags) {
      expectedRows.push(`h264-high-${tag}\tfull\th264-high-${tag}.mp4\tvideo/mp4;codecs=${codec}\tH264\thigh\t8\tPIXEL_FORMAT_NV12\t1`);
    }
    for (const [tag, , , , , , level] of tags) {
      expectedRows.push(`vp9-profile0-${tag}\tfull\tvp9-profile0-${tag}.webm\tvideo/webm;codecs=vp09.00.${level}.08\tVP9\tprofile0\t8\tPIXEL_FORMAT_NV12\t1`);
    }
    for (const [tag, , , , , , level] of tags) {
      expectedRows.push(`vp9-profile2-${tag}\tfull\tvp9-profile2-${tag}.webm\tvideo/webm;codecs=vp09.02.${level}.10\tVP9\tprofile2\t10\tPIXEL_FORMAT_P010LE\t1`);
    }

    const resolutionManifest = normalizedManifest(path.join(output, 'manifest-resolution.tsv'));
    const resolutionRows = resolutionManifest.split('\n').slice(1);
    assert.deepEqual(resolutionRows, expectedRows);
    assert.equal(resolutionRows.every((row) => row.split('\t').length === 9), true);
    assert.equal(resolutionRows.some((row) => row.includes('\tHEVC\t')), false);

    const probes = fs.readFileSync(path.join(output, 'ffprobe-resolution.txt'), 'utf8').trim().split('\n');
    assert.deepEqual(probes.map((line) => line.split('\t')[0]),
        expectedRows.map((row) => row.split('\t')[0]));

    const calls = fs.readFileSync(log, 'utf8').trim().split('\n').slice(8)
        .map((line) => line.split('\t').slice(1));
    assert.equal(calls.length, 12);
    for (const [tag, width, height, fps, h264Level] of tags) {
      const matching = calls.filter((args) => args.at(-1).includes(`-${tag}.`));
      assert.equal(matching.length, 3);
      for (const args of matching) {
        assert.equal(hasOption(args, '-i', `testsrc2=size=${width}x${height}:rate=${fps}:duration=6`), true);
        assert.equal(hasOption(args, '-g', String(fps)), true);
      }
      const h264 = matching.find((args) => args.at(-1).endsWith('.mp4'));
      assert.equal(hasOption(h264, '-profile:v', 'high'), true);
      assert.equal(hasOption(h264, '-level:v', h264Level), true);
      assert.equal(hasOption(h264, '-pix_fmt', 'yuv420p'), true);
      assert.equal(hasOption(h264, '-x264-params',
          `keyint=${fps}:min-keyint=${fps}:scenecut=0`), true);
      for (const vp9 of matching.filter((args) => args.at(-1).endsWith('.webm'))) {
        assert.equal(hasOption(vp9, '-deadline', 'realtime'), true);
        assert.equal(hasOption(vp9, '-cpu-used', '8'), true);
        assert.equal(hasOption(vp9, '-row-mt', '1'), true);
      }
      const vp9Profile0 = matching.find((args) => args.at(-1).includes('vp9-profile0-'));
      assert.equal(hasOption(vp9Profile0, '-profile:v', '0'), true);
      assert.equal(hasOption(vp9Profile0, '-pix_fmt', 'yuv420p'), true);
      const vp9Profile2 = matching.find((args) => args.at(-1).includes('vp9-profile2-'));
      assert.equal(hasOption(vp9Profile2, '-profile:v', '2'), true);
      assert.equal(hasOption(vp9Profile2, '-pix_fmt', 'yuv420p10le'), true);
    }

    const probeCalls = fs.readFileSync(log + '.ffprobe', 'utf8').trim().split('\n')
        .map((line) => line.split('\t'));
    for (const row of expectedRows) {
      const file = row.split('\t')[2];
      const fields = probeCalls.filter(([name]) => name === file)
          .map(([, entries]) => entries);
      const required = ['stream=codec_name', 'stream=profile', 'stream=pix_fmt',
        'stream=width', 'stream=height', 'stream=r_frame_rate'];
      if (file.endsWith('.mp4')) required.push('stream=level');
      for (const field of required) assert.equal(fields.includes(field), true, `${file}: ${field}`);
    }

    const checksumFiles = fs.readFileSync(path.join(output, 'SHA256SUMS'), 'utf8').trim().split('\n')
        .map((line) => path.basename(line.slice(66)));
    const expectedMedia = fs.readdirSync(output).filter((name) => /\.(?:mp4|webm)$/.test(name)).sort();
    assert.deepEqual(checksumFiles.sort(), expectedMedia);
    assert.equal(expectedMedia.length, 20);
  } finally {
    fs.rmSync(state, {recursive: true, force: true});
  }
});

test('resolution matrix rejects an H264 level mismatch', () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-fixtures-bad-level-'));
  const bin = path.join(state, 'bin');
  const output = path.join(state, 'fixtures');
  const log = path.join(state, 'ffmpeg.log');
  fs.mkdirSync(bin);
  makeFakeTools(bin);

  try {
    const result = spawnSync('bash', [generator, output], {
      encoding: 'utf8',
      timeout: 10000,
      env: {...process.env, PATH: bin + ':' + process.env.PATH,
        MOCK_FFMPEG_LOG: log, MOCK_FFPROBE_LOG: log + '.ffprobe',
        MOCK_BAD_MATRIX_LEVEL: '1', RESOLUTION_MATRIX: '1'},
    });
    assert.equal(result.status, 3);
    assert.match(result.stderr, /h264-high-1080p30\.mp4: expected level=40, got 31/);
    assert.equal(fs.existsSync(path.join(output, 'manifest-resolution.tsv')), false);
  } finally {
    fs.rmSync(state, {recursive: true, force: true});
  }
});
