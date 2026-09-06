{
  config,
  lib,
  modulesPath,
  ...
}:

let
  cfg = config.hardware.xiaomiElish.rootfs;
  buildPkgs = config.hardware.xiaomiElish.buildPkgs;
  # btrfs-progs >= 6.10 bypasses fakeroot while importing --rootdir via nftw.
  # This is the upstream nixpkgs fix (NixOS/nixpkgs#361051) expressed at the
  # call site until the pinned nixpkgs branch contains it.
  unshareRoot = buildPkgs.writeShellScriptBin "fakeroot" ''
    exec ${lib.getExe' buildPkgs.util-linux "unshare"} --map-root-user "$@"
  '';
in
{
  options.hardware.xiaomiElish.rootfs.uuid = lib.mkOption {
    type = lib.types.strMatching ''[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'';
    default = "44444444-4444-4444-8888-888888888888";
    example = "14e19a7b-0ae0-484d-9d54-43bd6fdc20c7";
    description = "Filesystem UUID for the Xiaomi Elish root filesystem image.";
  };

  config.system.build.elishRootfsImage = buildPkgs.callPackage (modulesPath + "/../lib/make-btrfs-fs.nix") {
    storePaths = [ config.system.build.toplevel ];
    compressImage = false;
    volumeLabel = "NIXOS_ROOT";
    uuid = cfg.uuid;
    fakeroot = unshareRoot;
  };

  config.systemd.services.register-nix-paths = {
    description = "Register Nix Store Paths";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/nix-path-registration";
    };
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "nix-daemon.socket"
      "nix-daemon.service"
    ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
      touch /etc/NIXOS
      ${lib.getExe' config.nix.package.out "nix-env"} \
        -p /nix/var/nix/profiles/system --set /run/current-system
      rm -f /nix-path-registration
    '';
  };
}
