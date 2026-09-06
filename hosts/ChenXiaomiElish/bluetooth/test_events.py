import os
import subprocess
import unittest
from unittest.mock import patch

from . import initialize, test_initializer


CONFIG = (
    "Unconfigured index list with 1 item\nhci7:\tUnconfigured controller\n"
    + "\tmanufacturer 29\n\tsupported options: public-address \n"
    + "\tmissing options: public-address \n"
)
INFO = (
    "Index list with 1 item\nhci7:\tPrimary controller\n"
    + "\taddr 42:10:20:30:40:50 version 11 manufacturer 29 class 0x000000\n"
    + "\tsupported settings: powered configuration \n\tcurrent settings: powered \n"
    + "\tname Elish\n\tshort name \nhci7:\tConfiguration options\n"
    + "\tsupported options: public-address \n\tmissing options: \n"
)
EVENTS = (
    "hci0 new_settings: powered ",
    "hci7 new_settings: powered connectable bondable ssp br/edr le secure-conn ",
    "hci8 class of device changed: 0x6c010c",
    "hci7 name changed: ChenXiaomiElish",
)
TRANSITIONS = (
    "hci7 added", "hci8 removed", "hci7 added (unconfigured)",
    "hci7 removed (unconfigured)", "hci8 added (type 0 bus 1)",
    "hci8 removed (type 0 bus 1)", "hci7 new_config_options: ",
    "hci8 new_config_options: external public-address ",
)


def response(output: str) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(["mock-btmgmt"], 0, output, "")


class EventTests(unittest.TestCase):
    def test_management_waits_for_command_completion_with_external_timeout(self) -> None:
        with patch.object(subprocess, "run", return_value=response(CONFIG)) as run:
            self.assertEqual(initialize.configuration(7), ({"public-address"}, {"public-address"}))
            run.assert_called_once_with(
                [os.environ.get("ELISH_BT_MGMT", "btmgmt"), "config"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=3, check=False,
                env=os.environ | {"LC_ALL": "C", "TERM": "dumb"},
            )

    def test_empty_config_accepts_reviewers_settings_event(self) -> None:
        with patch.object(subprocess, "run", return_value=response(
            "Unconfigured index list with 0 items\nhci0 new_settings: powered \n"
        )):
            self.assertIsNone(initialize.configuration(0))

    def test_legal_events_before_between_and_after_records(self) -> None:
        for output in (CONFIG, INFO):
            for event in EVENTS:
                for position in range(len(output.splitlines()) + 1):
                    with self.subTest(event=event, position=position, info=output == INFO):
                        lines = output.splitlines(keepends=True)
                        lines.insert(position, event + "\n")
                        with patch.object(subprocess, "run", return_value=response("".join(lines))):
                            if output == CONFIG:
                                self.assertEqual(initialize.configuration(7), ({"public-address"}, {"public-address"}))
                            else:
                                self.assertEqual(initialize.configured_address(7), "42:10:20:30:40:50")

    def test_unknown_malformed_and_error_lines_are_not_hidden(self) -> None:
        for extra in ("unknown line", "hci7 new_settings: bogus ",
                      "hci7 added (unknown)", "hci7 class of device changed: rubbish",
                      "Reading hci7 config failed with status 0x03 (Failed)",
                      "hci7 error 0x03"):
            for output in (CONFIG, INFO):
                with self.subTest(extra=extra, info=output == INFO):
                    with patch.object(subprocess, "run", return_value=response(
                        EVENTS[0] + "\n" + output + extra + "\n"
                    )):
                        with self.assertRaises(initialize.InitializationError):
                            if output == CONFIG:
                                _ = initialize.configuration(7)
                            else:
                                _ = initialize.configured_address(7)

    def test_cli_accepts_events_and_verifies_once_without_rewriting(self) -> None:
        fixture = test_initializer.InitializerTests()
        try:
            mock = fixture.root / "btmgmt"
            original = mock.read_text()
            injection = (
                "import builtins\noriginal_print = print\n"
                + "def event_print(*args):\n"
                + "    original_print('hci8 new_settings: powered ')\n"
                + "    original_print(*args)\n"
                + "    original_print('hci7 class of device changed: 0x000000')\n"
                + "builtins.print = event_print\n"
                + "if 'public-addr' in sys.argv:\n"
                + "    original_print('hci7 removed (unconfigured)')\n"
                + "    original_print('hci7 new_config_options: ')\n"
                + "    original_print('hci7 added')\n"
            )
            _ = mock.write_text(original.replace("root = Path(", injection + "root = Path(", 1))
            result = fixture.run_initializer()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((fixture.root / "calls").read_text().count("public-addr"), 1)
        finally:
            _ = fixture.doCleanups()

    def test_transitions_force_fresh_read_only_snapshots(self) -> None:
        for transition in TRANSITIONS:
            for output in (CONFIG, INFO):
                with self.subTest(transition=transition, info=output == INFO):
                    with patch.object(subprocess, "run", side_effect=[
                        response(output + transition + "\n"), response(output),
                    ]) as run:
                        if output == CONFIG:
                            self.assertEqual(initialize.configuration(7), ({"public-address"}, {"public-address"}))
                        else:
                            self.assertEqual(initialize.configured_address(7), "42:10:20:30:40:50")
                        self.assertEqual(run.call_count, 2)
                        self.assertNotIn("public-addr", str(run.call_args_list))

    def test_persistent_transitions_are_bounded_and_errors_do_not_retry(self) -> None:
        with patch.object(subprocess, "run", return_value=response(CONFIG + "hci7 added\n")) as run:
            with self.assertRaises(initialize.InitializationError):
                _ = initialize.configuration(7)
            self.assertEqual(run.call_count, 3)
        for extra in ("unknown\n", "Reading hci7 config failed with status 0x03 (Failed)\n"):
            with patch.object(subprocess, "run", return_value=response(CONFIG + "hci7 added\n" + extra)) as run:
                with self.assertRaises(initialize.InitializationError):
                    _ = initialize.configuration(7)
                self.assertEqual(run.call_count, 1)

    def test_mixed_controller_records_keep_counts_and_complete_bodies(self) -> None:
        for output in (CONFIG, INFO):
            header, body = output.split("\n", 1)
            mixed = header.replace("1 item", "2 items") + "\n" + body + EVENTS[0] + "\n" + body.replace("hci7:", "hci8:")
            with patch.object(subprocess, "run", return_value=response(mixed)):
                if output == CONFIG:
                    self.assertEqual(initialize.configuration(7), ({"public-address"}, {"public-address"}))
                else:
                    self.assertEqual(initialize.configured_address(7), "42:10:20:30:40:50")
            for broken in (mixed.replace("2 items", "3 items"), mixed + "unexpected\n", mixed.replace("hci8:", "hci7:")):
                with patch.object(subprocess, "run", return_value=response(broken)):
                    with self.assertRaises(initialize.InitializationError):
                        _ = initialize.snapshot("config" if output == CONFIG else "info")

    def test_public_address_ack_does_not_hide_unknown_lines_or_errors(self) -> None:
        for extra in ("unknown line", "Set Public Address for hci7 failed with status 0x03 (Failed)"):
            fixture = test_initializer.InitializerTests()
            try:
                mock = fixture.root / "btmgmt"
                _ = mock.write_text(mock.read_text() + "\nif 'public-addr' in sys.argv:\n    print(" + repr(extra) + ")\n")
                result = fixture.run_initializer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(extra, result.stderr)
                self.assertEqual((fixture.root / "calls").read_text().count("public-addr"), 1)
            finally:
                _ = fixture.doCleanups()

    def test_changed_config_is_reread_before_any_write(self) -> None:
        fixture = test_initializer.InitializerTests()
        try:
            mock = fixture.root / "btmgmt"
            original = mock.read_text().replace('scenario = os.environ.get("SCENARIO", "missing")', 'scenario = "configured" if (root / "count").exists() else "missing"')
            _ = mock.write_text(original + '\nif command == ["config"] and count == 0:\n    print("hci7 added")\n')
            result = fixture.run_initializer()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("public-addr", (fixture.root / "calls").read_text())
        finally:
            _ = fixture.doCleanups()


if __name__ == "__main__":
    _ = unittest.main(verbosity=2)
