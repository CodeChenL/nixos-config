from __future__ import annotations

import json
import secrets
import shutil
from pathlib import Path

from ..identity import IdentityError
from ..remote_guard import delete_owned_root
from .helpers import assert_raises

TOKEN = "a" * 32


def _root() -> Path:
    root = Path(f"/tmp/firefox-video-qa.{secrets.token_hex(6)}")
    root.mkdir(mode=0o700)
    _ = (root / ".owner").write_text(TOKEN + "\n")
    _ = (root / ".boot_id").write_text(Path("/proc/sys/kernel/random/boot_id").read_text())
    (root / "profile").mkdir()
    return root


def test_blocked_run_without_browser_identity_can_be_removed() -> None:
    # Given
    root = _root()
    _ = (root / "outcome.json").write_text(
        json.dumps({"status": "BLOCKED", "reason": "visible external video decoder owner"})
    )

    try:
        # When
        delete_owned_root(root, TOKEN)

        # Then
        assert not root.exists()
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_unproven_run_without_outcome_is_retained() -> None:
    # Given
    root = _root()

    try:
        # When / Then
        _ = assert_raises(IdentityError, lambda: delete_owned_root(root, TOKEN))
        assert root.exists()
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_non_blocked_outcome_does_not_authorize_removal() -> None:
    # Given
    root = _root()
    _ = (root / "outcome.json").write_text(json.dumps({"status": "RUNNING"}))

    try:
        # When / Then
        _ = assert_raises(IdentityError, lambda: delete_owned_root(root, TOKEN))
        assert root.exists()
    finally:
        shutil.rmtree(root, ignore_errors=True)
