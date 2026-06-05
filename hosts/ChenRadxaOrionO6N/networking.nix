{ lib, config, ... }:

let
  cfg = config.o6n.openwrt;
in
{
  options.o6n.openwrt = {
    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp1s0";
    };

    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp49s0";
    };

    wanBridge = lib.mkOption {
      type = lib.types.str;
      default = "vmbr0";
    };

    lanBridge = lib.mkOption {
      type = lib.types.str;
      default = "vmbr1";
    };

    lanHostAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.33.100";
    };

    lanPrefixLength = lib.mkOption {
      type = lib.types.int;
      default = 24;
    };

    lanGateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.33.1";
    };
  };

  config = {
    networking.useDHCP = false;

    networking.bridges."${cfg.wanBridge}".interfaces = [ cfg.wanInterface ];
    networking.bridges."${cfg.lanBridge}".interfaces = [ cfg.lanInterface ];

    networking.interfaces."${cfg.wanInterface}".useDHCP = false;
    networking.interfaces."${cfg.lanInterface}".useDHCP = false;
    networking.interfaces."${cfg.wanBridge}".useDHCP = false;

    networking.interfaces."${cfg.lanBridge}" = {
      useDHCP = true;
      ipv4.addresses = [
        {
          address = cfg.lanHostAddress;
          prefixLength = cfg.lanPrefixLength;
        }
      ];
    };

    networking.defaultGateway = {
      address = cfg.lanGateway;
      interface = cfg.lanBridge;
    };
  };
}
