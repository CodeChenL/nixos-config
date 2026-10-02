{ pkgs }:

let
  inherit (pkgs) lib;
  fixture = pkgs.writeShellScriptBin "kiro-rs" ''
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
  guardedJq = pkgs.writeShellScriptBin "jq" ''
    set -euo pipefail
    barrier=/run/kiro-setup-fixture
    if [ -e "$barrier/armed" ]; then
      printf '%s\n' "$PPID" > "$barrier/parent-pid"
      printf '%s\n' "$$" > "$barrier/pid.tmp"
      ${pkgs.coreutils}/bin/mv "$barrier/pid.tmp" "$barrier/pid"
      IFS= read -r release < "$barrier/release"
    fi
    exec ${pkgs.jq}/bin/jq "$@"
  '';
  probe = pkgs.writeText "kiro-setup-probe.py" ''
    import sys
    sys.path.insert(0, "/etc")
    from kiro_setup_normalized_probe import check_normalized_keys
    import glob
    import json
    import os
    from pathlib import Path
    import pwd
    import re
    import shutil
    import stat
    import subprocess
    import time

    state = Path("/var/lib/kiro-rs")
    source = Path("/home/chen/nixos-config/secrets/kiro-rs")
    admin_source = source.parent / "sub2api/admin-password"
    barrier = Path("/run/kiro-setup-fixture")
    unit = "kiro-rs-setup.service"
    observations = []
    violations = []
    owner = pwd.getpwnam("kiro-rs")
    os.umask(0o077)
    source.mkdir(parents=True)
    admin_source.parent.mkdir(parents=True)
    barrier.mkdir(mode=0o700)
    os.chown(barrier, owner.pw_uid, owner.pw_gid)

    def systemctl(*arguments):
        return subprocess.run(["systemctl", *arguments], check=True,
                              capture_output=True, text=True).stdout.strip()

    def normalize(value):
        return value.replace("\r", "").replace("\n", "")

    def secret(label):
        return 'SYNTHETIC_KIRO_' + label + '_"quoted"\\path\r\nline\tend;$(touch /run/kiro-shell-injection)\n'

    def write(path, value):
        path.write_text(value)
        path.chmod(0o600)

    def assert_private(path, mode, uid, gid):
        metadata = path.stat()
        assert (stat.S_IMODE(metadata.st_mode), metadata.st_uid, metadata.st_gid) == (
            mode, uid, gid), (str(path), oct(stat.S_IMODE(metadata.st_mode)),
                             metadata.st_uid, metadata.st_gid)

    def execute_setup(label: str) -> tuple[subprocess.CompletedProcess[str], str, str]:
        previous_config = (state / "config.json").read_bytes() if (state / "config.json").exists() else None
        systemctl("stop", unit)
        systemctl("reset-failed")
        for name in ("pid", "parent-pid", "release"):
            (barrier / name).unlink(missing_ok=True)
        os.mkfifo(barrier / "release", 0o600)
        os.chown(barrier / "release", owner.pw_uid, owner.pw_gid)
        (barrier / "armed").touch()
        process = subprocess.Popen(["systemctl", "start", unit],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 20
            while not (barrier / "pid").exists():
                assert process.poll() is None, process.communicate()
                assert time.monotonic() < deadline, "setup never reached jq barrier"
                time.sleep(0.01)
            pid = int((barrier / "pid").read_text())
            parent = int((barrier / "parent-pid").read_text())
            assert parent == int(systemctl("show", "-p", "MainPID", "--value", unit))
            setup_argv = Path(f"/proc/{parent}/cmdline").read_bytes().split(b"\0")[:-1]
            assert any(argument.endswith(b"-kiro-rs-setup") for argument in setup_argv), setup_argv
            setup_script = Path(setup_argv[-1].decode()).read_text()
            assert f"--rawfile apiKey {state}/api-key" in setup_script
            assert "--rawfile adminApiKey" in setup_script
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[:-1]
            visible_argv = subprocess.run(
                ["runuser", "-u", "chen", "--", "cat", f"/proc/{pid}/cmdline"],
                check=True, capture_output=True).stdout
            assert visible_argv == b"\0".join(argv) + b"\0"
            api = normalize((state / "api-key").read_text())
            admin = normalize(admin_source.read_text())
            exposed = {"apiKey": bool(api) and any(api.encode() in argument for argument in argv),
                       "adminApiKey": bool(admin) and any(admin.encode() in argument for argument in argv)}
            environments = [Path(f"/proc/{process_id}/environ").read_bytes() for process_id in (pid, parent)]
            env_exposed = any(value and value.encode() in environment
                              for value in (api, admin) for environment in environments)
            current_config = (state / "config.json").read_bytes() if (state / "config.json").exists() else None
            assert current_config == previous_config, "config replaced before jq validation"
            temp_candidates = glob.glob(str(state / ".config.*"))
            assert len(temp_candidates) == 1, f"expected one temp config, found {temp_candidates}"
            metadata = Path(temp_candidates[0]).stat()
            temporary_mode = stat.S_IMODE(metadata.st_mode)
            rawfiles = {name: any(argv[index:index + 2] == [b"--rawfile", name.encode()]
                                  for index in range(len(argv)))
                        for name in ("apiKey", "adminApiKey")}
            observation = {"case": label, "setupArgv": [arg.decode() for arg in setup_argv],
                            "apiKeyVisibleInArgv": exposed["apiKey"],
                            "adminKeyVisibleInArgv": exposed["adminApiKey"],
                            "secretVisibleInEnvironment": env_exposed,
                            "normalizedApiEmpty": not bool(api), "normalizedAdminEmpty": not bool(admin),
                           "rawfiles": rawfiles, "temporaryMode": oct(temporary_mode)}
            observations.append(observation)
            print("KIRO_SETUP_ARGV " + json.dumps(observation), flush=True)
            if any(exposed.values()):
                violations.append(label + ": fixture secret visible in actual setup jq argv")
            if env_exposed:
                violations.append(label + ": fixture secret visible in setup environment")
            if not all(rawfiles.values()):
                violations.append(label + ": secrets were not loaded with --rawfile")
            if temporary_mode != 0o600:
                violations.append(label + ": config temp created with " + oct(temporary_mode))
            assert (metadata.st_uid, metadata.st_gid) == (owner.pw_uid, owner.pw_gid)
        finally:
            if (barrier / "pid").exists():
                with (barrier / "release").open("w") as gate:
                    gate.write("release\n")
            else:
                systemctl("stop", unit)
            (barrier / "armed").unlink()
        stdout, stderr = process.communicate(timeout=20)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr), api, admin

    def run_setup(label, expected_credentials, expected_api=None):
        result, api, admin = execute_setup(label)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert systemctl("show", "-p", "Result", "--value", unit) == "success"
        assert (state / "credentials.json").read_text() == expected_credentials
        if expected_api is not None:
            assert (state / "api-key").read_bytes() == expected_api.encode()
        else:
            assert re.fullmatch(r"[0-9a-f]{48}\n", (state / "api-key").read_text())
        config = json.loads((state / "config.json").read_text())
        assert config == {"host": "127.0.0.1", "port": 8999, "apiKey": api,
                          "adminApiKey": admin, "region": "eu-central-1", "tlsBackend": "rustls",
                          "proxyUrl": "http://fixture.invalid:7890", "kiroVersion": "fixture-1"}
        assert_private(state, 0o700, owner.pw_uid, owner.pw_gid)
        for name in ("credentials.json", "api-key", "config.json"):
            assert_private(state / name, 0o600, owner.pw_uid, owner.pw_gid)
        assert not (state / "config.json.tmp").exists()
        assert not glob.glob(str(state / ".config.*"))
        assert not Path("/run/kiro-shell-injection").exists()
        print("KIRO_SETUP_PASS " + label + " JSON, seed state and permissions", flush=True)

    def rejected_admin(label, empty):
        systemctl("stop", unit)
        systemctl("reset-failed")
        before = {path.name: path.read_bytes() for path in state.iterdir() if path.is_file()}
        (barrier / "pid").unlink(missing_ok=True)
        if empty:
            write(admin_source, "")
        else:
            admin_source.unlink(missing_ok=True)
        result = subprocess.run(["systemctl", "start", unit], capture_output=True, text=True)
        assert result.returncode != 0, label
        assert systemctl("show", "-p", "Result", "--value", unit) == "exit-code"
        assert not (barrier / "pid").exists()
        assert not (state / "config.json.tmp").exists()
        assert not glob.glob(str(state / ".config.*"))
        for name, value in before.items():
            assert (state / name).read_bytes() == value, (label, name)
        if "config.json" not in before:
            assert not (state / "config.json").exists()
        journal = subprocess.run(["journalctl", "-u", unit, "--no-pager"],
                                 check=True, capture_output=True, text=True).stdout
        assert "admin password source is missing or empty" in journal
        print("KIRO_SETUP_PASS " + label + " fails closed without replacing config", flush=True)

    credentials = '[{"refreshToken":"SYNTHETIC_KIRO_SEED_TOKEN"}]\n'
    api = secret("SEED_API")
    write(source / "credentials.json", credentials)
    write(source / "api-key", api)
    write(admin_source, secret("FIRST_ADMIN"))
    run_setup("first initialization with existing seeds", credentials, api)

    credentials = '[{"refreshToken":"SYNTHETIC_KIRO_ONLINE_TOKEN"}]\n'
    api = secret("RUNTIME_API")
    write(state / "credentials.json", credentials)
    write(state / "api-key", api)
    for name in ("credentials.json", "api-key"):
        os.chown(state / name, 0, 0)
    write(source / "credentials.json", '[{"refreshToken":"SYNTHETIC_KIRO_CHANGED_SEED"}]\n')
    write(source / "api-key", secret("CHANGED_SEED_API"))
    write(admin_source, secret("ROTATED_ADMIN"))
    run_setup("runtime state preserved and admin rotated", credentials, api)
    previous_config = (state / "config.json").read_bytes()
    run_setup("repeated initialization is stable", credentials, api)
    assert (state / "config.json").read_bytes() == previous_config
    rejected_admin("missing admin with existing config", empty=False)
    rejected_admin("empty admin with existing config", empty=True)

    shutil.rmtree(state)
    state.mkdir(mode=0o700)
    for name in ("credentials.json", "api-key"):
        write(state / name, "")
        (source / name).unlink()
    write(admin_source, secret("GENERATED_ADMIN"))
    run_setup("empty runtime without seeds generates API key", "[]\n")
    generated_api = (state / "api-key").read_text()
    run_setup("generated API key survives repeated initialization", "[]\n", generated_api)

    for empty in (False, True):
        shutil.rmtree(state)
        state.mkdir(mode=0o700)
        rejected_admin("first initialization with " + ("empty" if empty else "missing") + " admin", empty)

    check_normalized_keys(execute_setup, run_setup, write)
    (barrier / "observations.json").write_text(json.dumps(observations, indent=2) + "\n")
    assert not violations, "\n".join(violations)
    print("KIRO_SETUP_GREEN: no fixture secrets in actual argv; all lifecycle checks passed", flush=True)
  '';
in
pkgs.testers.runNixOSTest {
  name = "kiro-setup-secrets-argv";
  node.pkgsReadOnly = false;
  nodes.machine = { ... }: {
    imports = [ ../hosts/Aliyun/kiro-rs.nix ];
    nixpkgs.overlays = lib.mkForce (pkgs.overlays ++ [
      (_final: _prev: {
        kiro-rs = fixture;
        jq = guardedJq;
      })
    ]);
    users.users.chen.isNormalUser = true;
    services.kiro-rs = {
      enable = true;
      listenHost = "127.0.0.1";
      port = 8999;
      region = "eu-central-1";
      tlsBackend = "rustls";
      proxyUrl = "http://fixture.invalid:7890";
      kiroVersion = "fixture-1";
    };
    systemd.services.kiro-rs.wantedBy = lib.mkForce [ ];
    environment.systemPackages = [ pkgs.python3 ];
    environment.etc."kiro-setup-probe.py".source = probe;
    environment.etc."kiro_setup_normalized_probe.py".source = ./kiro-setup-normalized-probe.py;
    environment.etc."kiro-setup-boundary-probe.py".source = ./kiro-setup-boundary-probe.py;
    virtualisation.memorySize = 768;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    status, output = machine.execute("python /etc/kiro-setup-probe.py", timeout=360)
    print(output)
    assert status == 0, output
    machine.copy_from_vm("/run/kiro-setup-fixture/observations.json")
    machine.copy_from_vm("/run/kiro-setup-fixture/normalized-observations.json")
    status2, output2 = machine.execute("python /etc/kiro-setup-boundary-probe.py", timeout=360)
    print(output2)
    machine.copy_from_vm("/run/kiro-setup-fixture/boundary-observations.json")
  '';
}
