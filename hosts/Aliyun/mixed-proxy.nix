{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mixed-proxy;
  acmeDomain = "chenjaly.cn";
  certDirectory = config.security.acme.certs.${acmeDomain}.directory;
  configFile = (pkgs.formats.json { }).generate "mixed-proxy.json" {
    listen = "0.0.0.0:8443";
    tls = {
      certFile = "${certDirectory}/fullchain.pem";
      keyFile = "${certDirectory}/key.pem";
    };
    udp = {
      publicAddress = cfg.publicUdpAddress;
      portRange = {
        from = cfg.udpPortRange.from;
        to = cfg.udpPortRange.to;
      };
    };
  };
in
{
  options.services.mixed-proxy = {
    publicUdpAddress = lib.mkOption {
      type = lib.types.str;
      default = "47.254.74.103";
      description = "Public address advertised in SOCKS5 UDP association replies.";
    };
    udpPortRange = {
      from = lib.mkOption {
        type = lib.types.port;
        default = 20000;
        description = "First port available for SOCKS5 UDP associations.";
      };
      to = lib.mkOption {
        type = lib.types.port;
        default = 20127;
        description = "Last port available for SOCKS5 UDP associations.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.udpPortRange.from <= cfg.udpPortRange.to;
        message = "services.mixed-proxy.udpPortRange.from must not exceed udpPortRange.to.";
      }
    ];

    environment.etc."mixed-proxy/config.json".source = configFile;

    security.acme.certs.${acmeDomain}.reloadServices = [ "mixed-proxy" ];

    security.pam.services.mixed-proxy.text = ''
      auth required ${pkgs.pam}/lib/security/pam_unix.so noreap
      account required ${pkgs.pam}/lib/security/pam_permit.so
    '';

    systemd.services.mixed-proxy = {
      description = "Authenticated HTTPS and SOCKS5 TCP/UDP forward proxy";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "acme-${acmeDomain}.service"
      ];
      wants = [ "acme-order-renew-${acmeDomain}.service" ];
      after = [
        "acme-${acmeDomain}.service"
        "acme-order-renew-${acmeDomain}.service"
      ];
      restartTriggers = [ configFile ];
      serviceConfig = {
        User = "chen";
        SupplementaryGroups = [ "nginx" ];
        NoNewPrivileges = false;
        PrivateUsers = false;
        RestrictSUIDSGID = false;
        DynamicUser = false;
        TimeoutStopSec = "15s";
        KillMode = "control-group";
        SendSIGKILL = true;
        ExecStart = "${pkgs.mixed-proxy-rs}/bin/mixed-proxy --config /etc/mixed-proxy/config.json";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

  };
}
