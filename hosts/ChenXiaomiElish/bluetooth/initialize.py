import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Final


NODE: Final = "firmware/devicetree/base/soc@0/geniqup@9c0000/serial@998000/bluetooth"
CONFIG_RECORD: Final = re.compile(
    r"hci(\d+):\s+Unconfigured controller\n"
    + r"\s+manufacturer (\d+)\n"
    + r"\s+supported options:([^\n]*)\n"
    + r"\s+missing options:([^\n]*)(?:\n|$)"
)
INFO_RECORD: Final = re.compile(
    r"hci(\d+):\tPrimary controller\n"
    + r"\taddr ((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}) version \d+ manufacturer \d+ class 0x[0-9a-fA-F]{6}\n"
    + r"\tsupported settings:[^\n]*\n\tcurrent settings:[^\n]*\n"
    + r"\tname [^\n]*\n\tshort name [^\n]*\n"
)
INFO_OPTIONS: Final = re.compile(
    r"hci(\d+):\tConfiguration options\n"
    + r"\tsupported options:[^\n]*\n\tmissing options:[^\n]*\n"
)
SETTINGS: Final = (
    "powered|connectable|fast-connectable|discoverable|bondable|link-security|ssp|"
    + "br/edr|hs|le|advertising|secure-conn|debug-keys|privacy|configuration|static-addr|"
    + "phy-configuration|wide-band-speech|cis-central|cis-peripheral|iso-broadcaster|"
    + "sync-receiver|ll-privacy|past-sender|past-receiver"
)
NOTIFICATION: Final = re.compile(
    rf"hci\d+ (?:new_settings: (?:(?:{SETTINGS}) )*"
    + r"|class of device changed: 0x[0-9a-f]{6}|name changed: [^\x00-\x1f\x7f]*)\n"
)
TRANSITION: Final = re.compile(
    r"hci\d+ (?:(?:added|removed)(?: \(unconfigured\)| \(type \d+ bus \d+\))?"
    + r"|new_config_options: (?:(?:external|public-address) )*)\n"
)


class InitializationError(Exception):
    pass


def management(arguments: list[str]) -> tuple[str, bool]:
    result = subprocess.run(
        [os.environ.get("ELISH_BT_MGMT", "btmgmt"), *arguments],
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
        timeout=3, check=False, env=os.environ | {"LC_ALL": "C", "TERM": "dumb"},
    )
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    if result.returncode or result.stderr or re.search(
        r"(?im)^(?:Reading .* failed|.* failed with status|Unable to |Too (?:small|short) |Invalid |Index count |Unknown command)",
        output,
    ):
        raise InitializationError(f"btmgmt {arguments[0]} failed: {output.strip()} {result.stderr.strip()}")
    lines = output.splitlines(keepends=True)
    changed = any(TRANSITION.fullmatch(line) is not None for line in lines)
    return "".join(
        line for line in lines
        if NOTIFICATION.fullmatch(line) is None and TRANSITION.fullmatch(line) is None
    ), changed


def snapshot(command: str) -> list[re.Match[str]]:
    for _attempt in range(3):
        output, changed = management([command])
        prefix = "Unconfigured index" if command == "config" else "Index"
        header = re.match(rf"{prefix} list with (\d+) items?\n", output)
        if header is None:
            raise InitializationError(f"Malformed btmgmt {command} header")
        body = output[header.end():]
        pattern = CONFIG_RECORD if command == "config" else INFO_RECORD
        records = list(pattern.finditer(body))
        remainder = pattern.sub("", body)
        if command == "info":
            options = list(INFO_OPTIONS.finditer(remainder))
            option_indices = [int(record[1]) for record in options]
            if len(set(option_indices)) != len(option_indices) or not set(option_indices) <= {int(record[1]) for record in records}:
                raise InitializationError("Unexpected btmgmt info configuration options")
            remainder = INFO_OPTIONS.sub("", remainder)
        if len(records) != int(header[1]) or remainder:
            raise InitializationError(f"Incomplete or malformed btmgmt {command} records")
        indices = [int(record[1]) for record in records]
        if len(set(indices)) != len(indices):
            raise InitializationError(f"Duplicate btmgmt {command} indices")
        if not changed:
            return records
    raise InitializationError("Controller management snapshot kept changing after 3 reads")


def configuration(index: int) -> tuple[set[str], set[str]] | None:
    for record in snapshot("config"):
        if int(record[1]) == index:
            if int(record[2]) != 29:
                raise InitializationError("Unexpected controller manufacturer")
            return set(record[3].split()), set(record[4].split())
    return None


def configured_address(index: int) -> str | None:
    for record in snapshot("info"):
        if int(record[1]) == index:
            address = record[2]
            if address == "00:00:00:00:00:00":
                raise InitializationError("Configured controller has a zero address")
            return address.upper()
    return None


def matches_device(device: Path, sysfs: Path) -> bool:
    node = sysfs / NODE
    return (
        (device / "of_node").resolve() == node
        and (device / "driver").resolve() == sysfs / "bus/serial/drivers/hci_uart_qca"
        and b"qcom,qca6390-bt" in (node / "compatible").read_bytes().split(b"\0")
    )


def initialize(controller: str) -> None:
    if re.fullmatch(r"hci(?:0|[1-9][0-9]*)", controller) is None or int(controller[3:]) >= 65535:
        raise InitializationError("Expected an HCI controller instance, for example hci0")
    sysfs = Path(os.environ.get("ELISH_BT_SYSFS", "/sys")).resolve()
    device = sysfs / "class/bluetooth" / controller / "device"
    if not matches_device(device, sysfs):
        print(f"{controller}: skipped, not the built-in Elish QCA6390")
        return
    identity = device.resolve()
    index = int(controller[3:])
    wait_seconds = float(os.environ.get("ELISH_BT_WAIT_SECONDS", "20"))
    if not 0 < wait_seconds <= 20:
        raise InitializationError("Readiness timeout must be between 0 and 20 seconds")
    deadline = time.monotonic() + wait_seconds
    while True:
        options = configuration(index)
        if options is not None:
            supported, missing = options
            if "public-address" not in missing:
                print(f"{controller}: skipped, public address is not missing")
                return
            if "public-address" not in supported or missing != {"public-address"}:
                raise InitializationError("Public address alone cannot configure this controller")
            break
        if configured_address(index) is not None:
            print(f"{controller}: skipped, already configured")
            return
        if time.monotonic() >= deadline:
            raise InitializationError("Controller management readiness timed out")
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))

    machine_id = Path(os.environ.get("ELISH_BT_MACHINE_ID", "/etc/machine-id")).read_bytes()
    if re.fullmatch(rb"[0-9a-f]{32}\n?", machine_id) is None or machine_id.rstrip(b"\n") == b"0" * 32:
        raise InitializationError("Missing or invalid machine-id")
    digest = hashlib.sha256(machine_id.rstrip(b"\n") + b" bluetooth\n").hexdigest()
    address = "42:" + ":".join(digest[offset:offset + 2] for offset in (0, 4, 8, 12, 16)).upper()
    if device.resolve() != identity or not matches_device(device, sysfs):
        raise InitializationError("Controller identity changed before address initialization")
    output, _changed = management(["--index", str(index), "public-addr", address])
    if re.fullmatch(rf"hci{index} Set Public Address complete, options: *\n", output) is None:
        raise InitializationError(f"Public address command did not acknowledge complete configuration: {output!r}")
    deadline = time.monotonic() + wait_seconds
    while True:
        options = configuration(index)
        actual_address = configured_address(index)
        if options is None and actual_address == address:
            print(f"{controller}: configured public address {address}")
            return
        if actual_address is not None and actual_address != address:
            raise InitializationError("Controller address verification mismatch")
        if time.monotonic() >= deadline:
            raise InitializationError("Controller configuration verification timed out")
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))


def main() -> int:
    if sys.argv[1:] == ["--help"]:
        print("Usage: elish-bluetooth-address hciN\nInitialize only the built-in QCA6390 missing public address.")
        return 0
    if len(sys.argv) != 2:
        print("Usage: elish-bluetooth-address hciN", file=sys.stderr)
        return 2
    try:
        initialize(sys.argv[1])
    except (InitializationError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"elish-bluetooth-address: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
