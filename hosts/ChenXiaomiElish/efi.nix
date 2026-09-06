{
  config,
  lib,
  ...
}:

let
  buildPkgs = config.hardware.xiaomiElish.buildPkgs;
  espSize = 1000341504;
  espSectors = 244224;
  sectorSize = 4096;
  expectedDtbName = "qcom/sm8250-xiaomi-elish-csot.dtb";
  toplevel = toString config.system.build.toplevel;
  systemdBoot = "${config.systemd.package}/lib/systemd/boot/efi/systemd-bootaa64.efi";

  espImage =
    assert espSize == espSectors * sectorSize;
    buildPkgs.runCommand "ChenXiaomiElish-esp.fat32" {
      nativeBuildInputs = [
        buildPkgs.coreutils
        buildPkgs.dosfstools
        buildPkgs.findutils
        buildPkgs.gnugrep
        buildPkgs.jq
        buildPkgs.libfaketime
        buildPkgs.mtools
      ];
    } ''
      set -euo pipefail
      export LC_ALL=C

      image_size=${toString espSize}
      sector_count=${toString espSectors}
      sector_size=${toString sectorSize}
      expected_dtb_name=${lib.escapeShellArg expectedDtbName}
      toplevel=${lib.escapeShellArg toplevel}
      systemd_boot=${lib.escapeShellArg systemdBoot}
      boot_json="$toplevel/boot.json"

      fail() {
        printf '%s\n' "$1" >&2
        exit 1
      }

      test "$image_size" -eq $((sector_count * sector_size)) || fail "ESP size does not match the sector geometry"
      test -f "$boot_json" || fail "missing toplevel boot.json"
      test -f "$systemd_boot" || fail "missing AA64 systemd-boot binary"

      ${buildPkgs.jq}/bin/jq -e '
        (
          [
            .["org.nixos.bootspec.v1"].toplevel,
            .["org.nixos.bootspec.v1"].kernel,
            .["org.nixos.bootspec.v1"].initrd,
            .["org.nixos.bootspec.v1"].init,
            .["org.nixos.systemd-boot"].devicetree
          ]
          | all(.[]; (type == "string") and (length > 0))
        )
        and (
          .["org.nixos.bootspec.v1"].kernelParams
          | if type == "array" then all(.[]; (type == "string") and (length > 0)) else false end
        )
      ' "$boot_json" > /dev/null || fail "boot.json is missing required boot specification fields"

      toplevel_from_boot_json="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.bootspec.v1".toplevel' "$boot_json" )"
      kernel="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.bootspec.v1".kernel' "$boot_json" )"
      initrd="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.bootspec.v1".initrd' "$boot_json" )"
      init="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.bootspec.v1".init' "$boot_json" )"
      kernel_parameters="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.bootspec.v1".kernelParams | join(" ")' "$boot_json" )"
      devicetree="$( ${buildPkgs.jq}/bin/jq -er '."org.nixos.systemd-boot".devicetree' "$boot_json" )"

      test "$toplevel_from_boot_json" = "$toplevel" || fail "boot.json toplevel does not match the image input"
      test -f "$kernel" || fail "boot.json kernel is missing"
      test -f "$initrd" || fail "boot.json initrd is missing"
      test -e "$init" || fail "boot.json init is missing"
      test -f "$devicetree" || fail "boot.json devicetree is missing"
      resolved_devicetree="$( ${buildPkgs.coreutils}/bin/readlink -f "$devicetree" )"
      case "$resolved_devicetree" in
        /nix/store/*/dtbs/*) ;;
        *) fail "boot.json devicetree is not in a Nix store dtbs directory" ;;
      esac
      dtb_store_relative_path="''${resolved_devicetree#*/dtbs/}"
      test "$dtb_store_relative_path" = "$expected_dtb_name" || fail "boot.json selected an unexpected devicetree"

      canonical_destination() {
        source_path="$( ${buildPkgs.coreutils}/bin/readlink -f "$1" )"
        case "$source_path" in
          /nix/store/*) ;;
          *) fail "boot payload is not in the Nix store" ;;
        esac
        store_path="''${source_path#/nix/store/}"
        store_subdir="''${store_path%%/*}"
        suffix="''${source_path##*/}"
        if [ "$suffix" = "$store_subdir" ]; then
          printf 'EFI/nixos/%s.efi\n' "$suffix"
        else
          printf 'EFI/nixos/%s-%s.efi\n' "$store_subdir" "$suffix"
        fi
      }

      kernel_destination="$(canonical_destination "$kernel")"
      initrd_destination="$(canonical_destination "$initrd")"
      devicetree_destination="$(canonical_destination "$devicetree")"

      test "$kernel_destination" != "$initrd_destination" || fail "kernel and initrd destinations collide"
      test "$kernel_destination" != "$devicetree_destination" || fail "kernel and devicetree destinations collide"
      test "$initrd_destination" != "$devicetree_destination" || fail "initrd and devicetree destinations collide"

      ${buildPkgs.coreutils}/bin/truncate --size="$image_size" "$out"
      ${buildPkgs.dosfstools}/bin/mkfs.vfat -F 32 -S "$sector_size" -s 1 --invariant -i 454c4953 -n NIXOS_ESP "$out"

      ${buildPkgs.coreutils}/bin/install -Dm0644 "$kernel" "contents/$kernel_destination"
      ${buildPkgs.coreutils}/bin/install -Dm0644 "$initrd" "contents/$initrd_destination"
      ${buildPkgs.coreutils}/bin/install -Dm0644 "$devicetree" "contents/$devicetree_destination"
      ${buildPkgs.coreutils}/bin/install -Dm0644 "$systemd_boot" contents/EFI/systemd/systemd-bootaa64.efi
      ${buildPkgs.coreutils}/bin/install -Dm0644 "$systemd_boot" contents/EFI/BOOT/BOOTAA64.EFI
      ${buildPkgs.coreutils}/bin/install -d contents/loader/entries

      ${buildPkgs.coreutils}/bin/cat > contents/loader/loader.conf <<EOF
      timeout 3
      default nixos-generation-1.conf
      editor 0
      console-mode keep
      EOF

      ${buildPkgs.coreutils}/bin/cat > contents/loader/entries/nixos-generation-1.conf <<EOF
      title NixOS
      sort-key nixos
      version Generation 1
      linux /$kernel_destination
      initrd /$initrd_destination
      options init=$init $kernel_parameters
      devicetree /$devicetree_destination
      EOF

      ${buildPkgs.findutils}/bin/find contents -exec ${buildPkgs.coreutils}/bin/touch --date='2000-01-01 00:00:00 UTC' {} +

      while IFS= read -r directory; do
        fat_directory="''${directory#contents/}"
        ${buildPkgs.libfaketime}/bin/faketime '2000-01-01 00:00:00' ${buildPkgs.mtools}/bin/mmd -i "$out" "::/$fat_directory"
      done < <(${buildPkgs.findutils}/bin/find contents -type d -mindepth 1 -print | ${buildPkgs.coreutils}/bin/sort)

      while IFS= read -r file; do
        fat_file="''${file#contents/}"
        ${buildPkgs.mtools}/bin/mcopy -pvm -i "$out" "$file" "::/$fat_file"
      done < <(${buildPkgs.findutils}/bin/find contents -type f -print | ${buildPkgs.coreutils}/bin/sort)

      ${buildPkgs.dosfstools}/bin/fsck.vfat -vn "$out"

      actual_size="$( ${buildPkgs.coreutils}/bin/stat -Lc %s "$out" )"
      test "$actual_size" -eq "$image_size" || fail "ESP image size changed after formatting"

      kernel_size="$( ${buildPkgs.coreutils}/bin/stat -Lc %s "$kernel" )"
      initrd_size="$( ${buildPkgs.coreutils}/bin/stat -Lc %s "$initrd" )"
      devicetree_size="$( ${buildPkgs.coreutils}/bin/stat -Lc %s "$devicetree" )"
      free_bytes="$(
        ${buildPkgs.mtools}/bin/mdir -i "$out" :: \
          | ${buildPkgs.gnugrep}/bin/grep 'bytes free' \
          | ${buildPkgs.coreutils}/bin/tr -cd '0-9'
      )"
      case "$free_bytes" in
        "" | *[!0-9]*) fail "could not determine free space in ESP image" ;;
      esac
      required_free_bytes=$((kernel_size + initrd_size + devicetree_size + 32 * 1024 * 1024))
      test "$free_bytes" -ge "$required_free_bytes" || fail "ESP lacks room for another payload set and 32 MiB"
    '';
in
{
  hardware.deviceTree = {
    enable = true;
    name = expectedDtbName;
  };

  boot.loader = {
    timeout = 3;
    efi = {
      canTouchEfiVariables = false;
      efiSysMountPoint = "/boot";
    };
    systemd-boot = {
      enable = true;
      installDeviceTree = true;
      editor = false;
      consoleMode = "keep";
      configurationLimit = 2;
    };
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_ESP";
    fsType = "vfat";
    options = [
      "nofail"
      "umask=0077"
    ];
  };

  system.build.elishEspImage = espImage;
}
