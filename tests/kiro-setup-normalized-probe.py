from collections.abc import Callable
import glob
import json
from pathlib import Path
import shutil
import subprocess

type SetupResult = tuple[subprocess.CompletedProcess[str], str, str]
type ExecuteSetup = Callable[[str], SetupResult]
type SuccessfulSetup = Callable[[str, str, str | None], None]
type WriteSecret = Callable[[Path, str], None]


def check_normalized_keys(
    execute_setup: ExecuteSetup, run_setup: SuccessfulSetup, write: WriteSecret
) -> None:
    state = Path("/var/lib/kiro-rs")
    source = Path("/home/chen/nixos-config/secrets/kiro-rs/api-key")
    runtime = state / "api-key"
    config = state / "config.json"
    admin_source = source.parent.parent / "sub2api/admin-password"
    failures: list[str] = []
    cases: list[dict[str, str | int | bool]] = []
    seed = 'SYNTHETIC_NORMALIZED_SEED_"quote"\\path\r\n;$(touch /run/kiro-shell-injection)\n'
    active = 'SYNTHETIC_NORMALIZED_RUNTIME_"different"\\path\r\n&;$(touch /run/kiro-shell-injection)\n'
    admin = 'SYNTHETIC_NORMALIZED_ADMIN_"third"\\path\r\n|;$(touch /run/kiro-shell-injection)\n'

    for line_name, newline in (("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r")):
        for selected, invalid_admin in (
            (source, False), (runtime, False), (None, True), (source, True), (runtime, True)
        ):
            for existing in (False, True):
                label = f"{line_name} {('seed' if selected == source else 'runtime') if selected else 'admin'}"
                label += " + admin" if selected and invalid_admin else ""
                label += " rollback" if existing else " first setup"
                shutil.rmtree(state)
                state.mkdir(mode=0o700)
                write(source, seed)
                write(admin_source, admin)
                if existing:
                    write(runtime, active)
                    run_setup("valid baseline for " + label, "[]\n", active)
                before = config.read_bytes() if existing else None
                if selected == source:
                    runtime.unlink(missing_ok=True)
                if selected:
                    write(selected, newline)
                if invalid_admin:
                    write(admin_source, newline)
                expected_api = newline if selected else (active if existing else seed)

                result, api_key, admin_key = execute_setup(label)

                preserved = config.read_bytes() == before if existing else not config.exists()
                raw_preserved = runtime.read_bytes() == expected_api.encode()
                clean = not (state / "config.json.tmp").exists() and not glob.glob(str(state / ".config.*"))
                service_result = subprocess.run(
                    ["systemctl", "show", "-p", "Result", "--value", "kiro-rs-setup.service"],
                    check=True, capture_output=True, text=True,
                ).stdout.strip()
                observation = {
                    "case": label, "exitCode": result.returncode,
                    "configPreserved": preserved, "selectedApiFilePreserved": raw_preserved,
                    "temporaryClean": clean, "normalizedApiEmpty": not bool(api_key),
                    "normalizedAdminEmpty": not bool(admin_key),
                }
                cases.append(observation)
                print("KIRO_SETUP_NORMALIZED " + json.dumps(observation), flush=True)
                if not (result.returncode != 0 and service_result == "exit-code"
                        and preserved and raw_preserved and clean):
                    failures.append(label)
                journal = subprocess.run(
                    ["journalctl", "-u", "kiro-rs-setup.service", "--no-pager"],
                    check=True, capture_output=True, text=True,
                ).stdout
                for value in (seed, active, admin):
                    assert value.replace("\r", "").replace("\n", "") not in journal

                write(source, seed)
                write(runtime, active)
                write(admin_source, admin)
                run_setup("recovery after " + label, "[]\n", active)

        write(source, newline)
        write(runtime, active)
        write(admin_source, admin)
        run_setup("valid runtime ignores " + line_name + " seed", "[]\n", active)

    write(source, "")
    runtime.unlink()
    run_setup("zero-byte seed generates API key", "[]\n", None)
    generated = runtime.read_text()
    run_setup("zero-byte seed preserves generated API key", "[]\n", generated)
    runtime.unlink()
    source.unlink()
    run_setup("missing runtime and seed generate API key", "[]\n", None)
    generated = runtime.read_text()
    run_setup("missing seed preserves generated API key", "[]\n", generated)
    _ = Path("/run/kiro-setup-fixture/normalized-observations.json").write_text(
        json.dumps(cases, indent=2) + "\n"
    )
    assert not failures, "normalized mandatory keys did not fail closed: " + ", ".join(failures)
    print("KIRO_SETUP_NORMALIZED_GREEN: 30 rejections, 30 recoveries, 3 precedence and 4 generation checks", flush=True)
