'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function runMatrix(resultMode) {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-matrix-'));
  try {
    fs.copyFileSync(path.join(__dirname, 'run-matrix.sh'), path.join(state, 'run-matrix.sh'));
    fs.writeFileSync(path.join(state, 'probe-target.sh'), '#!/bin/sh\nprintf "probe\\n"\n', {mode: 0o700});
    fs.writeFileSync(path.join(state, 'run-scenario.sh'), `#!/bin/sh
case '${resultMode}' in
  missing) exit 0 ;;
  malformed) printf 'case\\tPASS\\n' > "$OUTPUT_DIR/case-result.tsv"; exit 0 ;;
  symlink) printf 'case\\tPASS\\n' > "$OUTPUT_DIR/external.tsv"; ln -s "$OUTPUT_DIR/external.tsv" "$OUTPUT_DIR/case-result.tsv"; exit 0 ;;
  inconclusive) printf 'case\\tPLAYBACK_PASS\\tHW_PATH_OBSERVED\\tOWNED_CLEANUP_PASS\\tGLOBAL_IDLE_UNKNOWN\\tOVERALL_INCONCLUSIVE_ROOTLESS\\tH264\\thigh\\t8\\tPIXEL_FORMAT_NV12\\n' > "$OUTPUT_DIR/case-result.tsv"; exit 1 ;;
  unsupported) printf 'case\\tPLAYBACK_UNSUPPORTED\\tHW_PATH_NOT_OBSERVED\\tOWNED_CLEANUP_PASS\\tGLOBAL_IDLE_UNKNOWN\\tOVERALL_UNSUPPORTED\\tH264\\thigh\\t8\\tPIXEL_FORMAT_NV12\\n' > "$OUTPUT_DIR/case-result.tsv"; exit 1 ;;
esac
`, {mode: 0o700});
    const manifest = path.join(state, 'manifest-resolution.tsv');
    fs.writeFileSync(manifest, 'case\tfull\t/media.mp4\tvideo/mp4\tH264\thigh\t8\tPIXEL_FORMAT_NV12\t1\n');
    fs.writeFileSync(path.join(state, 'ffprobe-resolution.txt'), 'resolution metadata\n');
    fs.writeFileSync(path.join(state, 'SHA256SUMS'), 'checksum\n');
    const output = path.join(state, 'output');
    const result = spawnSync('bash', [path.join(state, 'run-matrix.sh'), manifest, output],
        {encoding: 'utf8', timeout: 3000});
    return {
      code: result.status,
      summary: fs.readFileSync(path.join(output, 'summary.tsv'), 'utf8'),
      resolutionProbe: fs.readFileSync(path.join(output, 'ffprobe-resolution.txt'), 'utf8'),
      checksums: fs.readFileSync(path.join(output, 'SHA256SUMS'), 'utf8'),
    };
  } finally { fs.rmSync(state, {recursive: true, force: true}); }
}

for (const mode of ['missing', 'malformed', 'symlink']) {
  test(`${mode} scenario result fails closed and cannot synthesize PASS`, () => {
    const result = runMatrix(mode);
    assert.equal(result.code, 1);
    assert.match(result.summary, /OVERALL_FAIL/);
    assert.doesNotMatch(result.summary, /\tPASS\t/);
  });
}

test('matrix preserves explicit rootless axes and nonzero inconclusive semantics', () => {
  const result = runMatrix('inconclusive');
  assert.equal(result.code, 1);
  assert.match(result.summary,
      /PLAYBACK_PASS\tHW_PATH_OBSERVED\tOWNED_CLEANUP_PASS\tGLOBAL_IDLE_UNKNOWN\tOVERALL_INCONCLUSIVE_ROOTLESS/);
});

test('resolution metadata is copied with matrix output', () => {
  const result = runMatrix('inconclusive');
  assert.equal(result.resolutionProbe, 'resolution metadata\n');
  assert.equal(result.checksums, 'checksum\n');
});

test('unsupported capability boundary is reported but not counted as failure', () => {
  const result = runMatrix('unsupported');
  assert.equal(result.code, 0);
  assert.match(result.summary, /OVERALL_UNSUPPORTED/);
  assert.doesNotMatch(result.summary, /OVERALL_FAIL/);
});
