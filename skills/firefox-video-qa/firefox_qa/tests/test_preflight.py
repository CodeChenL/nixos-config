from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

from ..json_value import load_json
from ..models import JsonValue, Manifest, RunMode, Scenario, TraceProfile
from ..observation import snapshot
from ..remote_runner import evaluate_preflight, run


def _scenario(root: Path) -> Scenario:
    return Scenario(
        id="case",
        mode=RunMode.FULL,
        trace_profile=TraceProfile.EVIDENCE,
        media_path=root / "media",
        sha256="a" * 64,
        mime="video/mp4;codecs=avc1",
        container="mp4",
        codec="h264",
        profile="High",
        bit_depth=8,
        chroma="4:2:0",
        width=1280,
        height=720,
        fps=30.0,
        duration=6.0,
        expected_frames=180,
        expected_output="NV12",
        seek_target=None,
        dropped_threshold=None,
    )


def _run_blocked(root: Path, records: tuple[dict[str, str | int | bool | list[str]], ...]) -> int:
    _ = (root / "scenario.json").write_text("{}")
    _ = (root / "media").write_bytes(b"fixture")
    manifest = Manifest(1, (_scenario(root),))
    with (
        patch("firefox_qa.remote_runner.parse_and_verify_manifest", return_value=manifest),
        patch("firefox_qa.remote_runner.snapshot", return_value=records),
        patch("firefox_qa.remote_runner.subprocess.Popen") as launch,
    ):
        return_code = run(root, "a" * 32, Path("/missing/firefox"), 1.0)
    launch.assert_not_called()
    return return_code


def test_visible_external_video_owner_blocks_without_launch_or_signal(tmp_path: Path) -> None:
    # Given
    root = tmp_path / "run"
    root.mkdir()
    sleep = shutil.which("sleep")
    assert sleep is not None
    external = subprocess.Popen((sleep, "30"))
    records = (
        {
            "phase": "before",
            "complete": True,
            "pid": external.pid,
            "start_time": 1,
            "session": external.pid,
            "role": "external",
            "devices": ["/dev/video7"],
            "maps": [],
        },
    )

    try:
        # When
        return_code = _run_blocked(root, records)

        # Then
        assert return_code == 3
        assert external.poll() is None
        outcome = load_json((root / "outcome.json").read_text())
        assert isinstance(outcome, dict)
        assert outcome["status"] == "BLOCKED"
    finally:
        external.terminate()
        _ = external.wait(timeout=2)


def test_visible_render_node_owner_does_not_block_decoder_preflight() -> None:
    # Given
    records: tuple[dict[str, JsonValue], ...] = (
        {
            "phase": "before",
            "complete": True,
            "pid": 123,
            "start_time": 1,
            "session": 123,
            "role": "external",
            "devices": ["/dev/dri/renderD128"],
            "maps": [],
        },
    )

    # When
    outcome = evaluate_preflight(records)

    # Then
    assert outcome is None


def test_same_uid_opaque_process_makes_before_snapshot_incomplete(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    entry = proc / "123"
    entry.mkdir(parents=True)
    _ = (entry / "stat").write_text("123 (opaque) S 1 123 123 " + "0 " * 16 + "500")
    _ = (entry / "cmdline").write_bytes(b"\xff")
    _ = (entry / "status").write_text(
        f"Uid:\t{os.getuid()}\t{os.getuid()}\t{os.getuid()}\t{os.getuid()}\n"
    )

    # When
    records = snapshot("before", None, proc)

    # Then
    assert any(record.get("complete") is False for record in records)
