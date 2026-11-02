from __future__ import annotations

import re
import tarfile
from pathlib import Path

from .transport import EVIDENCE_ALLOWLIST

DECODER_LOG = re.compile(r"decoder\.log(?:\.child-[0-9]+)?\.moz_log")


def build_decoder_archive(root: Path, destination: Path) -> tuple[str, ...]:
    logs = tuple(
        sorted(
            entry.name
            for entry in root.iterdir()
            if entry.is_file() and not entry.is_symlink() and DECODER_LOG.fullmatch(entry.name)
        )
    )
    with tarfile.open(destination, "w") as archive:
        for name in logs:
            archive.add(root / name, arcname=name, recursive=False)
    return logs


def build_evidence_archive(root: Path, destination: Path) -> tuple[str, ...]:
    members = tuple(
        name
        for name in EVIDENCE_ALLOWLIST
        if name != destination.name and (root / name).is_file() and not (root / name).is_symlink()
    )
    with tarfile.open(destination, "w") as archive:
        for name in members:
            archive.add(root / name, arcname=name, recursive=False)
    return members
