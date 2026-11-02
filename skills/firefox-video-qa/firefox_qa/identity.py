from __future__ import annotations

import json
import os
import re
import signal
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal

from .models import JsonValue

TOKEN: Final = re.compile(r"[a-f0-9]{32}")
ROOT: Final = re.compile(r"/tmp/firefox-video-qa\.[A-Za-z0-9]{12}")
ELF_MAGIC: Final = b"\x7fELF"
PT_NOTE: Final = 4
NT_GNU_BUILD_ID: Final = 3
SignalSender = Callable[[int, signal.Signals], None]
BuildIdReader = Callable[[Path], str]


class IdentityError(Exception):
    reason: str

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True, slots=True)
class ProcessIdentity:
    boot_id: str
    pid: int
    start_time: int
    session: int
    process_group: int
    profile: str
    token: str
    executable: str
    build_id: str

    def to_json(self) -> dict[str, JsonValue]:
        return {
            "boot_id": self.boot_id,
            "pid": self.pid,
            "start_time": self.start_time,
            "session": self.session,
            "process_group": self.process_group,
            "profile": self.profile,
            "token": self.token,
            "executable": self.executable,
            "build_id": self.build_id,
        }


@dataclass(frozen=True, slots=True)
class _ProcIdentity:
    parent: int
    process_group: int
    session: int
    start_time: int


def _boot_id(proc_root: Path) -> str:
    test_path = proc_root / "boot_id"
    path = test_path if test_path.exists() else proc_root / "sys/kernel/random/boot_id"
    try:
        return path.read_text().strip()
    except OSError as error:
        raise IdentityError("boot identity is opaque") from error


def _read_process(proc_root: Path, pid: int) -> tuple[_ProcIdentity, tuple[str, ...]]:
    entry = proc_root / str(pid)
    try:
        fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        argv = tuple(
            part.decode(errors="strict")
            for part in (entry / "cmdline").read_bytes().split(b"\0")
            if part
        )
        identity = _ProcIdentity(
            parent=int(fields[1]),
            process_group=int(fields[2]),
            session=int(fields[3]),
            start_time=int(fields[19]),
        )
    except (OSError, UnicodeDecodeError, ValueError, IndexError) as error:
        raise IdentityError(f"process {pid} identity is opaque") from error
    if not argv:
        raise IdentityError(f"process {pid} command line is opaque")
    return identity, argv


def _parse_notes(segment: bytes, byteorder: Literal["little", "big"]) -> str | None:
    cursor = 0
    while cursor + 12 <= len(segment):
        name_size = int.from_bytes(segment[cursor : cursor + 4], byteorder)
        descriptor_size = int.from_bytes(segment[cursor + 4 : cursor + 8], byteorder)
        note_type = int.from_bytes(segment[cursor + 8 : cursor + 12], byteorder)
        cursor += 12
        name_end = cursor + name_size
        descriptor_start = name_end + (-name_size % 4)
        descriptor_end = descriptor_start + descriptor_size
        if descriptor_end > len(segment):
            return None
        name = segment[cursor:name_end].rstrip(b"\0")
        descriptor = segment[descriptor_start:descriptor_end]
        cursor = descriptor_end + (-descriptor_size % 4)
        if note_type == NT_GNU_BUILD_ID and name == b"GNU" and descriptor:
            return descriptor.hex()
    return None


def read_elf_build_id(path: Path) -> str:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise IdentityError("executable build identity is opaque") from error
    if data[:4] != ELF_MAGIC or len(data) < 52:
        raise IdentityError("executable is not an ELF object")
    elf_class = data[4]
    byteorder: Literal["little", "big"]
    if data[5] == 1:
        byteorder = "little"
    elif data[5] == 2:
        byteorder = "big"
    else:
        raise IdentityError("executable has an unknown byte order")
    if elf_class == 2:
        header_size, header_endian = 64, True
    elif elf_class == 1:
        header_size, header_endian = 52, False
    else:
        raise IdentityError("executable has an unsupported ELF class")
    if len(data) < header_size:
        raise IdentityError("executable header is truncated")
    program_offset = int.from_bytes(data[32:40] if header_endian else data[28:32], byteorder)
    program_size = int.from_bytes(data[54:56] if header_endian else data[42:44], byteorder)
    program_count = int.from_bytes(data[56:58] if header_endian else data[44:46], byteorder)
    if program_offset + program_count * program_size > len(data):
        raise IdentityError("executable program headers are truncated")
    offset_at, size_at = (8, 32) if header_endian else (4, 16)
    for index in range(program_count):
        base = program_offset + index * program_size
        if base + size_at + 4 > len(data):
            break
        if int.from_bytes(data[base : base + 4], byteorder) != PT_NOTE:
            continue
        offset = int.from_bytes(data[base + offset_at : base + offset_at + 4], byteorder)
        size = int.from_bytes(data[base + size_at : base + size_at + 4], byteorder)
        build_id = _parse_notes(data[offset : offset + size], byteorder)
        if build_id is not None:
            return build_id
    raise IdentityError("executable has no GNU build id")


def _executable(proc_root: Path, pid: int) -> str:
    try:
        return str((proc_root / str(pid) / "exe").readlink())
    except OSError as error:
        raise IdentityError(f"process {pid} executable is opaque") from error


def capture_identity(
    pid: int,
    profile: Path,
    token: str,
    binary_name: str,
    proc_root: Path | None = None,
    build_id_reader: BuildIdReader = read_elf_build_id,
) -> ProcessIdentity:
    proc_root = proc_root or Path("/proc")
    if TOKEN.fullmatch(token) is None or ROOT.fullmatch(str(profile.parent)) is None:
        raise IdentityError("invalid profile or token")
    process, argv = _read_process(proc_root, pid)
    if process.session != pid or process.process_group != pid:
        raise IdentityError("Firefox parent is not its session and process-group leader")
    if str(profile) not in argv or not any(token in argument for argument in argv):
        raise IdentityError("Firefox parent does not contain the exact profile and token")
    executable = _executable(proc_root, pid)
    if Path(executable).name != binary_name:
        raise IdentityError(f"process {pid} is still the launcher, not {binary_name}")
    return ProcessIdentity(
        boot_id=_boot_id(proc_root),
        pid=pid,
        start_time=process.start_time,
        session=process.session,
        process_group=process.process_group,
        profile=str(profile),
        token=token,
        executable=executable,
        build_id=build_id_reader(Path(executable)),
    )


def wait_capture_identity(
    pid: int,
    profile: Path,
    token: str,
    binary_name: str,
    timeout: float = 2.0,
    proc_root: Path | None = None,
) -> ProcessIdentity:
    root = proc_root or Path("/proc")
    deadline = time.monotonic() + timeout
    last_error = IdentityError("Firefox parent identity was not ready")
    while time.monotonic() < deadline:
        try:
            return capture_identity(pid, profile, token, binary_name, root)
        except IdentityError as error:
            last_error = error
            if not (root / str(pid)).exists():
                raise
            time.sleep(0.01)
    raise last_error


def authorize_signal(
    identity: ProcessIdentity,
    proc_root: Path | None = None,
    build_id_reader: BuildIdReader = read_elf_build_id,
) -> None:
    proc_root = proc_root or Path("/proc")
    if (
        TOKEN.fullmatch(identity.token) is None
        or ROOT.fullmatch(str(Path(identity.profile).parent)) is None
    ):
        raise IdentityError("stored profile or token is invalid")
    if _boot_id(proc_root) != identity.boot_id:
        raise IdentityError("boot identity changed")
    process, argv = _read_process(proc_root, identity.pid)
    expected = (identity.start_time, identity.session, identity.process_group)
    observed = (process.start_time, process.session, process.process_group)
    if (
        observed != expected
        or identity.session != identity.pid
        or identity.process_group != identity.pid
    ):
        raise IdentityError("PID start time, session, or process group changed")
    if identity.profile not in argv or not any(identity.token in argument for argument in argv):
        raise IdentityError("profile or run token ownership failed")
    executable = _executable(proc_root, identity.pid)
    if build_id_reader(Path(executable)) != identity.build_id:
        raise IdentityError("executable build identity changed")


def signal_owned_group(
    identity: ProcessIdentity,
    requested_signal: signal.Signals,
    proc_root: Path | None = None,
    sender: SignalSender = os.kill,
    build_id_reader: BuildIdReader = read_elf_build_id,
) -> None:
    root = proc_root or Path("/proc")
    authorize_signal(identity, root, build_id_reader)
    sender(-identity.process_group, requested_signal)


def write_identity(path: Path, identity: ProcessIdentity) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(identity.to_json(), handle, sort_keys=True)
        _ = handle.write("\n")
