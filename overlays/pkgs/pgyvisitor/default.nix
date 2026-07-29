# overlays/pkgs/pgyvisitor/default.nix
#
# 贝锐蒲公英访问端（PgyVisitor）Linux 客户端。
# 闭源软件，官方仅提供 deb/rpm 二进制：
#   https://pgy.oray.com/softwares/153/download/2549/PgyVisitor-6.9.0-amd64.deb
#
# 包内组件：
#   sbin/pgyvpn_svr  核心守护进程（动态链接，需要 libstdc++）
#   sbin/pgystarnet  P2P/打洞辅助进程（静态链接 Go 二进制）
#   bin/pgyvisitor   用户 CLI（login/logout/getmbrs/...，通过 RPC 与 pgyvpn_svr 通信）
#
# 二进制存在硬编码路径（见 hosts/pgyvpn.nix 的 tmpfiles 规则）：
#   /usr/share/pgyvpn/res    语言资源（缺失时 CLI 报 "load language fail!"）
#   /usr/sbin/pgystarnet     pgyvpn_svr 直接 exec 该绝对路径
#   /etc/oray/pgyvpn         配置与登录状态（可写、需持久化）
#   /var/log/oray/pgyvpn     日志目录
{ inputs, final, prev }:

{
  pgyvisitor = final.callPackage (
    {
      lib,
      stdenv,
      fetchurl,
      dpkg,
      autoPatchelfHook,
    }:
    stdenv.mkDerivation rec {
      pname = "pgyvisitor";
      # deb 内 control 的实际版本为 6.9.0.17608；文件名只到三位
      version = "6.9.0";

      src = fetchurl {
        url = "https://pgy.oray.com/softwares/153/download/2549/PgyVisitor-${version}-amd64.deb";
        hash = "sha256-OlPhs2Jm9QMcm001wC3xhYNDf+2zhKWOiX3efCrItg0=";
      };

      nativeBuildInputs = [
        dpkg
        autoPatchelfHook
      ];

      # pgyvpn_svr / pgyvisitor 依赖 libstdc++（pgystarnet 为静态链接无需处理）
      buildInputs = [
        stdenv.cc.cc.lib
      ];

      unpackPhase = ''
        runHook preUnpack
        dpkg-deb -x $src .
        runHook postUnpack
      '';

      installPhase = ''
        runHook preInstall

        install -Dm755 usr/sbin/pgyvpn_svr $out/sbin/pgyvpn_svr
        install -Dm755 usr/sbin/pgystarnet $out/sbin/pgystarnet
        install -Dm755 usr/sbin/pgyvisitor $out/bin/pgyvisitor

        # 语言资源（pgyvisitor/pgyvpn_svr 从 /usr/share/pgyvpn/res 加载，缺省会报错退出）
        install -Dm644 usr/share/pgyvpn/res/*.xml -t $out/share/pgyvpn/res/

        # 默认配置模板：autologin=true 已开启；首次启动由 pgyvpn 模块复制到 /etc/oray/pgyvpn/config.ini
        install -Dm644 etc/oray/pgyvpn/config.ini $out/share/pgyvpn/config.ini.example

        runHook postInstall
      '';

      # 官方二进制，保持原样
      dontStrip = true;

      meta = with lib; {
        description = "Oray PgyVisitor (蒲公英访问端) SD-WAN 异地组网客户端";
        homepage = "https://pgy.oray.com";
        license = licenses.unfree;
        sourceProvenance = with sourceTypes; [ binaryNativeCode ];
        mainProgram = "pgyvisitor";
        platforms = [ "x86_64-linux" ];
      };
    }
  ) { };
}
