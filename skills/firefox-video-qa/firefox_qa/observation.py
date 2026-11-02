from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .identity import IdentityError, ProcessIdentity
from .models import JsonValue


@dataclass(frozen=True, slots=True)
class ProcessObservation:
    pid: int
    start_time: int
    session: int
    role: str
    devices: tuple[str, ...]
    maps: tuple[str, ...]

    def to_json(self, phase: str, complete: bool) -> dict[str, JsonValue]:
        return {
            "phase": phase,
            "complete": complete,
            "pid": self.pid,
            "start_time": self.start_time,
            "session": self.session,
            "role": self.role,
            "devices": list(self.devices),
            "maps": list(self.maps),
        }


def _role(argv: tuple[str, ...]) -> str:
    words = {word for argument in argv for word in argument.split()}
    for role in ("rdd", "gpu", "tab", "socket", "utility"):
        if role in words or role in argv:
            return role
    return "parent"


def _same_uid(entry: Path) -> bool:
    try:
        status = (entry / "status").read_text()
    except (OSError, UnicodeDecodeError):
        return False
    return f"Uid:\t{os.getuid()}\t" in status


def _vanished(entry: Path) -> bool:
    return not entry.exists()


def _process(entry: Path, session: int | None) -> ProcessObservation | None:
    try:
        fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        process_session = int(fields[3])
        start_time = int(fields[19])
        argv = tuple(
            part.decode() for part in (entry / "cmdline").read_bytes().split(b"\0") if part
        )
    except (OSError, UnicodeDecodeError, ValueError, IndexError) as error:
        if _vanished(entry):
            return None
        if session is not None or _same_uid(entry):
            raise IdentityError(f"process {entry.name} identity is opaque") from error
        return None
    devices: set[str] = set()
    try:
        for descriptor in (entry / "fd").iterdir():
            try:
                target = str(descriptor.readlink())
            except FileNotFoundError:
                continue
            if re.fullmatch(r"/dev/(?:video[0-9]+|dri/renderD[0-9]+)", target):
                devices.add(target)
    except (FileNotFoundError, PermissionError):
        if _vanished(entry):
            return None
        if session is not None and process_session == session:
            raise IdentityError(f"owned process {entry.name} descriptors are opaque") from None
    if session is None:
        if not devices:
            return None
        return ProcessObservation(
            int(entry.name), start_time, process_session, "external", tuple(sorted(devices)), ()
        )
    if process_session != session:
        return None
    mappings: set[str] = set()
    try:
        for line in (entry / "maps").read_text().splitlines():
            path = line.rsplit(maxsplit=1)[-1]
            if any(name in path for name in ("libavcodec", "libva", "v4l2_drv_video")):
                mappings.add(path)
    except (FileNotFoundError, PermissionError) as error:
        if _vanished(entry):
            return None
        raise IdentityError(f"owned process {entry.name} mappings are opaque") from error
    return ProcessObservation(
        int(entry.name),
        start_time,
        process_session,
        _role(argv),
        tuple(sorted(devices)),
        tuple(sorted(mappings)),
    )


def snapshot(
    phase: str,
    identity: ProcessIdentity | None,
    proc_root: Path | None = None,
) -> tuple[dict[str, JsonValue], ...]:
    root = proc_root or Path("/proc")
    session = identity.session if identity is not None else None
    records: list[dict[str, JsonValue]] = []
    complete = True
    for entry in root.iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            process = _process(entry, session)
        except IdentityError:
            complete = False
            continue
        if process is not None:
            records.append(process.to_json(phase, complete=True))
    if not records:
        records.append({"phase": phase, "complete": complete, "processes": []})
    elif not complete:
        records.append({"phase": phase, "complete": False, "processes": []})
    return tuple(records)


def append_snapshot(path: Path, records: tuple[dict[str, JsonValue], ...]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
        for record in records:
            _ = handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
