{ config, pkgs, lib, ... }:

{
  imports = [
    ./common.nix
    ./packages.nix
  ];

  # 周期性清理 home-manager generations：保留 30 天内的，最旧的自动失效。
  # 失效的 generation 路径会保留到下一次 `nix-collect-garbage` 才会真正删除 store object。
  services.home-manager.autoExpire = {
    enable = true;
    timestamp = "-30 days";
    frequency = "daily";
  };

  # Yakuake 开机自启（用户级 XDG autostart）
  xdg.configFile."autostart/org.kde.yakuake.desktop".source =
    "${pkgs.kdePackages.yakuake}/share/applications/org.kde.yakuake.desktop";

  xdg.dataFile."io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml".text = ''
    dns:
      enable: true
      nameserver:
        - 192.168.2.1
      direct-nameserver-follow-policy: true
      nameserver-policy:
        "+.vamrs.org": 192.168.2.1
        "+.lan": 192.168.2.1
        "+.local": 192.168.2.1
        "+.home.arpa": 192.168.2.1
        localhost: 192.168.2.1
  '';

  xdg.dataFile."io.github.clash-verge-rev.clash-verge-rev/profiles/Script.js".text = ''
    const prependRules = [
      "DOMAIN,localhost,DIRECT",
      "DOMAIN-SUFFIX,lan,DIRECT",
      "DOMAIN-SUFFIX,local,DIRECT",
      "DOMAIN-SUFFIX,home.arpa,DIRECT",
      "DOMAIN-SUFFIX,vamrs.org,DIRECT",
      "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
      "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
      "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
      "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
      "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
      "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
      "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
      "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
      "IP-CIDR6,::1/128,DIRECT,no-resolve",
      "DOMAIN-KEYWORD,discord,Proxy"
    ];

    const prependProxy = [
      { name: "SOCKS5-Proxy", type: "socks5", server: "192.168.2.4", port: 7891, udp: true }
    ];

    const prependProxygroupsProxies = ["SOCKS5-Proxy"];

    function main(config) {
      const existingRules = Array.isArray(config.rules) ? config.rules : [];
      config.rules = prependRules.concat(existingRules);

      config["proxies"] = prependProxy.concat(config["proxies"]);

      config["proxy-groups"].forEach(group => {
        group["proxies"] = prependProxygroupsProxies.concat(group["proxies"]);
      });

      return config;
    }
  '';
}
