from __future__ import annotations

import os
import re
import shutil
import sys
from collections.abc import Sequence
from pathlib import Path

from .identity import IdentityError, ProcessIdentity, authorize_signal
from .json_value import load_json
from .models import JsonValue

ROOT = re.compile(r"/tmp/firefox-video-qa\.[A-Za-z0-9]{12}")
TOKEN = re.compile(r"[a-f0-9]{32}")


def _owned_root(root: Path, token: str) -> None:
    if ROOT.fullmatch(str(root)) is None or TOKEN.fullmatch(token) is None:
        raise IdentityError("invalid cleanup identity")
    if not root.is_dir() or root.is_symlink() or root.stat().st_uid != os.getuid():
        raise IdentityError("run root is not an owned directory")
    owner = root / ".owner"
    if not owner.is_file() or owner.is_symlink() or owner.read_text().strip() != token:
        raise IdentityError("owner token mismatch")
    boot = root / ".boot_id"
    current_boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    if not boot.is_file() or boot.is_symlink() or boot.read_text().strip() != current_boot:
        raise IdentityError("boot identity mismatch")


def _stored_identity(path: Path) -> ProcessIdentity:
    raw = load_json(path.read_text())
    if not isinstance(raw, dict):
        raise IdentityError("stored process identity is invalid")
    try:
        return ProcessIdentity(
            boot_id=_required_string(raw, "boot_id"),
            pid=_required_integer(raw, "pid"),
            start_time=_required_integer(raw, "start_time"),
            session=_required_integer(raw, "session"),
            process_group=_required_integer(raw, "process_group"),
            profile=_required_string(raw, "profile"),
            token=_required_string(raw, "token"),
            executable=_required_string(raw, "executable"),
            build_id=_required_string(raw, "build_id"),
        )
    except KeyError as error:
        raise IdentityError("stored process identity is invalid") from error


def _required_string(raw: dict[str, JsonValue], key: str) -> str:
    value = raw[key]
    if not isinstance(value, str):
        raise IdentityError(f"stored {key} is not a string")
    return value


def _required_integer(raw: dict[str, JsonValue], key: str) -> int:
    value = raw[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise IdentityError(f"stored {key} is not an integer")
    return value


def _session_processes(identity: ProcessIdentity) -> tuple[int, ...]:
    processes: list[int] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            if int(fields[3]) == identity.session or int(fields[2]) == identity.process_group:
                processes.append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (PermissionError, ValueError, IndexError) as error:
            try:
                status = (entry / "status").read_text()
            except (FileNotFoundError, PermissionError):
                continue
            if f"Uid:\t{os.getuid()}\t" in status:
                raise IdentityError(f"same-user process {entry.name} is opaque") from error
    return tuple(processes)


def delete_owned_root(root: Path, token: str) -> None:
    _owned_root(root, token)
    identity_path = root / "browser-identity.json"
    if not identity_path.is_file() or identity_path.is_symlink():
        if _blocked_without_launch(root):
            shutil.rmtree(root)
            return
        raise IdentityError("browser identity was never proven; retaining run directory")
    identity = _stored_identity(identity_path)
    if identity.profile != str(root / "profile") or identity.token != token:
        raise IdentityError("stored profile or token does not own this run root")
    if identity.boot_id != (root / ".boot_id").read_text().strip():
        raise IdentityError("stored browser boot identity does not match run root")
    try:
        authorize_signal(identity)
    except IdentityError as error:
        if (Path("/proc") / str(identity.pid)).exists():
            raise IdentityError("browser identity is opaque or still live") from error
    else:
        raise IdentityError("browser is still live")
    if _session_processes(identity):
        raise IdentityError("browser session or process group still has members")
    shutil.rmtree(root)


def _blocked_without_launch(root: Path) -> bool:
    path = root / "outcome.json"
    if not path.is_file() or path.is_symlink():
        return False
    try:
        outcome = load_json(path.read_text())
    except (OSError, ValueError):
        return False
    return isinstance(outcome, dict) and outcome.get("status") == "BLOCKED"


def main(arguments: Sequence[str] | None = None) -> int:
    values = tuple(sys.argv[1:] if arguments is None else arguments)
    if len(values) != 3 or values[0] != "delete":
        _ = sys.stderr.write("usage: remote_guard delete ROOT TOKEN\n")
        return 2
    root = Path(values[1])
    token = values[2]
    try:
        delete_owned_root(root, token)
    except (IdentityError, OSError) as error:
        print(f"cleanup refused: {error}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
