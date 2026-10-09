"""Synchronize HM secrets through OpenCode V2's public credential API, not SQL."""

import argparse
import base64
import contextlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import select
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid


PROVIDERS = {
    "openai": "and.key",
    "deepseek": "deepseek.key",
    "kimi-code-plan-cn": "kimi.key",
    "xiaomi-token-plan-cn": "xiaomi.key",
    "minimax-cn-coding-plan": "minimax.key",
}
PREFIX = "cred_home_manager_"


class SyncError(Exception):
    """Only fixed, secret-free diagnostics may escape the synchronizer."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise SyncError("拒绝凭据 API 重定向")


def read_keys(directory):
    keys = {}
    # Validate every available input before changing any credential.
    for provider, filename in PROVIDERS.items():
        path = directory / filename
        try:
            key = path.read_text().strip()
        except FileNotFoundError:
            print(f"opencode-auth: 缺少 {filename}，保留该供应商现有凭据", file=sys.stderr)
            continue
        except (OSError, UnicodeError):
            raise SyncError(f"无法读取 {filename}") from None
        if not key or any(ord(char) < 32 or ord(char) == 127 for char in key):
            raise SyncError(f"{filename} 为空或含控制字符，未进行同步")
        keys[provider] = key
    return keys


@contextlib.contextmanager
def private_api(opencode, data):
    # The same stdio ownership lease is used by upstream --standalone. No shared
    # service discovery, restarts, project plugins, or persistent service config.
    with tempfile.TemporaryDirectory(prefix=".credential-sync-", dir=data) as directory:
        env = {key: value for key, value in os.environ.items() if not key.startswith("OPENCODE_")}
        password = secrets.token_urlsafe(32)
        env.update({
            "OPENCODE_PASSWORD": password,
            "OPENCODE_CONFIG_DIR": directory,
            "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_FFF": "1",
        })
        proc = subprocess.Popen(
            [opencode, "serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0", "--log-level", "none"],
            cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            if not select.select([proc.stdout], [], [], 60)[0]:
                raise SyncError("临时 V2 服务启动超时")
            url = json.loads(proc.stdout.readline(4096))["url"]
            address = urllib.parse.urlsplit(url)
            if (address.scheme != "http" or address.hostname != "127.0.0.1"
                    or not address.port or address.username or address.password
                    or address.path not in ("", "/") or address.query or address.fragment):
                raise SyncError("临时 V2 服务返回了非本机地址")
            # Never send secrets through a proxy, redirect, argv, file, or log.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            authorization = "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode()

            def request(method, path, payload=None):
                body = None if payload is None else json.dumps(payload).encode()
                req = urllib.request.Request(url.rstrip("/") + path, data=body, method=method,
                                             headers={"Authorization": authorization, "Content-Type": "application/json"})
                try:
                    with opener.open(req, timeout=30) as response:
                        raw = response.read()
                    return json.loads(raw) if raw else None
                except Exception:
                    # Server errors / schema diagnostics can include submitted secrets.
                    raise SyncError("V2 凭据 API 请求失败（响应内容已隐藏）") from None

            yield request
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            proc.stdout.close()


def owned(entry, provider):
    return (entry["integrationID"] == provider
            and entry["id"].startswith(PREFIX + provider + "_")
            and entry["label"] == "Home Manager: " + provider)


def synchronize(request, keys):
    existing = request("GET", "/api/credential")["data"]
    selected = {}
    for provider, key in keys.items():
        value = {"type": "key", "key": key}
        same = next((entry for entry in existing if owned(entry, provider) and entry["value"] == value), None)
        if same is None:
            # Create + activate is one upstream transaction. Never delete the old
            # account first; an interrupted run can safely retry and prune later.
            credential_id = PREFIX + provider + "_" + uuid.uuid4().hex
            request("POST", "/api/credential", {
                "id": credential_id, "integrationID": provider,
                "label": "Home Manager: " + provider, "value": value, "activate": True,
            })
        else:
            credential_id = same["id"]
            if not same["active"]:
                request("POST", f"/api/credential/{credential_id}/activate")
        selected[provider] = credential_id

    def verify():
        entries = request("GET", "/api/credential")["data"]
        for provider, credential_id in selected.items():
            active = [entry for entry in entries if entry["integrationID"] == provider and entry["active"]]
            if (len(active) != 1 or active[0]["id"] != credential_id
                    or active[0]["value"] != {"type": "key", "key": keys[provider]}):
                raise SyncError(f"{provider} 活动凭据校验失败")
        return entries

    verified = verify()
    for entry in verified:
        provider = entry["integrationID"]
        if provider in selected and owned(entry, provider) and entry["id"] != selected[provider]:
            request("DELETE", "/api/credential/" + urllib.parse.quote(entry["id"], safe=""))
    remaining = verify()
    if any(sum(owned(entry, provider) for entry in remaining) != 1 for provider in selected):
        raise SyncError("旧托管凭据清理校验失败")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencode", required=True)
    parser.add_argument("--secrets", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if os.environ.get("OPENCODE_DB"):
        raise SyncError("不支持 OPENCODE_DB 覆盖；请使用默认本地数据库进行 HM 同步")
    keys = read_keys(args.secrets)
    if not keys:
        return
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "opencode"
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    data.chmod(0o700)
    # Serialize our own activations; leave upstream's DB concurrency to its API.
    with (data / ".home-manager-credentials.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SyncError("另一个凭据同步正在运行，请稍后重试") from None
        with private_api(args.opencode, data) as request:
            synchronize(request, keys)
    print("opencode-auth: V2 数据库同步并校验完成；请重启已运行的 V2 服务/TUI 以刷新缓存", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        detail = str(error) if isinstance(error, SyncError) else "同步失败（错误详情已隐藏，避免泄露凭据）"
        print("opencode-auth: " + detail, file=sys.stderr)
        sys.exit(1)
