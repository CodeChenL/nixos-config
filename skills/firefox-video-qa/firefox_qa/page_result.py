from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Final

from .json_value import JsonDecodeError, load_json
from .models import (
    CapabilityResult,
    FrameCallback,
    JsonValue,
    Metric,
    MetricState,
    PageResult,
    RunMode,
)

TOKEN: Final = re.compile(r"[a-f0-9]{32}")
RESULT_FIELDS: Final = {
    "schemaVersion",
    "runToken",
    "scenarioId",
    "mode",
    "state",
    "currentTime",
    "duration",
    "presentedFrames",
    "postSeekPresented",
    "frameCallbacks",
    "capabilities",
    "quality",
    "error",
}


class ResultError(Exception):
    pass


def _mapping(value: JsonValue, label: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        raise ResultError(f"{label} must be an object")
    return dict(value)


def _string(raw: Mapping[str, JsonValue], key: str) -> str:
    value = raw.get(key)
    if not isinstance(value, str) or not value or len(value) > 256:
        raise ResultError(f"invalid {key}")
    return value


def _number(raw: Mapping[str, JsonValue], key: str) -> float:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ResultError(f"invalid {key}")
    return float(value)


def _integer(raw: Mapping[str, JsonValue], key: str) -> int:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ResultError(f"invalid {key}")
    return value


def _optional_boolean(raw: Mapping[str, JsonValue], key: str) -> bool | None:
    value = raw.get(key)
    if value is not None and not isinstance(value, bool):
        raise ResultError(f"invalid {key}")
    return value


def _metric(value: JsonValue) -> Metric:
    raw = _mapping(value, "metric")
    if set(raw) != {"state", "value"}:
        raise ResultError("invalid metric schema")
    try:
        state = MetricState(_string(raw, "state"))
    except ValueError as error:
        raise ResultError("invalid metric state") from error
    metric_value = raw["value"]
    if state in {MetricState.UNAVAILABLE, MetricState.NULL}:
        if metric_value is not None:
            raise ResultError("non-value metric must contain null")
        return Metric(state, None)
    if isinstance(metric_value, bool) or not isinstance(metric_value, int) or metric_value < 0:
        raise ResultError("value metric must contain a non-negative integer")
    if (state is MetricState.ZERO) != (metric_value == 0):
        raise ResultError("metric state and value disagree")
    return Metric(state, metric_value)


def parse_page_result_bytes(payload: bytes) -> PageResult:
    try:
        raw = load_json(payload)
    except JsonDecodeError as error:
        raise ResultError("result is not valid UTF-8 JSON") from error
    document = _mapping(raw, "result")
    if set(document) != RESULT_FIELDS or document["schemaVersion"] != 1:
        raise ResultError("result fields do not match schema version 1")
    token = _string(document, "runToken")
    if TOKEN.fullmatch(token) is None:
        raise ResultError("invalid run token")
    try:
        mode = RunMode(_string(document, "mode"))
    except ValueError as error:
        raise ResultError("invalid result mode") from error
    callbacks_raw = document["frameCallbacks"]
    if not isinstance(callbacks_raw, list) or len(callbacks_raw) > 10_000:
        raise ResultError("invalid frame callback list")
    callbacks: list[FrameCallback] = []
    for value in callbacks_raw:
        callback = _mapping(value, "frame callback")
        if set(callback) != {"mediaTime", "presentedFrames"}:
            raise ResultError("invalid frame callback schema")
        callbacks.append(
            FrameCallback(_number(callback, "mediaTime"), _integer(callback, "presentedFrames"))
        )
    quality = _mapping(document["quality"], "quality")
    if set(quality) != {"api", "totalVideoFrames", "droppedVideoFrames", "corruptedVideoFrames"}:
        raise ResultError("invalid quality schema")
    quality_api = _string(quality, "api")
    if quality_api not in {"available", "unavailable"}:
        raise ResultError("invalid quality API state")
    capabilities = _mapping(document["capabilities"], "capabilities")
    capability_fields = {
        "canPlayType",
        "mediaCapabilitiesState",
        "supported",
        "smooth",
        "powerEfficient",
        "error",
    }
    if set(capabilities) != capability_fields:
        raise ResultError("invalid capabilities schema")
    capability_state = _string(capabilities, "mediaCapabilitiesState")
    if capability_state not in {"available", "unavailable", "error"}:
        raise ResultError("invalid MediaCapabilities state")
    supported = _optional_boolean(capabilities, "supported")
    smooth = _optional_boolean(capabilities, "smooth")
    power_efficient = _optional_boolean(capabilities, "powerEfficient")
    capability_error = capabilities["error"]
    if capability_error is not None and not isinstance(capability_error, str):
        raise ResultError("invalid MediaCapabilities error")
    error_value = document["error"]
    if error_value is not None and (not isinstance(error_value, str) or len(error_value) > 1024):
        raise ResultError("invalid result error")
    post_seek = document["postSeekPresented"]
    if not isinstance(post_seek, bool):
        raise ResultError("invalid postSeekPresented")
    return PageResult(
        schema_version=1,
        run_token=token,
        scenario_id=_string(document, "scenarioId"),
        mode=mode,
        state=_string(document, "state"),
        current_time=_number(document, "currentTime"),
        duration=_number(document, "duration"),
        presented_frames=_integer(document, "presentedFrames"),
        post_seek_presented=post_seek,
        frame_callbacks=tuple(callbacks),
        capabilities=CapabilityResult(
            can_play_type=_string(capabilities, "canPlayType"),
            media_capabilities_state=capability_state,
            supported=supported,
            smooth=smooth,
            power_efficient=power_efficient,
            error=capability_error,
        ),
        quality_api=quality_api,
        total_video_frames=_metric(quality["totalVideoFrames"]),
        dropped_video_frames=_metric(quality["droppedVideoFrames"]),
        corrupted_video_frames=_metric(quality["corruptedVideoFrames"]),
        error=error_value,
    )
