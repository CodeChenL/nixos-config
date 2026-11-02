from __future__ import annotations

import tarfile
from pathlib import Path

from ..evidence import build_evidence_archive
from ..transport import (
    EVIDENCE_ALLOWLIST,
    TransportError,
    build_ssh_command,
    validate_remote_identity,
)
from .helpers import assert_raises


def test_manifest_transport_uses_ssh_n_and_never_standard_input() -> None:
    # Given / When
    command = build_ssh_command("qa@example.test", ["python3", "/tmp/run.py", "scenario.json"])

    # Then
    assert command[:2] == ("ssh", "-n")
    assert any("scenario.json" in argument for argument in command)
    assert "bash -s" not in command


def _assert_remote_identity_rejected(target: str, root: str, token: str) -> None:
    # Given / When / Then
    _ = assert_raises(TransportError, lambda: validate_remote_identity(target, root, token))


def test_ssh_option_as_target_is_rejected() -> None:
    _assert_remote_identity_rejected(
        "-oProxyCommand=bad", "/tmp/firefox-video-qa.ABCDEF123456", "a" * 32
    )


def test_traversing_remote_root_is_rejected() -> None:
    _assert_remote_identity_rejected(
        "qa@example.test", "/tmp/firefox-video-qa.ABC/../owned", "a" * 32
    )


def test_invalid_run_token_is_rejected() -> None:
    _assert_remote_identity_rejected(
        "qa@example.test", "/tmp/firefox-video-qa.ABCDEF123456", "bad token"
    )


def test_evidence_collection_allowlist_excludes_profiles_cookies_and_glean() -> None:
    # Given / When
    members = set(EVIDENCE_ALLOWLIST)

    # Then
    assert "result.json" in members
    assert "decoder-logs.tar" in members
    assert not any(
        "profile" in member or "cookie" in member.lower() or "glean" in member.lower()
        for member in members
    )
    assert all(Path(member).name == member for member in members)


def test_evidence_archive_never_recurses_into_firefox_profile(tmp_path: Path) -> None:
    # Given
    root = tmp_path / "run"
    profile = root / "profile/datareporting/glean"
    profile.mkdir(parents=True)
    _ = (root / "result.json").write_text("{}")
    _ = (profile / "state").write_text("private")
    _ = (root / "profile/cookies.sqlite").write_text("private")
    archive_path = root / "evidence.tar"

    # When
    _ = build_evidence_archive(root, archive_path)

    # Then
    with tarfile.open(archive_path) as archive:
        assert archive.getnames() == ["result.json"]
