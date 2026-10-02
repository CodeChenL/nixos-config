"""Boundary security probe: verify root setup does not follow attacker-controlled symlinks.

Runs inside the NixOS VM as root. Creates root-owned sentinel files,
plants hostile symlinks as kiro-rs, runs setup, and verifies sentinels
remain untouched.  Also tests FIFO / directory substitution and prior-config
preservation on validation failure.
"""

import json
import os
import pwd
import shutil
import stat
import subprocess
from pathlib import Path

state = Path("/var/lib/kiro-rs")
source = Path("/home/chen/nixos-config/secrets/kiro-rs")
admin_source = source.parent / "sub2api/admin-password"
barrier = Path("/run/kiro-setup-fixture")
unit = "kiro-rs-setup.service"
owner = pwd.getpwnam("kiro-rs")
cases: list[dict[str, object]] = []
failures: list[str] = []

os.umask(0o077)
source.mkdir(parents=True, exist_ok=True)
admin_source.parent.mkdir(parents=True, exist_ok=True)


def systemctl(*args: str) -> str:
    return subprocess.run(
        ["systemctl", *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def write_secret(path: Path, value: str) -> None:
    path.write_text(value)
    path.chmod(0o600)


def make_sentinel(name: str) -> Path:
    """Create a root-owned 0600 sentinel outside the state directory."""
    path = state.parent / f"kiro-sentinel-{name}"
    path.write_text(f"SYNTHETIC_SENTINEL_{name.upper()}")
    path.chmod(0o600)
    return path


def sentinel_state(path: Path) -> dict[str, object]:
    st = path.stat()
    return {
        "bytes": path.stat().st_size,
        "content": path.read_text(),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "mode": stat.S_IMODE(st.st_mode),
    }


def plant_link_as_kiro(target: str, link_path: Path) -> None:
    """Create a symlink as kiro-rs user."""
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()
    subprocess.run(
        ["runuser", "-u", "kiro-rs", "--", "ln", "-s", str(target), str(link_path)],
        check=True,
    )


def prepare_state(clean: bool = True) -> None:
    systemctl("stop", unit)
    systemctl("reset-failed")
    if clean:
        for entry in state.iterdir():
            if entry.is_symlink() or entry.is_file():
                entry.unlink()
            elif entry.is_dir():
                shutil.rmtree(entry)
    write_secret(source / "credentials.json", '[{"refreshToken":"SYNTHETIC_BOUNDARY_SEED"}]\n')
    write_secret(source / "api-key", "SYNTHETIC_BOUNDARY_API\n")
    write_secret(admin_source, "SYNTHETIC_BOUNDARY_ADMIN\n")


def run_setup_checked(label: str) -> tuple[subprocess.CompletedProcess[str], str]:
    try:
        result = subprocess.run(
            ["systemctl", "start", unit],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        subprocess.run(["systemctl", "stop", unit], capture_output=True, timeout=10)
        result = subprocess.CompletedProcess(
            ["systemctl", "start", unit], 124, "", "timeout"
        )
    service_result = systemctl("show", "-p", "Result", "--value", unit)
    return result, service_result


def record(label: str, passed: bool, detail: dict[str, object]) -> None:
    case = {"case": label, "passed": passed, **detail}
    cases.append(case)
    status = "PASS" if passed else "FAIL"
    print(f"KIRO_BOUNDARY_{status} {json.dumps(case)}", flush=True)
    if not passed:
        failures.append(label)


def check_sentinel_unchanged(label: str, sentinel: Path, before: dict[str, object]) -> bool:
    after = sentinel_state(sentinel)
    unchanged = after == before
    record(
        label,
        unchanged,
        {"sentinelBefore": before, "sentinelAfter": after},
    )
    return unchanged


# ---- Test 1: api-key symlink to sentinel ----
def test_api_key_symlink() -> None:
    prepare_state()
    sentinel = make_sentinel("api-key")
    before = sentinel_state(sentinel)
    # Verify kiro-rs cannot read sentinel
    can_read = subprocess.run(
        ["runuser", "-u", "kiro-rs", "--", "cat", str(sentinel)],
        capture_output=True,
    ).returncode == 0
    if can_read:
        record("api-key-symlink/attacker-cannot-read-sentinel", False, {"reason": "kiro-rs can read sentinel"})
        return
    plant_link_as_kiro(str(sentinel), state / "api-key")
    result, service_result = run_setup_checked("api-key symlink")
    check_sentinel_unchanged("api-key-symlink/sentinel-unchanged", sentinel, before)
    # Config should not contain sentinel content
    config_path = state / "config.json"
    config_has_sentinel = False
    if config_path.exists() and not config_path.is_symlink():
        config_has_sentinel = before["content"] in config_path.read_text()
    record(
        "api-key-symlink/secret-not-leaked-into-config",
        not config_has_sentinel,
        {"configExists": config_path.exists(), "hasSentinelContent": config_has_sentinel},
    )


# ---- Test 2: credentials.json symlink to sentinel ----
def test_credentials_symlink() -> None:
    prepare_state()
    sentinel = make_sentinel("credentials")
    before = sentinel_state(sentinel)
    plant_link_as_kiro(str(sentinel), state / "credentials.json")
    result, service_result = run_setup_checked("credentials symlink")
    check_sentinel_unchanged("credentials-symlink/sentinel-unchanged", sentinel, before)


# ---- Test 3: legacy config.json.tmp symlink to sentinel (old fixed temp) ----
def test_legacy_tmp_symlink_sentinel() -> None:
    prepare_state()
    sentinel = make_sentinel("legacy-tmp")
    before = sentinel_state(sentinel)
    # Also set up valid api-key so setup gets past early checks
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    plant_link_as_kiro(str(sentinel), state / "config.json.tmp")
    # Use invalid admin to trigger validation failure after tmp creation
    write_secret(admin_source, "\n")
    result, service_result = run_setup_checked("legacy tmp symlink to sentinel")
    check_sentinel_unchanged("legacy-tmp-symlink/sentinel-unchanged", sentinel, before)


# ---- Test 4: legacy config.json.tmp symlink to prior config ----
def test_legacy_tmp_symlink_config() -> None:
    prepare_state()
    # First create a valid config
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    result1, _ = run_setup_checked("initial valid config")
    config_path = state / "config.json"
    if config_path.exists() and not config_path.is_symlink():
        config_before = config_path.read_bytes()
    else:
        config_before = None
    # Now plant config.json.tmp -> config.json, with invalid admin
    if config_path.exists():
        plant_link_as_kiro(str(config_path), state / "config.json.tmp")
    write_secret(admin_source, "\n")
    result, service_result = run_setup_checked("legacy tmp symlink to config")
    config_preserved = False
    if config_before is not None and config_path.exists() and not config_path.is_symlink():
        config_preserved = config_path.read_bytes() == config_before
    record(
        "legacy-tmp-symlink/prior-config-preserved-on-invalid",
        config_preserved,
        {"configPreserved": config_preserved},
    )


# ---- Test 5: config.json symlink to sentinel ----
def test_config_symlink() -> None:
    prepare_state()
    sentinel = make_sentinel("config")
    before = sentinel_state(sentinel)
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    plant_link_as_kiro(str(sentinel), state / "config.json")
    result, service_result = run_setup_checked("config symlink")
    check_sentinel_unchanged("config-symlink/sentinel-unchanged", sentinel, before)


# ---- Test 6: FIFO instead of api-key ----
def test_fifo_api_key() -> None:
    prepare_state()
    api_path = state / "api-key"
    if api_path.is_symlink() or api_path.exists():
        api_path.unlink()
    os.mkfifo(api_path, 0o600)
    subprocess.run(["chown", "kiro-rs:kiro-rs", str(api_path)], check=True)
    # Run setup with timeout - should not hang forever
    try:
        result, service_result = run_setup_checked("FIFO api-key")
        fifo_rejected = result.returncode != 0
    except subprocess.TimeoutExpired:
        fifo_rejected = False
    record(
        "fifo-api-key/setup-does-not-hang",
        fifo_rejected,
        {"rejected": fifo_rejected},
    )
    # Cleanup FIFO
    api_path.unlink(missing_ok=True)


# ---- Test 7: directory instead of credentials.json ----
def test_directory_credentials() -> None:
    prepare_state()
    cred_path = state / "credentials.json"
    if cred_path.is_symlink() or cred_path.exists():
        cred_path.unlink()
    cred_path.mkdir(mode=0o700)
    subprocess.run(["chown", "kiro-rs:kiro-rs", str(cred_path)], check=True)
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    result, service_result = run_setup_checked("directory credentials")
    dir_rejected = result.returncode != 0 or service_result == "exit-code"
    record(
        "directory-credentials/setup-rejects-nonregular",
        dir_rejected,
        {"rejected": dir_rejected},
    )
    cred_path.rmdir()


# ---- Test 8: normal operation after clearing hostile entries ----
def test_recovery_after_hostile() -> None:
    prepare_state()
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    result, service_result = run_setup_checked("recovery")
    success = result.returncode == 0 and service_result == "success"
    config_ok = False
    config_path = state / "config.json"
    if config_path.exists() and not config_path.is_symlink():
        try:
            cfg = json.loads(config_path.read_text())
            config_ok = cfg.get("apiKey") == "SYNTHETIC_VALID_API"
        except (json.JSONDecodeError, OSError):
            pass
    record(
        "recovery/normal-operation-restored",
        success and config_ok,
        {"success": success, "configValid": config_ok},
    )


# ---- Test 9: legacy root-owned regular file repair ----
def test_legacy_root_ownership_repair() -> None:
    prepare_state()
    write_secret(state / "api-key", "SYNTHETIC_VALID_API\n")
    write_secret(state / "credentials.json", '[{"refreshToken":"SYNTHETIC_LEGACY"}]\n')
    subprocess.run(["chown", "root:root", str(state / "api-key")], check=True)
    subprocess.run(["chown", "root:root", str(state / "credentials.json")], check=True)
    result, service_result = run_setup_checked("legacy root ownership")
    success = result.returncode == 0 and service_result == "success"
    api_repaired = False
    cred_repaired = False
    api_path = state / "api-key"
    cred_path = state / "credentials.json"
    if api_path.exists() and not api_path.is_symlink():
        st = api_path.stat()
        api_repaired = st.st_uid == owner.pw_uid and stat.S_IMODE(st.st_mode) == 0o600
    if cred_path.exists() and not cred_path.is_symlink():
        st = cred_path.stat()
        cred_repaired = st.st_uid == owner.pw_uid and stat.S_IMODE(st.st_mode) == 0o600
    api_preserved = api_path.read_text() == "SYNTHETIC_VALID_API\n" if api_path.exists() else False
    record(
        "legacy-root-ownership/repair-and-preserve",
        success and api_repaired and cred_repaired and api_preserved,
        {
            "success": success,
            "apiRepaired": api_repaired,
            "credRepaired": cred_repaired,
            "apiBytesPreserved": api_preserved,
        },
    )


def main() -> None:
    test_api_key_symlink()
    test_credentials_symlink()
    test_legacy_tmp_symlink_sentinel()
    test_legacy_tmp_symlink_config()
    test_config_symlink()
    test_fifo_api_key()
    test_directory_credentials()
    test_legacy_root_ownership_repair()
    test_recovery_after_hostile()

    Path("/run/kiro-setup-fixture/boundary-observations.json").write_text(
        json.dumps(cases, indent=2) + "\n"
    )
    if failures:
        print(f"KIRO_BOUNDARY_RED: {len(failures)} failures: {failures}", flush=True)
        raise SystemExit(1)
    print(f"KIRO_BOUNDARY_GREEN: {len(cases)} boundary cases passed", flush=True)


if __name__ == "__main__":
    main()
