from __future__ import annotations

import os
import subprocess
from pathlib import Path


def _write_tool(path: Path, source: str) -> None:
    _ = path.write_text(source)
    path.chmod(0o755)


def _run_generator(tmp_path: Path, *, resolution_matrix: bool) -> tuple[list[str], list[str]]:
    skill = Path(__file__).resolve().parents[2]
    tools = tmp_path / "tools"
    tools.mkdir()
    ffmpeg_log = tmp_path / "ffmpeg.log"
    python_log = tmp_path / "python.log"
    _write_tool(
        tools / "ffmpeg",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FFMPEG_LOG"
output="${!#}"
printf fixture >"$output"
""",
    )
    _write_tool(tools / "ffprobe", "#!/usr/bin/env bash\nexit 0\n")
    _write_tool(
        tools / "python3",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$PYTHON_LOG"
""",
    )
    environment = dict(os.environ)
    environment.update(
        {
            "PATH": f"{tools}:{environment['PATH']}",
            "FFMPEG_LOG": str(ffmpeg_log),
            "PYTHON_LOG": str(python_log),
            "RESOLUTION_MATRIX": "1" if resolution_matrix else "0",
        }
    )
    output = tmp_path / "fixtures"

    completed = subprocess.run(
        (str(skill / "scripts/generate-fixtures.sh"), str(output)),
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    return ffmpeg_log.read_text().splitlines(), python_log.read_text().splitlines()


def test_generator_default_commands_remain_unchanged(tmp_path: Path) -> None:
    commands, builder_calls = _run_generator(tmp_path, resolution_matrix=False)

    assert len(commands) == 5
    h264 = next(command for command in commands if command.endswith("h264-high.mp4"))
    vp9 = next(command for command in commands if command.endswith("vp9-profile0.webm"))
    assert "-profile:v high -level:v 3.1 -pix_fmt yuv420p -g 30" in h264
    assert "-x264-params" not in h264
    assert "-deadline realtime -cpu-used 8 -profile:v 0" in vp9
    assert "-row-mt" not in vp9
    assert len(builder_calls) == 1
    assert builder_calls[0].startswith("-m firefox_qa.build_manifest ")
    assert "--resolution-matrix" not in builder_calls[0]


def test_generator_resolution_matrix_uses_deterministic_codec_settings(tmp_path: Path) -> None:
    commands, builder_calls = _run_generator(tmp_path, resolution_matrix=True)

    assert len(commands) == 25
    h264 = next(command for command in commands if command.endswith("h264-high-4k60.mp4"))
    hevc = next(command for command in commands if command.endswith("hevc-main10-1080p60.mp4"))
    vp9 = next(command for command in commands if command.endswith("vp9-profile2-4k30.webm"))
    assert "testsrc2=size=3840x2160:rate=60:duration=6" in h264
    assert "-profile:v high -pix_fmt yuv420p -g 60" in h264
    assert "-level:v" not in h264
    assert "-x264-params keyint=60:min-keyint=60:scenecut=0" in h264
    assert "testsrc2=size=1920x1080:rate=60:duration=6" in hevc
    assert "-profile:v main10 -pix_fmt yuv420p10le -g 60" in hevc
    assert "testsrc2=size=3840x2160:rate=30:duration=6" in vp9
    assert "-deadline realtime -cpu-used 8 -row-mt 1" in vp9
    assert "-profile:v 2 -pix_fmt yuv420p10le -g 30" in vp9
    assert len(builder_calls) == 2
    assert "--resolution-matrix 6" in builder_calls[1]
