{ pkgs, ... }:

let
  acmeDomain = "chenjaly.cn";
  dnsZone = "acme.chenjaly.cn";
  tsigName = "acme-update";
  stateDir = "/var/lib/acme-dns";
  tsigSecretFile = "${stateDir}/tsig-secret";
  knotKeyFile = "${stateDir}/knot-key.conf";
  acmeEnvironmentFile = "${stateDir}/acme.env";

  zoneStore = pkgs.writeTextDir "${dnsZone}.zone" ''
    $ORIGIN ${dnsZone}.
    $TTL 300
    @ IN SOA acme-ns.chenjaly.cn. chenjiali.radxa.com. (
      2026093001 3600 600 604800 300
    )
    @ IN NS acme-ns.chenjaly.cn.
  '';

  setupScript = pkgs.writeShellScript "acme-dns-setup" ''
    set -euo pipefail

    ${pkgs.coreutils}/bin/install -d -m 0711 -o root -g root ${stateDir}

    if [ ! -s ${tsigSecretFile} ]; then
      secret_tmp=$(${pkgs.coreutils}/bin/mktemp ${stateDir}/.tsig-secret.XXXXXX)
      ${pkgs.openssl}/bin/openssl rand -base64 32 \
        | ${pkgs.coreutils}/bin/tr -d '\n' > "$secret_tmp"
      printf '\n' >> "$secret_tmp"
      ${pkgs.coreutils}/bin/chown root:root "$secret_tmp"
      ${pkgs.coreutils}/bin/chmod 0600 "$secret_tmp"
      ${pkgs.coreutils}/bin/mv "$secret_tmp" ${tsigSecretFile}
    fi

    secret=$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${tsigSecretFile})
    umask 077

    knot_tmp=$(${pkgs.coreutils}/bin/mktemp ${stateDir}/.knot-key.XXXXXX)
    printf '%s\n' \
      'key:' \
      '  - id: ${tsigName}' \
      '    algorithm: hmac-sha256' \
      "    secret: $secret" > "$knot_tmp"
    ${pkgs.coreutils}/bin/chown knot:knot "$knot_tmp"
    ${pkgs.coreutils}/bin/chmod 0600 "$knot_tmp"
    ${pkgs.coreutils}/bin/mv "$knot_tmp" ${knotKeyFile}

    env_tmp=$(${pkgs.coreutils}/bin/mktemp ${stateDir}/.acme-env.XXXXXX)
    printf '%s\n' \
      'DNSUPDATE_NAMESERVER=127.0.0.1:53' \
      'DNSUPDATE_TSIG_KEY=${tsigName}' \
      "DNSUPDATE_TSIG_SECRET=$secret" \
      'DNSUPDATE_TSIG_ALGORITHM=hmac-sha256' > "$env_tmp"
    ${pkgs.coreutils}/bin/chown root:root "$env_tmp"
    ${pkgs.coreutils}/bin/chmod 0600 "$env_tmp"
    ${pkgs.coreutils}/bin/mv "$env_tmp" ${acmeEnvironmentFile}
  '';

  proxyStreamSettings = ''
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    send_timeout 3600s;
  '';
in
{
  systemd.services.acme-dns-setup = {
    description = "Set up local RFC2136 credentials for ACME";
    before = [
      "knot.service"
      "acme-order-renew-${acmeDomain}.service"
    ];
    requiredBy = [
      "knot.service"
      "acme-order-renew-${acmeDomain}.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setupScript;
    };
  };

  services.knot = {
    enable = true;
    keyFiles = [ knotKeyFile ];
    settings = {
      server.listen = [ "0.0.0.0@53" ];
      server.identity = "unknown";
      server.version = "unknown";

      acl.${tsigName} = {
        address = "127.0.0.1";
        key = tsigName;
        action = "update";
        update-type = [ "TXT" ];
      };

      template.default = {
        storage = zoneStore;
        acl = [ tsigName ];
        zonefile-sync = -1;
        zonefile-load = "difference-no-serial";
        journal-content = "all";
        zonefile-skip = [ "TXT" ];
      };

      zone.${dnsZone}.file = "${dnsZone}.zone";
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "chenjiali@radxa.com";
    certs.${acmeDomain} = {
      domain = acmeDomain;
      extraDomainNames = [ "*.${acmeDomain}" ];
      dnsProvider = "rfc2136";
      dnsPropagationCheck = true;
      environmentFile = acmeEnvironmentFile;
      group = "nginx";
      reloadServices = [ "nginx" ];
    };
  };

  systemd.services."acme-order-renew-${acmeDomain}" = {
    after = [ "knot.service" ];
    requires = [ "knot.service" ];
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."api.${acmeDomain}" = {
      useACMEHost = acmeDomain;
      forceSSL = true;
      locations = {
        "= /kiro".return = "302 /kiro/admin";
        "= /kiro/".return = "302 /kiro/admin";
        "= /kiro/admin/".return = "302 /kiro/admin";

        "/kiro/" = {
          proxyPass = "http://127.0.0.1:8990/";
          extraConfig = proxyStreamSettings + ''
            proxy_set_header Accept-Encoding "";
            sub_filter_types text/javascript application/javascript;
            sub_filter_once off;
            sub_filter '"/admin/' '"/kiro/admin/';
            sub_filter '"/api/admin"' '"/kiro/api/admin"';
          '';
        };

        "/" = {
          proxyPass = "http://127.0.0.1:8080";
          extraConfig = proxyStreamSettings;
        };
      };
    };
  };
}
