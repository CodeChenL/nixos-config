from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from unittest.mock import patch

from ..manifest import ManifestError, ffprobe_media, parse_and_verify_manifest
from .helpers import assert_raises


def _scenario(media: Path) -> dict[str, str | int | float | None]:
    return {
        "id": "hevc-main10-seek",
        "mode": "seek",
        "trace_profile": "evidence",
        "media_path": str(media.resolve()),
        "sha256": hashlib.sha256(media.read_bytes()).hexdigest(),
        "mime": "video/mp4;codecs=hvc1.2.4.L93.B0",
        "container": "mp4",
        "codec": "hevc",
        "profile": "Main 10",
        "bit_depth": 10,
        "chroma": "4:2:0",
        "width": 1280,
        "height": 720,
        "fps": 30.0,
        "duration": 6.0,
        "expected_frames": 180,
        "expected_output": "P010",
        "seek_target": 4.0,
        "dropped_threshold": None,
    }


def test_manifest_accepts_exact_hash_and_ffprobe_metadata(tmp_path: Path) -> None:
    # Given
    media = tmp_path / "fixture.mp4"
    _ = media.write_bytes(b"fixture")
    manifest = tmp_path / "manifest.json"
    _ = manifest.write_text(json.dumps({"schema_version": 1, "scenarios": [_scenario(media)]}))
    probe = {
        "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
        "codec_name": "hevc",
        "profile": "Main 10",
        "pix_fmt": "yuv420p10le",
        "width": "1280",
        "height": "720",
        "avg_frame_rate": "30/1",
        "duration": "6.000000",
        "nb_frames": "180",
    }

    # When
    parsed = parse_and_verify_manifest(manifest, lambda _path: probe)

    # Then
    assert parsed.scenarios[0].id == "hevc-main10-seek"


def _assert_unsafe_path_rejected(tmp_path: Path, unsafe: str) -> None:
    # Given
    media = tmp_path / "fixture.mp4"
    _ = media.write_bytes(b"fixture")
    raw = _scenario(media)
    raw["media_path"] = unsafe
    manifest = tmp_path / "manifest.json"
    _ = manifest.write_text(json.dumps({"schema_version": 1, "scenarios": [raw]}))
    # When / Then
    _ = assert_raises(ManifestError, lambda: parse_and_verify_manifest(manifest, lambda _path: {}))


def test_manifest_rejects_relative_media_path_before_transport(tmp_path: Path) -> None:
    _assert_unsafe_path_rejected(tmp_path, "../fixture.mp4")


def test_manifest_rejects_multiline_media_path_before_transport(tmp_path: Path) -> None:
    _assert_unsafe_path_rejected(tmp_path, "/tmp/a\nfixture.mp4")


def test_manifest_rejects_hash_mismatch_before_probe(tmp_path: Path) -> None:
    # Given
    media = tmp_path / "fixture.mp4"
    _ = media.write_bytes(b"fixture")
    raw = _scenario(media)
    raw["sha256"] = "0" * 64
    manifest = tmp_path / "manifest.json"
    _ = manifest.write_text(json.dumps({"schema_version": 1, "scenarios": [raw]}))
    called = False

    def probe(_path: Path) -> dict[str, str]:
        nonlocal called
        called = True
        return {}

    # When / Then
    _ = assert_raises(ManifestError, lambda: parse_and_verify_manifest(manifest, probe))
    assert called is False


def test_ffprobe_media_counts_frames_when_container_omits_nb_frames(tmp_path: Path) -> None:
    # Given
    media = tmp_path / "clip.webm"
    _ = media.write_bytes(b"fixture")
    primary = json.dumps(
        {
            "streams": [
                {
                    "codec_name": "vp9",
                    "profile": "Profile 0",
                    "level": "-99",
                    "pix_fmt": "yuv420p",
                    "width": "160",
                    "height": "120",
                    "avg_frame_rate": "10/1",
                }
            ],
            "format": {"format_name": "matroska,webm", "duration": "1.000000"},
        }
    )
    counted = json.dumps({"streams": [{"nb_read_frames": "10"}]})
    commands: list[list[str]] = []

    def run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        commands.append(command)
        stdout = counted if "-count_frames" in command else primary
        return subprocess.CompletedProcess(command, 0, stdout, "")

    # When
    with patch("subprocess.run", run):
        probe = ffprobe_media(media)

    # Then
    assert probe["nb_frames"] == "10"
    assert any("-count_frames" in command for command in commands)


def test_ffprobe_media_accepts_codecs_without_level_metadata(tmp_path: Path) -> None:
    media = tmp_path / "fixture.webm"
    _ = media.write_bytes(b"fixture")
    primary = json.dumps(
        {
            "streams": [
                {
                    "codec_name": "vp9",
                    "profile": "Profile 0",
                    "pix_fmt": "yuv420p",
                    "width": "1280",
                    "height": "720",
                    "avg_frame_rate": "30/1",
                    "nb_frames": "180",
                }
            ],
            "format": {"format_name": "matroska,webm", "duration": "6.000000"},
        }
    )

    def run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(command, 0, primary, "")

    with patch("subprocess.run", run):
        probe = ffprobe_media(media)

    assert "level" not in probe


def test_manifest_rejects_mime_codec_disagreement_before_probe(tmp_path: Path) -> None:
    # Given
    media = tmp_path / "fixture.mp4"
    _ = media.write_bytes(b"fixture")
    raw = _scenario(media)
    raw["mime"] = "video/mp4;codecs=avc1.64001F"
    manifest = tmp_path / "manifest.json"
    _ = manifest.write_text(json.dumps({"schema_version": 1, "scenarios": [raw]}))

    # When / Then
    _ = assert_raises(ManifestError, lambda: parse_and_verify_manifest(manifest, lambda _path: {}))


def test_manifest_accepts_multiple_resolutions(tmp_path: Path) -> None:
    media_1080p = tmp_path / "h264-high-1080p30.mp4"
    media_4k = tmp_path / "h264-high-4k60.mp4"
    _ = media_1080p.write_bytes(b"1080p")
    _ = media_4k.write_bytes(b"4k")
    scenario_1080p = _scenario(media_1080p)
    scenario_1080p.update(
        {
            "id": "h264-high-1080p30",
            "mode": "full",
            "mime": "video/mp4;codecs=avc1.640028",
            "codec": "h264",
            "profile": "High",
            "bit_depth": 8,
            "width": 1920,
            "height": 1080,
            "expected_output": "NV12",
            "seek_target": None,
        }
    )
    scenario_4k = dict(scenario_1080p)
    scenario_4k.update(
        {
            "id": "h264-high-4k60",
            "media_path": str(media_4k.resolve()),
            "sha256": hashlib.sha256(media_4k.read_bytes()).hexdigest(),
            "mime": "video/mp4;codecs=avc1.640034",
            "width": 3840,
            "height": 2160,
            "fps": 60.0,
            "expected_frames": 360,
        }
    )
    manifest = tmp_path / "manifest-resolution.json"
    _ = manifest.write_text(
        json.dumps({"schema_version": 1, "scenarios": [scenario_1080p, scenario_4k]})
    )

    def probe(path: Path) -> dict[str, str]:
        scenario = scenario_1080p if path == media_1080p else scenario_4k
        return {
            "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
            "codec_name": "h264",
            "profile": "High",
            "level": "40" if path == media_1080p else "52",
            "pix_fmt": "yuv420p",
            "width": str(scenario["width"]),
            "height": str(scenario["height"]),
            "avg_frame_rate": f"{scenario['fps']:.0f}/1",
            "duration": "6.000000",
            "nb_frames": str(scenario["expected_frames"]),
        }

    parsed = parse_and_verify_manifest(manifest, probe)

    assert [scenario.id for scenario in parsed.scenarios] == [
        "h264-high-1080p30",
        "h264-high-4k60",
    ]


def test_manifest_rejects_resolution_or_frame_count_mismatch(tmp_path: Path) -> None:
    media = tmp_path / "h264-high-4k60.mp4"
    _ = media.write_bytes(b"fixture")
    raw = _scenario(media)
    raw.update(
        {
            "id": "h264-high-4k60",
            "mode": "full",
            "mime": "video/mp4;codecs=avc1.640034",
            "codec": "h264",
            "profile": "High",
            "bit_depth": 8,
            "width": 3840,
            "height": 2160,
            "fps": 60.0,
            "expected_frames": 360,
            "expected_output": "NV12",
            "seek_target": None,
        }
    )
    manifest = tmp_path / "manifest-resolution.json"
    _ = manifest.write_text(json.dumps({"schema_version": 1, "scenarios": [raw]}))
    probe = {
        "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
        "codec_name": "h264",
        "profile": "High",
        "level": "52",
        "pix_fmt": "yuv420p",
        "width": "1920",
        "height": "1080",
        "avg_frame_rate": "60/1",
        "duration": "6.000000",
        "nb_frames": "359",
    }

    _ = assert_raises(
        ManifestError, lambda: parse_and_verify_manifest(manifest, lambda _path: probe)
    )
