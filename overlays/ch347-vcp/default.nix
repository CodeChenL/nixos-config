{
  lib,
  stdenv,
  fetchFromGitHub,
  kernel,
  ...
}:

let
  rev = "a81c3edc876bd8a89c120f392c3837815e5a667e";
in
stdenv.mkDerivation {
  pname = "ch347-vcp";
  version = "0-unstable-${lib.substring 0 7 rev}";

  src = fetchFromGitHub {
    owner = "ayStarik";
    repo = "ch347_vcp";
    inherit rev;
    hash = "sha256-aD00ZP0Cs/DhW7jawOAW9qJ04KyBxYd3S0ktv1zWZBA=";
  };

  patches = [
    ./linux-6.17-gpio-set-return-value.patch
    ./linux-55de-device-id.patch
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "pic" ];

  makeFlags = [
    "KERNEL_SRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  installPhase = ''
    runHook preInstall

    install -Dm644 mfd-ch347.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/mfd/mfd-ch347.ko
    install -Dm644 i2c-ch347.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/i2c/busses/i2c-ch347.ko
    install -Dm644 gpio-ch347.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/gpio/gpio-ch347.ko
    install -Dm644 spi-ch347.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/spi/spi-ch347.ko

    runHook postInstall
  '';

  meta = with lib; {
    description = "WCH CH347 USB bridge I2C, SPI, and GPIO kernel modules";
    homepage = "https://github.com/ayStarik/ch347_vcp";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
