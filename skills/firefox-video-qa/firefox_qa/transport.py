from __future__ import annotations

import re
import shlex
from pathlib import Path
from typing import Final

TARGET: Final = re.compile(r"(?:[A-Za-z0-9_.%+-]+@)?[A-Za-z0-9_.:-]+")
REMOTE_ROOT: Final = re.compile(r"/tmp/firefox-video-qa\.[A-Za-z0-9]{12}")
RUN_TOKEN: Final = re.compile(r"[a-f0-9]{32}")
EVIDENCE_ALLOWLIST: Final = (
    "scenario.json",
    "runtime.json",
    "outcome.json",
    "result.json",
    "firefox.stdout",
    "firefox.stderr",
    "decoder-logs.tar",
    "observe-before.jsonl",
    "observe-during.jsonl",
    "observe-after.jsonl",
    "cleanup.json",
)
TRANSFER_FILES: Final = (
    "__init__.py",
    "evidence.py",
    "identity.py",
    "json_value.py",
    "manifest.py",
    "models.py",
    "observation.py",
    "page_result.py",
    "remote_guard.py",
    "remote_runner.py",
    "result_server.py",
    "timeline.py",
    "transport.py",
    "verdict.py",
)


class TransportError(Exception):
    pass


def validate_remote_identity(target: str, root: str, token: str) -> None:
    if TARGET.fullmatch(target) is None or target.startswith("-"):
        raise TransportError("invalid SSH target")
    if REMOTE_ROOT.fullmatch(root) is None:
        raise TransportError("invalid remote root")
    if RUN_TOKEN.fullmatch(token) is None:
        raise TransportError("invalid run token")


def build_ssh_command(target: str, remote_arguments: list[str]) -> tuple[str, ...]:
    if TARGET.fullmatch(target) is None or target.startswith("-"):
        raise TransportError("invalid SSH target")
    if not remote_arguments or any(
        "\x00" in argument or "\n" in argument for argument in remote_arguments
    ):
        raise TransportError("invalid remote command")
    return (
        "ssh",
        "-n",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        "--",
        target,
        shlex.join(remote_arguments),
    )


def evidence_paths(root: str) -> tuple[str, ...]:
    if REMOTE_ROOT.fullmatch(root) is None:
        raise TransportError("invalid remote root")
    return tuple(str(Path(root) / member) for member in EVIDENCE_ALLOWLIST)


def build_scp_command(target: str, sources: tuple[str, ...], destination: str) -> tuple[str, ...]:
    if TARGET.fullmatch(target) is None or target.startswith("-") or not sources:
        raise TransportError("invalid SCP request")
    if any("\x00" in value or "\n" in value for value in (*sources, destination)):
        raise TransportError("invalid SCP path")
    return (
        "scp",
        "-q",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        "--",
        *sources,
        destination,
    )
