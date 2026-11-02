from __future__ import annotations

import json
import math
import sys
from collections.abc import Sequence
from fractions import Fraction
from pathlib import Path

from .manifest import (
    ManifestError,
    ProbeResult,
    ProbeRunner,
    ffprobe_media,
    parse_and_verify_manifest,
    sha256_file,
)

SPECS = (
    ("h264-high.mp4", "video/mp4;codecs=avc1.64001F", "mp4", "High", "NV12"),
    ("hevc-main.mp4", "video/mp4;codecs=hvc1.1.6.L93.B0", "mp4", "Main", "NV12"),
    ("hevc-main10.mp4", "video/mp4;codecs=hvc1.2.4.L93.B0", "mp4", "Main 10", "P010"),
    ("vp9-profile0.webm", "video/webm;codecs=vp09.00.10.08", "webm", "Profile 0", "NV12"),
    ("vp9-profile2.webm", "video/webm;codecs=vp09.02.10.10", "webm", "Profile 2", "P010"),
)

RESOLUTION_FAMILIES = (
    ("h264-high", ".mp4", "mp4", "High", "NV12", "h264", "yuv420p"),
    ("hevc-main", ".mp4", "mp4", "Main", "NV12", "hevc", "yuv420p"),
    ("hevc-main10", ".mp4", "mp4", "Main 10", "P010", "hevc", "yuv420p10le"),
    ("vp9-profile0", ".webm", "webm", "Profile 0", "NV12", "vp9", "yuv420p"),
    ("vp9-profile2", ".webm", "webm", "Profile 2", "P010", "vp9", "yuv420p10le"),
)
RESOLUTIONS = (
    ("1080p30", 1920, 1080, 30),
    ("1080p60", 1920, 1080, 60),
    ("4k30", 3840, 2160, 30),
    ("4k60", 3840, 2160, 60),
)
H264_LEVELS = {"1080p30": 40, "1080p60": 42, "4k30": 51, "4k60": 52}
HEVC_LEVELS = {"1080p30": 120, "1080p60": 123, "4k30": 150, "4k60": 153}
VP9_LEVELS = {"1080p30": "40", "1080p60": "41", "4k30": "50", "4k60": "51"}


def _scenario(
    path: Path,
    mime: str,
    container: str,
    profile: str,
    output: str,
    probe: ProbeResult | None = None,
) -> dict[str, str | int | float | None]:
    observed = ffprobe_media(path) if probe is None else probe
    pix_fmt = observed["pix_fmt"]
    fps_parts = observed["avg_frame_rate"].split("/", 1)
    fps = float(fps_parts[0]) / float(fps_parts[1])
    return {
        "id": path.stem,
        "mode": "full",
        "trace_profile": "evidence",
        "media_path": str(path.resolve()),
        "sha256": sha256_file(path),
        "mime": mime,
        "container": container,
        "codec": observed["codec_name"],
        "profile": profile,
        "bit_depth": 10 if "10" in pix_fmt else 8,
        "chroma": "4:2:0",
        "width": int(observed["width"]),
        "height": int(observed["height"]),
        "fps": fps,
        "duration": float(observed["duration"]),
        "expected_frames": int(observed["nb_frames"]),
        "expected_output": output,
        "seek_target": None,
        "dropped_threshold": None,
    }


def _write_manifest(
    manifest_path: Path, scenarios: list[dict[str, str | int | float | None]]
) -> Path:
    _ = manifest_path.write_text(
        json.dumps({"schema_version": 1, "scenarios": scenarios}, sort_keys=True, indent=2) + "\n"
    )
    _ = parse_and_verify_manifest(manifest_path)
    return manifest_path


def build_standard_manifest(fixture_dir: Path, probe_runner: ProbeRunner = ffprobe_media) -> Path:
    scenarios = [
        _scenario(
            fixture_dir / name,
            mime,
            container,
            profile,
            output,
            probe_runner(fixture_dir / name),
        )
        for name, mime, container, profile, output in SPECS
    ]
    source = next(scenario for scenario in scenarios if scenario["id"] == "hevc-main10")
    duration = source["duration"]
    if not isinstance(duration, int | float):
        raise ManifestError("generated scenario duration is missing")
    seek = dict(source)
    seek.update(
        {
            "id": "hevc-main10-seek",
            "mode": "seek",
            "seek_target": round(float(duration) / 2, 3),
        }
    )
    scenarios.append(seek)
    return _write_manifest(fixture_dir / "manifest.json", scenarios)


def _codec_level(probe: ProbeResult, scenario_id: str) -> int:
    try:
        level = int(probe["level"])
    except (KeyError, ValueError) as error:
        raise ManifestError(f"ffprobe returned invalid codec level for {scenario_id}") from error
    if level <= 0:
        raise ManifestError(f"ffprobe returned invalid codec level for {scenario_id}")
    return level


def _resolution_mime(family: str, tag: str, probe: ProbeResult) -> str:
    scenario_id = f"{family}-{tag}"
    if family == "h264-high":
        level = _codec_level(probe, scenario_id)
        if level != H264_LEVELS[tag]:
            raise ManifestError(f"unexpected H.264 level for {scenario_id}")
        return f"video/mp4;codecs=avc1.6400{level:02X}"
    if family in {"hevc-main", "hevc-main10"}:
        level = _codec_level(probe, scenario_id)
        if level != HEVC_LEVELS[tag]:
            raise ManifestError(f"unexpected HEVC level for {scenario_id}")
        profile = "1.6" if family == "hevc-main" else "2.4"
        return f"video/mp4;codecs=hvc1.{profile}.L{level}.B0"
    profile = "00" if family == "vp9-profile0" else "02"
    bit_depth = "08" if family == "vp9-profile0" else "10"
    return f"video/webm;codecs=vp09.{profile}.{VP9_LEVELS[tag]}.{bit_depth}"


def _verify_resolution_probe(
    path: Path,
    probe: ProbeResult,
    *,
    codec: str,
    profile: str,
    pix_fmt: str,
    width: int,
    height: int,
    fps: int,
    duration: float,
) -> None:
    expected_frames = round(fps * duration)
    try:
        observed_fps = float(Fraction(probe["avg_frame_rate"]))
        exact = (
            probe["codec_name"] == codec
            and probe["profile"] == profile
            and probe["pix_fmt"] == pix_fmt
            and int(probe["width"]) == width
            and int(probe["height"]) == height
            and math.isclose(observed_fps, fps, rel_tol=0.0, abs_tol=0.001)
            and math.isclose(float(probe["duration"]), duration, rel_tol=0.0, abs_tol=0.05)
            and int(probe["nb_frames"]) == expected_frames
        )
    except (KeyError, ValueError, ZeroDivisionError) as error:
        raise ManifestError(f"ffprobe returned invalid metadata for {path.stem}") from error
    if not exact:
        raise ManifestError(f"resolution fixture metadata mismatch for {path.stem}")


def build_resolution_manifest(
    fixture_dir: Path,
    duration: float = 6.0,
    probe_runner: ProbeRunner = ffprobe_media,
) -> Path:
    scenarios: list[dict[str, str | int | float | None]] = []
    for tag, width, height, fps in RESOLUTIONS:
        for family, suffix, container, profile, output, codec, pix_fmt in RESOLUTION_FAMILIES:
            path = fixture_dir / f"{family}-{tag}{suffix}"
            probe = probe_runner(path)
            _verify_resolution_probe(
                path,
                probe,
                codec=codec,
                profile=profile,
                pix_fmt=pix_fmt,
                width=width,
                height=height,
                fps=fps,
                duration=duration,
            )
            scenarios.append(
                _scenario(
                    path, _resolution_mime(family, tag, probe), container, profile, output, probe
                )
            )
    return _write_manifest(fixture_dir / "manifest-resolution.json", scenarios)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    resolution_matrix = False
    duration = 6.0
    if len(arguments) == 3 and arguments[1] == "--resolution-matrix":
        resolution_matrix = True
        try:
            duration = float(arguments[2])
        except ValueError:
            duration = 0.0
    elif len(arguments) != 1:
        print(
            "usage: build-manifest.py FIXTURE_DIR [--resolution-matrix DURATION]",
            file=sys.stderr,
        )
        return 2
    if not math.isfinite(duration) or duration <= 0:
        print("resolution matrix duration must be finite and positive", file=sys.stderr)
        return 2
    fixture_dir = Path(arguments[0]).resolve()
    manifest_path = (
        build_resolution_manifest(fixture_dir, duration)
        if resolution_matrix
        else build_standard_manifest(fixture_dir)
    )
    print(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
