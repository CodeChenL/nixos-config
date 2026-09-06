{ config, lib, pkgs, ... }:

let
  initializer = pkgs.writeShellApplication {
    name = "elish-bluetooth-address";
    runtimeInputs = [ config.hardware.bluetooth.package ];
    text = ''
      exec ${lib.getExe pkgs.python3} ${./bluetooth/initialize.py} "$@"
    '';
  };
  tests = pkgs.runCommand "elish-bluetooth-address-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${./bluetooth} bluetooth
    ELISH_BT_TEST_MODULE=${./bluetooth.nix} ELISH_BT_TEST_EXECUTABLE=${lib.getExe initializer} python3 -B -m unittest bluetooth.test_initializer bluetooth.test_events bluetooth.test_dispatch -v
    touch "$out"
  '';
in
{
  system.build = {
    elishBluetoothInitializer = initializer;
    elishBluetoothTests = tests;
  };

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", KERNEL=="hci[0-9]*", DRIVERS=="hci_uart_qca", TAG+="systemd", ENV{SYSTEMD_WANTS}+="elish-bluetooth-address@%k.service"
  '';

  systemd.services."elish-bluetooth-address@" = {
    description = "Initialize the missing Elish QCA6390 public address (%I)";
    bindsTo = [ "sys-subsystem-bluetooth-devices-%i.device" ];
    after = [
      "sys-subsystem-bluetooth-devices-%i.device"
      "systemd-machine-id-commit.service"
    ];
    unitConfig.ConditionPathExists = "/sys/class/bluetooth/%i";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe initializer} %i";
      TimeoutStartSec = 65;
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  systemd.services.elish-bluetooth-address-present = {
    description = "Start Elish Bluetooth address initialization for existing controllers";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-trigger.service" ];
    restartTriggers = [ initializer ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for device in /sys/class/bluetooth/hci*; do
        [ -e "$device" ] || continue
        [[ ''${device##*/} =~ ^hci(0|[1-9][0-9]*)$ ]] || continue
        ${pkgs.systemd}/bin/systemctl --no-block start "elish-bluetooth-address@''${device##*/}.service"
      done
    '';
  };
}
