from __future__ import annotations

import signal
from pathlib import Path

from ..identity import (
    IdentityError,
    ProcessIdentity,
    authorize_signal,
    capture_identity,
    signal_owned_group,
)
from .helpers import assert_raises


def _proc_entry(
    proc: Path, pid: int, *, start: int, session: int, pgrp: int, cmdline: bytes
) -> None:
    entry = proc / str(pid)
    entry.mkdir()
    fields = ["S", "1", str(pgrp), str(session), *(["0"] * 15), str(start)]
    _ = (entry / "stat").write_text(f"{pid} (firefox) " + " ".join(fields))
    _ = (entry / "cmdline").write_bytes(cmdline)
    executable = proc / "firefox-bin"
    if not executable.exists():
        _ = executable.write_bytes(b"ELF")
    (entry / "exe").symlink_to(executable)


def _identity(root: Path) -> ProcessIdentity:
    return ProcessIdentity(
        boot_id="boot-a",
        pid=100,
        start_time=500,
        session=100,
        process_group=100,
        profile=str(root / "profile"),
        token="a" * 32,
        executable=str(root / "firefox-bin"),
        build_id="build-a",
    )


def test_pid_reuse_start_time_mismatch_refuses_term(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    _proc_entry(
        proc,
        100,
        start=501,
        session=100,
        pgrp=100,
        cmdline=f"firefox\0--profile\0{root}/profile\0?run={'a' * 32}\0".encode(),
    )

    # When / Then
    _ = assert_raises(IdentityError, lambda: authorize_signal(_identity(root), proc))


def test_profile_or_token_ownership_failure_refuses_term(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    _proc_entry(
        proc, 100, start=500, session=100, pgrp=100, cmdline=b"firefox\0--profile\0/tmp/other\0"
    )

    # When / Then
    _ = assert_raises(IdentityError, lambda: authorize_signal(_identity(root), proc))


def test_external_process_is_never_signalled_with_owned_group(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    token = "a" * 32
    _proc_entry(
        proc,
        100,
        start=500,
        session=100,
        pgrp=100,
        cmdline=f"firefox\0--profile\0{root}/profile\0http://127.0.0.1/?run={token}\0".encode(),
    )
    _proc_entry(proc, 200, start=700, session=200, pgrp=200, cmdline=b"external\0")
    sent: list[tuple[int, signal.Signals]] = []

    # When
    signal_owned_group(
        _identity(root),
        signal.SIGTERM,
        proc,
        lambda pid, sig: sent.append((pid, sig)),
        lambda _path: "build-a",
    )

    # Then
    assert sent == [(-100, signal.SIGTERM)]
    assert all(pid != -200 for pid, _sig in sent)


def test_capture_requires_the_requested_binary_image(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    token = "a" * 32
    _proc_entry(
        proc,
        100,
        start=500,
        session=100,
        pgrp=100,
        cmdline=f"{root}/bin/firefox\0--profile\0{root}/profile\0?run={token}\0".encode(),
    )
    launcher = proc / "bash"
    _ = launcher.write_bytes(b"ELF")
    (proc / "100/exe").unlink()
    (proc / "100/exe").symlink_to(launcher)

    # When / Then
    _ = assert_raises(
        IdentityError,
        lambda: capture_identity(100, root / "profile", token, "firefox", proc, lambda _p: "b"),
    )


def test_capture_binds_the_final_firefox_image(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    token = "a" * 32
    _proc_entry(
        proc,
        100,
        start=500,
        session=100,
        pgrp=100,
        cmdline=f"{root}/bin/firefox\0--profile\0{root}/profile\0?run={token}\0".encode(),
    )
    binary = proc / "firefox"
    _ = binary.write_bytes(b"ELF")
    (proc / "100/exe").unlink()
    (proc / "100/exe").symlink_to(binary)

    # When
    identity = capture_identity(100, root / "profile", token, "firefox", proc, lambda _p: "b")

    # Then
    assert identity.executable == str(binary)
    assert identity.build_id == "b"


def test_executable_identity_mismatch_refuses_term(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _ = (proc / "boot_id").write_text("boot-a")
    root = Path("/tmp/firefox-video-qa.ABCDEF123456")
    token = "a" * 32
    _proc_entry(
        proc,
        100,
        start=500,
        session=100,
        pgrp=100,
        cmdline=f"firefox\0--profile\0{root}/profile\0?run={token}\0".encode(),
    )
    identity = _identity(root)

    # When / Then
    _ = assert_raises(
        IdentityError,
        lambda: authorize_signal(identity, proc, lambda _path: "build-b"),
    )
