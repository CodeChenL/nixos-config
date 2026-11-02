from __future__ import annotations

import base64
import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

from ..probe import PROBE_LOADER, probe_target


def test_probe_loader_gives_probe_the_firefox_argument() -> None:
    # Given
    python3 = shutil.which("python3")
    assert python3 is not None
    payload = base64.b64encode(b"import sys;print(sys.argv[1])").decode()

    # When
    completed = subprocess.run(
        (python3, "-c", PROBE_LOADER, payload, "/opt/firefox/firefox"),
        check=False,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )

    # Then
    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == "/opt/firefox/firefox\n"


def test_probe_transports_fixed_source_without_ssh_stdin_or_multiline_arguments() -> None:
    # Given
    captured: tuple[str, ...] = ()

    def run(
        command: tuple[str, ...],
        *,
        check: bool,
        capture_output: bool,
        text: bool,
        stdin: int,
    ) -> subprocess.CompletedProcess[str]:
        _ = check, capture_output, text, stdin
        nonlocal captured
        captured = command
        return subprocess.CompletedProcess(command, 0, '{"schema_version":1}', "")

    # When
    with patch("subprocess.run", run):
        _ = probe_target("qa@example.test", Path("/opt/firefox/firefox"))

    # Then
    assert captured[:2] == ("ssh", "-n")
    assert all("\n" not in argument for argument in captured)
