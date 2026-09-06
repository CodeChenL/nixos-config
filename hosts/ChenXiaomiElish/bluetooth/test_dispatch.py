from fnmatch import fnmatchcase
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


MODULE = Path(os.environ.get(
    "ELISH_BT_TEST_MODULE", str(Path(__file__).parent.parent / "bluetooth.nix")
)).read_text()


class DispatchTests(unittest.TestCase):
    def test_udev_dispatch_uses_host_property_not_connection_name(self) -> None:
        rule = MODULE.split("services.udev.extraRules = ''", 1)[1].split("'';", 1)[0].strip()
        clauses = rule.split(", ")
        for name, devtype, driver, action, expected in (
            ("hci0", "host", "hci_uart_qca", "add", ["elish-bluetooth-address@hci0.service"]),
            ("hci12", "host", "hci_uart_qca", "add", ["elish-bluetooth-address@hci12.service"]),
            ("hci0:1", "link", "hci_uart_qca", "add", []),
            ("hci0", "link", "hci_uart_qca", "add", []),
            ("hci0", "", "hci_uart_qca", "add", []),
            ("hci0", "host", "btusb", "add", []),
            ("hci0", "host", "hci_uart_qca", "remove", []),
        ):
            with self.subTest(name=name, devtype=devtype, driver=driver, action=action):
                properties = {
                    "ACTION": action, "SUBSYSTEM": "bluetooth", "KERNEL": name,
                    "DRIVERS": driver, "ENV{DEVTYPE}": devtype,
                }
                wants: list[str] = []
                for clause in clauses:
                    match = re.fullmatch(r'([^=+]+)(==|\+=)"([^"]*)"', clause)
                    self.assertIsNotNone(match, clause)
                    if match is None:
                        self.fail(clause)
                    key, operator, value = match.groups()
                    if operator == "==" and not fnmatchcase(properties[key], value):
                        break
                    if operator == "+=" and key == "ENV{SYSTEMD_WANTS}":
                        wants.append(value.replace("%k", name))
                self.assertEqual(wants, expected)

    def test_bootstrap_dispatches_only_exact_controller_names(self) -> None:
        script = MODULE.split("    script = ''", 1)[1].split("    '';", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("hci0", "hci12", "hci0:1", "hci12:42", "hci", "hci7extra", "hci00"):
                (root / name).mkdir()
            script = script.replace("/sys/class/bluetooth", str(root))
            script = script.replace("${pkgs.systemd}/bin/systemctl", "record_start")
            script = script.replace("''${", "${")
            result = subprocess.run(
                ["bash", "-eu", "-c", 'record_start() { printf "%s\\n" "$*"; }\n' + script],
                capture_output=True, text=True, timeout=3, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "--no-block start elish-bluetooth-address@hci0.service",
                "--no-block start elish-bluetooth-address@hci12.service",
            ])


if __name__ == "__main__":
    _ = unittest.main(verbosity=2)
