{
  prev,
  ...
}:

prev.rustPlatform.buildRustPackage {
  pname = "mixed-proxy-rs";
  version = "0.1.0";

  src = prev.lib.fileset.toSource {
    root = ./.;
    fileset = prev.lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./clippy.toml
      ./src
      ./tests
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;
  buildInputs = [ prev.pam ];
  nativeCheckInputs = [
    prev.clippy
    prev.rustfmt
  ];
  doCheck = true;
  postCheck = ''
    cargo fmt --all -- --check
    cargo clippy --offline --locked --all-targets -- -D warnings
  '';

  meta = {
    description = "Single-port TLS HTTP and SOCKS5 proxy with native PAM authentication";
    license = prev.lib.licenses.mit;
    platforms = prev.lib.platforms.linux;
    mainProgram = "mixed-proxy";
  };
}
