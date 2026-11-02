from __future__ import annotations

from ..models import TraceProfile
from ..remote_runner import trace_settings


def test_performance_profile_uses_low_overhead_observation() -> None:
    # Given / When
    settings = trace_settings(TraceProfile.PERFORMANCE)

    # Then
    assert settings.monitor_interval >= 1.0
    assert not any(entry.endswith(":5") for entry in settings.log_level.split(","))


def test_evidence_profile_retains_high_detail_observation() -> None:
    # Given / When
    settings = trace_settings(TraceProfile.EVIDENCE)

    # Then
    assert settings.monitor_interval == 0.1
    assert "FFmpegLib:5" in settings.log_level
