{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.services.natfrp;
  autoStartTunnelsJson = builtins.toJSON cfg.autoStartTunnels;
  remoteManagementEnabled = if cfg.remoteManagement.enable then "true" else "false";
  startAllTunnelsEnabled = if cfg.startAllTunnels then "true" else "false";
  generateConfig = pkgs.writeShellScript "natfrp-generate-config" ''
    set -eu

    install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${lib.escapeShellArg cfg.workDir}

    token_file=${lib.escapeShellArg cfg.tokenFile}
    if [ ! -f "$token_file" ]; then
      echo "natfrp token file not found: $token_file" >&2
      exit 1
    fi

    token=$(tr -d '\r\n' < "$token_file")
    if [ -z "$token" ]; then
      echo "natfrp token file is empty: $token_file" >&2
      exit 1
    fi

    auto_start_tunnels='${autoStartTunnelsJson}'
    if [ ${startAllTunnelsEnabled} = true ]; then
      tunnels_json=""
      for attempt in 1 2 3 4 5; do
        if tunnels_json=$(${pkgs.curl}/bin/curl -fsSL \
          -H "Authorization: Bearer $token" \
          ${lib.escapeShellArg "${cfg.apiBaseUrl}/tunnels"}); then
          break
        fi

        if [ "$attempt" -eq 5 ]; then
          echo "Failed to fetch natfrp tunnel list after $attempt attempts" >&2
          exit 1
        fi

        sleep "$attempt"
      done

      auto_start_tunnels=$(printf '%s' "$tunnels_json" | ${pkgs.jq}/bin/jq -c 'map(.id)')
    fi

    remote_key=""
    if [ ${remoteManagementEnabled} = true ]; then
      remote_password_file=${lib.escapeShellArg cfg.remoteManagement.passwordFile}
      if [ ! -f "$remote_password_file" ]; then
        echo "natfrp remote password file not found: $remote_password_file" >&2
        exit 1
      fi

      remote_password=$(tr -d '\r\n' < "$remote_password_file")
      if [ -z "$remote_password" ]; then
        echo "natfrp remote password file is empty: $remote_password_file" >&2
        exit 1
      fi

      remote_key=$(${cfg.package}/bin/natfrp-service remote-kdf "$remote_password" | tr -d '\r\n')
    fi

    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT

    ${pkgs.jq}/bin/jq -n \
      --arg token "$token" \
      --arg remoteKey "$remote_key" \
      --argjson autoStartTunnels "$auto_start_tunnels" \
      --argjson remoteManagement ${remoteManagementEnabled} \
      '
        {
          token: $token,
          auto_start_tunnels: $autoStartTunnels,
          update_interval: -1,
          log_stdout: true,
          remote_management: $remoteManagement
        }
        + (if $remoteManagement then { remote_management_key: $remoteKey } else {} end)
      ' > "$tmp"

    install -m 0600 -o ${cfg.user} -g ${cfg.group} "$tmp" ${lib.escapeShellArg cfg.workDir}/config.json
  '';
in
{
  options.services.natfrp = {
    enable = lib.mkEnableOption "SakuraFrp launcher service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.natfrp-service;
      description = "natfrp launcher package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "natfrp";
      description = "System user running natfrp.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "natfrp";
      description = "System group running natfrp.";
    };

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/natfrp";
      description = "Working directory containing natfrp config and runtime data.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/home/chen/nixos-config/secrets/natfrp/token";
      description = "Local file path containing the natfrp access token.";
    };

    tokenSourceFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Source file path containing the natfrp access token. Will be copied to workDir on activation.";
    };

    apiBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api.natfrp.com/v4";
      description = "Base URL for natfrp API used to discover tunnels at runtime.";
    };

    autoStartTunnels = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "Tunnel IDs that natfrp launcher should auto-start after login.";
    };

    startAllTunnels = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If enabled, query the natfrp API at runtime and auto-start all tunnels owned by the configured token.";
    };

    remoteManagement.enable = lib.mkEnableOption "natfrp remote management";

    remoteManagement.passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/home/chen/nixos-config/secrets/natfrp/remote-password";
      description = "Local file path containing the plain-text natfrp remote management password.";
    };

    remoteManagement.passwordSourceFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Source file path containing the plain-text natfrp remote management password. Will be copied to workDir on activation.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.workDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.workDir} 0700 ${cfg.user} ${cfg.group} -"
    ];

    # 声明式管理 secrets：系统激活时自动复制源文件到 workDir
    system.activationScripts.natfrp-secrets = lib.mkIf (cfg.tokenSourceFile != "" || cfg.remoteManagement.passwordSourceFile != "") {
      text = ''
        ${lib.optionalString (cfg.tokenSourceFile != "") ''
          if [ -f "${cfg.tokenSourceFile}" ]; then
            install -D -m 0600 -o ${cfg.user} -g ${cfg.group} "${cfg.tokenSourceFile}" "${cfg.workDir}/token"
          fi
        ''}
        ${lib.optionalString (cfg.remoteManagement.enable && cfg.remoteManagement.passwordSourceFile != "") ''
          if [ -f "${cfg.remoteManagement.passwordSourceFile}" ]; then
            install -D -m 0600 -o ${cfg.user} -g ${cfg.group} "${cfg.remoteManagement.passwordSourceFile}" "${cfg.workDir}/remote-password"
          fi
        ''}
      '';
      deps = [ "users" ];
    };

    systemd.services.natfrp-prepare = {
      description = "Prepare natfrp declarative config";
      wantedBy = [ "natfrp.service" ];
      before = [ "natfrp.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        Environment = [
          "NATFRP_SERVICE_WD=${cfg.workDir}"
          "HOME=${cfg.workDir}"
        ];
      };
      script = ''
        ${generateConfig}
      '';
    };

    systemd.services.natfrp = {
      description = "SakuraFrp Launcher";
      after = [
        "network-online.target"
        "natfrp-prepare.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "natfrp-prepare.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.workDir;
        ExecStart = "${cfg.package}/bin/natfrp-service --daemon";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 20;
        Environment = [
          "NATFRP_SERVICE_WD=${cfg.workDir}"
          "NATFRP_FRPC_PATH=${cfg.package}/bin/frpc"
        ];
      };
    };
  };
}
