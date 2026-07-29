{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.services.pgyvpn;

  # 以下路径硬编码在闭源二进制中（strings 可验证），故意不做成 option：
  #   pgyvpn_svr  内部固定写 /etc/oray/pgyvpn（orayboxvpn_status.dat 等状态文件）
  #   pgyvisitor  内部固定写 /var/log/oray/pgyvpn
  # 若允许配置会导致 -f/-p 参数路径与二进制内部路径分裂。
  stateDir = "/etc/oray/pgyvpn";
  logDir = "/var/log/oray/pgyvpn";
in
{
  options.services.pgyvpn = {
    enable = lib.mkEnableOption "贝锐蒲公英访问端（PgyVisitor）SD-WAN 异地组网服务";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pgyvisitor;
      description = "pgyvisitor 包（见 overlays/pkgs/pgyvisitor）。";
    };
  };

  config = lib.mkIf cfg.enable {
    # pgyvisitor CLI 全局可用（管理操作需 root：sudo pgyvisitor login）
    environment.systemPackages = [ cfg.package ];

    # 创建 oray_vnc 虚拟网卡依赖 tun 设备
    boot.kernelModules = [ "tun" ];

    # 二进制硬编码路径兼容（见 overlays/pkgs/pgyvisitor/default.nix 注释）
    #
    # 两套机制互补：
    #   - activationScripts：nixos-rebuild switch 时立即创建，无需 reboot 即可用
    #   - tmpfiles：boot 早期兜底重建（switch 时 NixOS 只对 /dev /proc /sys /run 跑 tmpfiles）
    system.activationScripts.pgyvpn-compat = ''
      mkdir -p /usr/share /usr/sbin ${stateDir} ${logDir}
      ln -sfn ${cfg.package}/share/pgyvpn /usr/share/pgyvpn
      ln -sfn ${cfg.package}/sbin/pgystarnet /usr/sbin/pgystarnet
      ln -sfn ${cfg.package}/sbin/pgyvpn_svr /usr/sbin/pgyvpn_svr
      ln -sfn ${cfg.package}/bin/pgyvisitor /usr/sbin/pgyvisitor
    '';

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${logDir} 0755 root root -"
      # 语言资源（缺失时 pgyvisitor/pgyvpn_svr 报 "load language fail!" 退出）
      "L+ /usr/share/pgyvpn - - - - ${cfg.package}/share/pgyvpn"
      # pgyvpn_svr 以绝对路径 exec /usr/sbin/pgystarnet（P2P 打洞辅助进程）
      "L+ /usr/sbin/pgystarnet - - - - ${cfg.package}/sbin/pgystarnet"
      # 与官方文档/脚本路径保持一致的便捷链接
      "L+ /usr/sbin/pgyvisitor - - - - ${cfg.package}/bin/pgyvisitor"
      "L+ /usr/sbin/pgyvpn_svr - - - - ${cfg.package}/sbin/pgyvpn_svr"
    ];

    systemd.services.pgyvpn = {
      description = "Oray PgyVPN (PgyVisitor) SD-WAN client";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # pgyvpn_svr 通过 popen 调用的外部命令（strings 提取自官方二进制）
      path = with pkgs; [
        dmidecode # 设备 UUID（成员身份标识）
        nettools # route add/del、ifconfig
        iproute2 # ip address
        iptables
        iputils # ping（成员连通性探测）
        psmisc # killall
        lsb-release # 系统信息上报（可选）
        coreutils
        findutils
        gawk
        gnugrep
        procps # ps
      ];

      # 首次启动：从包内模板生成 config.ini（默认 autologin=true）；
      # 已存在则保留用户登录状态与自定义配置
      preStart = ''
        mkdir -p ${stateDir} ${logDir}
        if [ ! -f ${stateDir}/config.ini ]; then
          install -m 0644 ${cfg.package}/share/pgyvpn/config.ini.example ${stateDir}/config.ini
        fi

        # pgyvpn_svr 以 /tmp/pgyvpnsvr*_mutex 文件存在性做单实例检查（硬编码路径），
        # 异常退出（SIGKILL/断电）后残留会导致后续启动全部报 "already has a process" 255 退出。
        # 本服务是 pgyvpn_svr 的唯一管理者，启动前清理残留锁是安全的。
        rm -f /tmp/pgyvpnsvr_mutex /tmp/pgyvpnsvr_rpc_mutex
      '';

      serviceConfig = {
        Type = "simple";
        # 参数对齐官方 pgyvpn_monitor 脚本，去掉 -d（daemonize），前台运行交由 systemd 托管
        ExecStart = "${cfg.package}/sbin/pgyvpn_svr -R -A --mlink -t -i pgy-api.oray.com -K 255.255.255.255 -p ${logDir}/pgyvpn_svr -f ${stateDir}/config.ini --logmask 0xFFFFFFF7 --norpceventnotify";
        Restart = "always";
        RestartSec = 30;
      };
    };
  };
}
