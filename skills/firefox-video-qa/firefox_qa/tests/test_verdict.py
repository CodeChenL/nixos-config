from __future__ import annotations

from pathlib import Path

from ..models import (
    AxisStatus,
    CapabilityResult,
    FrameCallback,
    Metric,
    MetricState,
    PageResult,
    RunMode,
    Scenario,
    TimelineSummary,
    TraceProfile,
)
from ..verdict import evaluate_verdict


def _scenario(*, threshold: int | None = None, trace_profile: str = "evidence") -> Scenario:
    return Scenario(
        id="case",
        mode=RunMode.FULL,
        trace_profile=TraceProfile(trace_profile),
        media_path=Path("/tmp/fixture.mp4"),
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
        dropped_threshold=threshold,
    )


def _telemetry(*, corrupted_state: str, corrupted_value: int | None = None) -> PageResult:
    return PageResult(
        schema_version=1,
        run_token="a" * 32,
        scenario_id="case",
        mode=RunMode.FULL,
        state="ended",
        current_time=6.0,
        duration=6.0,
        presented_frames=170,
        post_seek_presented=False,
        frame_callbacks=(FrameCallback(6.0, 170),),
        capabilities=CapabilityResult("probably", "available", True, True, True, None),
        quality_api="available",
        total_video_frames=Metric(MetricState.NONZERO, 180),
        dropped_video_frames=Metric(MetricState.NONZERO, 5),
        corrupted_video_frames=Metric(MetricState(corrupted_state), corrupted_value),
        error=None,
    )


def _hardware() -> TimelineSummary:
    return TimelineSummary(
        playback_tracking=True,
        hardware_codec=True,
        hardware_accelerated=True,
        terminal_pts=True,
        seek_pts=True,
        rdd_device_owner=True,
        media_libraries_mapped=True,
        dmabuf_import=True,
        playback_fallback=False,
        playback_tracking_ids=("ChannelDecoder-1-0",),
        decoder_instances=("2:MediaPDecoder #1",),
        hardware_frame_pts=(0, 5_966_666),
        events=(),
    )


def test_null_corruption_is_quality_inconclusive_and_blocks_overall_pass() -> None:
    # Given / When
    verdict = evaluate_verdict(_scenario(), _telemetry(corrupted_state="null"), _hardware(), True)

    # Then
    assert verdict.quality.status is AxisStatus.INCONCLUSIVE
    assert verdict.overall.status is AxisStatus.INCONCLUSIVE


def test_nonzero_corruption_is_quality_fail() -> None:
    # Given / When
    verdict = evaluate_verdict(
        _scenario(), _telemetry(corrupted_state="nonzero", corrupted_value=1), _hardware(), True
    )

    # Then
    assert verdict.quality.status is AxisStatus.FAIL
    assert verdict.overall.status is AxisStatus.FAIL


def test_dropped_frames_without_predeclared_threshold_cannot_pass_performance() -> None:
    # Given / When
    verdict = evaluate_verdict(
        _scenario(trace_profile="performance"),
        _telemetry(corrupted_state="zero", corrupted_value=0),
        _hardware(),
        True,
    )

    # Then
    assert verdict.performance.status is AxisStatus.INCONCLUSIVE


def test_evidence_profile_metrics_are_instrumented_not_performance_pass() -> None:
    # Given / When
    verdict = evaluate_verdict(
        _scenario(threshold=10),
        _telemetry(corrupted_state="zero", corrupted_value=0),
        _hardware(),
        True,
    )

    # Then
    assert verdict.performance.status is AxisStatus.INCONCLUSIVE
    assert verdict.performance.instrumented is True


def test_performance_profile_passes_only_with_declared_threshold() -> None:
    # Given / When
    verdict = evaluate_verdict(
        _scenario(threshold=5, trace_profile="performance"),
        _telemetry(corrupted_state="zero", corrupted_value=0),
        _hardware(),
        True,
    )

    # Then
    assert verdict.performance.status is AxisStatus.PASS
