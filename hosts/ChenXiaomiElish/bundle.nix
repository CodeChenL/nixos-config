{
  config,
  lib,
  pkgs,
  ...
}:

let
  ablBootImages = config.system.build.ablBootImages;
  rootfsImage = config.system.build.elishRootfsImage;
  rootfsName = "ChenXiaomiElish-rootfs.btrfs";
  bootImageNames = [
    "boot-a-boe.img"
    "boot-a-csot.img"
    "boot-b-boe.img"
    "boot-b-csot.img"
  ];
in
{
  config.system.build.elishBundle = pkgs.runCommand "chen-xiaomi-elish-bundle" { } ''
    set -eu

    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg rootfsImage} "$out/${rootfsName}"
    ${lib.concatMapStringsSep "\n" (name: ''
      ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg "${ablBootImages}/${name}"} "$out/${name}"
    '') bootImageNames}

    ${pkgs.coreutils}/bin/cat > "$out/BUILD-INFO.txt" <<'EOF'
    Hostname: ${config.networking.hostName}
    Architecture: ${pkgs.stdenv.hostPlatform.system}
    Btrfs label: NIXOS_ROOT
    Btrfs UUID: ${config.hardware.xiaomiElish.rootfs.uuid}
    Nix toplevel store path: ${config.system.build.toplevel}
    Nix kernel store path: ${config.system.build.kernel}
    Btrfs rootfs store path: ${rootfsImage}
    ABL boot images store path: ${ablBootImages}
    Flashing performed: no
    EOF

    (
      cd "$out"
      ${pkgs.coreutils}/bin/sha256sum \
        BUILD-INFO.txt \
        ${rootfsName} \
        ${lib.concatStringsSep " " bootImageNames} \
        > SHA256SUMS
    )
  '';
}
