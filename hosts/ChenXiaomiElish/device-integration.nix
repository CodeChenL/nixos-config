{ lib, pkgs, ... }:

let
  elishHexagonFs = pkgs.callPackage ../../overlays/xiaomi-elish-hexagonfs { };

  elishUcmFiles = pkgs.runCommand "alsa-ucm-conf-xiaomi-elish" {
    passthru.pmaportsRevision = "57cff102e1716bd87e7236146581d61dc8d76b23";
  } ''
    install -Dm644 ${./audio/elish.conf} \
      "$out/share/alsa/ucm2/Xiaomi/elish/elish.conf"
    install -Dm644 ${./audio/HiFi.conf} \
      "$out/share/alsa/ucm2/Xiaomi/elish/HiFi.conf"
    mkdir -p "$out/share/alsa/ucm2/conf.d/sm8250"
    ln -s ../../Xiaomi/elish/elish.conf \
      "$out/share/alsa/ucm2/conf.d/sm8250/Xiaomi Mi Pad 5 Pro.conf"
    ln -s ../../Xiaomi/elish/elish.conf \
      "$out/share/alsa/ucm2/conf.d/sm8250/Xiaomi-MiPad5Pro-elish.conf"
  '';

  elishUcm = pkgs.symlinkJoin {
    name = "alsa-ucm-conf-xiaomi-elish-${pkgs.alsa-ucm-conf.version}";
    paths = [
      pkgs.alsa-ucm-conf
      elishUcmFiles
    ];
    postBuild = ''
      for cardName in "Xiaomi Mi Pad 5 Pro" "Xiaomi-MiPad5Pro-elish"; do
        test "$out/share/alsa/ucm2/conf.d/sm8250/$cardName.conf" \
          -ef "$out/share/alsa/ucm2/Xiaomi/elish/elish.conf"
        cmp "$out/share/alsa/ucm2/conf.d/sm8250/$cardName.conf" ${./audio/elish.conf}
      done
      cmp "$out/share/alsa/ucm2/Xiaomi/elish/HiFi.conf" ${./audio/HiFi.conf}
      cmp "$out/share/alsa/ucm2/ucm.conf" ${pkgs.alsa-ucm-conf}/share/alsa/ucm2/ucm.conf
    '';
    passthru.pmaportsRevision = "57cff102e1716bd87e7236146581d61dc8d76b23";
  };

  hexagonFsRoot = "${elishHexagonFs}/share/qcom/sm8250/Xiaomi/elish";
in
{
  environment = {
    systemPackages = [
      elishUcm
      pkgs.hexagonrpc
    ];
    variables.ALSA_CONFIG_UCM2 = "${elishUcm}/share/alsa/ucm2";
  };

  systemd.user.services = {
    pipewire.environment.ALSA_CONFIG_UCM2 = "${elishUcm}/share/alsa/ucm2";
    wireplumber.environment.ALSA_CONFIG_UCM2 = "${elishUcm}/share/alsa/ucm2";
  };

  users = {
    groups.fastrpc = { };
    users.fastrpc = {
      isSystemUser = true;
      group = "fastrpc";
      description = "FastRPC service user";
    };
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", OWNER="fastrpc", GROUP="fastrpc", MODE="0600"
    SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hexagonrpcd-sdsp.service"
    SUBSYSTEM=="misc", KERNEL=="fastrpc-*", ENV{ACCEL_MOUNT_MATRIX}+="-1, 0, 0; 0, -1, 0; 0, 0, -1"
    SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"
  '';

  hardware.sensor.iio.enable = true;

  systemd.services = {
    hexagonrpcd-sdsp = {
      description = "Server for FastRPC remote procedure calls from Qualcomm SDSP";
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "dev-fastrpc\\x2dsdsp.device" ];
      after = [ "dev-fastrpc\\x2dsdsp.device" ];
      unitConfig.ConditionPathExists = "/dev/fastrpc-sdsp";
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.hexagonrpc} -f /dev/fastrpc-sdsp -d sdsp -s -R ${hexagonFsRoot}";
        Restart = "always";
        RestartSec = 3;
        User = "fastrpc";
        Group = "fastrpc";
      };
    };

    iio-sensor-proxy = {
      wants = [ "hexagonrpcd-sdsp.service" ];
      bindsTo = [ "dev-fastrpc\\x2dsdsp.device" ];
      after = [
        "dev-fastrpc\\x2dsdsp.device"
        "hexagonrpcd-sdsp.service"
      ];
      # The proxy exits successfully when libssc cannot find the SSC service yet.
      serviceConfig = {
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
