from __future__ import annotations

import json
import secrets
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final

from .json_value import load_json
from .manifest import parse_and_verify_manifest
from .models import AxisStatus, Manifest, Scenario
from .page_result import parse_page_result_bytes
from .timeline import analyze_timeline
from .transport import (
    EVIDENCE_ALLOWLIST,
    TRANSFER_FILES,
    build_scp_command,
    build_ssh_command,
    validate_remote_identity,
)
from .verdict import evaluate_verdict

BLOCKED_EXIT_CODE: Final = 3


@dataclass(frozen=True, slots=True)
class RunConfiguration:
    manifest: Path
    scenario_id: str
    target: str
    firefox: Path
    output: Path
    timeout: float
    remote_environment: tuple[str, ...]


class RunError(Exception):
    pass


def _run(command: tuple[str, ...], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command, check=check, capture_output=True, text=True, stdin=subprocess.DEVNULL
    )


def _scenario(manifest: Manifest, scenario_id: str) -> Scenario:
    for scenario in manifest.scenarios:
        if scenario.id == scenario_id:
            return scenario
    raise RunError(f"scenario not found: {scenario_id}")


def _create_remote_root(target: str, token: str) -> str:
    script = (
        "set -eu; umask 077; root=$(mktemp -d /tmp/firefox-video-qa.XXXXXXXXXXXX); "
        'mkdir "$root/firefox_qa"; printf \'%s\\n\' "$1" >"$root/.owner"; '
        'cat /proc/sys/kernel/random/boot_id >"$root/.boot_id"; printf \'%s\\n\' "$root"'
    )
    completed = _run(build_ssh_command(target, ["sh", "-c", script, "firefox-qa-create", token]))
    root = completed.stdout.strip()
    validate_remote_identity(target, root, token)
    return root


def _extract_evidence(archive_path: Path, output: Path) -> None:
    allowed = set(EVIDENCE_ALLOWLIST)
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        if any(member.name not in allowed or not member.isfile() for member in members):
            raise RunError("evidence archive contains a non-allowlisted member")
        output.mkdir(parents=True, exist_ok=True)
        for member in members:
            source = archive.extractfile(member)
            if source is None:
                raise RunError("evidence archive member is unreadable")
            _ = (output / member.name).write_bytes(source.read())


def _analyze(output: Path, scenario: Scenario, remote_deleted: bool) -> AxisStatus:
    cleanup_path = output / "cleanup.json"
    cleanup_value = load_json(cleanup_path.read_text())
    if not isinstance(cleanup_value, dict):
        raise RunError("cleanup result must be an object")
    cleanup_raw = dict(cleanup_value)
    cleanup_raw["remote_directory_deleted"] = remote_deleted
    _ = cleanup_path.write_text(json.dumps(cleanup_raw, sort_keys=True, indent=2) + "\n")
    with tarfile.open(output / "decoder-logs.tar") as archive:
        logs: list[str] = []
        for member in archive.getmembers():
            source = archive.extractfile(member) if member.isfile() else None
            if source is not None:
                logs.append(source.read().decode(errors="replace"))
        decoder_log = "\n".join(logs)
    observation = (output / "observe-during.jsonl").read_text()
    timeline = analyze_timeline(scenario, decoder_log, observation)
    _ = (output / "timeline.json").write_text(
        json.dumps(timeline.to_json(), sort_keys=True, indent=2) + "\n"
    )
    page = parse_page_result_bytes((output / "result.json").read_bytes())
    cleanup_complete = (
        remote_deleted
        and cleanup_raw.get("browser_exited") is True
        and cleanup_raw.get("observer_complete") is True
        and cleanup_raw.get("after_snapshot_complete") is True
        and cleanup_raw.get("after_processes_empty") is True
    )
    verdict = evaluate_verdict(scenario, page, timeline, cleanup_complete)
    _ = (output / "verdict.json").write_text(
        json.dumps(verdict.to_json(), sort_keys=True, indent=2) + "\n"
    )
    return verdict.overall.status


def run_scenario(configuration: RunConfiguration) -> int:
    manifest = parse_and_verify_manifest(configuration.manifest)
    scenario = _scenario(manifest, configuration.scenario_id)
    token = secrets.token_hex(16)
    root = _create_remote_root(configuration.target, token)
    skill = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="firefox-video-qa-") as temporary_name:
        temporary = Path(temporary_name)
        remote_scenario = replace(scenario, media_path=Path(root) / "media")
        payload = {"schema_version": 1, "scenarios": [remote_scenario.to_json()]}
        scenario_path = temporary / "scenario.json"
        _ = scenario_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
        package_sources = tuple(str(skill / "firefox_qa" / name) for name in TRANSFER_FILES)
        _ = _run(
            build_scp_command(
                configuration.target, package_sources, f"{configuration.target}:{root}/firefox_qa/"
            )
        )
        transfers = (
            (skill / "assets/video-qa.html", "video-qa.html"),
            (skill / "assets/telemetry.js", "telemetry.js"),
            (scenario.media_path, "media"),
            (scenario_path, "scenario.json"),
        )
        for source, destination in transfers:
            _ = _run(
                build_scp_command(
                    configuration.target,
                    (str(source),),
                    f"{configuration.target}:{root}/{destination}",
                )
            )
        remote_command = [
            "env",
            *configuration.remote_environment,
            f"PYTHONPATH={root}",
            "python3",
            "-m",
            "firefox_qa.remote_runner",
            "--root",
            root,
            "--token",
            token,
            "--firefox",
            str(configuration.firefox),
            "--timeout",
            str(configuration.timeout),
        ]
        run_result = _run(build_ssh_command(configuration.target, remote_command), check=False)
        archive_path = temporary / "evidence.tar"
        copy_result = _run(
            build_scp_command(
                configuration.target,
                (f"{configuration.target}:{root}/evidence.tar",),
                str(archive_path),
            ),
            check=False,
        )
        delete_result = _run(
            build_ssh_command(
                configuration.target,
                [
                    "env",
                    f"PYTHONPATH={root}",
                    "python3",
                    "-m",
                    "firefox_qa.remote_guard",
                    "delete",
                    root,
                    token,
                ],
            ),
            check=False,
        )
        configuration.output.mkdir(parents=True, exist_ok=True)
        _ = (configuration.output / "transport.json").write_text(
            json.dumps(
                {
                    "remote_root": root,
                    "run_exit_code": run_result.returncode,
                    "evidence_copy_exit_code": copy_result.returncode,
                    "delete_exit_code": delete_result.returncode,
                    "remote_directory_retained": delete_result.returncode != 0,
                    "run_stderr": run_result.stderr[-4096:],
                    "evidence_copy_stderr": copy_result.stderr[-4096:],
                    "delete_stderr": delete_result.stderr[-4096:],
                },
                sort_keys=True,
                indent=2,
            )
            + "\n"
        )
        if archive_path.is_file():
            try:
                _extract_evidence(archive_path, configuration.output)
            except (RunError, OSError, tarfile.TarError):
                if run_result.returncode != BLOCKED_EXIT_CODE:
                    return 1
        if run_result.returncode == BLOCKED_EXIT_CODE:
            return BLOCKED_EXIT_CODE
        if copy_result.returncode != 0 or not archive_path.is_file():
            return 1
        try:
            overall = _analyze(configuration.output, scenario, delete_result.returncode == 0)
        except (OSError, KeyError, ValueError, tarfile.TarError):
            return 1
        complete = (
            run_result.returncode == 0
            and delete_result.returncode == 0
            and overall is AxisStatus.PASS
        )
        return 0 if complete else 1
