{ pkgs }:

let
  inherit (pkgs) lib;
  python = pkgs.python3;
  domain = "chenjaly.cn";
  fixturePassword = "proxy-fixture-only";
  firstUdpPort = 20000;
  lastUdpPort = 20001;
  nodeSource = lib.fileset.toSource {
    root = ../tests;
    fileset = lib.fileset.unions [
      ./mixed-proxy.test.cjs
      (lib.fileset.fileFilter (file: file.hasExt "cjs") ./mixed-proxy)
    ];
  };
  runtimeClosure = pkgs.closureInfo { rootPaths = [ pkgs.mixed-proxy-rs ]; };

  certificateFixture =
    directory: names:
    pkgs.writeShellScript "mixed-proxy-vm-certificates" ''
      set -euo pipefail
      umask 077
      ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g nginx ${directory}
      cd ${directory}
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -subj '/CN=mixed-proxy VM private fixture CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout ca.key -out ca.pem
      ${pkgs.openssl}/bin/openssl req -newkey rsa:2048 -nodes \
        -subj '/CN=${builtins.head names}' -keyout key.pem -out request.pem
      printf '%s\n' 'subjectAltName=${lib.concatMapStringsSep "," (name: "DNS:${name}") names}' \
        'basicConstraints=critical,CA:FALSE' 'extendedKeyUsage=serverAuth' > extensions
      ${pkgs.openssl}/bin/openssl x509 -req -days 2 -in request.pem -CA ca.pem \
        -CAkey ca.key -CAcreateserial -extfile extensions -out cert.pem
      ${pkgs.coreutils}/bin/cat cert.pem ca.pem > fullchain.pem
      ${pkgs.coreutils}/bin/cp ca.pem chain.pem
      ${pkgs.coreutils}/bin/chown root:nginx key.pem cert.pem fullchain.pem chain.pem ca.pem
      ${pkgs.coreutils}/bin/chmod 0640 key.pem cert.pem fullchain.pem chain.pem ca.pem
    '';

  wire = pkgs.writeText "mixed_proxy_wire.py" ''
    from contextlib import contextmanager
    from dataclasses import dataclass
    from collections.abc import Iterator
    import select
    import socket
    import struct
    from typing import Final

    PASSWORD: Final = "${fixturePassword}"
    UDP_PORTS: Final = range(${toString firstUdpPort}, ${toString (lastUdpPort + 1)})

    @dataclass(frozen=True, slots=True)
    class Credentials:
        username: str = "chen"
        password: str = PASSWORD

    @dataclass(frozen=True, slots=True)
    class Reply:
        status: int
        address: str
        port: int

    def receive(connection: socket.socket, size: int) -> bytes:
        result = bytearray()
        while len(result) < size:
            fragment = connection.recv(size - len(result))
            assert fragment, "SOCKS connection closed before a complete reply"
            result.extend(fragment)
        return bytes(result)

    @contextmanager
    def control(proxy: str) -> Iterator[socket.socket]:
        with socket.create_connection((proxy, 8443), timeout=20) as connection:
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            yield connection

    def greet(connection: socket.socket, chunks: tuple[bytes, ...]) -> None:
        connection.settimeout(1)
        for fragment in chunks[:-1]:
            connection.sendall(fragment)
            assert not select.select([connection], [], [], 0.05)[0]
        connection.sendall(chunks[-1])
        assert receive(connection, 2) == b"\x05\x02"
        connection.settimeout(20)

    def send_credentials(connection: socket.socket, credentials: Credentials) -> None:
        username = credentials.username.encode()
        password = credentials.password.encode()
        connection.sendall(b"\x01" + bytes([len(username)]) + username
                           + bytes([len(password)]) + password)

    def authenticate(connection: socket.socket, credentials: Credentials) -> bool:
        send_credentials(connection, credentials)
        response = receive(connection, 2)
        assert response[0] == 1, response.hex()
        if response[1] != 0:
            assert connection.recv(1) == b"", "Authentication failure must close the connection"
            return False
        return True

    def associate(connection: socket.socket) -> Reply:
        connection.sendall(b"\x05\x03\x00\x01" + bytes(6))
        response = receive(connection, 10)
        assert response[0] == 5 and response[2:4] == b"\x00\x01", response.hex()
        return Reply(response[1], socket.inet_ntoa(response[4:8]),
                     struct.unpack("!H", response[8:10])[0])

    def packet(destination: str, marker: str) -> bytes:
        if destination == "echo.test":
            name = destination.encode()
            address = b"\x03" + bytes([len(name)]) + name
        else:
            address = b"\x01" + socket.inet_aton(destination)
        return bytes(3) + address + struct.pack("!H", 9999) + marker.encode()

    def echo(datagram: socket.socket, relay: tuple[str, int], request: bytes) -> None:
        datagram.sendto(request, relay)
        response, source = datagram.recvfrom(4096)
        assert source == relay, (source, relay)
        assert response[:4] == b"\x00\x00\x00\x01", response.hex()
        target = socket.gethostbyname("echo.test")
        assert socket.inet_ntoa(response[4:8]) == target
        assert struct.unpack("!H", response[8:10])[0] == 9999
        header_size = {1: 10, 3: 7 + request[4]}[request[3]]
        assert response[10:] == request[header_size:]
  '';

  probes = pkgs.writeText "mixed_proxy_probes.py" ''
    import base64
    import hashlib
    import socket
    import ssl
    import subprocess
    import sys
    from mixed_proxy_wire import Credentials, PASSWORD, UDP_PORTS
    from mixed_proxy_wire import associate, authenticate, control, greet, packet, receive

    def fingerprint(proxy: str) -> None:
        context = ssl.create_default_context(cafile="/run/proxy-ca.pem")
        with socket.create_connection((proxy, 8443), timeout=20) as raw:
            with context.wrap_socket(raw, server_hostname="api.chenjaly.cn") as connection:
                certificate = connection.getpeercert(binary_form=True)
                assert certificate is not None
                print(hashlib.sha256(certificate).hexdigest())

    def http_auth(proxy: str, credentials: Credentials | None, tunnel: bool = False) -> int:
        context = ssl.create_default_context(cafile="/run/proxy-ca.pem")
        with socket.create_connection((proxy, 8443), timeout=20) as raw:
            with context.wrap_socket(raw, server_hostname="api.chenjaly.cn") as connection:
                header = ""
                if credentials is not None:
                    token = base64.b64encode(
                        f"{credentials.username}:{credentials.password}".encode()).decode()
                    header = f"Proxy-Authorization: Basic {token}\r\n"
                request = "CONNECT echo.test:9443" if tunnel else "GET http://echo.test:8080/auth-fixture"
                authority = "echo.test:9443" if tunnel else "echo.test:8080"
                connection.sendall((request + " HTTP/1.1\r\n"
                                    + f"Host: {authority}\r\n" + header
                                    + "Connection: close\r\n\r\n").encode())
                with connection.makefile("rb") as response:
                    status = int(response.readline().split()[1])
                    if not tunnel:
                        result = response.read()
                        assert (b"mixed-proxy-vm-target" in result) is (status == 200)
        return status

    def auth(proxy: str, accepted: bool) -> None:
        with control(proxy) as connection:
            greet(connection, (b"\x05\x01\x02",))
            assert authenticate(connection, Credentials()) is accepted
        status = http_auth(proxy, Credentials())
        assert status == 200 if accepted else status in (401, 407)
        if not accepted:
            assert http_auth(proxy, Credentials(), tunnel=True) in (401, 407)

    def greetings(proxy: str) -> None:
        for chunks in ((b"\x05\x01\x02",), (b"\x05\x02\x00\x02",),
                       (b"\x05", b"\x01", b"\x02"), (b"\x05\x01", b"\x02"),
                       (b"\x05", b"\x02\x00", b"\x02")):
            with control(proxy) as connection:
                greet(connection, chunks)
        with control(proxy) as connection:
            connection.sendall(b"\x05\x01\x00")
            assert receive(connection, 2) == b"\x05\xff"
        assert http_auth(proxy, None) in (401, 407)
        assert http_auth(proxy, None, tunnel=True) in (401, 407)

    def negative_credentials(proxy: str) -> None:
        credentials = (Credentials(password="wrong-fixture-password"), Credentials(password=""),
                       Credentials(username="root"), Credentials(username="alice"),
                       *(Credentials(password=PASSWORD + suffix) for suffix in ("\x00", "\r", "\n")))
        for candidate in credentials:
            with control(proxy) as connection:
                greet(connection, (b"\x05\x01\x02",))
                assert authenticate(connection, candidate) is False
            assert http_auth(proxy, candidate) in (401, 407)
            assert http_auth(proxy, candidate, tunnel=True) in (401, 407)

    def exhausted(proxy: str) -> None:
        with control(proxy) as connection:
            greet(connection, (b"\x05\x01\x02",))
            assert authenticate(connection, Credentials())
            assert associate(connection).status == 1

    def assert_drop(proxy: str, port: int) -> None:
        assert port in UDP_PORTS
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagram:
            datagram.settimeout(0.5)
            datagram.sendto(packet("echo.test", "closed-control"), (proxy, port))
            try:
                response = datagram.recvfrom(4096)
            except TimeoutError:
                return
            assert False, ("UDP relay survived TCP control close", response)

    def transfers(proxy: str) -> None:
        for proxy_scheme in ("https", "socks5h"):
            for target_scheme, port in (("http", 8080), ("https", 9443)):
                command = ["curl", "--disable", "--silent", "--show-error", "--fail",
                           "--noproxy", "", "--connect-timeout", "3", "--max-time", "20",
                           "--proxy-user", f"chen:{PASSWORD}", "--cacert", "/run/target-ca.pem"]
                if proxy_scheme == "https":
                    command += ["--proxy", "https://api.chenjaly.cn:8443",
                                "--resolve", f"api.chenjaly.cn:8443:{proxy}",
                                "--proxy-cacert", "/run/proxy-ca.pem"]
                else:
                    command += ["--proxy", f"socks5h://{proxy}:8443", "--socks5-basic"]
                command += [f"{target_scheme}://echo.test:{port}/transfer-fixture"]
                result = subprocess.run(command, capture_output=True, text=True, check=True)
                assert result.stdout == "mixed-proxy-vm-target\n"
        for name, trust in (("api.chenjaly.cn", False), ("wrong-proxy.test", True)):
            command = ["curl", "--disable", "--silent", "--show-error", "--noproxy", "",
                       "--connect-timeout", "3", "--max-time", "20", "--proxy-user", f"chen:{PASSWORD}",
                       "--proxy", f"https://{name}:8443", "--resolve", f"{name}:8443:{proxy}"]
            if trust:
                command += ["--proxy-cacert", "/run/proxy-ca.pem"]
            result = subprocess.run(command + ["http://echo.test:8080/untrusted-fixture"],
                                    capture_output=True, text=True, check=False)
            assert result.returncode == 60, result.stderr

    def main() -> None:
        mode, proxy = sys.argv[1:3]
        actions = {"greetings": lambda: greetings(proxy), "negative": lambda: negative_credentials(proxy),
                   "accept": lambda: auth(proxy, True), "deny": lambda: auth(proxy, False),
                    "transfers": lambda: transfers(proxy),
                   "fingerprint": lambda: fingerprint(proxy),
                    "exhausted": lambda: exhausted(proxy),
                   "closed": lambda: assert_drop(proxy, int(sys.argv[3]))}
        actions[mode]()
        print(f"PASS {mode}")

    if __name__ == "__main__":
        main()
  '';

  pamBlocker = pkgs.writeShellScript "mixed-proxy-vm-pam-blocker" ''
    set -eu
    trap "" TERM
    gate="$1/gate-$$"
    ${pkgs.coreutils}/bin/mkfifo -m 0600 "$gate"
    printf '%s\n' "$$" > "$1/entered"
    IFS= read -r release < "$gate"
    ${pkgs.coreutils}/bin/rm "$gate"
    printf '%s\n' "$$" > "$1/returned"
  '';

  pamBounds = pkgs.writeText "mixed_proxy_pam_bounds.py" ''
    from concurrent.futures import ThreadPoolExecutor
    from contextlib import ExitStack
    from pathlib import Path
    import os
    import select
    import subprocess
    import sys
    from tempfile import TemporaryDirectory
    from time import monotonic
    from typing import BinaryIO
    from mixed_proxy_probes import http_auth
    from mixed_proxy_wire import Credentials, authenticate, control, greet, send_credentials

    def read_pid(notification: BinaryIO) -> int:
        value = bytearray()
        while not value.endswith(b"\n"):
            assert select.select([notification], [], [], 5)[0], "PAM fixture notification timed out"
            value.extend(notification.read(1))
        return int(value)

    def denied(proxy: str, index: int) -> float:
        started = monotonic()
        if index % 2:
            assert http_auth(proxy, Credentials()) in (401, 407)
        else:
            with control(proxy) as connection:
                greet(connection, (b"\x05\x01\x02",))
                assert authenticate(connection, Credentials()) is False
        return monotonic() - started

    def bounded_authentication(proxy: str, directory: Path, resources: ExitStack) -> None:
        entered = resources.enter_context(os.fdopen(os.open(directory / "entered", os.O_RDWR), "rb", buffering=0))
        returned = resources.enter_context(os.fdopen(os.open(directory / "returned", os.O_RDWR), "rb", buffering=0))
        with ThreadPoolExecutor(max_workers=4) as executor:
            requests = [executor.submit(denied, proxy, index) for index in range(4)]
            workers: list[int] = []
            try:
                for _ in range(4):
                    workers.append(read_pid(entered))
                assert len(set(workers)) == 4
                for index in range(2):
                    assert denied(proxy, index) < 2, "Fifth authentication must reject immediately"
                elapsed = [request.result(timeout=16) for request in requests]
                assert all(9 <= duration < 16 for duration in elapsed), elapsed
                assert all((directory / f"gate-{worker}").exists() for worker in workers)
                for index in range(2):
                    assert denied(proxy, index) < 2, "Timed-out FFI workers must retain their permits"
            finally:
                for worker in workers:
                    with (directory / f"gate-{worker}").open("w") as gate:
                        gate.write("release\n")
                assert {read_pid(returned) for _ in workers} == set(workers)

    def bounded_shutdown(proxy: str, directory: Path, resources: ExitStack) -> None:
        entered = resources.enter_context(os.fdopen(os.open(directory / "entered", os.O_RDWR), "rb", buffering=0))
        resources.enter_context(os.fdopen(os.open(directory / "returned", os.O_RDWR), "rb", buffering=0))
        for _ in range(4):
            connection = resources.enter_context(control(proxy))
            greet(connection, (b"\x05\x01\x02",))
            send_credentials(connection, Credentials())
        workers = [read_pid(entered) for _ in range(4)]
        group = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", "mixed-proxy"],
                               capture_output=True, text=True, check=True).stdout.strip()
        assert group
        started = monotonic()
        subprocess.run(["systemctl", "stop", "mixed-proxy"], check=True, timeout=18)
        elapsed = monotonic() - started
        assert elapsed < 18, elapsed
        assert all(not Path(f"/proc/{worker}").exists() for worker in workers)
        processes = Path("/sys/fs/cgroup" + group) / "cgroup.procs"
        assert not processes.exists() or not processes.read_text().strip()
        print(f"PASS entire service cgroup stopped in {elapsed:.2f}s with blocked PAM calls")

    def main() -> None:
        mode, proxy = sys.argv[1:3]
        policy = Path("/etc/pam.d/mixed-proxy")
        original = policy.read_text()
        with TemporaryDirectory(prefix="mixed-proxy-pam-", dir="/run") as temporary:
            directory = Path(temporary)
            os.chown(directory, 1000, -1)
            for name in ("entered", "returned"):
                notification = directory / name
                os.mkfifo(notification, 0o600)
                os.chown(notification, 1000, -1)
            try:
                policy.write_text("auth required ${pkgs.pam}/lib/security/pam_exec.so "
                                  + "${pamBlocker} " + temporary + "\n" + original)
                with ExitStack() as resources:
                    actions = {"bounds": bounded_authentication, "stop": bounded_shutdown}
                    actions[mode](proxy, directory, resources)
            except (AssertionError, OSError, subprocess.SubprocessError):
                subprocess.run(["systemctl", "stop", "mixed-proxy"], check=True, timeout=20)
                raise
            finally:
                policy.write_text(original)
        print(f"PASS native PAM {mode}")

    if __name__ == "__main__":
        main()
  '';

  udpSession = pkgs.writeText "mixed_proxy_udp_session.py" ''
    from contextlib import ExitStack
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import socket
    import sys
    from mixed_proxy_wire import Credentials, UDP_PORTS, associate, authenticate
    from mixed_proxy_wire import control, echo, greet, packet

    def serve(proxy: str) -> None:
        with ExitStack() as resources:
            connection = resources.enter_context(control(proxy))
            greet(connection, (b"\x05\x01\x02",))
            assert authenticate(connection, Credentials())
            reply = associate(connection)
            assert reply.status == 0 and reply.address == proxy and reply.port in UDP_PORTS, reply
            relay = (reply.address, reply.port)
            datagram = resources.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
            datagram.bind(("0.0.0.0", 0))
            datagram.settimeout(2)

            class Commands(BaseHTTPRequestHandler):
                def do_GET(self) -> None:
                    parts = self.path.strip("/").split("/")
                    match parts:
                        case ["relay"]:
                            output = f"{relay[0]}:{relay[1]}"
                        case ["ipv4", marker]:
                            echo(datagram, relay, packet(socket.gethostbyname("echo.test"), marker))
                            output = marker
                        case ["domain", marker]:
                            echo(datagram, relay, packet("echo.test", marker))
                            output = marker
                        case ["inject", port, marker]:
                            datagram.settimeout(0.5)
                            datagram.sendto(packet("echo.test", marker), (proxy, int(port)))
                            try:
                                response = datagram.recvfrom(4096)
                            except TimeoutError:
                                output = "dropped"
                            else:
                                assert False, ("other client IP accepted by relay", response)
                            finally:
                                datagram.settimeout(2)
                        case _:
                            self.send_error(404)
                            return
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(output.encode())

            server = resources.enter_context(HTTPServer(("127.0.0.1", 18080), Commands))
            server.serve_forever()

    if __name__ == "__main__":
        serve(sys.argv[1])
  '';

  udpTarget = pkgs.writeScript "mixed-proxy-vm-udp-echo" ''
    #!${python}/bin/python
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as endpoint:
        endpoint.bind(("0.0.0.0", 9999))
        with open("/run/udp-target.log", "a", buffering=1) as observations:
            while True:
                payload, sender = endpoint.recvfrom(4096)
                observations.write(payload.decode() + "\n")
                endpoint.sendto(payload, sender)
  '';
in
pkgs.testers.runNixOSTest {
  name = "mixed-proxy-pam-udp";

  defaults = { nodes, ... }: {
    environment.systemPackages = [
      python
      pkgs.curl
      pkgs.openssl
      pkgs.nodejs
    ];
    environment.etc = {
      "mixed_proxy_wire.py".source = wire;
      "mixed_proxy_probes.py".source = probes;
      "mixed_proxy_probes.py".mode = "0444";
      "mixed_proxy_udp_session.py".source = udpSession;
      "mixed_proxy_udp_session.py".mode = "0444";
      "mixed_proxy_pam_bounds.py".source = pamBounds;
      "mixed_proxy_pam_bounds.py".mode = "0444";
    };
    networking.hosts = {
      ${nodes.proxy.networking.primaryIPAddress} = [ "api.chenjaly.cn" ];
      ${nodes.target.networking.primaryIPAddress} = [ "echo.test" ];
    };
    virtualisation.memorySize = 768;
  };

  nodes.proxy = { config, ... }: {
    imports = [ ../hosts/Aliyun/mixed-proxy.nix ];
    nixpkgs.overlays = lib.mkForce pkgs.overlays;
    services.mixed-proxy = {
      publicUdpAddress = config.networking.primaryIPAddress;
      udpPortRange = {
        from = firstUdpPort;
        to = lastUdpPort;
      };
    };
    networking.firewall.allowedTCPPorts = [ 8443 ];
    networking.firewall.allowedUDPPortRanges = [
      {
        from = firstUdpPort;
        to = lastUdpPort;
      }
    ];
    users.groups.nginx = { };
    users.users = {
      chen = {
        isNormalUser = true;
        uid = 1000;
        initialPassword = fixturePassword;
      };
      alice = {
        isNormalUser = true;
        uid = 1001;
        initialPassword = fixturePassword;
      };
      root = {
        initialPassword = lib.mkForce fixturePassword;
        hashedPasswordFile = lib.mkForce null;
      };
    };
    security.acme = {
      acceptTerms = true;
      defaults.email = "fixture@example.test";
      certs.${domain} = {
        inherit domain;
        extraDomainNames = [ "*.${domain}" ];
        group = "nginx";
        webroot = "/var/empty";
      };
    };
    systemd.services."acme-${domain}" = lib.mkForce {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = certificateFixture config.security.acme.certs.${domain}.directory [
          domain
          "*.${domain}"
          "api.${domain}"
        ];
      };
    };
    systemd.services."acme-order-renew-${domain}" = lib.mkForce {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    };
    systemd.timers."acme-renew-${domain}".enable = lib.mkForce false;
    environment.etc."pam.d/mixed-proxy".mode = lib.mkForce "0644";
    environment.etc."mixed-proxy-runtime-closure".source = "${runtimeClosure}/store-paths";
  };

  nodes.clientA = { nodes, ... }: {
    systemd.services.udp-session.serviceConfig.ExecStart =
      "${python}/bin/python /etc/mixed_proxy_udp_session.py ${nodes.proxy.networking.primaryIPAddress}";
  };
  nodes.clientB = { nodes, ... }: {
    systemd.services.udp-session.serviceConfig.ExecStart =
      "${python}/bin/python /etc/mixed_proxy_udp_session.py ${nodes.proxy.networking.primaryIPAddress}";
  };

  nodes.target = {
    networking.firewall.allowedTCPPorts = [
      8080
      9443
    ];
    networking.firewall.allowedUDPPorts = [ 9999 ];
    services.nginx = {
      enable = true;
      virtualHosts."echo.test" = {
        addSSL = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = 8080;
          }
          {
            addr = "0.0.0.0";
            port = 9443;
            ssl = true;
          }
        ];
        sslCertificate = "/var/lib/target-fixture/fullchain.pem";
        sslCertificateKey = "/var/lib/target-fixture/key.pem";
        locations."/".return = ''200 "mixed-proxy-vm-target\n"'';
      };
    };
    systemd.services.target-certificates = {
      before = [ "nginx.service" ];
      requiredBy = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = certificateFixture "/var/lib/target-fixture" [ "echo.test" ];
      };
    };
    systemd.services.udp-target = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = udpTarget;
    };
  };

  testScript = { nodes, ... }: ''
    from concurrent.futures import ThreadPoolExecutor
    import json
    from shlex import quote
    from test_driver.machine import BaseMachine

    start_all()
    proxy_ip = "${nodes.proxy.networking.primaryIPAddress}"

    def probe(machine: BaseMachine, mode: str) -> None:
        machine.succeed(f"python /etc/mixed_proxy_probes.py {quote(mode)} {proxy_ip}")

    def udp(machine: BaseMachine, path: str) -> str:
        return machine.succeed("curl --disable --silent --show-error --fail --noproxy '*' "
                               f"--max-time 5 http://127.0.0.1:18080/{quote(path)}").strip()

    def relay_ports() -> set[int]:
        addresses = (line.split()[3] for line in proxy.succeed("ss -H -ulnp").splitlines()
                     if '"mixed-proxy"' in line)
        return {int(address.rsplit(":", 1)[1]) for address in addresses
                if address.rsplit(":", 1)[0] == proxy_ip}

    def restore_account() -> None:
        proxy.succeed("passwd -u chen; chage -E -1 -I -1 -M 99999 -d $(date +%F) chen")
        probe(clientA, "accept")

    def restore_service() -> None:
        proxy.succeed("systemctl reset-failed mixed-proxy; systemctl start mixed-proxy")
        proxy.wait_for_open_port(8443)
        probe(clientA, "accept")

    with subtest("real module, fixture certificates and one unprivileged native PAM Rust service"):
        proxy.wait_for_unit("mixed-proxy.service")
        proxy.wait_for_open_port(8443)
        assert proxy.succeed("systemctl show -p Result --value acme-${domain} "
                             "acme-order-renew-${domain}").split() == ["success", "success"]
        target.wait_for_unit("nginx.service")
        target.wait_for_unit("udp-target.service")
        target.wait_until_succeeds("ss -H -lun | grep -F ':9999 '")
        for machine, source, filename in (
            (proxy, "/var/lib/acme/${domain}/ca.pem", "/run/proxy-ca.pem"),
            (target, "/var/lib/target-fixture/ca.pem", "/run/target-ca.pem"),
        ):
            public_ca = machine.succeed(f"base64 -w0 {source}").strip()
            for client in (proxy, clientA, clientB):
                client.succeed(f"printf %s {quote(public_ca)} | base64 -d > {filename}")
        assert proxy.succeed("systemctl show -p User --value mixed-proxy").strip() == "chen"
        proxy_pid = int(proxy.succeed("systemctl show -p MainPID --value mixed-proxy"))
        status = dict(line.split(":", 1) for line in proxy.succeed(f"cat /proc/{proxy_pid}/status").splitlines()
                      if ":" in line)
        assert status["Uid"].split() == ["1000"] * 4
        assert status["NoNewPrivs"].strip() == "0"
        primary_group = proxy.succeed("id -g chen").strip()
        assert status["Gid"].split() == [primary_group] * 4
        nginx_group = proxy.succeed("getent group nginx").split(":")[2]
        assert nginx_group in status["Groups"].split()
        for property in ("NoNewPrivileges", "PrivateUsers", "RestrictSUIDSGID", "DynamicUser"):
            assert proxy.succeed(f"systemctl show -p {property} --value mixed-proxy").strip() == "no"
        assert proxy.succeed("systemctl show -p TimeoutStopUSec --value mixed-proxy").strip() == "15s"
        assert proxy.succeed("systemctl show -p KillMode --value mixed-proxy").strip() == "control-group"
        assert proxy.succeed("systemctl show -p SendSIGKILL --value mixed-proxy").strip() == "yes"
        proxy.succeed("test -u /run/wrappers/bin/unix_chkpwd")
        assert proxy.succeed("stat -c %u /run/wrappers/bin/unix_chkpwd").strip() == "0"
        assert proxy.succeed(f"cat /proc/{proxy_pid}/comm").strip() == "mixed-proxy"
        assert "libpam.so" in proxy.succeed(f"cat /proc/{proxy_pid}/maps")
        assert proxy.succeed("systemctl show -p LoadState --value mixed-proxy-auth").strip() == "not-found"
        proxy.fail("ss -H -ltn | grep -F ':19090 '")
        proxy.fail("getent passwd mixed-proxy")
        proxy.fail("getent group mixed-proxy")
        proxy.fail("pgrep -x sslh")
        proxy.fail("pgrep -x gost")
        closure = proxy.succeed("cat /etc/mixed-proxy-runtime-closure").splitlines()
        assert all(not any(name in path for name in ("mixed-proxy-auth", "pamtester", "python"))
                   for path in closure), closure
        policy = proxy.succeed("cat /etc/pam.d/mixed-proxy")
        assert [line.split() for line in policy.splitlines() if line.strip()] == [
            ["auth", "required", "${pkgs.pam}/lib/security/pam_unix.so", "noreap"],
            ["account", "required", "${pkgs.pam}/lib/security/pam_unix.so", "noreap"]]
        config = json.loads(proxy.succeed("cat /etc/mixed-proxy/config.json"))
        assert set(config) == {"listen", "tls", "udp"}
        assert config["listen"] == "0.0.0.0:8443"
        assert config["tls"] == {
            "certFile": "/var/lib/acme/${domain}/fullchain.pem",
            "keyFile": "/var/lib/acme/${domain}/key.pem"}
        assert config["udp"] == {"publicAddress": proxy_ip, "portRange": {
            "from": ${toString firstUdpPort}, "to": ${toString lastUdpPort}}}
        probe(clientA, "accept")

    with subtest("three/four byte and fragmented greetings, required authentication"):
        probe(clientA, "greetings")

    with subtest("HTTP forward and HTTPS CONNECT with strict CA and hostname checks"):
        probe(clientA, "transfers")
        target.fail("grep -F '/untrusted-fixture' /var/log/nginx/access.log")

    with subtest("certificate regeneration and configured restart load a new trusted leaf"):
        before = clientA.succeed(
            f"python /etc/mixed_proxy_probes.py fingerprint {proxy_ip}").splitlines()[0]
        reload_services = "${
          lib.concatStringsSep " " nodes.proxy.security.acme.certs.${domain}.reloadServices
        }"
        assert reload_services == "mixed-proxy"
        proxy.succeed("systemctl restart acme-${domain}")
        proxy.succeed(f"systemctl restart {reload_services}")
        proxy.wait_for_unit("mixed-proxy.service")
        proxy.wait_for_open_port(8443)
        clientA.fail(f"python /etc/mixed_proxy_probes.py fingerprint {proxy_ip}")
        public_ca = proxy.succeed("base64 -w0 /var/lib/acme/${domain}/ca.pem").strip()
        for client in (proxy, clientA, clientB):
            client.succeed(f"printf %s {quote(public_ca)} | base64 -d > /run/proxy-ca.pem")
        after = clientA.succeed(
            f"python /etc/mixed_proxy_probes.py fingerprint {proxy_ip}").splitlines()[0]
        assert after != before
        probe(clientA, "transfers")

    with subtest("wrong/empty credentials, root/alice and NUL/CR/LF suffixes are denied"):
        before = target.succeed("wc -l < /var/log/nginx/access.log")
        probe(clientA, "negative")
        assert target.succeed("wc -l < /var/log/nginx/access.log") == before

    with subtest("locked password is rejected and unlocking restores PAM"):
        before = target.succeed("wc -l < /var/log/nginx/access.log")
        proxy.succeed("passwd -l chen")
        try:
            probe(clientA, "deny")
            assert target.succeed("wc -l < /var/log/nginx/access.log") == before
        finally:
            restore_account()

    with subtest("expired account is rejected by PAM account management"):
        before = target.succeed("wc -l < /var/log/nginx/access.log")
        proxy.succeed("chage -E 1 chen")
        try:
            probe(clientA, "deny")
            assert target.succeed("wc -l < /var/log/nginx/access.log") == before
        finally:
            restore_account()

    with subtest("expired password and mandatory password change are rejected"):
        for change in ("chage -M 1 -d 1 chen", "chage -d 0 chen"):
            before = target.succeed("wc -l < /var/log/nginx/access.log")
            proxy.succeed(change)
            try:
                probe(clientA, "deny")
                assert target.succeed("wc -l < /var/log/nginx/access.log") == before
            finally:
                restore_account()

    with subtest("missing PAM auth/account stacks and modules fail closed through both protocols"):
        auth_rule, account_rule = policy.strip().splitlines()
        for broken in (auth_rule + "\n", account_rule + "\n",
                       "auth required /missing-auth-module.so\n" + account_rule + "\n",
                       auth_rule + "\naccount required /missing-account-module.so\n"):
            before = target.succeed("wc -l < /var/log/nginx/access.log")
            proxy.succeed(f"printf %s {quote(broken)} > /etc/pam.d/mixed-proxy")
            try:
                probe(clientA, "deny")
                assert target.succeed("wc -l < /var/log/nginx/access.log") == before
                proxy.succeed("systemctl is-active mixed-proxy")
            finally:
                proxy.succeed(f"printf %s {quote(policy)} > /etc/pam.d/mixed-proxy")
            probe(clientA, "accept")

    with subtest("four shared native PAM slots retain permits after the ten-second caller deadline"):
        before = target.succeed("wc -l < /var/log/nginx/access.log")
        try:
            proxy.succeed(f"python /etc/mixed_proxy_pam_bounds.py bounds {proxy_ip}", timeout=60)
            assert target.succeed("wc -l < /var/log/nginx/access.log") == before
            proxy.succeed("systemctl is-active mixed-proxy")
            proxy.wait_until_succeeds(f"python /etc/mixed_proxy_probes.py accept {proxy_ip}", timeout=30)
        finally:
            proxy.succeed(f"printf %s {quote(policy)} > /etc/pam.d/mixed-proxy")

    with subtest("blocked PAM calls cannot prevent bounded whole-service shutdown"):
        try:
            proxy.succeed(f"python /etc/mixed_proxy_pam_bounds.py stop {proxy_ip}", timeout=45)
            assert proxy.succeed("systemctl show -p MainPID --value mixed-proxy").strip() == "0"
            proxy.fail("ss -H -ltn | grep -F ':8443 '")
        finally:
            proxy.succeed(f"printf %s {quote(policy)} > /etc/pam.d/mixed-proxy")
            restore_service()

    with subtest("two UDP associations use distinct network clients and public range"):
        assert clientA.succeed("hostname -I") != clientB.succeed("hostname -I")
        for client in (clientA, clientB):
            client.succeed("systemctl start udp-session")
            client.wait_for_open_port(18080)
        port_a = int(udp(clientA, "relay").rsplit(":", 1)[1])
        port_b = int(udp(clientB, "relay").rsplit(":", 1)[1])
        assert {port_a, port_b} == {${toString firstUdpPort}, ${toString lastUdpPort}}
        assert relay_ports() == {port_a, port_b}
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = [executor.submit(udp, client, path) for client, path in (
                (clientA, "ipv4/client-a-ipv4"), (clientB, "domain/client-b-domain"))]
            assert [result.result() for result in results] == ["client-a-ipv4", "client-b-domain"]
        assert udp(clientA, "domain/client-a-domain") == "client-a-domain"
        assert udp(clientB, "ipv4/client-b-ipv4") == "client-b-ipv4"

    with subtest("actual TCP peer IP pins UDP source and ignores other client"):
        assert udp(clientB, f"inject/{port_a}/wrong-client-b") == "dropped"
        assert udp(clientA, f"inject/{port_b}/wrong-client-a") == "dropped"
        assert udp(clientA, "domain/after-wrong-source-a") == "after-wrong-source-a"
        assert udp(clientB, "domain/after-wrong-source-b") == "after-wrong-source-b"
        target.fail("grep -E '^wrong-client-[ab]$' /run/udp-target.log")

    with subtest("third association exhausts two-port range without fallback bind"):
        probe(clientA, "exhausted")
        assert relay_ports() == {port_a, port_b}

    with subtest("closing TCP controls releases UDP relays and permits reassociation"):
        for client in (clientA, clientB):
            client.succeed("systemctl stop udp-session")
        proxy.wait_until_succeeds(f"! ss -H -uanp | grep -F '{proxy_ip}:' | grep -F '\"mixed-proxy\"'")
        assert relay_ports() == set()
        clientA.succeed(f"python /etc/mixed_proxy_probes.py closed {proxy_ip} {port_a}")
        target.fail("grep -Fx 'closed-control' /run/udp-target.log")
        for client in (clientA, clientB):
            client.succeed("systemctl start udp-session")
            client.wait_for_open_port(18080)
        assert udp(clientA, "domain/reassociated-a") == "reassociated-a"
        assert udp(clientB, "domain/reassociated-b") == "reassociated-b"
        assert relay_ports() == {${toString firstUdpPort}, ${toString lastUdpPort}}
        for client in (clientA, clientB):
            client.succeed("systemctl stop udp-session")
        proxy.wait_until_succeeds(f"! ss -H -uanp | grep -F '{proxy_ip}:' | grep -F '\"mixed-proxy\"'")

    with subtest("complete Node protocol suite runs as chen against native PAM inside the VM"):
        proxy.succeed("printf '%s\\n' '${fixturePassword}' | runuser -u chen -- "
                      "node ${nodeSource}/mixed-proxy.test.cjs "
                      "${pkgs.mixed-proxy-rs}/bin/mixed-proxy /etc/mixed-proxy/config.json", timeout=240)
  '';
}
