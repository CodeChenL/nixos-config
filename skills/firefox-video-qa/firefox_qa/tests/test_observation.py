from __future__ import annotations

from pathlib import Path

from ..identity import ProcessIdentity
from ..observation import snapshot


def _process_entry(proc: Path, pid: int, cmdline: bytes, session: int) -> None:
    entry = proc / str(pid)
    entry.mkdir()
    fields = ["S", "1", str(session), str(session), *(["0"] * 15), "500"]
    _ = (entry / "stat").write_text(f"{pid} (firefox) " + " ".join(fields))
    _ = (entry / "cmdline").write_bytes(cmdline)
    (entry / "fd").mkdir()
    _ = (entry / "maps").write_text("")


def _identity(session: int) -> ProcessIdentity:
    return ProcessIdentity(
        boot_id="boot-a",
        pid=session,
        start_time=500,
        session=session,
        process_group=session,
        profile="/tmp/firefox-video-qa.ABCDEF123456/profile",
        token="a" * 32,
        executable="/opt/firefox/firefox",
        build_id="build-a",
    )


def test_content_process_parameters_in_one_argument_are_classified(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _process_entry(proc, 100, b"firefox -contentproc -parentPid 90 -appDir /x 4 rdd", session=100)

    # When
    records = snapshot("during", _identity(100), proc)

    # Then
    assert records[0]["role"] == "rdd"


def test_separate_role_token_is_classified(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _process_entry(proc, 100, b"firefox\0-contentproc\0gpu\0", session=100)

    # When
    records = snapshot("during", _identity(100), proc)

    # Then
    assert records[0]["role"] == "gpu"


def test_vanished_process_does_not_mark_snapshot_incomplete(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _process_entry(proc, 100, b"firefox\0-contentproc\0rdd\0", session=100)
    (proc / "123").symlink_to(proc / "gone")

    # When
    records = snapshot("during", _identity(100), proc)

    # Then
    assert all(record.get("complete") is True for record in records)
    assert records[0]["role"] == "rdd"


def test_still_present_opaque_process_marks_snapshot_incomplete(tmp_path: Path) -> None:
    # Given
    proc = tmp_path / "proc"
    proc.mkdir()
    _process_entry(proc, 100, b"firefox\0-contentproc\0rdd\0", session=100)
    opaque = proc / "101"
    opaque.mkdir()
    _ = (opaque / "stat").write_text("101 (firefox) S 1 101 101 " + "0 " * 15 + "500")
    _ = (opaque / "cmdline").write_bytes(b"\xff")

    # When
    records = snapshot("during", _identity(100), proc)

    # Then
    assert any(record.get("complete") is False for record in records)
