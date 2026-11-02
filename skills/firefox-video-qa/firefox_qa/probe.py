from __future__ import annotations

import base64
import subprocess
from pathlib import Path
from typing import Final

from .json_value import load_json
from .models import JsonValue
from .transport import build_ssh_command

PROBE_LOADER: Final = (
    "import base64,sys;source=base64.b64decode(sys.argv[1]);del sys.argv[1];"
    "exec(compile(source,'<probe>','exec'))"
)

REMOTE_PROBE = r"""
import glob, json, os, platform, subprocess, sys
firefox = sys.argv[1]
def run(command):
    result = subprocess.run(command, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
devices = []
for path in sorted(glob.glob("/sys/class/video4linux/video*")):
    try:
        devices.append({"node": "/dev/" + os.path.basename(path), "name": open(path + "/name").read().strip()})
    except OSError:
        devices.append({"node": "/dev/" + os.path.basename(path), "name": None})
tools = {name: bool(run(["sh", "-c", "command -v -- " + name]).get("stdout")) for name in ("ffprobe", "vainfo", "v4l2-ctl", "gst-inspect-1.0", "readelf")}
data = {
    "schema_version": 1,
    "os": platform.platform(),
    "machine": platform.machine(),
    "kernel": platform.release(),
    "firefox_path": firefox,
    "firefox_version": run([firefox, "--version"]),
    "firefox_build_id": run(["readelf", "-n", firefox]) if tools["readelf"] else None,
    "video_devices": devices,
    "tools": tools,
    "vainfo": run(["vainfo"]) if tools["vainfo"] else None,
    "v4l2": {device["node"]: run(["v4l2-ctl", "-d", device["node"], "--all", "--list-formats-out-ext", "--list-formats-ext"]) for device in devices} if tools["v4l2-ctl"] else None,
}
print(json.dumps(data, sort_keys=True))
"""


class ProbeError(Exception):
    pass


def probe_target(target: str, firefox: Path) -> dict[str, JsonValue]:
    encoded_probe = base64.b64encode(REMOTE_PROBE.encode()).decode()
    command = build_ssh_command(
        target,
        ["python3", "-c", PROBE_LOADER, encoded_probe, str(firefox)],
    )
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip()[-1024:] or "no remote stderr"
        raise ProbeError(f"remote probe failed ({completed.returncode}): {detail}")
    raw = load_json(completed.stdout)
    if not isinstance(raw, dict) or raw.get("schema_version") != 1:
        raise ProbeError("target probe returned an invalid schema")
    return dict(raw)
