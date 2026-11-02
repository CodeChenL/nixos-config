from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .local_runner import RunConfiguration, RunError, run_scenario
from .manifest import ManifestError
from .transport import TransportError

ALLOWED_ENVIRONMENT = {
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "DBUS_SESSION_BUS_ADDRESS",
    "MOZ_ENABLE_WAYLAND",
}


def main() -> int:
    if len(sys.argv) < 6:
        print(
            "usage: run-scenario.sh MANIFEST SCENARIO TARGET FIREFOX OUTPUT [KEY=VALUE ...]",
            file=sys.stderr,
        )
        return 2
    environment = tuple(sys.argv[6:])
    if any(
        "=" not in item or item.split("=", 1)[0] not in ALLOWED_ENVIRONMENT for item in environment
    ):
        print("invalid remote environment entry", file=sys.stderr)
        return 2
    configuration = RunConfiguration(
        manifest=Path(sys.argv[1]),
        scenario_id=sys.argv[2],
        target=sys.argv[3],
        firefox=Path(sys.argv[4]),
        output=Path(sys.argv[5]),
        timeout=60.0,
        remote_environment=environment,
    )
    try:
        return run_scenario(configuration)
    except (ManifestError, RunError, TransportError, OSError, subprocess.SubprocessError) as error:
        print(f"scenario failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
