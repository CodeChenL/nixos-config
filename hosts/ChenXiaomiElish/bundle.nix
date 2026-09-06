{
  config,
  lib,
  pkgs,
  ...
}:

let
  buildPkgs = config.hardware.xiaomiElish.buildPkgs;
  ablBootImages = config.system.build.ablBootImages;
  espImage = config.system.build.elishEspImage;
  espName = "ChenXiaomiElish-esp.fat32";
  espByteSize = "1000341504";
  espLabel = "NIXOS_ESP";
  csotDtb = "qcom/sm8250-xiaomi-elish-csot.dtb";
  rootfsImage = config.system.build.elishRootfsImage;
  rootfsName = "ChenXiaomiElish-rootfs.btrfs";
  bootJson = "${config.system.build.toplevel}/boot.json";
  systemdBootEfi = "${config.systemd.package}/lib/systemd/boot/efi/systemd-bootaa64.efi";
  bootImageNames = [
    "boot-a-boe.img"
    "boot-a-csot.img"
    "boot-b-boe.img"
    "boot-b-csot.img"
  ];
  checksumNames = [
    "BUILD-INFO.txt"
    espName
    rootfsName
  ] ++ bootImageNames;
in
assert builtins.length checksumNames == 7;
assert builtins.length (lib.unique checksumNames) == 7;
{
  options.hardware.xiaomiElish.buildPkgs = lib.mkOption {
    type = lib.types.pkgs;
    default = pkgs.buildPackages;
    defaultText = lib.literalExpression "pkgs.buildPackages";
    description = ''
      Native packages for ESP, rootfs, bundle and ABL image assembly. Defaults
      to the declared Nixpkgs build platform, not the evaluating machine.
      Override with a native package set for an external assembler; target
      kernel, initrd, device trees and systemd-boot remain unchanged.
    '';
  };

  config.system.build.elishBundle = buildPkgs.runCommand "chen-xiaomi-elish-bundle" { } ''
    set -eu

    ${buildPkgs.coreutils}/bin/mkdir -p "$out"
    ${buildPkgs.coreutils}/bin/ln -s ${lib.escapeShellArg espImage} "$out/${espName}"
    ${buildPkgs.coreutils}/bin/ln -s ${lib.escapeShellArg rootfsImage} "$out/${rootfsName}"
    ${lib.concatMapStringsSep "\n" (name: ''
      ${buildPkgs.coreutils}/bin/ln -s ${lib.escapeShellArg "${ablBootImages}/${name}"} "$out/${name}"
    '') bootImageNames}

    ${buildPkgs.coreutils}/bin/cat > "$out/BUILD-INFO.txt" <<'EOF'
    Hostname: ${config.networking.hostName}
    Target architecture: ${pkgs.stdenv.hostPlatform.system}
    Bundle assembly architecture: ${buildPkgs.stdenv.hostPlatform.system}
    ESP filename: ${espName}
    ESP byte size: ${espByteSize}
    ESP label: ${espLabel}
    ESP store path: ${espImage}
    Device tree: ${csotDtb}
    Systemd-boot source path: ${systemdBootEfi}
    Btrfs label: NIXOS_ROOT
    Btrfs UUID: ${config.hardware.xiaomiElish.rootfs.uuid}
    Nix toplevel store path: ${config.system.build.toplevel}
    Nix boot.json path: ${bootJson}
    Nix kernel store path: ${config.system.build.kernel}
    Btrfs rootfs store path: ${rootfsImage}
    ABL boot images store path: ${ablBootImages}
    Flashing performed: no
    EOF

    (
      cd "$out"
      ${buildPkgs.coreutils}/bin/sha256sum ${lib.concatStringsSep " " checksumNames} > SHA256SUMS
      ${buildPkgs.coreutils}/bin/test "$( ${buildPkgs.coreutils}/bin/wc -l < SHA256SUMS )" -eq 7
    )
  '';
}
