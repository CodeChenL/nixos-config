from __future__ import annotations

import hashlib
from pathlib import Path
from unittest.mock import patch

from .. import build_manifest
from ..json_value import load_json
from ..manifest import REQUIRED_FIELDS, ManifestError, parse_and_verify_manifest
from .helpers import assert_raises


def _write_fixtures(fixture_dir: Path, names: list[str]) -> None:
    for name in names:
        _ = (fixture_dir / name).write_bytes(name.encode())


def _resolution_probe(path: Path) -> dict[str, str]:
    family, tag = path.stem.rsplit("-", 1)
    resolutions = {
        "1080p30": (1920, 1080, 30),
        "1080p60": (1920, 1080, 60),
        "4k30": (3840, 2160, 30),
        "4k60": (3840, 2160, 60),
    }
    width, height, fps = resolutions[tag]
    profiles = {
        "h264-high": ("h264", "High", "yuv420p"),
        "hevc-main": ("hevc", "Main", "yuv420p"),
        "hevc-main10": ("hevc", "Main 10", "yuv420p10le"),
        "vp9-profile0": ("vp9", "Profile 0", "yuv420p"),
        "vp9-profile2": ("vp9", "Profile 2", "yuv420p10le"),
    }
    codec, profile, pix_fmt = profiles[family]
    levels = {
        "h264-high": build_manifest.H264_LEVELS[tag],
        "hevc-main": build_manifest.HEVC_LEVELS[tag],
        "hevc-main10": build_manifest.HEVC_LEVELS[tag],
        "vp9-profile0": -99,
        "vp9-profile2": -99,
    }
    return {
        "format_name": "matroska,webm" if codec == "vp9" else "mov,mp4,m4a,3gp,3g2,mj2",
        "codec_name": codec,
        "profile": profile,
        "level": str(levels[family]),
        "pix_fmt": pix_fmt,
        "width": str(width),
        "height": str(height),
        "avg_frame_rate": f"{fps}/1",
        "duration": "6.000000",
        "nb_frames": str(fps * 6),
    }


def _standard_probe(path: Path) -> dict[str, str]:
    family = path.stem
    profiles = {
        "h264-high": ("h264", "High", "yuv420p", 31),
        "hevc-main": ("hevc", "Main", "yuv420p", 93),
        "hevc-main10": ("hevc", "Main 10", "yuv420p10le", 93),
        "vp9-profile0": ("vp9", "Profile 0", "yuv420p", -99),
        "vp9-profile2": ("vp9", "Profile 2", "yuv420p10le", -99),
    }
    codec, profile, pix_fmt, level = profiles[family]
    return {
        "format_name": "matroska,webm" if codec == "vp9" else "mov,mp4,m4a,3gp,3g2,mj2",
        "codec_name": codec,
        "profile": profile,
        "level": str(level),
        "pix_fmt": pix_fmt,
        "width": "1280",
        "height": "720",
        "avg_frame_rate": "30/1",
        "duration": "6.000000",
        "nb_frames": "180",
    }


def test_standard_builder_preserves_six_scenarios(tmp_path: Path) -> None:
    names = [spec[0] for spec in build_manifest.SPECS]
    _write_fixtures(tmp_path, names)

    with patch.object(build_manifest, "parse_and_verify_manifest") as verify:
        manifest_path = build_manifest.build_standard_manifest(tmp_path, _standard_probe)

    assert manifest_path == tmp_path / "manifest.json"
    verify.assert_called_once_with(manifest_path)
    parsed = parse_and_verify_manifest(manifest_path, _standard_probe)
    assert [scenario.id for scenario in parsed.scenarios] == [
        "h264-high",
        "hevc-main",
        "hevc-main10",
        "vp9-profile0",
        "vp9-profile2",
        "hevc-main10-seek",
    ]
    assert parsed.scenarios[-1].seek_target == 3.0


def test_resolution_builder_writes_valid_twenty_scenario_matrix(tmp_path: Path) -> None:
    names = [
        f"{family}-{tag}{suffix}"
        for tag, _width, _height, _fps in build_manifest.RESOLUTIONS
        for family, suffix, _container, _profile, _output, _codec, _pix_fmt in (
            build_manifest.RESOLUTION_FAMILIES
        )
    ]
    _write_fixtures(tmp_path, names)
    standard_manifest = tmp_path / "manifest.json"
    _ = standard_manifest.write_text("standard sentinel\n")
    probed: list[Path] = []

    def probe(path: Path) -> dict[str, str]:
        probed.append(path)
        return _resolution_probe(path)

    with patch.object(build_manifest, "parse_and_verify_manifest") as verify:
        manifest_path = build_manifest.build_resolution_manifest(tmp_path, 6.0, probe)

    assert manifest_path == tmp_path / "manifest-resolution.json"
    assert standard_manifest.read_text() == "standard sentinel\n"
    assert probed == [tmp_path / name for name in names]
    verify.assert_called_once_with(manifest_path)
    parsed = parse_and_verify_manifest(manifest_path, _resolution_probe)
    assert len(parsed.scenarios) == 20
    assert {scenario.id for scenario in parsed.scenarios} == {Path(name).stem for name in names}
    assert all(scenario.mode.value == "full" for scenario in parsed.scenarios)
    assert all(scenario.trace_profile.value == "evidence" for scenario in parsed.scenarios)
    assert all(scenario.seek_target is None for scenario in parsed.scenarios)
    assert all(scenario.dropped_threshold is None for scenario in parsed.scenarios)

    raw = load_json(manifest_path.read_text())
    assert isinstance(raw, dict)
    scenarios = raw["scenarios"]
    assert isinstance(scenarios, list)
    for scenario in scenarios:
        assert isinstance(scenario, dict)
        assert set(scenario) == REQUIRED_FIELDS
        media_path = scenario["media_path"]
        sha256 = scenario["sha256"]
        assert isinstance(media_path, str)
        assert isinstance(sha256, str)
        assert Path(media_path).is_absolute()
        assert sha256 == hashlib.sha256(Path(media_path).read_bytes()).hexdigest()

    mimes = {scenario.id: scenario.mime for scenario in parsed.scenarios}
    assert mimes["h264-high-1080p30"] == "video/mp4;codecs=avc1.640028"
    assert mimes["h264-high-1080p60"] == "video/mp4;codecs=avc1.64002A"
    assert mimes["h264-high-4k30"] == "video/mp4;codecs=avc1.640033"
    assert mimes["h264-high-4k60"] == "video/mp4;codecs=avc1.640034"
    assert mimes["hevc-main-4k60"] == "video/mp4;codecs=hvc1.1.6.L153.B0"
    assert mimes["hevc-main10-1080p60"] == "video/mp4;codecs=hvc1.2.4.L123.B0"
    assert mimes["vp9-profile0-4k30"] == "video/webm;codecs=vp09.00.50.08"
    assert mimes["vp9-profile2-4k60"] == "video/webm;codecs=vp09.02.51.10"


def test_resolution_builder_rejects_stale_fixture_metadata(tmp_path: Path) -> None:
    path = tmp_path / "h264-high-1080p30.mp4"
    _ = path.write_bytes(b"fixture")
    stale_probe = _resolution_probe(path)
    stale_probe["width"] = "1280"

    error = assert_raises(
        ManifestError,
        lambda: build_manifest.build_resolution_manifest(tmp_path, 6.0, lambda _path: stale_probe),
    )

    assert error.reason == "resolution fixture metadata mismatch for h264-high-1080p30"
