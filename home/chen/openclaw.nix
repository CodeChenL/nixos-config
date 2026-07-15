{ config, pkgs, ... }:

let
  openclawPackage = pkgs.master.openclaw;
  openclawStateDir = "${config.home.homeDirectory}/.openclaw";
  secretsDir = "${config.home.homeDirectory}/nixos-config/secrets";
  minimaxApiKey = {
    source = "file";
    provider = "minimax";
    id = "/";
  };
  gatewayToken = {
    source = "file";
    provider = "gateway-token";
    id = "/";
  };
in

{
  home.packages = [ openclawPackage ];

  home.file.".openclaw/openclaw.json".text = builtins.toJSON {
    meta.managedBy = "home-manager";

    secrets = {
      providers = {
        minimax = {
          source = "file";
          path = "${secretsDir}/opencode/minimax.key";
          mode = "singleValue";
        };
        gateway-token = {
          source = "file";
          path = "${secretsDir}/openclaw/gateway-token";
          mode = "singleValue";
        };
      };
      defaults.file = "minimax";
    };

    gateway = {
      mode = "local";
      bind = "lan";
      port = 18789;
      auth = {
        mode = "token";
        token = gatewayToken;
      };
      controlUi.allowedOrigins = [
        "http://localhost:18789"
        "http://127.0.0.1:18789"
      ];
      nodes.denyCommands = [
        "camera.snap"
        "camera.clip"
        "screen.record"
        "contacts.add"
        "calendar.add"
        "reminders.add"
        "sms.send"
      ];
      tailscale = {
        mode = "off";
        resetOnExit = false;
      };
    };

    models = {
      mode = "merge";
      providers.minimax-cn = {
        api = "anthropic-messages";
        apiKey = minimaxApiKey;
        baseUrl = "https://api.minimaxi.com/anthropic";
        models = [
          {
            id = "MiniMax-M2.7";
            name = "MiniMax M2.7";
            contextWindow = 200000;
            input = [ "text" ];
            reasoning = true;
            cost = {
              input = 0.3;
              output = 1.2;
              cacheRead = 0.03;
              cacheWrite = 0.12;
            };
          }
        ];
      };
    };

    agents.defaults = {
      workspace = "${openclawStateDir}/workspace";
      model = {
        primary = "minimax-cn/MiniMax-M2.7";
        fallbacks = [ "minimax-cn/MiniMax-M2.7" ];
      };
      models."minimax-cn/MiniMax-M2.7".alias = "Minimax";
    };

    plugins = {
      entries.feishu = {
        enabled = true;
        config = { };
      };
      load.paths = [ ];
    };
  };

  systemd.user.services.openclaw-gateway = {
    Unit = {
      Description = "OpenClaw Gateway";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      StartLimitBurst = 5;
      StartLimitIntervalSec = 60;
    };

    Service = {
      ExecStart = "${openclawPackage}/bin/openclaw gateway";
      Restart = "always";
      RestartSec = 5;
      RestartPreventExitStatus = 78;
      TimeoutStopSec = 30;
      TimeoutStartSec = 30;
      SuccessExitStatus = "0 143";
      KillMode = "control-group";
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "TMPDIR=/tmp"
        "OPENCLAW_HOME=${openclawStateDir}"
        "OPENCLAW_CONFIG_PATH=${openclawStateDir}/openclaw.json"
        "OPENCLAW_GATEWAY_PORT=18789"
        "OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service"
        "OPENCLAW_SERVICE_MARKER=openclaw"
        "OPENCLAW_SERVICE_KIND=gateway"
      ];
    };

    Install.WantedBy = [ "default.target" ];
  };
}
