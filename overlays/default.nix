# 自定义 Overlay：注入 unstable / master / NUR 通道包
inputs: final: prev: {
  unstable = import inputs.nixpkgs-unstable {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };
  master = import inputs.nixpkgs-master {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };
  nur = import inputs.NUR {
    pkgs = prev;
    nurpkgs = prev;
  };
}
