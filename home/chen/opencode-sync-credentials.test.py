"""Run with Python and OPENCODE_TEST_BINARY pointing to the packaged V2 CLI."""

import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("opencode-sync-credentials.py")
spec = importlib.util.spec_from_file_location("sync", SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
BINARY = os.environ.get("OPENCODE_TEST_BINARY")


class VerificationTests(unittest.TestCase):
    def test_noop_create_cannot_claim_success(self):
        def request(method, path, payload=None):
            return {"data": []}
        with self.assertRaises(sync.SyncError):
            sync.synchronize(request, {"openai": "dummy-key"})

    def test_wrong_value_cannot_claim_success(self):
        entries = []
        def request(method, path, payload=None):
            if method == "POST":
                entries.append({**payload, "active": True, "value": {"type": "key", "key": "wrong"}})
            return {"data": entries}
        with self.assertRaises(sync.SyncError):
            sync.synchronize(request, {"openai": "dummy-key"})

    def test_failed_create_never_deletes_old_key(self):
        calls = []
        def request(method, path, payload=None):
            calls.append(method)
            if method == "POST":
                raise sync.SyncError("injected failure")
            return {"data": []}
        with self.assertRaises(sync.SyncError):
            sync.synchronize(request, {"openai": "dummy-key"})
        self.assertNotIn("DELETE", calls)

    def test_redirects_rejected(self):
        with self.assertRaises(sync.SyncError):
            sync.NoRedirect().redirect_request(None, None, 307, "redirect", {}, "http://example.invalid")


@unittest.skipUnless(BINARY, "set OPENCODE_TEST_BINARY for real V2 integration tests")
class V2IntegrationTests(unittest.TestCase):
    def test_migrate_rotate_late_secrets_and_failures(self):
        with tempfile.TemporaryDirectory(prefix="v2-credential-test-", dir="/tmp/opencode") as directory:
            root = Path(directory)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("OPENCODE_", "XDG_"))}
            env.update({"HOME": str(root), "TMPDIR": str(root)})
            for name in ("DATA", "CONFIG", "CACHE", "STATE"):
                env[f"XDG_{name}_HOME"] = str(root / name.lower())
            env["XDG_RUNTIME_DIR"] = str(root / "runtime")
            (root / "runtime").mkdir(mode=0o700)
            data = root / "data/opencode"
            data.mkdir(parents=True, mode=0o700)
            db = data / "opencode.db"
            secret_dir = root / "secrets"
            secret_dir.mkdir(mode=0o700)
            legacy = {
                "openai": {"type": "api", "key": "dummy-legacy-openai"},
                "anthropic": {"type": "oauth", "access": "dummy-oauth-access",
                              "refresh": "dummy-oauth-refresh", "expires": 9999999999999},
            }
            auth = data / "auth.json"
            auth.write_text(json.dumps(legacy))
            auth.chmod(0o600)
            outputs = []
            placeholders = ["dummy-legacy-openai", "dummy-oauth-access", "dummy-oauth-refresh"]

            def export():
                result = subprocess.run(
                    [BINARY, "auth", "export", "--standalone", "--log-level", "none"],
                    cwd=root, env=env, capture_output=True, text=True, timeout=90,
                )
                self.assertEqual(result.returncode, 0, "isolated auth export failed")
                return json.loads(result.stdout)

            def invoke(extra=None, expected=0):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--opencode", BINARY, "--secrets", str(secret_dir)],
                    cwd=root, env={**env, **(extra or {})}, capture_output=True, text=True, timeout=90,
                )
                outputs.append(result.stdout + result.stderr)
                self.assertEqual(result.returncode, expected, "synchronizer exit code")
                self.assertFalse(list(data.glob(".credential-sync-*")))
                return result

            def snapshot():
                with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as connection:
                    return connection.execute("SELECT * FROM credential ORDER BY id").fetchall()

            def migrations():
                with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as connection:
                    return connection.execute("SELECT * FROM migration ORDER BY id").fetchall()

            def assert_active(keys):
                # Independent official CLI read + read-only SQL, not helper's response.
                entries = export()
                with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as connection:
                    for provider, key in keys.items():
                        active = [item for item in entries if item["integrationID"] == provider and item["active"]]
                        self.assertEqual(len(active), 1)
                        self.assertEqual(active[0]["value"], {"type": "key", "key": key})
                        row = connection.execute(
                            "SELECT value, active FROM credential WHERE id = ?", (active[0]["id"],)
                        ).fetchone()
                        self.assertEqual(json.loads(row[0]), {"type": "key", "key": key})
                        self.assertEqual(row[1], 1)
                return entries

            initial = export()  # Actually completes upstream legacy migration.
            original_migrations = migrations()
            self.assertTrue(any(row[0] == "20260805200742_import_legacy_credentials" for row in original_migrations))
            original = snapshot()
            invoke()  # No secrets yet: warn, leave DB untouched.
            self.assertEqual(snapshot(), original)

            # Reproduce the old activation: auth.json changes after migration do nothing.
            legacy["openai"]["key"] = "dummy-auth-json-rotation"
            auth.write_text(json.dumps(legacy))
            self.assertEqual(export(), initial)

            keys = {provider: f'dummy-first-{provider}-"quoted"-\\escaped' for provider in sync.PROVIDERS}
            placeholders.extend(keys.values())
            for provider, key in keys.items():
                path = secret_dir / sync.PROVIDERS[provider]
                path.write_text(key + "\n")
                path.chmod(0o600)
            invoke({"OPENCODE_CONFIG_CONTENT": "invalid inherited configuration"})
            first = assert_active(keys)
            self.assertEqual(len(first), len(initial) + len(keys))
            unchanged = snapshot()
            invoke()
            self.assertEqual(snapshot(), unchanged)  # No new IDs or timestamp churn.

            keys = {provider: f"dummy-rotated-{provider}" for provider in sync.PROVIDERS}
            placeholders.extend(keys.values())
            for provider, key in keys.items():
                (secret_dir / sync.PROVIDERS[provider]).write_text(key + "\n")
            invoke()
            rotated = assert_active(keys)
            self.assertEqual(len(rotated), len(first))
            for item in initial:
                preserved = next(entry for entry in rotated if entry["id"] == item["id"])
                self.assertEqual(preserved["value"], item["value"])
            self.assertEqual(migrations(), original_migrations)

            # Missing one source must not prevent the other providers rotating.
            (secret_dir / "kimi.key").unlink()
            keys["openai"] = "dummy-partial-rotation"
            placeholders.append(keys["openai"])
            (secret_dir / "and.key").write_text(keys["openai"])
            missing = invoke()
            self.assertIn("kimi.key", missing.stderr)
            assert_active(keys)

            # Empty input fails before any writes, even with an earlier valid change.
            before_failure = snapshot()
            (secret_dir / "and.key").write_text("dummy-must-not-be-written")
            (secret_dir / "deepseek.key").write_text(" \n")
            invoke(expected=1)
            self.assertEqual(snapshot(), before_failure)
            (secret_dir / "deepseek.key").write_text(keys["deepseek"])
            invoke({"OPENCODE_DB": ":memory:"}, expected=1)
            self.assertEqual(snapshot(), before_failure)

            # No fallback to real HOME, shared service, or a different binary on failure.
            with patch.dict(os.environ, env, clear=True):
                with self.assertRaises(OSError):
                    with sync.private_api("/nonexistent/opencode", data):
                        pass
            self.assertFalse(list(data.glob(".credential-sync-*")))
            self.assertEqual(snapshot(), before_failure)
            self.assertEqual(data.stat().st_mode & 0o777, 0o700)
            for path in data.glob("opencode.db*"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(auth.read_text()), legacy)  # V1 file not rewritten.

            # Check public output and log files; only DB and explicit dummy input files may contain keys.
            logs = "".join(outputs)
            for path in data.glob("log/**/*"):
                if path.is_file():
                    logs += path.read_text(errors="replace")
            for key in placeholders:
                self.assertNotIn(key, logs)
            self.assertFalse((root / "state/opencode/service.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
