{ config, pkgs, lib, ... }:

# kiro-rs：Anthropic Claude API ⇄ Kiro API 反代，把 Kiro 订阅暴露为
# Anthropic 兼容端点（/v1/messages、/v1/models）。
#
# 凭据（不进 Nix store，运行时位于 /var/lib/kiro-rs；secrets 目录仅作**首次种子**，
# 之后 token 刷新回写与 /admin 在线修改都以运行时文件为准）：
#   - 可选种子：~/nixos-config/secrets/kiro-rs/credentials.json
#     Kiro OAuth 凭据（refreshToken/expiresAt/authMethod，可从 Kiro IDE 提取，
#     支持单对象或多凭据数组格式；服务启动后自动刷新并回写）。无种子时以空
#     凭据集启动，凭据经 /admin 在线录入（支持 social 登录流程）。
#   - 可选种子：~/nixos-config/secrets/kiro-rs/api-key
#     客户端调用本反代时的 x-api-key；缺省时 setup 自动生成随机值
#   - 管理密钥：复用 ~/nixos-config/secrets/sub2api/admin-password（与 sub2api
#     共享管理口令）。/admin Web UI 与 /api/admin/* 凭据在线管理（增删/禁用/
#     优先级/失败计数/余额）由它鉴权；kiro.rs 管理面为单密钥认证、无用户名。
#
# 安全边界：listenHost 0.0.0.0 + host/firewall 按 Aliyun 主机约定由安全组控制；
# 服务强制 apiKey 鉴权（x-api-key / Bearer）。管理面同密钥，安全组应限制
# /admin 与 /api/admin/* 的来源。
let
  cfg = config.services.kiro-rs;
  package = pkgs.kiro-rs;
  secretSourceDir = "${config.users.users.chen.home}/nixos-config/secrets/kiro-rs";
  credentialsSourceFile = "${secretSourceDir}/credentials.json";
  apiKeySourceFile = "${secretSourceDir}/api-key";
  # 管理密钥复用 sub2api 的 admin-password（两服务共享管理口令）
  adminPasswordSourceFile = "${config.users.users.chen.home}/nixos-config/secrets/sub2api/admin-password";
  stateDir = "/var/lib/kiro-rs";

  ownershipRepair = pkgs.writeShellScript "kiro-rs-ownership-repair" ''
    set -euo pipefail
    for name in credentials.json api-key; do
      path="${stateDir}/$name"
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        ${pkgs.coreutils}/bin/chown --no-dereference kiro-rs:kiro-rs "$path" 2>/dev/null || true
      fi
    done
    ${pkgs.coreutils}/bin/chown kiro-rs:kiro-rs ${stateDir} 2>/dev/null || true
    ${pkgs.coreutils}/bin/chmod 0700 ${stateDir} 2>/dev/null || true
  '';

  setupScript = pkgs.writeShellScript "kiro-rs-setup" ''
    set -euo pipefail
    umask 077

    CRED_DIR=''${CREDENTIALS_DIRECTORY:?missing credentials directory}

    # Reject symlinks and non-regular files for runtime state (defense-in-depth;
    # privilege boundary is enforced by service UID + non-following ownership repair).
    for target in credentials.json api-key config.json; do
      if [ -L "${stateDir}/$target" ] || { [ -e "${stateDir}/$target" ] && [ ! -f "${stateDir}/$target" ]; }; then
        echo "$target is not a regular file" >&2
        exit 1
      fi
    done

    # credentials.json 仅作首次种子：运行期 token 刷新会回写此文件，/admin 在线
    # 管理同样改它；覆盖会毁掉已刷新凭据。更新请直接改运行时文件，或删除后重启。
    if [ ! -s ${stateDir}/credentials.json ]; then
      if [ -s "$CRED_DIR/credentials-seed" ] && [ "$(cat "$CRED_DIR/credentials-seed")" != "_" ]; then
        tmp=$(mktemp ${stateDir}/.credentials.XXXXXX)
        trap 'rm -f "$tmp"' EXIT
        cp "$CRED_DIR/credentials-seed" "$tmp"
        chmod 600 "$tmp"
        mv -T "$tmp" ${stateDir}/credentials.json
        trap - EXIT
      else
        printf '[]\n' > ${stateDir}/credentials.json
      fi
    fi

    # 客户端 apiKey 同样仅首次种子（保护运行时状态）
    if [ ! -s ${stateDir}/api-key ]; then
      if [ -s "$CRED_DIR/api-key-seed" ] && [ "$(cat "$CRED_DIR/api-key-seed")" != "_" ]; then
        tmp=$(mktemp ${stateDir}/.api-key.XXXXXX)
        trap 'rm -f "$tmp"' EXIT
        cp "$CRED_DIR/api-key-seed" "$tmp"
        chmod 600 "$tmp"
        mv -T "$tmp" ${stateDir}/api-key
        trap - EXIT
      else
        ${pkgs.openssl}/bin/openssl rand -hex 24 > ${stateDir}/api-key
        chmod 600 ${stateDir}/api-key
      fi
    fi

    # 管理密钥复用 sub2api 的 admin-password（kiro.rs 管理面是单密钥认证、
    # 无用户名概念，常量时间比较 x-api-key/Bearer）。每次 setup 运行时重新读取；
    # setup 是 RemainAfterExit oneshot，轮换后须 `systemctl restart kiro-rs-setup kiro-rs`。
    if [ ! -s "$CRED_DIR/admin-password" ] || [ "$(cat "$CRED_DIR/admin-password")" = "_" ]; then
      echo "sub2api admin password source is missing or empty" >&2
      exit 1
    fi
    config_tmp=$(mktemp ${stateDir}/.config.XXXXXX)
    trap 'rm -f "$config_tmp"' EXIT
    ${pkgs.jq}/bin/jq -n \
      --arg host ${lib.escapeShellArg cfg.listenHost} \
      --argjson port ${toString cfg.port} \
      --rawfile apiKey ${stateDir}/api-key \
      --rawfile adminApiKey "$CRED_DIR/admin-password" \
      --arg region ${lib.escapeShellArg cfg.region} \
      --arg tlsBackend ${lib.escapeShellArg cfg.tlsBackend} \
      --arg proxyUrl ${lib.escapeShellArg (if cfg.proxyUrl == null then "" else cfg.proxyUrl)} \
      --arg kiroVersion ${lib.escapeShellArg (if cfg.kiroVersion == null then "" else cfg.kiroVersion)} \
      '
        {
          host: $host,
          port: $port,
          apiKey: ($apiKey | gsub("[\r\n]"; "")),
          adminApiKey: ($adminApiKey | gsub("[\r\n]"; "")),
          region: $region,
          tlsBackend: $tlsBackend
        }
        + (if $proxyUrl != "" then { proxyUrl: $proxyUrl } else {} end)
        + (if $kiroVersion != "" then { kiroVersion: $kiroVersion } else {} end)
        | if .apiKey == "" or .adminApiKey == "" then
            error("kiro-rs API and admin keys must be nonempty after CR/LF normalization")
          else . end
      ' > "$config_tmp"
    mv -T "$config_tmp" ${stateDir}/config.json
    chmod 600 ${stateDir}/config.json
  '';
in
{
  options.services.kiro-rs = {
    enable = lib.mkEnableOption "kiro-rs Kiro-to-Anthropic relay";

    listenHost = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "监听地址。公网/隧道可达性由阿里云安全组与 WireGuard 拓扑决定。";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8990;
      description = "监听端口（Anthropic 兼容 API：/v1/messages、/v1/models）。";
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "us-east-1";
      description = "Kiro AWS Region。GPT-5.6 系列仅 us-east-1 / eu-central-1 提供。";
    };

    tlsBackend = lib.mkOption {
      type = lib.types.enum [ "rustls" "native-tls" ];
      default = "native-tls";
      description = "上游 TLS 后端。境外链路遇 token 刷新失败时上游 README 建议 native-tls。";
    };

    proxyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://127.0.0.1:7890";
      description = "全局 HTTP/SOCKS5 出境代理（可选；凭据级 proxyUrl 优先级更高）。";
    };

    kiroVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      # FIXME(metadataEvent): 上游不发 metadataEvent.tokenUsage（精确 usage / cache_read /
      # cache_creation / stopReason），kiro-protocol.patch 的解析目前空转，usage 仍是估算值。
      # 疑似按客户端版本号门控：实测把本项设为 1.1.70 时上游对每个请求返回
      # 400 "profileArn is required for this request."；本账号 authMethod=idc 且
      # hasProfileArn=false（admin API 可见），故暂时回落服务默认 0.11.107。
      # 拿到 profileArn 后（或换非 IdC 账号）：把本项升到当时稳定版重测，
      # 响应 usage 应出现 cache_read_input_tokens / cache_creation_input_tokens。
      description = "上报的 Kiro 客户端版本号（可选；缺省由服务自行选择）。";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.kiro-rs = {
      isSystemUser = true;
      group = "kiro-rs";
      home = stateDir;
      createHome = true;
    };
    users.groups.kiro-rs = { };

    systemd.services.kiro-rs-setup = {
      description = "kiro-rs secrets/config setup";
      before = [ "kiro-rs.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "kiro-rs";
        Group = "kiro-rs";
        UMask = "0077";
        RemainAfterExit = true;
        LoadCredential = [
          "credentials-seed:${credentialsSourceFile}"
          "api-key-seed:${apiKeySourceFile}"
          "admin-password:${adminPasswordSourceFile}"
        ];
        SetCredential = [
          "credentials-seed:_"
          "api-key-seed:_"
          "admin-password:_"
        ];
        ExecStartPre = [
          "+${ownershipRepair}"
        ];
        ExecStart = setupScript;
      };
    };

    systemd.services.kiro-rs = {
      description = "kiro-rs Kiro-to-Anthropic relay";
      after = [ "kiro-rs-setup.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "kiro-rs-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "kiro-rs";
        Group = "kiro-rs";
        ExecStart = "${package}/bin/kiro-rs -c ${stateDir}/config.json --credentials ${stateDir}/credentials.json";
        WorkingDirectory = stateDir;
        Restart = "on-failure";
        RestartSec = 5;

        # 安全加固（token 刷新会回写 credentials.json，仅放行状态目录）
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ stateDir ];
      };
    };
  };
}
