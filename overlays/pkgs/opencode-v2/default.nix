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
  version = "2.0.26";

  # 平台 → npm 平台包 CPU 后缀 + 实测 sha256（nix-prefetch-url 输出转 SRI）
  targets = {
    x86_64-linux = {
      cpu = "x64";
      hash = "sha256-ChFuAzoCgEdB1GRDN9ASvfWiSqwzo0wMllNNLVOWERk=";
    };
    aarch64-linux = {
      cpu = "arm64";
      hash = "sha256-HXEX27MZaEVviVN7Vi+14g5I2envAyX8iEWr3abvSEI=";
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

  # 内嵌 JS 载荷的等长字节补丁（上游 issue #51541，修复借鉴 PR #44064 语义）：
  # openai-compatible 协议（rQ）对 `reasoning_options=[{type:"toggle"}]` 的模型此前派生
  # 零个推理档位；改为复用同一二进制内 deepseek 协议（tQ）的 toggle 分支——生成
  # none/thinking 两档并写入请求体 `thinking.type=disabled|enabled`（与小米 MiMo 官方
  # 开关一致）。8 字节等长替换（di→tQ），不改文件尺寸、不破坏 .bun 载荷的 EOF 相对布局；
  # 构建期强校验命中数与体积，宿主升级导致锚点变化时构建会直接失败。
  postPatch = ''
    python3 - <<'PY'
    import pathlib
    p = pathlib.Path("bin/opencode")
    data = p.read_bytes()
    # 精确修复 #51541（2.0.26 锚点）：仅 reasoning_options=[{type:"toggle"}] 的模型
    # 改道 rP（deepseek 协议的 thinking.type 两态，body 通道直达请求体）；effort /
    # budget 分支保持原 ei（openaiChat）行为——rP 的 effort 分支会改变档位语义
    # （low/high/max、none→thinking disabled），不能整函数替换。U5 原样保留在区域中。
    # .bun 载荷依赖 EOF 相对偏移，必须字节等长：顺手把 mP 里等价的 includes 链
    # 改写为 .some()（语义相同）腾出字节，差额以空格补齐（语句间空白无害）。
    old = (
        b'cP=(e,i)=>{if(e.providerID==="nvidia")return lP(e,i);return ei(e,i)},'
        b'U5=(e,i)=>{if(i.type==="effort")return ya(i.values??li,(r)=>({settings:{reasoningEffort:r}}));'
        b'if(i.type==="toggle")return ma({settings:{reasoning:{enabled:!1}}},{settings:{reasoning:{enabled:!0}}});return[]},'
        b'mP=(e,i)=>{let r=ni(e).toLowerCase(),u=r.includes("k2.5")||r.includes("k2-5")||r.includes("k2.6")||r.includes("k2-6");'
    )
    core = (
        b'cP=(e,i)=>e.providerID==="nvidia"?lP(e,i):i.type==="toggle"?rP(e,i):ei(e,i),'
        b'U5=(e,i)=>{if(i.type==="effort")return ya(i.values??li,(r)=>({settings:{reasoningEffort:r}}));'
        b'if(i.type==="toggle")return ma({settings:{reasoning:{enabled:!1}}},{settings:{reasoning:{enabled:!0}}});return[]},'
        b'mP=(e,i)=>{let r=ni(e).toLowerCase(),u=["k2.5","k2-5","k2.6","k2-6"].some(x=>r.includes(x));'
    )
    n = data.count(old)
    if n != 1:
        raise SystemExit("opencode-v2 toggle patch: anchor count %d (expected 1)" % n)
    if len(core) > len(old):
        raise SystemExit("opencode-v2 toggle patch: core longer than anchor")
    new = core + b" " * (len(old) - len(core))
    out = data.replace(old, new)
    if len(out) != len(data):
        raise SystemExit("opencode-v2 toggle patch: size changed")
    if out.count(new) != 1:
        raise SystemExit("opencode-v2 toggle patch: replacement not unique")
    p.write_bytes(out)
    print("opencode-v2: toggle patch applied (rQ: toggle->tQ; effort/budget stay di)")
    PY
  '';

  nativeBuildInputs = [ prev.autoPatchelfHook prev.python3 ];
  # ldd 实测仅依赖 glibc（libc/libm/libpthread/libdl/ld-linux）；
  # 保留 cc.lib 兜底可能的 dlopen 或间接 libstdc++/libgcc_s 依赖（多装无害）。
  buildInputs = [ prev.stdenv.cc.cc.lib ];

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
