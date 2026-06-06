{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.o6n.openwrt;
  containerName = "o6n-openwrt";
  declarativeConfig = import ./openwrt/uci.nix { inherit lib; };

  # distrobuilder 需要 root 权限（chroot/mknod），无法在 Nix 沙盒中运行。
  # 镜像构建在 systemd 阶段完成（o6n-openwrt-ensure.service，以 root 运行）。
  # 首次构建可能需数分钟，已构建后幂等跳过，后续 switch 秒级完成。
  buildImageScript = pkgs.writeShellScriptBin "o6n-openwrt-build-image" ''
    set -eu
    TMP=$(mktemp -d)
    trap "rm -rf $TMP" EXIT
    sed 's/armsr-armv8/aarch64/' ${./openwrt-image.yaml} > "$TMP/o6n-image.yaml"
    ${pkgs.distrobuilder}/bin/distrobuilder build-incus "$TMP/o6n-image.yaml" "$TMP/image" \
      --sources-dir "$TMP/sources" --cache-dir "$TMP/cache"
    ${pkgs.incus}/bin/incus image delete openwrt-custom 2>/dev/null || true
    ${pkgs.incus}/bin/incus image import "$TMP/image/incus.tar.xz" "$TMP/image/rootfs.squashfs" --alias openwrt-custom
    echo "Image imported as openwrt-custom"
  '';

  # 镜像配置哈希：当 image.yaml 或 distrobuilder 版本变更时自动触发重建
  imageConfigHash = builtins.hashString "sha256" (
    builtins.readFile ./openwrt-image.yaml
    + "${pkgs.distrobuilder}"
  );
  imageStampFile = "${secretDir}/.image-config-hash";

  openwrtPluginDir = ./openwrt/plugins;
  openwrtPluginEntries = builtins.readDir openwrtPluginDir;
  openwrtPluginFiles = builtins.mapAttrs (
    name: _: builtins.readFile (openwrtPluginDir + "/${name}")
  ) (lib.filterAttrs (_: type: type == "regular") openwrtPluginEntries);
  openwrtConfigSources = declarativeConfig.files // openwrtPluginFiles;
  openwrtConfigDir = pkgs.runCommandLocal "o6n-openwrt-config" { } (
    "mkdir -p $out\n"
    + lib.concatMapStringsSep "\n" (name: ''
      cat > "$out/${name}" <<'EOF'
      ${openwrtConfigSources.${name}}EOF
    '') (builtins.attrNames openwrtConfigSources)
  );
  secretDir = "/var/lib/o6n-openwrt";
  secretSourceFile = "secrets/o6n-openwrt.env";
  secretFile = "${secretDir}/secrets.env";
  openwrtConfigEntries = builtins.readDir openwrtConfigDir;
  openwrtConfigFiles = builtins.attrNames (
    lib.filterAttrs (_: type: type == "regular") openwrtConfigEntries
  );
  managedConfigManifest = pkgs.writeText "o6n-openwrt-managed-config-files" ''
    ${lib.concatStringsSep "\n" openwrtConfigFiles}
  '';
  pushConfigCommands = lib.concatMapStringsSep "\n" (
    name:
    let
      target = "${containerName}/etc/config/${name}";
    in
    "incus file push \"$render_dir/${name}\" ${lib.escapeShellArg target}"
  ) openwrtConfigFiles;
  renderOpenWrtConfig = pkgs.writeText "o6n-openwrt-render-config.py" ''
    import base64
    import os
    import re
    import stat
    import sys
    from pathlib import Path

    source_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    secret_file = Path(sys.argv[3])
    placeholder = re.compile(r"@@OWRT_SECRET:([A-Z0-9_]+)@@")

    templates = {
        path.name: path.read_text(errors="surrogateescape")
        for path in source_dir.iterdir()
        if path.is_file()
    }
    required = sorted({
        name
        for content in templates.values()
        for name in placeholder.findall(content)
    })

    secrets = {}
    if required:
        if not secret_file.exists():
            print(f"Missing OpenWrt secrets file: {secret_file}", file=sys.stderr)
            print("Required secret keys: " + ", ".join(required), file=sys.stderr)
            sys.exit(1)

        mode = stat.S_IMODE(secret_file.stat().st_mode)
        if mode & 0o077:
            print(f"OpenWrt secrets file must not be readable by group/others: {secret_file}", file=sys.stderr)
            print("Fix with: chmod 600 " + str(secret_file), file=sys.stderr)
            sys.exit(1)

        for line_number, raw in enumerate(secret_file.read_text(errors="surrogateescape").splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                print(f"Invalid OpenWrt secret line {line_number}: expected NAME=value", file=sys.stderr)
                sys.exit(1)
            key, value = line.split("=", 1)
            key = key.strip()
            if not re.fullmatch(r"[A-Z0-9_]+", key):
                print(f"Invalid OpenWrt secret name at line {line_number}: {key}", file=sys.stderr)
                sys.exit(1)
            if value.startswith("base64:"):
                value = base64.b64decode(value[len("base64:"):]).decode()
            secrets[key] = value

    missing = [name for name in required if name not in secrets]
    if missing:
        print("Missing OpenWrt secret keys: " + ", ".join(missing), file=sys.stderr)
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(output_dir, 0o700)

    for name, content in templates.items():
        rendered = placeholder.sub(lambda match: secrets[match.group(1)], content)
        unresolved = sorted(set(placeholder.findall(rendered)))
        if unresolved:
            print(f"Unresolved OpenWrt placeholders in {name}: " + ", ".join(unresolved), file=sys.stderr)
            sys.exit(1)
        target = output_dir / name
        target.write_text(rendered, errors="surrogateescape")
        os.chmod(target, 0o600)
  '';

  cleanupScript = pkgs.writeText "o6n-openwrt-cleanup.sh" ''
    set -eu
    old=/etc/o6n-managed-config-files
    new=/tmp/o6n-managed-config-files

    if [ -f "$old" ]; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in *[!A-Za-z0-9_.-]*) exit 1 ;; esac
        if ! grep -qxF "$name" "$new"; then
          rm -f "/etc/config/$name"
        fi
      done < "$old"
    fi
  '';

  applyScript = pkgs.writeText "o6n-openwrt-apply.sh" ''
    set -eu
    cp /tmp/o6n-managed-config-files /etc/o6n-managed-config-files
    chmod 0600 /etc/o6n-managed-config-files
    /etc/init.d/network restart || /sbin/reload_config || true
  '';

  ensureOpenWrt = pkgs.writeShellApplication {
    name = "o6n-openwrt-ensure";
    runtimeInputs = with pkgs; [
      coreutils
      distrobuilder
      gnugrep
      gnused
      gzip
      incus
      squashfsTools
      xz
    ];
    text = ''
      set -eu
      PATH="$PATH:${pkgs.xz}/bin:${pkgs.gzip}/bin"

      install -d -m 0700 ${secretDir}

      incus_cfg=/root/.config/incus/config.yml
      if [ -f "$incus_cfg" ] && [ ! -s "$incus_cfg" ]; then
        rm -f "$incus_cfg"
      fi

      need_rebuild=0
      if ! incus image list --format csv | grep -q "openwrt-custom"; then
        need_rebuild=1
      elif [ ! -f ${imageStampFile} ] || [ "$(cat ${imageStampFile})" != "${imageConfigHash}" ]; then
        echo "Image configuration changed, rebuilding..." >&2
        need_rebuild=1
      fi

      if [ "$need_rebuild" = 1 ]; then
        echo "Building openwrt-custom image (this may take several minutes)..." >&2
        TMP=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf $TMP" EXIT
        sed 's/armsr-armv8/aarch64/' ${./openwrt-image.yaml} > "$TMP/o6n-image.yaml"
        distrobuilder build-incus "$TMP/o6n-image.yaml" "$TMP/image" \
          --sources-dir "$TMP/sources" --cache-dir "$TMP/cache"
        incus image delete openwrt-custom 2>/dev/null || true
        incus image import "$TMP/image/incus.tar.xz" "$TMP/image/rootfs.squashfs" --alias openwrt-custom
        echo "${imageConfigHash}" > ${imageStampFile}
        echo "Image imported as openwrt-custom" >&2
      fi

      if ! incus info ${containerName} >/dev/null 2>&1; then
        incus launch openwrt-custom ${containerName} --profile o6n-openwrt
      fi

      incus config set ${containerName} boot.autostart true

      if ! incus info ${containerName} | grep -q '^Status: RUNNING$'; then
        incus start ${containerName} || true
      fi
    '';
  };
  reconcileOpenWrt = pkgs.writeShellApplication {
    name = "o6n-openwrt-reconcile";
    runtimeInputs = with pkgs; [
      coreutils
      incus
      python3
    ];
    text = ''
      set -eu
      umask 077

      render_dir="$(mktemp -d /run/o6n-openwrt-rendered.XXXXXX)"
      cleanup() {
        rm -rf "$render_dir"
      }
      trap cleanup EXIT

      if [ -f ${secretSourceFile} ]; then
        install -d -m 0700 ${secretDir}
        install -m 0600 ${secretSourceFile} ${secretFile}
      fi

      python3 ${renderOpenWrtConfig} ${openwrtConfigDir} "$render_dir" ${secretFile}

      ${ensureOpenWrt}/bin/o6n-openwrt-ensure
      incus file push ${cleanupScript} ${containerName}/tmp/o6n-cleanup.sh
      incus file push ${applyScript} ${containerName}/tmp/o6n-apply.sh
      incus file push ${managedConfigManifest} ${containerName}/tmp/o6n-managed-config-files

      incus exec ${containerName} -- sh /tmp/o6n-cleanup.sh

      ${pushConfigCommands}

      incus exec ${containerName} -- sh /tmp/o6n-apply.sh
    '';
  };
in
{
  virtualisation.incus = {
    enable = true;
    preseed = {
      storage_pools = [
        {
          name = "o6n-openwrt";
          driver = "dir";
        }
      ];
      networks = [ ];
      profiles = [
        {
          name = "o6n-openwrt";
          config = {
            "security.privileged" = "true";
            "raw.lxc" = "lxc.cap.drop=";
          };
          devices = {
            root = {
              type = "disk";
              path = "/";
              pool = "o6n-openwrt";
            };
            ppp = {
              type = "unix-char";
              path = "/dev/ppp";
            };
          }
          // {
            eth0 = {
              type = "nic";
              name = "eth0";
              nictype = "bridged";
              parent = cfg.lanBridge;
            };
            eth1 = {
              type = "nic";
              name = "eth1";
              nictype = "bridged";
              parent = cfg.wanBridge;
              hwaddr = "88:c3:97:9b:92:03";
            };
          };
        }
      ];
    };
  };

  networking.nftables.enable = true;

  environment.systemPackages = [
    ensureOpenWrt
    reconcileOpenWrt
  ];

  systemd.tmpfiles.rules = [
    "d ${secretDir} 0700 root root -"
  ];

  systemd.services.o6n-openwrt-ensure = {
    description = "Ensure the O6N OpenWrt Incus container exists";
    wantedBy = [ "multi-user.target" ];
    after = [
      "incus.service"
      "incus-preseed.service"
      "network-online.target"
    ];
    wants = [
      "incus-preseed.service"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ensureOpenWrt}/bin/o6n-openwrt-ensure";
      RemainAfterExit = true;
      TimeoutStartSec = 900;
    };
  };

  systemd.services.o6n-openwrt-reconcile = {
    description = "Replay Nix-owned OpenWrt UCI settings into the O6N container";
    wantedBy = [ "multi-user.target" ];
    after = [ "o6n-openwrt-ensure.service" ];
    requires = [ "o6n-openwrt-ensure.service" ];
    restartTriggers = [ openwrtConfigDir ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${reconcileOpenWrt}/bin/o6n-openwrt-reconcile";
      WorkingDirectory = "/etc/nixos";
      UMask = "0077";
    };
  };
}
