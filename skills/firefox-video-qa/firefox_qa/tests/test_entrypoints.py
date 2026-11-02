from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from ..transport import TRANSFER_FILES


def test_shell_entrypoint_runs_from_unrelated_working_directory(tmp_path: Path) -> None:
    # Given
    skill = Path(__file__).resolve().parents[2]

    # When
    completed = subprocess.run(
        (str(skill / "scripts/run-scenario.sh"),),
        cwd=tmp_path,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert completed.returncode == 2
    assert completed.stderr.startswith("usage: run-scenario.sh")


def test_remote_transfer_package_imports_in_isolated_directory(tmp_path: Path) -> None:
    # Given
    source = Path(__file__).resolve().parents[1]
    package = tmp_path / "firefox_qa"
    package.mkdir()
    for name in TRANSFER_FILES:
        _ = shutil.copyfile(source / name, package / name)
    environment = {"PATH": os.environ["PATH"], "PYTHONPATH": str(tmp_path)}

    # When
    completed = subprocess.run(
        (sys.executable, "-m", "firefox_qa.remote_guard"),
        cwd=tmp_path,
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert completed.returncode == 2
    assert completed.stderr == "usage: remote_guard delete ROOT TOKEN\n"
