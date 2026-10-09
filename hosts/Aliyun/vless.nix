{
  config,
  lib,
  pkgs,
  ...
}:

# VLESS + Reality + XTLS-Vision（xray-core）——新一代代理服务，与 mixed-proxy 并行
# 监听（8444），只新增不替换；mixed-proxy（8443）保持原样，迁移另行安排。
#
# 密钥与 UUID 存 /home/chen/nixos-config/secrets/vless/（gitignored，两端分别部署），
# 不写入本仓库与 Nix store：ExecStartPre 在运行时把占位符模板渲染成 /run/xray/config.json。
# Reality 伪装目标 www.microsoft.com:443；客户端需配套 secrets/vless/{uuid,reality-public.key,short-id}。
let
  xray = pkgs.xray;
  secretsDir = "/home/chen/nixos-config/secrets/vless";
  runtimeConfigDir = "/run/xray";
  runtimeConfig = "${runtimeConfigDir}/config.json";
  listenPort = 8444;
  # Reality 伪装目标：经实测（xray 26.3.27 的镜像解析对 target TLS 航程形态敏感，
  # microsoft/bing/baidu 的航程会在证书记录处断掉）apple.com 的航程形态兼容且
  # 从阿里云 CN 侧可达性/速度均佳（200/56ms）。更换目标前请先用 loopback 实测航程。
  realityDest = "www.apple.com:443";
  realityServerName = "www.apple.com";

  # 占位符模板进 store（无任何密钥）；@UUID@/@PRIVKEY@/@SHORTID@ 由 ExecStartPre 替换。
  configTemplate = pkgs.writeText "xray-vless-config.template.json" (
    builtins.toJSON {
      log.loglevel = "warning";
      inbounds = [
        {
          listen = "0.0.0.0";
          port = listenPort;
          protocol = "vless";
          settings = {
            clients = [
              {
                id = "@UUID@";
                flow = "xtls-rprx-vision";
                email = "chen-vless";
              }
            ];
            decryption = "none";
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = {
              dest = realityDest;
              serverNames = [ realityServerName ];
              privateKey = "@PRIVKEY@";
              shortIds = [ "@SHORTID@" ];
            };
          };
          sniffing = {
            enabled = true;
            destOverride = [
              "http"
              "tls"
              "quic"
            ];
            routeOnly = true;
          };
        }
      ];
      outbounds = [
        {
          protocol = "freedom";
          tag = "direct";
        }
        {
          protocol = "blackhole";
          tag = "block";
        }
      ];
    }
  );

  renderConfig = pkgs.writeShellScript "xray-vless-render-config" ''
    set -euo pipefail
    install -d -m 0700 ${runtimeConfigDir}
    umask 077
    read_secret() {
      local file="$1"
      [ -r "$file" ] || { echo "missing vless secret: $file" >&2; exit 1; }
      tr -d '\r\n' < "$file"
    }
    uuid=$(read_secret ${secretsDir}/uuid)
    privkey=$(read_secret ${secretsDir}/reality-private.key)
    shortid=$(read_secret ${secretsDir}/short-id)
    [ -n "$uuid" ] && [ -n "$privkey" ] && [ -n "$shortid" ] || {
      echo "empty vless secret" >&2; exit 1;
    }
    sed -e "s|@UUID@|$uuid|g" \
        -e "s|@PRIVKEY@|$privkey|g" \
        -e "s|@SHORTID@|$shortid|g" \
        ${configTemplate} > ${runtimeConfig}
    chmod 600 ${runtimeConfig}
  '';
in
{
  # 只读性检查：secrets 目录须已部署（与 mixed-proxy 的 PAM 密码同理，两端分别同步）。
  systemd.services.xray-vless = {
    description = "Xray VLESS+Reality proxy (parallel to mixed-proxy, additive)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    wants = [ "network.target" ];
    restartTriggers = [ configTemplate ];
    serviceConfig = {
      User = "chen";
      DynamicUser = false;
      NoNewPrivileges = true;
      TimeoutStopSec = "15s";
      KillMode = "control-group";
      # 长连接代理同样需要高文件描述符上限（同 mixed-proxy 的经验）。
      LimitNOFILE = 65536;
      RuntimeDirectory = "xray";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = "${renderConfig}";
      ExecStart = "${xray}/bin/xray run -config ${runtimeConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
