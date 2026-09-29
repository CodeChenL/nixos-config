{ config, pkgs, lib, ... }:

# Zeron — coding-agent 控制平面（GUI + headless 引擎 + MCP server）。
# 驱动 claude/codex/cursor 等 agent CLI，本地优先，会话存于 ~/.zeron。
#
# 仅 x86_64 交付（aarch64 哈希已在 overlay 就绪，日后放开本门控即可）。
# headless 引擎用声明式 user unit 替代官方 `zeron daemon install` 的
# 命令式 unit；GUI（`zeron` / 菜单入口）随 home.packages 一并装入。
# 自更新无需处理：二进制在 /nix/store 下被上游 detect_install() 判为
# Unmanaged，`zeron update` 自行 bail。
lib.mkIf (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
  home.packages = [ pkgs.zeron ];

  systemd.user.services.zeron = {
    Unit = {
      Description = "Zeron coding-agent control plane (headless engine)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      StartLimitBurst = 5;
      StartLimitIntervalSec = 60;
    };

    Service = {
      ExecStart = "${pkgs.zeron}/bin/zeron headless";
      Restart = "on-failure";
      RestartSec = 5;
      WorkingDirectory = config.home.homeDirectory;
      # 与上游 unit 同款约定：可选 ZERON_* 运行时覆盖（ZERON_DATA_DIR 等）
      EnvironmentFile = [ "-%h/.zeron/env" ];
      Environment = [
        "HOME=${config.home.homeDirectory}"
      ];
    };

    Install.WantedBy = [ "default.target" ];
  };
}
