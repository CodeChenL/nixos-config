{ inputs, final, prev }:
let
  version = "0.1.169";
  src = prev.fetchurl {
    url = "https://github.com/Wei-Shaw/sub2api/releases/download/v${version}/sub2api_${version}_linux_amd64.tar.gz";
    hash = "sha256-Rcq3CcV4IIsJ68rBoc+aao1qgbmZRipxO1jO4yuFOUY=";
  };
in
{
  sub2api = prev.stdenv.mkDerivation {
    pname = "sub2api";
    inherit version src;

    nativeBuildInputs = [ prev.gnutar prev.gzip ];

    dontBuild = true;
    dontConfigure = true;

    unpackPhase = ''
      mkdir -p source
      tar xzf $src -C source
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp source/sub2api $out/bin/
      chmod +x $out/bin/sub2api
    '';

    meta = with prev.lib; {
      description = "AI API Gateway Platform for Subscription Quota Distribution";
      homepage = "https://github.com/Wei-Shaw/sub2api";
      license = licenses.lgpl3Only;
      platforms = [ "x86_64-linux" ];
    };
  };
}
