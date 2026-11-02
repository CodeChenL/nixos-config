from __future__ import annotations

import re
from typing import Final

from .json_value import load_json
from .models import JsonValue, RunMode, Scenario, TimelineSummary

TRACKING: Final = re.compile(r"mTrackingId = (ChannelDecoder-[A-Za-z0-9-]+)")
INSTANCE: Final = re.compile(r"\[(RDD) ([0-9]+): (MediaPDecoder #[0-9]+|MediaSupervisor #[0-9]+)\]")
PTS: Final = re.compile(r"VA-API frame pts=([0-9]+)")
SOFTWARE: Final = re.compile(r"Using preferred software codec ([A-Za-z0-9_-]+)")
HARDWARE: Final = re.compile(r"Using preferred hardware codec ([A-Za-z0-9_-]+)")
OUTPUT_MARKERS: Final = {"NV12": "3231564e", "P010": "30313050", "P010LE": "30313050"}


def _observation_flags(text: str, rdd_pids: frozenset[int]) -> tuple[bool, bool]:
    owner = False
    libraries: set[str] = set()
    complete = True
    for line in text.splitlines():
        if not line.strip():
            continue
        raw = load_json(line)
        if not isinstance(raw, dict) or raw.get("phase") != "during":
            continue
        if raw.get("complete") is not True:
            complete = False
        if raw.get("role") != "rdd":
            continue
        pid = raw.get("pid")
        if not isinstance(pid, int) or pid not in rdd_pids:
            continue
        devices = raw.get("devices")
        maps = raw.get("maps")
        if isinstance(devices, list) and any(
            isinstance(device, str) and re.fullmatch(r"/dev/video[0-9]+", device)
            for device in devices
        ):
            owner = True
        if isinstance(maps, list):
            for mapping in maps:
                if isinstance(mapping, str):
                    libraries.add(mapping)
    required = ("libavcodec", "libva", "v4l2_drv_video")
    mapped = all(any(name in mapping for mapping in libraries) for name in required)
    return owner and complete, mapped and complete


def analyze_timeline(scenario: Scenario, decoder_log: str, observation_log: str) -> TimelineSummary:
    lines = decoder_log.splitlines()
    tracking_ids = tuple(
        dict.fromkeys(match.group(1) for line in lines if (match := TRACKING.search(line)))
    )
    tracking_index = next(
        (index for index, line in enumerate(lines) if TRACKING.search(line)), None
    )
    hardware_index = next(
        (
            index
            for index, line in enumerate(lines)
            if (match := HARDWARE.search(line)) and match.group(1).lower() == scenario.codec
        ),
        None,
    )
    relevant = lines[hardware_index:] if hardware_index is not None else []
    instances = tuple(
        dict.fromkeys(
            f"{match.group(2)}:{match.group(3)}"
            for line in relevant
            if (match := INSTANCE.search(line))
        )
    )
    pts = tuple(int(match.group(1)) for line in relevant if (match := PTS.search(line)))
    software_rebuild = any(
        (match := SOFTWARE.search(line))
        and match.group(1).lower() == scenario.codec
        and (instance := INSTANCE.search(line)) is not None
        and instance.group(3).startswith("MediaPDecoder")
        for line in relevant[1:]
    )
    disallowed = any("HardwareDecoderNotAllowed" in line for line in relevant)
    decode_error = any(
        marker in line
        for line in relevant
        for marker in ("Decode error", "decoder error", "surface import failed")
    )
    playback_fallback = software_rebuild or disallowed or decode_error
    terminal_target = int(max(0.0, scenario.duration - max(0.25, 2.0 / scenario.fps)) * 1_000_000)
    seek_target = int((scenario.seek_target or 0.0) * 1_000_000)
    rdd_pids = frozenset(int(instance.split(":", 1)[0]) for instance in instances)
    owner, libraries = _observation_flags(observation_log, rdd_pids)
    output_marker = OUTPUT_MARKERS[scenario.expected_output]
    dmabuf = any(
        "ImportPRIMESurfaceDescriptor" in line and output_marker in line for line in relevant
    )
    dmabuf = dmabuf and any("zero-copy EGLImageTargetTexture2D succeeded" in line for line in lines)
    events: list[dict[str, JsonValue]] = []
    for index, line in enumerate(lines):
        event: str | None = None
        if TRACKING.search(line):
            event = "playback-tracking"
        elif HARDWARE.search(line):
            event = "hardware-codec"
        elif "IsHardwareAccelerated=true" in line:
            event = "hardware-accelerated"
        elif "ProcessFlush()" in line:
            event = "flush"
        elif PTS.search(line):
            event = "hardware-frame"
        elif "HardwareDecoderNotAllowed" in line:
            event = "fallback-signal"
        elif SOFTWARE.search(line):
            instance = INSTANCE.search(line)
            event = (
                "fallback-signal"
                if hardware_index is not None
                and index > hardware_index
                and instance is not None
                and instance.group(3).startswith("MediaPDecoder")
                else "capability-probe"
            )
        if event is not None:
            events.append({"sequence": index, "event": event, "raw": line})
    return TimelineSummary(
        playback_tracking=bool(tracking_ids),
        hardware_codec=(
            hardware_index is not None
            and tracking_index is not None
            and tracking_index < hardware_index
            and bool(instances)
        ),
        hardware_accelerated=any("IsHardwareAccelerated=true" in line for line in relevant),
        terminal_pts=bool(pts) and max(pts) >= terminal_target,
        seek_pts=scenario.mode is RunMode.FULL or any(value >= seek_target for value in pts),
        rdd_device_owner=owner,
        media_libraries_mapped=libraries,
        dmabuf_import=dmabuf,
        playback_fallback=playback_fallback,
        playback_tracking_ids=tracking_ids,
        decoder_instances=instances,
        hardware_frame_pts=pts,
        events=tuple(events),
    )
