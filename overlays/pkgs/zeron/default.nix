{ inputs, final, prev }:

let
  version = "0.2.84";

  # tarball 按架构命名，官方 CDN（zeron.sh/releases）与 GitHub release 资产
  # 字节一致（sha256 已对照 release manifest 实测）。用 CDN 是因为本机网络
  # 不可达 GitHub release assets；URL 含版本号不可变，fetchurl 自带哈希校验。
  archMap = {
    x86_64-linux = "x86_64";
    aarch64-linux = "aarch64";
  };
  srcHashes = {
    x86_64 = "sha256-YL5ta6CKYIWUWupkpKunKT3LgJgVMzldL3sSmBFLDC0=";
    aarch64 = "sha256-fE+AFv9tKL/fA4hkMgkIdFIuSzwXnhKx4sFJknxqFbA=";
  };
  throwSystem = throw "zeron: unsupported system ${prev.stdenv.hostPlatform.system}";
  arch = archMap.${prev.stdenv.hostPlatform.system} or throwSystem;
in
prev.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "zeron";
  inherit version;

  src = prev.fetchurl {
    url = "https://zeron.sh/releases/zeron-${version}-linux-${arch}.tar.gz";
    hash = srcHashes.${arch} or throwSystem;
  };

  # 二进制 DT_NEEDED 硬依赖仅 3 项：libxcb / libxkbcommon(-x11) / libgcc_s，
  # 由 autoPatchelf 解析进 RUNPATH。其余窗口系统 / 图形 / 侧栏浏览器库全部
  # 运行时 dlopen（GPUI wayland 路径缺 libwayland-client 时直接 panic
  # NoWaylandLib），故 postFixup 注入 LD_LIBRARY_PATH。
  # GPU ICD 不需要额外处理：NixOS hardware.graphics 的 ICD JSON 带绝对路径，
  # libglvnd/vulkan-loader 自行定位驱动。
  nativeBuildInputs = [
    prev.autoPatchelfHook
    prev.makeWrapper
  ];
  buildInputs = [
    prev.stdenv.cc.cc.lib
    prev.libxkbcommon
    prev.libxcb
  ];

  sourceRoot = "zeron-${version}-linux-${arch}";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 zeron "$out/bin/zeron"
    install -Dm644 zeron.desktop "$out/share/applications/zeron.desktop"
    # 源图标是 1024x1024，但 hicolor 的 index.theme 最大只声明到 512x512，
    # 放 1024x1024 目录会让图标主题查找失败（启动器/任务栏无图标）。
    # 故装入已声明的 512x512，加载器自行缩放。
    install -Dm644 zeron.png "$out/share/icons/hicolor/512x512/apps/zeron.png"
    install -Dm644 licenses/fonts/THIRD_PARTY_NOTICES.md "$out/share/licenses/zeron/THIRD_PARTY_NOTICES.md"
    install -Dm644 licenses/fonts/Geist-OFL.txt "$out/share/licenses/zeron/Geist-OFL.txt"

    runHook postInstall
  '';

  # dlopen 全集（strings 实证）：窗口 wayland-client/egl、GPU EGL/vulkan、
  # 侧栏 webkit2gtk-4.1/javascriptcoregtk + gtk3/glib/gdk-pixbuf/json-glib。
  postFixup = ''
    wrapProgram "$out/bin/zeron" \
      --prefix LD_LIBRARY_PATH : "${prev.lib.makeLibraryPath [
        prev.wayland
        prev.libglvnd
        prev.vulkan-loader
        prev.gtk3
        prev.glib
        prev.gdk-pixbuf
        prev.webkitgtk_4_1
        prev.json-glib
      ]}"
  '';

  meta = {
    description = "Native control plane for Claude Code, Codex, Cursor and other coding agents";
    homepage = "https://zeron.sh";
    license = prev.lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "zeron";
    sourceProvenance = with prev.lib.sourceTypes; [ binaryNativeCode ];
  };
})
