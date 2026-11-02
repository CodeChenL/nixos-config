from __future__ import annotations

import hashlib
import math
import re
import subprocess
from collections.abc import Callable, Mapping
from fractions import Fraction
from pathlib import Path
from typing import Final

from .json_value import load_json
from .models import JsonValue, Manifest, RunMode, Scenario, TraceProfile

SCENARIO_ID: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SHA256: Final = re.compile(r"[a-f0-9]{64}")
OUTPUTS: Final = {"NV12", "P010", "P010LE"}
CONTAINER_MIME: Final = {"mp4": "video/mp4", "webm": "video/webm"}
CODEC_TAGS: Final = {"h264": ("avc1",), "hevc": ("hvc1", "hev1"), "vp9": ("vp09",)}
REQUIRED_FIELDS: Final = {
    "id",
    "mode",
    "trace_profile",
    "media_path",
    "sha256",
    "mime",
    "container",
    "codec",
    "profile",
    "bit_depth",
    "chroma",
    "width",
    "height",
    "fps",
    "duration",
    "expected_frames",
    "expected_output",
    "seek_target",
    "dropped_threshold",
}
type ProbeResult = Mapping[str, str]
type ProbeRunner = Callable[[Path], ProbeResult]
PROBE_ENTRIES: Final = (
    "stream=codec_name,profile,level,pix_fmt,width,height,avg_frame_rate,nb_frames:"
    "format=format_name,duration"
)


class ManifestError(Exception):
    reason: str

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _json_mapping(value: JsonValue, label: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must be an object")
    return dict(value)


def _string(raw: Mapping[str, JsonValue], key: str) -> str:
    value = raw.get(key)
    if not isinstance(value, str) or not value or "\x00" in value or "\n" in value:
        raise ManifestError(f"{key} must be a non-empty single-line string")
    return value


def _number(raw: Mapping[str, JsonValue], key: str) -> float:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ManifestError(f"{key} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise ManifestError(f"{key} must be finite and positive")
    return result


def _integer(raw: Mapping[str, JsonValue], key: str) -> int:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ManifestError(f"{key} must be a positive integer")
    return value


def _optional_number(raw: Mapping[str, JsonValue], key: str) -> float | None:
    value = raw.get(key)
    if value is None:
        return None
    return _number(raw, key)


def _optional_integer(raw: Mapping[str, JsonValue], key: str) -> int | None:
    value = raw.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ManifestError(f"{key} must be null or a non-negative integer")
    return value


def parse_scenario(raw: Mapping[str, JsonValue]) -> Scenario:
    if set(raw) != REQUIRED_FIELDS:
        raise ManifestError("scenario fields do not match canonical schema")
    scenario_id = _string(raw, "id")
    if SCENARIO_ID.fullmatch(scenario_id) is None:
        raise ManifestError("invalid scenario id")
    media_path = Path(_string(raw, "media_path"))
    if not media_path.is_absolute() or ".." in media_path.parts:
        raise ManifestError("media_path must be an absolute normalized path")
    sha256 = _string(raw, "sha256")
    if SHA256.fullmatch(sha256) is None:
        raise ManifestError("invalid SHA-256")
    try:
        mode = RunMode(_string(raw, "mode"))
        trace_profile = TraceProfile(_string(raw, "trace_profile"))
    except ValueError as error:
        raise ManifestError("invalid mode or trace_profile") from error
    seek_target = _optional_number(raw, "seek_target")
    if (mode is RunMode.SEEK) != (seek_target is not None):
        raise ManifestError("seek_target is required only for seek mode")
    duration = _number(raw, "duration")
    if seek_target is not None and seek_target >= duration:
        raise ManifestError("seek_target must be before duration")
    container = _string(raw, "container").lower()
    mime = _string(raw, "mime")
    codec = _string(raw, "codec").lower()
    if container not in CONTAINER_MIME or mime.split(";", 1)[0] != CONTAINER_MIME[container]:
        raise ManifestError("MIME and container disagree")
    if codec not in CODEC_TAGS or not any(tag in mime for tag in CODEC_TAGS[codec]):
        raise ManifestError("MIME codec string and codec disagree")
    output = _string(raw, "expected_output").upper()
    if output not in OUTPUTS:
        raise ManifestError("unsupported expected_output")
    bit_depth = _integer(raw, "bit_depth")
    if (bit_depth > 8) != output.startswith("P010"):
        raise ManifestError("bit depth and expected output disagree")
    return Scenario(
        id=scenario_id,
        mode=mode,
        trace_profile=trace_profile,
        media_path=media_path,
        sha256=sha256,
        mime=mime,
        container=container,
        codec=codec,
        profile=_string(raw, "profile"),
        bit_depth=bit_depth,
        chroma=_string(raw, "chroma"),
        width=_integer(raw, "width"),
        height=_integer(raw, "height"),
        fps=_number(raw, "fps"),
        duration=duration,
        expected_frames=_integer(raw, "expected_frames"),
        expected_output=output,
        seek_target=seek_target,
        dropped_threshold=_optional_integer(raw, "dropped_threshold"),
    )


def _probe_document(
    path: Path, entries: str, *, count_frames: bool = False
) -> dict[str, JsonValue]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        *(["-count_frames"] if count_frames else []),
        "-show_entries",
        entries,
        "-of",
        "json",
        str(path),
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return _json_mapping(load_json(completed.stdout), "ffprobe")


def _probe_scalar(value: JsonValue) -> str | None:
    if isinstance(value, str | int | float) and str(value).strip() not in {"", "N/A"}:
        return str(value)
    return None


def _frame_count(path: Path, stream: Mapping[str, JsonValue], result: Mapping[str, str]) -> str:
    declared = _probe_scalar(stream.get("nb_frames"))
    if declared is not None:
        return declared
    counted = _probe_document(path, "stream=nb_read_frames", count_frames=True)
    streams = counted.get("streams")
    if isinstance(streams, list) and len(streams) == 1:
        observed = _probe_scalar(_json_mapping(streams[0], "ffprobe stream").get("nb_read_frames"))
        if observed is not None:
            return observed
    try:
        return str(round(float(Fraction(result["avg_frame_rate"])) * float(result["duration"])))
    except (KeyError, ValueError, ZeroDivisionError) as error:
        raise ManifestError("ffprobe cannot determine the frame count") from error


def ffprobe_media(path: Path) -> ProbeResult:
    document = _probe_document(path, PROBE_ENTRIES)
    streams = document.get("streams")
    if not isinstance(streams, list) or len(streams) != 1:
        raise ManifestError("ffprobe must return exactly one selected video stream")
    stream = _json_mapping(streams[0], "ffprobe stream")
    format_data = _json_mapping(document.get("format"), "ffprobe format")
    result: dict[str, str] = {}
    for key in ("codec_name", "profile", "pix_fmt", "width", "height", "avg_frame_rate"):
        value = _probe_scalar(stream.get(key))
        if value is None:
            raise ManifestError(f"ffprobe stream is missing {key}")
        result[key] = value
    level = _probe_scalar(stream.get("level"))
    if level is not None:
        result["level"] = level
    for key in ("format_name", "duration"):
        value = _probe_scalar(format_data.get(key))
        if value is None:
            raise ManifestError(f"ffprobe format is missing {key}")
        result[key] = value
    result["nb_frames"] = _frame_count(path, stream, result)
    return result


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _verify_probe(scenario: Scenario, probe: ProbeResult) -> None:
    pix_fmt = probe.get("pix_fmt", "")
    bit_depth = 10 if "10" in pix_fmt else 8
    chroma = "4:2:0" if "420" in pix_fmt else "unknown"
    try:
        fps = float(Fraction(probe.get("avg_frame_rate", "0/1")))
        duration = float(probe.get("duration", "0"))
        frames = int(probe.get("nb_frames", "0"))
        width = int(probe.get("width", "0"))
        height = int(probe.get("height", "0"))
    except (ValueError, ZeroDivisionError) as error:
        raise ManifestError("ffprobe returned invalid numeric metadata") from error
    container_names = probe.get("format_name", "").split(",")
    expected_container = "mov" if scenario.container == "mp4" else scenario.container
    exact = (
        probe.get("codec_name", "").lower() == scenario.codec
        and probe.get("profile") == scenario.profile
        and expected_container in container_names
        and bit_depth == scenario.bit_depth
        and chroma == scenario.chroma
        and width == scenario.width
        and height == scenario.height
        and frames == scenario.expected_frames
        and math.isclose(fps, scenario.fps, rel_tol=0.0, abs_tol=0.001)
        and math.isclose(duration, scenario.duration, rel_tol=0.0, abs_tol=0.05)
    )
    if not exact:
        raise ManifestError(f"ffprobe metadata mismatch for {scenario.id}")


def parse_and_verify_manifest(path: Path, probe_runner: ProbeRunner = ffprobe_media) -> Manifest:
    raw = load_json(path.read_text())
    document = _json_mapping(raw, "manifest")
    if set(document) != {"schema_version", "scenarios"} or document["schema_version"] != 1:
        raise ManifestError("unsupported manifest schema")
    scenarios_raw = document["scenarios"]
    if not isinstance(scenarios_raw, list) or not scenarios_raw:
        raise ManifestError("manifest scenarios must be a non-empty array")
    scenarios = tuple(parse_scenario(_json_mapping(item, "scenario")) for item in scenarios_raw)
    if len({scenario.id for scenario in scenarios}) != len(scenarios):
        raise ManifestError("duplicate scenario id")
    for scenario in scenarios:
        if not scenario.media_path.is_file() or scenario.media_path.is_symlink():
            raise ManifestError(f"missing or unsafe media: {scenario.media_path}")
        digest = sha256_file(scenario.media_path)
        if digest != scenario.sha256:
            raise ManifestError(f"SHA-256 mismatch for {scenario.id}")
        _verify_probe(scenario, probe_runner(scenario.media_path))
    return Manifest(schema_version=1, scenarios=scenarios)
