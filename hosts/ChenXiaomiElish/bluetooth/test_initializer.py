import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import final, override
import unittest


SCRIPT = Path(__file__).with_name("initialize.py")
NODE = "firmware/devicetree/base/soc@0/geniqup@9c0000/serial@998000/bluetooth"
MACHINE_ID = "0123456789abcdef0123456789abcdef"
MOCK = r'''
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["MOCK_ROOT"])
args = sys.argv[1:]
with (root / "calls").open("a") as calls:
    calls.write(" ".join(args) + "\n")
assert "--timeout" not in args
command = args
scenario = os.environ.get("SCENARIO", "missing")
written = (root / "address").exists()
if scenario == "hang":
    time.sleep(20)
if scenario == "exit-failure":
    print("Unable to open mgmt_socket")
    sys.exit(1)
if scenario == "error-zero":
    print("Reading hci7 config failed with status 0x03 (Failed)")
    sys.exit(0)
if command == ["config"]:
    counter = root / "count"
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    if scenario == "malformed":
        print("Unconfigured index list with 1 item")
    elif scenario == "other-only":
        print("Unconfigured index list with 1 item\nhci8:\tUnconfigured controller")
        print("\tmanufacturer 29\n\tsupported options: public-address \n\tmissing options: public-address ")
    elif (written and scenario != "verify-unconfigured") or scenario in ("configured", "absent", "info-error-zero") or (scenario == "delayed" and count < 2):
        print("Unconfigured index list with 0 items")
    else:
        missing = "external-config" if scenario == "no-missing" else "public-address"
        supported = "external-config" if scenario == "unsupported" else "public-address"
        if scenario == "extra-missing":
            missing += " external-config"
        print("Unconfigured index list with 1 item\nhci7:\tUnconfigured controller")
        print("\tmanufacturer 29\n\tsupported options: " + supported + " \n\tmissing options: " + missing + " ")
elif command == ["info"]:
    if scenario == "info-error-zero":
        print("Index list with 1 item\nReading hci7 info failed with status 0x11 (Invalid Index)")
        sys.exit(0)
    if (written and scenario not in ("verify-unconfigured", "verify-absent")) or scenario == "configured":
        address = (root / "address").read_text() if written else "10:20:30:40:50:60"
        if scenario == "verify-wrong-address":
            address = "10:20:30:40:50:60"
        print("Index list with 1 item\nhci7:\tPrimary controller")
        print("\taddr " + address + " version 11 manufacturer 29 class 0x000000")
        print("\tsupported settings: powered \n\tcurrent settings: \n\tname test\n\tshort name ")
    else:
        print("Index list with 0 items")
elif len(command) == 4 and command[:3] == ["--index", "7", "public-addr"]:
    if scenario in ("write-error-zero", "write-exit-failure"):
        print("Set Public Address for hci7 failed with status 0x03 (Failed)")
        sys.exit(1 if scenario == "write-exit-failure" else 0)
    (root / "address").write_text(command[3])
    print("hci7 Set Public Address complete, options: ")
else:
    raise AssertionError(command)
'''


@final
class InitializerTests(unittest.TestCase):
    temp: tempfile.TemporaryDirectory[str]
    root: Path
    sysfs: Path
    device: Path
    machine_id: Path
    env: dict[str, str]

    @override
    def __init__(self, methodName: str = "runTest") -> None:
        super().__init__(methodName)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sysfs = self.root / "sys"
        node = self.sysfs / NODE
        node.mkdir(parents=True)
        _ = (node / "compatible").write_bytes(b"qcom,qca6390-bt\0")
        self.device = self.sysfs / "class/bluetooth/hci7/device"
        self.device.mkdir(parents=True)
        (self.device / "of_node").symlink_to(node)
        driver = self.sysfs / "bus/serial/drivers/hci_uart_qca"
        driver.mkdir(parents=True)
        (self.device / "driver").symlink_to(driver)
        self.machine_id = self.root / "machine-id"
        _ = self.machine_id.write_text(MACHINE_ID + "\n")
        mock = self.root / "btmgmt"
        _ = mock.write_text(f"#!{sys.executable}\n" + MOCK)
        mock.chmod(0o700)
        self.env = os.environ | {
            "ELISH_BT_SYSFS": str(self.sysfs),
            "ELISH_BT_MACHINE_ID": str(self.machine_id),
            "ELISH_BT_MGMT": str(mock),
            "ELISH_BT_WAIT_SECONDS": "0.1",
            "MOCK_ROOT": str(self.root),
        }

    def run_initializer(self, scenario: str = "missing") -> subprocess.CompletedProcess[str]:
        executable = os.environ.get("ELISH_BT_TEST_EXECUTABLE")
        command = [executable] if executable else [sys.executable, str(SCRIPT)]
        result = subprocess.run(
            [*command, "hci7"],
            env=self.env | {"SCENARIO": scenario},
            capture_output=True, text=True, timeout=8, check=False,
        )
        self.assertNotIn(MACHINE_ID, result.stdout + result.stderr)
        return result

    def test_missing_address_is_written_and_verified(self) -> None:
        result = self.run_initializer()
        self.assertEqual(result.returncode, 0, result.stderr)
        address = (self.root / "address").read_text()
        self.assertRegex(address, r"^42(:[0-9A-F]{2}){5}$")
        self.assertIn(address, result.stdout)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual(sum("public-addr" in call for call in calls), 1)
        self.assertEqual(calls[-2:], ["config", "info"])

    def test_address_is_stable_and_machine_specific(self) -> None:
        self.assertEqual(self.run_initializer().returncode, 0)
        address = (self.root / "address").read_text()
        (self.root / "address").unlink()
        self.assertEqual(self.run_initializer().returncode, 0)
        self.assertEqual((self.root / "address").read_text(), address)
        (self.root / "address").unlink()
        _ = self.machine_id.write_text("fedcba9876543210fedcba9876543210\n")
        self.assertEqual(self.run_initializer().returncode, 0)
        self.assertNotEqual((self.root / "address").read_text(), address)

    def test_configured_and_no_missing_address_are_preserved(self) -> None:
        self.machine_id.unlink()
        for scenario in ("configured", "no-missing"):
            with self.subTest(scenario=scenario):
                result = self.run_initializer(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.root / "address").exists())

    def test_wrong_driver_node_or_compatible_never_calls_management(self) -> None:
        for identity in ("driver", "of_node", "compatible"):
            with self.subTest(identity=identity):
                path = self.device / identity
                if identity == "compatible":
                    path = self.sysfs / NODE / identity
                    _ = path.write_bytes(b"qcom,qca6490-bt\0")
                else:
                    path.unlink()
                    path.symlink_to(self.sysfs)
                result = self.run_initializer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.root / "calls").exists())
                if identity == "compatible":
                    _ = path.write_bytes(b"qcom,qca6390-bt\0")
                else:
                    path.unlink()
                    target = self.sysfs / (NODE if identity == "of_node" else "bus/serial/drivers/hci_uart_qca")
                    path.symlink_to(target)

    def test_missing_and_invalid_machine_id_never_write(self) -> None:
        for value in (None, "", "uninitialized\n", "0" * 32, "g" * 32, MACHINE_ID + "\nextra"):
            with self.subTest(value=value):
                if self.machine_id.exists():
                    self.machine_id.unlink()
                if value is not None:
                    _ = self.machine_id.write_text(value)
                result = self.run_initializer()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "address").exists())

    def test_failures_malformed_and_incomplete_config_never_write(self) -> None:
        for scenario in ("exit-failure", "error-zero", "info-error-zero", "malformed", "unsupported", "extra-missing", "absent", "other-only"):
            with self.subTest(scenario=scenario):
                result = self.run_initializer(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "address").exists())

    def test_write_errors_including_exit_zero_are_rejected(self) -> None:
        for scenario in ("write-error-zero", "write-exit-failure"):
            with self.subTest(scenario=scenario):
                self.assertNotEqual(self.run_initializer(scenario).returncode, 0)

    def test_failed_verification_is_not_success(self) -> None:
        for scenario in ("verify-unconfigured", "verify-absent", "verify-wrong-address"):
            with self.subTest(scenario=scenario):
                if (self.root / "address").exists():
                    (self.root / "address").unlink()
                self.assertNotEqual(self.run_initializer(scenario).returncode, 0)

    def test_management_registration_can_lag_sysfs(self) -> None:
        self.env["ELISH_BT_WAIT_SECONDS"] = "2"
        result = self.run_initializer("delayed")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hung_command_is_bounded(self) -> None:
        result = self.run_initializer("hang")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr)
        self.assertFalse((self.root / "address").exists())

    def test_readiness_attempts_are_bounded(self) -> None:
        result = self.run_initializer("absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("readiness timed out", result.stderr)
        self.assertLessEqual(int((self.root / "count").read_text()), 3)

    def test_second_run_preserves_initialized_controller(self) -> None:
        self.assertEqual(self.run_initializer().returncode, 0)
        result = self.run_initializer()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual(sum("public-addr" in call for call in calls), 1)


if __name__ == "__main__":
    _ = unittest.main(verbosity=2)
