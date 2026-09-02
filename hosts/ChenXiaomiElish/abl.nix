{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.xiaomiElish.abl;
  kernel = config.system.build.kernel;
  kernelImage = "${kernel}/${config.system.boot.loader.kernelFile}";
  initialRamdisk = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  dtbDirectory = "${kernel}/dtbs/qcom";
  kernelCommandLineFor = slot: lib.concatStringsSep " " (
    [
      "slot_suffix=${slot}"
      "init=${config.system.build.toplevel}/init"
    ]
    ++ config.boot.kernelParams
    ++ cfg.extraKernelArgs
  );
in
{
  options.hardware.xiaomiElish.abl = {
    extraKernelArgs = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching ''([^"[:space:]]|"[^"]*")+'');
      default = [ ];
      description = "Additional arguments appended to the ABL kernel command line.";
    };
  };

  config.system.build.ablBootImages = pkgs.runCommand "xiaomi-elish-abl-boot-images" { } ''
    set -eu

    kernel_image=${lib.escapeShellArg kernelImage}
    initial_ramdisk=${lib.escapeShellArg initialRamdisk}
    dtb_directory=${lib.escapeShellArg dtbDirectory}

    test -f "$kernel_image"
    test -f "$initial_ramdisk"
    test -f "$dtb_directory/sm8250-xiaomi-elish-boe.dtb"
    test -f "$dtb_directory/sm8250-xiaomi-elish-csot.dtb"

    mkdir -p "$out"
    ${pkgs.gzip}/bin/gzip -n -c "$kernel_image" > Image.gz

    build_image() {
      panel="$1"
      output_name="$2"
      command_line="$3"
      dtb="$dtb_directory/sm8250-xiaomi-elish-''${panel}.dtb"
      combined_kernel="Image.gz-''${panel}"
      cat Image.gz "$dtb" > "$combined_kernel"

      ${pkgs.mkbootimg-osm0sis}/bin/mkbootimg \
        --kernel "$combined_kernel" \
        --ramdisk "$initial_ramdisk" \
        --base 0x0 \
        --second_offset 0x00f00000 \
        --cmdline "$command_line" \
        --kernel_offset 0x8000 \
        --ramdisk_offset 0x1000000 \
        --tags_offset 0x100 \
        --pagesize 4096 \
        -o "$out/$output_name"
    }

    build_image boe boot-a-boe.img ${lib.escapeShellArg (kernelCommandLineFor "_a")}
    build_image csot boot-a-csot.img ${lib.escapeShellArg (kernelCommandLineFor "_a")}
    build_image boe boot-b-boe.img ${lib.escapeShellArg (kernelCommandLineFor "_b")}
    build_image csot boot-b-csot.img ${lib.escapeShellArg (kernelCommandLineFor "_b")}
  '';
}
