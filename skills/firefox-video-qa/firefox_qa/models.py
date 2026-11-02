from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum, unique
from pathlib import Path

type JsonValue = str | int | float | bool | None | list[JsonValue] | dict[str, JsonValue]


@unique
class RunMode(StrEnum):
    FULL = "full"
    SEEK = "seek"


@unique
class TraceProfile(StrEnum):
    EVIDENCE = "evidence"
    PERFORMANCE = "performance"


@unique
class MetricState(StrEnum):
    UNAVAILABLE = "unavailable"
    NULL = "null"
    ZERO = "zero"
    NONZERO = "nonzero"


@unique
class AxisStatus(StrEnum):
    PASS = "PASS"
    FAIL = "FAIL"
    INCONCLUSIVE = "INCONCLUSIVE"
    BLOCKED = "BLOCKED"
    UNSUPPORTED = "UNSUPPORTED"


@dataclass(frozen=True, slots=True)
class Scenario:
    id: str
    mode: RunMode
    trace_profile: TraceProfile
    media_path: Path
    sha256: str
    mime: str
    container: str
    codec: str
    profile: str
    bit_depth: int
    chroma: str
    width: int
    height: int
    fps: float
    duration: float
    expected_frames: int
    expected_output: str
    seek_target: float | None
    dropped_threshold: int | None

    def to_json(self) -> dict[str, JsonValue]:
        data: dict[str, JsonValue] = {
            "id": self.id,
            "mode": self.mode.value,
            "trace_profile": self.trace_profile.value,
            "media_path": str(self.media_path),
            "sha256": self.sha256,
            "mime": self.mime,
            "container": self.container,
            "codec": self.codec,
            "profile": self.profile,
            "bit_depth": self.bit_depth,
            "chroma": self.chroma,
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
            "duration": self.duration,
            "expected_frames": self.expected_frames,
            "expected_output": self.expected_output,
            "seek_target": self.seek_target,
            "dropped_threshold": self.dropped_threshold,
        }
        return data


@dataclass(frozen=True, slots=True)
class Manifest:
    schema_version: int
    scenarios: tuple[Scenario, ...]


@dataclass(frozen=True, slots=True)
class Metric:
    state: MetricState
    value: int | None


@dataclass(frozen=True, slots=True)
class FrameCallback:
    media_time: float
    presented_frames: int


@dataclass(frozen=True, slots=True)
class CapabilityResult:
    can_play_type: str
    media_capabilities_state: str
    supported: bool | None
    smooth: bool | None
    power_efficient: bool | None
    error: str | None


@dataclass(frozen=True, slots=True)
class PageResult:
    schema_version: int
    run_token: str
    scenario_id: str
    mode: RunMode
    state: str
    current_time: float
    duration: float
    presented_frames: int
    post_seek_presented: bool
    frame_callbacks: tuple[FrameCallback, ...]
    capabilities: CapabilityResult
    quality_api: str
    total_video_frames: Metric
    dropped_video_frames: Metric
    corrupted_video_frames: Metric
    error: str | None


@dataclass(frozen=True, slots=True)
class TimelineSummary:
    playback_tracking: bool
    hardware_codec: bool
    hardware_accelerated: bool
    terminal_pts: bool
    seek_pts: bool
    rdd_device_owner: bool
    media_libraries_mapped: bool
    dmabuf_import: bool
    playback_fallback: bool
    playback_tracking_ids: tuple[str, ...]
    decoder_instances: tuple[str, ...]
    hardware_frame_pts: tuple[int, ...]
    events: tuple[dict[str, JsonValue], ...]

    def to_json(self) -> dict[str, JsonValue]:
        return {
            "playback_tracking": self.playback_tracking,
            "hardware_codec": self.hardware_codec,
            "hardware_accelerated": self.hardware_accelerated,
            "terminal_pts": self.terminal_pts,
            "seek_pts": self.seek_pts,
            "rdd_device_owner": self.rdd_device_owner,
            "media_libraries_mapped": self.media_libraries_mapped,
            "dmabuf_import": self.dmabuf_import,
            "playback_fallback": self.playback_fallback,
            "playback_tracking_ids": list(self.playback_tracking_ids),
            "decoder_instances": list(self.decoder_instances),
            "hardware_frame_pts": list(self.hardware_frame_pts),
            "events": list(self.events),
        }


@dataclass(frozen=True, slots=True)
class AxisVerdict:
    status: AxisStatus
    reasons: tuple[str, ...]
    instrumented: bool = False

    def to_json(self) -> dict[str, JsonValue]:
        return {
            "status": self.status.value,
            "reasons": list(self.reasons),
            "instrumented": self.instrumented,
        }


@dataclass(frozen=True, slots=True)
class Verdict:
    hardware_path: AxisVerdict
    rendering: AxisVerdict
    quality: AxisVerdict
    cleanup: AxisVerdict
    performance: AxisVerdict
    overall: AxisVerdict

    def to_json(self) -> dict[str, JsonValue]:
        return {
            "hardware_path": self.hardware_path.to_json(),
            "rendering": self.rendering.to_json(),
            "quality": self.quality.to_json(),
            "cleanup": self.cleanup.to_json(),
            "performance": self.performance.to_json(),
            "overall": self.overall.to_json(),
        }
