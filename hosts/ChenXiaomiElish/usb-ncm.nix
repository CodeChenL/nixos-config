{ lib, pkgs, ... }:

let
  usbNcm = pkgs.writeShellApplication {
    name = "xiaomi-elish-usb-ncm";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
    ];
    text = ''
      gadget=/sys/kernel/config/usb_gadget/g1
      udc=a600000.usb
      udc_path=/sys/class/udc/$udc
      function=ncm.usb0
      configuration=c.1

      teardown() {
        if [[ ! -d "$gadget" ]]; then
          return
        fi

        printf '\n' > "$gadget/UDC"

        if [[ -L "$gadget/configs/$configuration/$function" ]]; then
          rm "$gadget/configs/$configuration/$function"
        fi
        if [[ -d "$gadget/configs/$configuration/strings/0x409" ]]; then
          rmdir "$gadget/configs/$configuration/strings/0x409"
        fi
        if [[ -d "$gadget/configs/$configuration" ]]; then
          rmdir "$gadget/configs/$configuration"
        fi
        if [[ -d "$gadget/functions/$function" ]]; then
          rmdir "$gadget/functions/$function"
        fi
        if [[ -d "$gadget/strings/0x409" ]]; then
          rmdir "$gadget/strings/0x409"
        fi
        rmdir "$gadget"
      }

      setup() {
        if [[ ! -e "$udc_path" ]]; then
          printf 'Required USB device controller %s is absent\n' "$udc" >&2
          return 1
        fi
        if [[ -e "$gadget" ]]; then
          printf 'USB gadget path already exists: %s\n' "$gadget" >&2
          return 1
        fi

        mkdir "$gadget"
        trap teardown ERR

        printf '0x1d6b\n' > "$gadget/idVendor"
        printf '0x0103\n' > "$gadget/idProduct"
        printf '0x0100\n' > "$gadget/bcdDevice"
        printf '0x0201\n' > "$gadget/bcdUSB"

        mkdir "$gadget/strings/0x409"
        printf 'NixOS\n' > "$gadget/strings/0x409/manufacturer"
        printf '0123456789\n' > "$gadget/strings/0x409/serialnumber"
        printf 'ChenXiaomiElish NCM\n' > "$gadget/strings/0x409/product"

        mkdir "$gadget/functions/$function"
        printf '4a:af:b8:f3:1b:32\n' > "$gadget/functions/$function/dev_addr"
        printf 'ce:b6:f0:69:11:02\n' > "$gadget/functions/$function/host_addr"

        mkdir "$gadget/configs/$configuration"
        printf '250\n' > "$gadget/configs/$configuration/MaxPower"
        mkdir "$gadget/configs/$configuration/strings/0x409"
        printf 'NCM Configuration\n' > "$gadget/configs/$configuration/strings/0x409/configuration"
        ln -s "$gadget/functions/$function" "$gadget/configs/$configuration/$function"

        printf '%s\n' "$udc" > "$gadget/UDC"

        for _ in {1..50}; do
          if [[ -e /sys/class/net/usb0 ]]; then
            ip address replace 172.18.42.1/24 dev usb0
            ip link set dev usb0 up
            trap - ERR
            return
          fi
          sleep 0.1
        done

        printf 'USB network interface usb0 did not appear within 5 seconds\n' >&2
        return 1
      }

      case "''${1:-}" in
        start)
          setup
          ;;
        stop)
          teardown
          ;;
        *)
          printf 'Usage: %s {start|stop}\n' "$0" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  networking = {
    networkmanager.unmanaged = [ "interface-name:usb0" ];
    firewall.interfaces.usb0 = {
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 67 ];
    };
  };

  services = {
    dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        interface = "usb0";
        bind-dynamic = true;
        port = 0;
        dhcp-authoritative = true;
        dhcp-lease-max = 1;
        dhcp-range = [ "172.18.42.2,172.18.42.2,255.255.255.0,1h" ];
        dhcp-option = [
          "option:router"
          "option:dns-server"
        ];
      };
    };

    openssh.openFirewall = false;
  };

  systemd.services = {
    usb-ncm-gadget = {
      description = "Xiaomi Elish USB NCM recovery gadget";
      wantedBy = [ "multi-user.target" ];
      requires = [ "sys-kernel-config.mount" ];
      unitConfig.RequiresMountsFor = [ "/sys/kernel/config" ];
      after = [
        "systemd-modules-load.service"
        "sys-kernel-config.mount"
      ];
      before = [
        "dnsmasq.service"
        "sshd.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe usbNcm} start";
        ExecStop = "${lib.getExe usbNcm} stop";
      };
    };

    dnsmasq = {
      requires = [ "usb-ncm-gadget.service" ];
      after = [ "usb-ncm-gadget.service" ];
    };

    sshd = {
      # 只保持启动顺序；gadget 失败时不能连带阻止恢复用的 sshd 启动。
      requires = lib.mkForce [ ];
      after = [ "usb-ncm-gadget.service" ];
    };
  };
}
