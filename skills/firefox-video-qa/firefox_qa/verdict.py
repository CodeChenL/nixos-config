from __future__ import annotations

from .models import (
    AxisStatus,
    AxisVerdict,
    MetricState,
    PageResult,
    RunMode,
    Scenario,
    TimelineSummary,
    TraceProfile,
    Verdict,
)


def _axis(passed: bool, failure: bool, pass_reason: str, fail_reason: str) -> AxisVerdict:
    if failure:
        return AxisVerdict(AxisStatus.FAIL, (fail_reason,))
    if passed:
        return AxisVerdict(AxisStatus.PASS, (pass_reason,))
    return AxisVerdict(AxisStatus.INCONCLUSIVE, (fail_reason,))


def evaluate_verdict(
    scenario: Scenario,
    page: PageResult,
    timeline: TimelineSummary,
    cleanup_complete: bool,
) -> Verdict:
    hardware_checks = (
        timeline.playback_tracking,
        timeline.hardware_codec,
        timeline.hardware_accelerated,
        timeline.terminal_pts,
        timeline.seek_pts,
        timeline.rdd_device_owner,
        timeline.media_libraries_mapped,
        timeline.dmabuf_import,
    )
    hardware = _axis(
        all(hardware_checks) and not timeline.playback_fallback,
        timeline.playback_fallback,
        "playback-correlated hardware chain is complete",
        "hardware chain is incomplete or playback fallback was observed",
    )
    rendered = (
        page.state == "ended"
        and page.error is None
        and page.presented_frames > 0
        and page.duration > 0
        and abs(page.current_time - page.duration) <= 0.25
        and (scenario.mode is RunMode.FULL or page.post_seek_presented)
        and (
            page.total_video_frames.value == scenario.expected_frames
            if scenario.mode is RunMode.FULL
            else page.total_video_frames.value is not None
            and page.presented_frames <= page.total_video_frames.value <= scenario.expected_frames
        )
    )
    rendering = _axis(
        rendered,
        page.state.endswith("error"),
        "playback reached EOS",
        "playback did not prove presentation to EOS",
    )
    corruption = page.corrupted_video_frames
    quality = {
        MetricState.NONZERO: AxisVerdict(AxisStatus.FAIL, ("corruptedVideoFrames is nonzero",)),
        MetricState.ZERO: AxisVerdict(AxisStatus.PASS, ("corruptedVideoFrames is zero",)),
        MetricState.UNAVAILABLE: AxisVerdict(
            AxisStatus.INCONCLUSIVE, ("corruptedVideoFrames is unavailable or null",)
        ),
        MetricState.NULL: AxisVerdict(
            AxisStatus.INCONCLUSIVE, ("corruptedVideoFrames is unavailable or null",)
        ),
    }[corruption.state]
    cleanup = _axis(
        cleanup_complete,
        not cleanup_complete,
        "all owned resources were released",
        "owned resource cleanup was not proven",
    )
    dropped = page.dropped_video_frames.value
    if scenario.trace_profile is TraceProfile.EVIDENCE:
        performance = AxisVerdict(
            AxisStatus.INCONCLUSIVE,
            ("evidence-profile metrics are instrumented",),
            instrumented=True,
        )
    elif scenario.dropped_threshold is None or dropped is None:
        performance = AxisVerdict(
            AxisStatus.INCONCLUSIVE, ("no predeclared dropped-frame threshold",)
        )
    elif dropped > scenario.dropped_threshold:
        performance = AxisVerdict(AxisStatus.FAIL, ("dropped frames exceeded threshold",))
    else:
        performance = AxisVerdict(AxisStatus.PASS, ("dropped frames remained within threshold",))
    required = (hardware, rendering, quality, cleanup, performance)
    if any(axis.status is AxisStatus.FAIL for axis in required):
        overall = AxisVerdict(AxisStatus.FAIL, ("one or more required axes failed",))
    elif all(axis.status is AxisStatus.PASS for axis in required):
        overall = AxisVerdict(AxisStatus.PASS, ("all required axes passed",))
    else:
        overall = AxisVerdict(
            AxisStatus.INCONCLUSIVE, ("one or more required axes are inconclusive",)
        )
    return Verdict(hardware, rendering, quality, cleanup, performance, overall)
