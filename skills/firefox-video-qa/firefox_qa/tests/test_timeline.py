from __future__ import annotations

from pathlib import Path

from ..models import RunMode, Scenario, TraceProfile
from ..timeline import analyze_timeline


def _scenario(*, mode: str = "full") -> Scenario:
    run_mode = RunMode(mode)
    return Scenario(
        id="hevc-main10",
        mode=run_mode,
        trace_profile=TraceProfile.EVIDENCE,
        media_path=Path("/tmp/fixture.mp4"),
        sha256="a" * 64,
        mime="video/mp4;codecs=hvc1",
        container="mp4",
        codec="hevc",
        profile="Main 10",
        bit_depth=10,
        chroma="4:2:0",
        width=1280,
        height=720,
        fps=30.0,
        duration=6.0,
        expected_frames=180,
        expected_output="P010",
        seek_target=4.0 if run_mode is RunMode.SEEK else None,
        dropped_threshold=None,
    )


def _observation() -> str:
    return "\n".join(
        [
            '{"phase":"during","complete":true,"pid":43643,"start_time":500,"session":43044,"role":"rdd","devices":["/dev/video0"],"maps":["libavcodec.so","libva.so","v4l2_drv_video.so"]}',
            '{"phase":"after","complete":true,"processes":[]}',
        ]
    )


def _hardware_log() -> str:
    return "\n".join(
        [
            "[Child 43746: MediaSupervisor #1] mTrackingId = ChannelDecoder-43746-0",
            "[RDD 43643: MediaSupervisor #1] Using preferred software codec hevc",
            "[RDD 43643: MediaPDecoder #1] Using preferred hardware codec hevc",
            "[RDD 43643: MediaPDecoder #1] IsHardwareAccelerated=true",
            "[RDD 43643: MediaPDecoder #1] ImportPRIMESurfaceDescriptor FOURCC 30313050",
            "[Parent 43044: Renderer] zero-copy EGLImageTargetTexture2D succeeded",
            "[RDD 43643: MediaPDecoder #1] VA-API frame pts=5966666",
        ]
    )


def test_capability_probe_software_codec_noise_is_not_playback_fallback() -> None:
    # Given / When
    summary = analyze_timeline(_scenario(), _hardware_log(), _observation())

    # Then
    assert summary.playback_fallback is False
    assert summary.hardware_codec is True


def test_seek_flush_with_post_seek_hardware_frames_is_recovery_not_fallback() -> None:
    # Given
    log = (
        _hardware_log()
        + "\n"
        + "\n".join(
            [
                "[RDD 43643: MediaPDecoder #1] ProcessFlush()",
                "[RDD 43643: MediaPDecoder #1] VA-API frame pts=4000000",
                "[RDD 43643: MediaPDecoder #1] VA-API frame pts=5966666",
            ]
        )
    )

    # When
    summary = analyze_timeline(_scenario(mode="seek"), log, _observation())

    # Then
    assert summary.playback_fallback is False
    assert summary.seek_pts is True


def test_flush_followed_by_hardware_disallow_and_software_rebuild_is_fallback() -> None:
    # Given
    log = (
        _hardware_log()
        + "\n"
        + "\n".join(
            [
                "[RDD 43643: MediaPDecoder #1] ProcessFlush()",
                "[RDD 43643: MediaPDecoder #1] HardwareDecoderNotAllowed",
                "[RDD 43643: MediaPDecoder #1] Using preferred software codec hevc",
            ]
        )
    )

    # When
    summary = analyze_timeline(_scenario(), log, _observation())

    # Then
    assert summary.playback_fallback is True


def test_unrelated_rdd_owner_cannot_complete_hardware_path() -> None:
    # Given
    observation = '{"phase":"during","complete":true,"pid":999,"start_time":1,"session":1,"role":"rdd","devices":["/dev/video0"],"maps":["libavcodec.so","libva.so","v4l2_drv_video.so"]}'

    # When
    summary = analyze_timeline(_scenario(), _hardware_log(), observation)

    # Then
    assert summary.rdd_device_owner is False
    assert summary.media_libraries_mapped is False
