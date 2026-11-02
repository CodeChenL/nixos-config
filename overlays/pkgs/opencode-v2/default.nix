# prev：overlay 的前一层包集。默认值仅为独立验证提供
# （nix-build -E 'let pkgs = import <nixpkgs> {}; in pkgs.callPackage ./overlays/pkgs/opencode-v2 {}'），
# 仓库 overlay 接入时显式传入 { inherit prev; }。
{ prev ? import <nixpkgs> { } }:

# OpenCode v2 CLI 自打包（nixpkgs 暂无 v2 包）。
# 直接取 npm 平台二进制包 @opencode/cli-linux-<arch>-${version}：
#   tarball 结构为 package/bin/opencode + package/package.json，
#   二进制是 ELF 动态链接（interpreter /lib64/ld-linux-*.so.2），需 autoPatchelfHook
#   修正解释器与 RPATH 才能在 nix store 里运行。
# 哈希为 nix-prefetch-url 对 tarball 实测的内容哈希，并已与 npm 元数据
# dist.integrity（sha512）交叉校验一致。
let
  version = "2.2.5";

  # 平台 → npm 平台包 CPU 后缀 + 实测 sha256（nix-prefetch-url 输出转 SRI）
  targets = {
    x86_64-linux = {
      cpu = "x64";
      hash = "sha256-kmkO7gemgNPLdgygK6Q4eN6eqxtOXV366HlVGMU2KPQ=";
    };
    aarch64-linux = {
      cpu = "arm64";
      hash = "sha256-+MWoIHX+3ptbBE7WyKbROtgHp+YsrqHNCoeK3vSesFM=";
    };
  };

  target =
    targets.${prev.stdenv.hostPlatform.system}
      or (throw "opencode-v2: 不支持的平台 ${prev.stdenv.hostPlatform.system}");
in
prev.stdenvNoCC.mkDerivation {
  pname = "opencode-v2";
  inherit version;

  src = prev.fetchurl {
    # 两源 tarball 字节一致（已用 npm dist.integrity sha512 交叉校验），
    # hash 锁定内容与来源无关。本网络下 registry.npmjs.org 正文传输停滞，
    # 故华为云 npm 镜像优先、官方源兜底。
    urls = [
      "https://repo.huaweicloud.com/repository/npm/@opencode/cli-linux-${target.cpu}/-/cli-linux-${target.cpu}-${version}.tgz"
      "https://registry.npmjs.org/@opencode/cli-linux-${target.cpu}/-/cli-linux-${target.cpu}-${version}.tgz"
    ];
    inherit (target) hash;
  };

  # npm tarball 解包后顶层只有 package/ 一个目录
  sourceRoot = "package";

  # mimo 思考档位补丁（上游 issue #51541）已放弃：上游未修，继续逐版重推导锚点
  # 成本高且改动闭源载荷。MiMo 按模型默认档位使用（见 home/chen/opencode-slim.nix），
  # 不依赖 none/thinking 变体；上游修复后直接升级即可获得变体。

  nativeBuildInputs = [ prev.autoPatchelfHook prev.makeWrapper ];
  # ldd 实测仅依赖 glibc（libc/libm/libpthread/libdl/ld-linux）；
  # 保留 cc.lib 兜底可能的 dlopen 或间接 libstdc++/libgcc_s 依赖（多装无害）。
  buildInputs = [ prev.stdenv.cc.cc.lib ];

  # 插件运行时才把 npm 依赖解包到 ~/.cache 并 dlopen 其原生模块
  # （如 opencode-mem 的 onnxruntime/sharp .node），这些文件不在本包输出里，
  # autoPatchelf 无法处理，且 dlopen 依赖解析不看主二进制 RPATH，
  # 只能通过启动环境提供 libstdc++。实测缺它时 mem 工具报
  # "libstdc++.so.6: cannot open shared object file"。
  postFixup = ''
    wrapProgram "$out/bin/opencode" \
      --prefix LD_LIBRARY_PATH : "${prev.lib.makeLibraryPath [ prev.stdenv.cc.cc.lib ]}"
  '';

  dontConfigure = true;
  dontBuild = true;
  # 关键：禁止 fixup 的 strip。二进制内嵌 JS 载荷段 .bun 依赖 EOF 相对偏移定位，
  # strip -S -p 会重排段布局（实测把 .bun 挪到 .bss 之后、整体缩 3880 字节），
  # 导致载荷定位失败、退化成裸 bun（--version 显示 bun 1.4.2）。
  # 仅 autoPatchelf 的 set-interpreter 是均匀移位（实测 +4096），不影响载荷。
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode "$out/bin/opencode"
    # npm @opencode/cli 的 bin 映射同时提供 opencode 与 opencode2 两个入口名，
    # 这里用符号链接保持兼容。
    ln -s opencode "$out/bin/opencode2"
    runHook postInstall
  '';

  meta = {
    description = "OpenCode v2 AI coding agent CLI (self-packaged from npm platform binary)";
    homepage = "https://github.com/anomalyco/opencode";
    license = prev.lib.licenses.mit;
    platforms = builtins.attrNames targets;
    mainProgram = "opencode";
  };
}
