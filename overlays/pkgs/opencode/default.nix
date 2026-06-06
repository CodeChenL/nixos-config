# overlays/pkgs/opencode/default.nix
# 使用 npm 包避免 glibc 兼容性问题
# npm 包使用标准路径 /lib/ld-linux-aarch64.so.1，由 NixOS 自动解析
{ inputs, final, prev }:

{
  opencode = let
    unstableOpencode = final.unstable.opencode;
    version = unstableOpencode.version;
    # 根据架构选择正确的 npm 包
    platformPkg = if final.stdenv.hostPlatform.isAarch64
      then final.fetchurl {
        url = "https://registry.npmjs.org/opencode-linux-arm64/-/opencode-linux-arm64-${version}.tgz";
        sha256 = "7dc33d6d062fb369dbef98cf0c48286a58f6e9ba96a808aa537cc674df2686ac";
      }
      else final.fetchurl {
        url = "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${version}.tgz";
        sha256 = ""; # TODO: 需要为 x86_64 更新
      };
  in
    final.runCommand "opencode-${version}" {
      nativeBuildInputs = [ final.makeWrapper ];
      meta = unstableOpencode.meta;
    } ''
      mkdir -p $out/bin $out/lib/opencode

      tar xzf ${platformPkg} -C $out/lib/opencode --strip-components=1

      makeWrapper $out/lib/opencode/bin/opencode $out/bin/opencode \
        --prefix PATH : ${final.lib.makeBinPath [ final.ripgrep ]}
    '';
}
