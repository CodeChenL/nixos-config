from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from .json_value import load_json
from .local_runner import BLOCKED_EXIT_CODE, RunConfiguration, RunError, run_scenario
from .manifest import ManifestError, parse_and_verify_manifest
from .probe import ProbeError, probe_target
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
    if len(sys.argv) < 5:
        print(
            "usage: run-matrix.sh MANIFEST TARGET FIREFOX OUTPUT [KEY=VALUE ...]", file=sys.stderr
        )
        return 2
    manifest_path = Path(sys.argv[1])
    target = sys.argv[2]
    firefox = Path(sys.argv[3])
    output = Path(sys.argv[4])
    environment = tuple(sys.argv[5:])
    if any(
        "=" not in item or item.split("=", 1)[0] not in ALLOWED_ENVIRONMENT for item in environment
    ):
        print("invalid remote environment entry", file=sys.stderr)
        return 2
    try:
        manifest = parse_and_verify_manifest(manifest_path)
        probe = probe_target(target, firefox)
    except (
        ManifestError,
        ProbeError,
        RunError,
        TransportError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"matrix preflight failed: {error}", file=sys.stderr)
        return 1
    output.mkdir(parents=True, exist_ok=True)
    _ = (output / "probe.json").write_text(json.dumps(probe, sort_keys=True, indent=2) + "\n")
    summary: list[dict[str, str | int]] = []
    failed = False
    for scenario in manifest.scenarios:
        scenario_output = output / scenario.id
        return_code = run_scenario(
            RunConfiguration(
                manifest=manifest_path,
                scenario_id=scenario.id,
                target=target,
                firefox=firefox,
                output=scenario_output,
                timeout=60.0,
                remote_environment=environment,
            )
        )
        status = {0: "PASS", BLOCKED_EXIT_CODE: "BLOCKED"}.get(return_code, "FAIL")
        verdict = scenario_output / "verdict.json"
        if verdict.is_file():
            raw = load_json(verdict.read_text())
            overall = raw.get("overall") if isinstance(raw, dict) else None
            verdict_status = overall.get("status") if isinstance(overall, dict) else None
            if isinstance(verdict_status, str):
                status = verdict_status
        summary.append({"id": scenario.id, "status": status, "exit_code": return_code})
        failed = failed or return_code != 0
    _ = (output / "summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    print(json.dumps(summary, sort_keys=True, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
