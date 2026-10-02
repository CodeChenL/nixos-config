{
  config,
  pkgs,
  lib,
  ...
}:

let
  clashProxyPasswordFile = "${config.home.homeDirectory}/nixos-config/secrets/mixed-proxy/password";
  clashProxyScriptFile = "${config.xdg.dataHome}/io.github.clash-verge-rev.clash-verge-rev/profiles/Script.js";
  publicClashScriptTemplate = pkgs.writeText "clash-script-template.js" ''
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
      // Aliyun / Sub2API 必须直连，避免 Clash 海外代理返回 403/timeout
      "DOMAIN,chenjaly.cn,DIRECT",
      "DOMAIN-SUFFIX,chenjaly.cn,DIRECT",
      "IP-CIDR,47.254.74.103/32,DIRECT,no-resolve",
      "DOMAIN-KEYWORD,discord,Proxy"
    ];

    const prependProxy = [
      { name: "SOCKS5-Proxy", type: "socks5", server: "192.168.2.4", port: 7891, udp: true },
      { name: "Aliyun-SOCKS5", type: "socks5", server: "api.chenjaly.cn", port: 8443, username: "chen", password: __CLASH_SOCKS5_RUNTIME_PASSWORD_90DB41EA__, udp: true },
      { name: "Aliyun-HTTPS", type: "https", server: "api.chenjaly.cn", port: 8443, username: "chen", password: __CLASH_SOCKS5_RUNTIME_PASSWORD_90DB41EA__ }
    ];

    const prependProxygroupsProxies = ["SOCKS5-Proxy", "Aliyun-SOCKS5", "Aliyun-HTTPS"];

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
  clashProxyGenerator = pkgs.writeText "clash-proxy-generator.cjs" ''
    const fs = require('node:fs');
    const path = require('node:path');
    const { randomBytes } = require('node:crypto');
    const { isUtf8 } = require('node:buffer');

    let failureMessage = 'Clash proxy: invalid generator arguments.';
    let temporaryPath;

    function readPassword(source) {
      failureMessage = 'Clash proxy: cannot open password; require an existing regular file without a symlink.';
      const descriptor = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
      let bytes;
      try {
        const stat = fs.fstatSync(descriptor);
        failureMessage = 'Clash proxy: password must be a regular file owned by the activation user with mode 0600.';
        if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o600) {
          throw new Error();
        }
        failureMessage = 'Clash proxy: password must be non-empty UTF-8, at most 255 bytes, without NUL/CR/LF except an optional terminal LF or CRLF.';
        if (stat.size > 257) {
          throw new Error();
        }
        bytes = fs.readFileSync(descriptor);
      } finally {
        fs.closeSync(descriptor);
      }
      if (!isUtf8(bytes)) {
        throw new Error();
      }
      if (bytes.at(-1) === 10) {
        bytes = bytes.subarray(0, bytes.length - (bytes.at(-2) === 13 ? 2 : 1));
      }
      if (bytes.length === 0 || bytes.length > 255 || bytes.includes(0) || bytes.includes(10) || bytes.includes(13)) {
        throw new Error();
      }
      return bytes.toString('utf8');
    }

    function writeScript(target, script) {
      failureMessage = 'Clash proxy: destination parent must be outside /nix/store and owned by the activation user.';
      const parent = path.dirname(path.resolve(target));
      let existingParent = parent;
      while (!fs.existsSync(existingParent)) {
        existingParent = path.dirname(existingParent);
      }
      const realAncestor = fs.realpathSync(existingParent);
      if (realAncestor === '/nix/store' || realAncestor.startsWith('/nix/store/')) {
        throw new Error();
      }
      const canonicalParent = path.join(realAncestor, path.relative(existingParent, parent));
      fs.mkdirSync(canonicalParent, { recursive: true, mode: 0o700 });
      const realParent = fs.realpathSync(canonicalParent);
      if (realParent === '/nix/store' || realParent.startsWith('/nix/store/') || fs.statSync(realParent).uid !== process.getuid()) {
        throw new Error();
      }

      failureMessage = 'Clash proxy: failed to atomically install the private runtime script.';
      const candidate = path.join(realParent, '.Script.js.' + randomBytes(16).toString('hex') + '.tmp');
      const descriptor = fs.openSync(candidate, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
      temporaryPath = candidate;
      try {
        fs.fchmodSync(descriptor, 0o600);
        fs.writeFileSync(descriptor, script, 'utf8');
        fs.fsyncSync(descriptor);
      } finally {
        fs.closeSync(descriptor);
      }
      fs.renameSync(temporaryPath, path.join(realParent, path.basename(target)));
      temporaryPath = undefined;
    }

    try {
      const [command, source, template, target] = process.argv.slice(2);
      if (command === '--check-secret' && process.argv.length === 4) {
        readPassword(source);
      } else if (command === 'generate' && process.argv.length === 6) {
        const password = readPassword(source);
        failureMessage = 'Clash proxy: public script template must contain at least one password placeholder.';
        const script = fs.readFileSync(template, 'utf8');
        const placeholder = '__CLASH_SOCKS5_RUNTIME_PASSWORD_90DB41EA__';
        if (script.split(placeholder).length < 2) {
          throw new Error();
        }
        writeScript(target, script.replaceAll(placeholder, () => JSON.stringify(password)));
      } else {
        throw new Error();
      }
    } catch {
      console.error(failureMessage);
      process.exitCode = 1;
    } finally {
      if (temporaryPath !== undefined) {
        try {
          fs.unlinkSync(temporaryPath);
        } catch (error) {
          if (error.code !== 'ENOENT') {
            console.error('Clash proxy: failed to remove the temporary runtime script.');
            process.exitCode = 1;
          }
        }
      }
    }
  '';
in
{
  imports = [
    ./common.nix
    ./packages.nix
    ./kicad.nix
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

  # ── KDE Plasma 桌面 UI 语言 ───────────────────────────────────
  # NixOS 下 KDE 系统设置的 "Region & Language" 页面功能损坏，必须直接写
  # ~/.config/plasma-localerc。声明式管理避免手动在系统设置里改被 rebuild 覆盖。
  # - [Formats].LANG: 区域格式用 en_US.UTF-8（日期/数字等国际标准格式）
  # - [Translations].LANGUAGE: KDE UI 翻译语言用 zh_CN（桌面显示中文）
  # SSH/终端 shell 不读此文件，仍由 shell.nix 的 profileExtra 控制为英文。
  xdg.configFile."plasma-localerc".text = ''
    [Formats]
    LANG=en_US.UTF-8

    [Translations]
    LANGUAGE=zh_CN
  '';

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

  home.activation.checkClashProxyPassword = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    ${pkgs.nodejs}/bin/node ${clashProxyGenerator} --check-secret ${lib.escapeShellArg clashProxyPasswordFile} || exit 1
  '';

  home.activation.writeClashProxyScript = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${pkgs.nodejs}/bin/node ${clashProxyGenerator} generate ${lib.escapeShellArg clashProxyPasswordFile} ${publicClashScriptTemplate} ${lib.escapeShellArg clashProxyScriptFile} || exit 1
  '';

  # Clash Verge 当前激活 profile 使用的 script。
  xdg.dataFile."io.github.clash-verge-rev.clash-verge-rev/profiles/srXJ1OAcZkXf.js".text = ''
    const prependRules = [
      "DOMAIN,chenjaly.cn,DIRECT",
      "DOMAIN-SUFFIX,chenjaly.cn,DIRECT",
      "IP-CIDR,47.254.74.103/32,DIRECT,no-resolve",
    ];

    function main(config, profileName) {
      config.rules = prependRules.concat(config.rules || []);
      return config;
    }
  '';
}
