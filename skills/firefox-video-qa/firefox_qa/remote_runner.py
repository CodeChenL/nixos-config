from __future__ import annotations

import json
import os
import platform
import re
import signal
import subprocess
import sys
import threading
import urllib.parse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from .evidence import build_decoder_archive, build_evidence_archive
from .identity import (
    IdentityError,
    ProcessIdentity,
    signal_owned_group,
    wait_capture_identity,
    write_identity,
)
from .manifest import parse_and_verify_manifest
from .models import JsonValue, TraceProfile
from .observation import append_snapshot, snapshot
from .result_server import ResultServer

VIDEO_DEVICE: Final = re.compile(r"/dev/video[0-9]+")


@dataclass(frozen=True, slots=True)
class TraceSettings:
    monitor_interval: float
    log_level: str


def trace_settings(profile: TraceProfile) -> TraceSettings:
    if profile is TraceProfile.PERFORMANCE:
        return TraceSettings(
            monitor_interval=1.0,
            log_level="MediaDecoder:4,PlatformDecoderModule:4,FFmpegVideo:4,Dmabuf:4",
        )
    return TraceSettings(
        monitor_interval=0.1,
        log_level="PlatformDecoderModule:5,MediaDecoder:5,FFmpegVideo:5,FFmpegLib:5,Dmabuf:5",
    )


def evaluate_preflight(records: Sequence[Mapping[str, JsonValue]]) -> dict[str, JsonValue] | None:
    owners: list[JsonValue] = []
    incomplete = False
    for record in records:
        if record.get("complete") is not True:
            incomplete = True
        if record.get("role") != "external":
            continue
        devices = record.get("devices")
        if not isinstance(devices, list):
            continue
        for device in devices:
            if isinstance(device, str) and VIDEO_DEVICE.fullmatch(device) is not None:
                pid = record.get("pid")
                owner: dict[str, JsonValue] = {
                    "pid": pid if isinstance(pid, int) else -1,
                    "device": device,
                }
                owners.append(owner)
    if owners:
        blocked: dict[str, JsonValue] = {
            "status": "BLOCKED",
            "reason": "visible external video decoder owner",
            "owners": owners,
        }
        return blocked
    if incomplete:
        opaque: dict[str, JsonValue] = {
            "status": "BLOCKED",
            "reason": "before snapshot could not prove the device is free",
            "owners": [],
        }
        return opaque
    return None


def _atomic_json(path: Path, value: dict[str, JsonValue]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    _ = temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.chmod(0o600)
    _ = temporary.replace(path)


def _monitor(
    path: Path,
    identity: ProcessIdentity,
    stopped: threading.Event,
    failed: threading.Event,
    interval: float,
) -> None:
    while not stopped.wait(interval):
        try:
            append_snapshot(path, snapshot("during", identity))
        except (IdentityError, OSError):
            failed.set()
            return


def _runtime(firefox: Path) -> dict[str, JsonValue]:
    version = subprocess.run(
        (str(firefox), "--version"), capture_output=True, text=True, check=False
    )
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "firefox": str(firefox),
        "firefox_version": (version.stdout or version.stderr).strip(),
        "trace_profiles": [TraceProfile.EVIDENCE.value, TraceProfile.PERFORMANCE.value],
        "observer": "rootless",
    }


def run(root: Path, token: str, firefox: Path, timeout: float) -> int:
    manifest = parse_and_verify_manifest(root / "scenario.json")
    if len(manifest.scenarios) != 1:
        raise IdentityError("remote scenario manifest must contain one scenario")
    scenario = manifest.scenarios[0]
    settings = trace_settings(scenario.trace_profile)
    profile = root / "profile"
    profile.mkdir(mode=0o700)
    before = snapshot("before", None)
    append_snapshot(root / "observe-before.jsonl", before)
    blocked = evaluate_preflight(before)
    if blocked is not None:
        _atomic_json(root / "outcome.json", blocked)
        _ = build_evidence_archive(root, root / "evidence.tar")
        return 3
    _atomic_json(root / "runtime.json", _runtime(firefox))
    environment = dict(os.environ)
    environment.update(
        {
            "MOZ_LOG": settings.log_level,
            "MOZ_LOG_FILE": str(root / "decoder.log"),
            "MOZ_CRASHREPORTER_DISABLE": "1",
        }
    )
    cleanup: dict[str, JsonValue] = {
        "identity_revalidated_before_term": False,
        "identity_revalidated_before_kill": None,
        "browser_exited": False,
        "observer_complete": True,
    }
    result_path = root / "result.json"
    url = (
        f"http://127.0.0.1:{{port}}/video-qa.html?id={scenario.id}&mode={scenario.mode.value}"
        f"&run={token}&seekTarget={scenario.seek_target or 0}&timeoutMs={int(timeout * 1000)}"
        f"&mime={urllib.parse.quote(scenario.mime, safe='')}"
        f"&profile={scenario.trace_profile.value}"
    )
    identity: ProcessIdentity | None = None
    monitor: threading.Thread | None = None
    monitor_failed = threading.Event()
    received = False
    with ResultServer(root, result_path, token, scenario.id, scenario.mode.value) as server:
        command = (
            str(firefox),
            "--no-remote",
            "--new-instance",
            "--profile",
            str(profile),
            url.format(port=server.port),
        )
        with (
            (root / "firefox.stdout").open("wb") as stdout,
            (root / "firefox.stderr").open("wb") as stderr,
        ):
            browser = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                env=environment,
                start_new_session=True,
            )
            try:
                identity = wait_capture_identity(browser.pid, profile, token, Path(firefox).name)
            except IdentityError:
                cleanup["observer_complete"] = False
                _atomic_json(root / "cleanup.json", cleanup)
                _ = build_decoder_archive(root, root / "decoder-logs.tar")
                _ = build_evidence_archive(root, root / "evidence.tar")
                return 1
            write_identity(root / "browser-identity.json", identity)
            stopped = threading.Event()
            monitor = threading.Thread(
                target=_monitor,
                args=(
                    root / "observe-during.jsonl",
                    identity,
                    stopped,
                    monitor_failed,
                    settings.monitor_interval,
                ),
                daemon=True,
            )
            monitor.start()
            received = server.wait_result(timeout)
            if browser.poll() is None:
                try:
                    signal_owned_group(identity, signal.SIGTERM)
                    cleanup["identity_revalidated_before_term"] = True
                    _ = browser.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    signal_owned_group(identity, signal.SIGKILL)
                    cleanup["identity_revalidated_before_kill"] = True
                    _ = browser.wait(timeout=5)
                except IdentityError:
                    cleanup["observer_complete"] = False
            stopped.set()
            monitor.join(timeout=2)
            cleanup["browser_exited"] = browser.poll() is not None
    owned_after = snapshot("after", identity)
    external_after = snapshot("after", None)
    append_snapshot(root / "observe-after.jsonl", owned_after + external_after)
    cleanup["after_snapshot_complete"] = all(
        record.get("complete") is True for record in owned_after
    )
    cleanup["after_processes_empty"] = all("pid" not in record for record in owned_after)
    cleanup["observer_complete"] = (
        bool(cleanup["observer_complete"])
        and not monitor.is_alive()
        and not monitor_failed.is_set()
    )
    _atomic_json(root / "cleanup.json", cleanup)
    _ = build_decoder_archive(root, root / "decoder-logs.tar")
    _ = build_evidence_archive(root, root / "evidence.tar")
    return 0 if received and bool(cleanup["browser_exited"]) else 1


def main(arguments: Sequence[str] | None = None) -> int:
    values = tuple(sys.argv[1:] if arguments is None else arguments)
    if len(values) != 8 or values[0::2] != ("--root", "--token", "--firefox", "--timeout"):
        _ = sys.stderr.write(
            "usage: remote_runner --root ROOT --token TOKEN --firefox FIREFOX --timeout SECONDS\n"
        )
        return 2
    try:
        timeout = float(values[7])
    except ValueError:
        _ = sys.stderr.write("timeout must be numeric\n")
        return 2
    return run(Path(values[1]), values[3], Path(values[5]), timeout)


if __name__ == "__main__":
    raise SystemExit(main())
