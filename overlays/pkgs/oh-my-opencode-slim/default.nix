{ final, prev, ... }:

let
  version = "3.0.3";
  bun = final.unstable.bun;
  # 宿主（opencode-v2）编译期 catalog：github.com/anomalyco/opencode 的
  # package.json → workspaces.catalog。@opentui/* 与 solid-js 由 TUI 宿主与插件
  # 共享进程全局状态（OPENTUI_* 环境变量注册表），必须与宿主内嵌版本完全一致，
  # 否则 TUI 插件加载时报 "already registered with different configuration"。
  # 当前对应 opencode-v2 2.0.26（catalog @opentui 0.5.17）；升级 opencode-v2 版本时同步更新这三个值。
  hostCatalog = {
    "@opentui/core" = "0.5.17";
    "@opentui/solid" = "0.5.17";
    "solid-js" = "1.9.15";
  };
  src = prev.fetchzip {
    url = "https://codeload.github.com/alvinunreal/oh-my-opencode-slim/tar.gz/4f9dd67a5f94b1a732e667a0e4ec32c181ca4ddb";
    extension = "tar.gz";
    hash = "sha256-CmKlmkkqX8oWQ/jSxJLRREhiyJ0cc+F8gNSQty/TPu4=";
  };
  # PR #1415（v2 retry-hook fallback + review 修正）已合入上游 3.0.3，不再打补丁。
  patches = [ ];
  nodeModules = prev.stdenvNoCC.mkDerivation {
    pname = "oh-my-opencode-slim-deps";
    inherit version src;
    nativeBuildInputs = [ bun prev.cacert ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      # Keep the dependency closure identical on the Linux x86_64 and aarch64 hosts.
      bun install --frozen-lockfile --ignore-scripts --os=linux --cpu='*'
    '';
    installPhase = ''
      mkdir -p "$out"
      cp -r node_modules "$out/"
    '';
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-JZiHU97oZCaXJ8rMrlCICywmbhZOMHM0uH4o7DAODg8=";
  };
  package = prev.stdenvNoCC.mkDerivation {
    pname = "oh-my-opencode-slim";
    inherit version src patches;
    patchFlags = [ "-p1" "--fuzz=0" ];
    nativeBuildInputs = [ bun prev.nodejs prev.jq ];
    dontConfigure = true;
    dontFixup = true;
    preBuild = ''
      export HOME="$TMPDIR/home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export XDG_DATA_HOME="$HOME/.local/share"
      export XDG_CACHE_HOME="$HOME/.cache"
      mkdir -p "$HOME"
      cp -r ${nodeModules}/node_modules node_modules
      chmod -R u+w node_modules
      patchShebangs --build node_modules
    '';
    buildPhase = ''
      runHook preBuild
      bun run build
      runHook postBuild
    '';
    postBuild = ''
      # 宿主（opencode-v2 2.0.22）的 TUI 运行时会重写「本地插件」的 @opentui/*、solid-js
      # 导入为 opentui:runtime-module:* 虚拟模块，让插件复用宿主内嵌实例（共享 Solid
      # RendererContext）。但 npm 安装的插件（node_modules ESM）不走该重写：插件自带的
      # @opentui/solid 实例拿不到宿主渲染上下文，侧栏渲染时报 "No renderer found"，
      # 只弹一次 toast 后静默空白（表现为「加载不报错、界面不显示」）。
      # 这里直接把产物里的裸导入改写为宿主虚拟模块 id（tui2.js 共 4 处），宿主大版本
      # 升级导致虚拟模块机制变化时需同步调整；tui.js 是 v1 入口，不受影响。
      node - <<'NODE'
      const fs = require("node:fs");
      const file = "dist/tui2.js";
      let code = fs.readFileSync(file, "utf8");
      const rewrite = (from, to, min) => {
        const needle = 'from "' + from + '"';
        const count = code.split(needle).length - 1;
        if (count < min) throw new Error("tui2.js runtime-module patch: " + from + " found " + count + " < " + min);
        code = code.split(needle).join('from "' + to + '"');
      };
      rewrite("@opentui/core", "opentui:runtime-module:%40opentui%2Fcore", 1);
      rewrite("@opentui/solid", "opentui:runtime-module:%40opentui%2Fsolid", 2);
      rewrite("solid-js", "opentui:runtime-module:solid-js", 1);
      for (const leftover of ['from "@opentui/', 'import "@opentui/', 'from "solid-js', 'import "solid-js']) {
        if (code.includes(leftover)) throw new Error("tui2.js runtime-module patch: leftover " + leftover);
      }
      fs.writeFileSync(file, code);
      NODE
      node --check dist/tui2.js
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      bun test src/hooks/foreground-fallback/index.test.ts
      bun test src/index.test.ts -t "host"
      bun test src/config/schema.test.ts src/config/model-resolution.test.ts src/agents/index.test.ts src/utils/background-task-concurrency.test.ts
      node --check dist/index.js
      node --check dist/server/index.js
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/src"
      cp -r dist src/skills "$out/"
      mv "$out/skills" "$out/src/skills"
      cp package.json oh-my-opencode-slim.schema.json LICENSE README*.md "$out/"
      # 注：@opentui/* 必须声明为普通 dependencies 而非 optionalDependencies。
      # opencode v2 插件安装器用 npm 安装本包；npm 对 engines 不满足的 optional
      # 依赖会静默跳过——@opentui/core@0.5.14 声明 "node": ">=26.4.0"（安装侧 node
      # 为 24.x），导致 TUI 插件运行时报 "Cannot find package '@opentui/core'"。
      # 作为普通依赖时 npm 仅告警仍会安装（运行期是 Bun，满足 bun>=1.3 约束）。
      # oh-my-openagent 上游亦采用该布局（@opentui/* 在 dependencies）。
      jq --arg core ${prev.lib.escapeShellArg hostCatalog."@opentui/core"} \
        --arg solid ${prev.lib.escapeShellArg hostCatalog."@opentui/solid"} \
        --arg js ${prev.lib.escapeShellArg hostCatalog."solid-js"} \
        '.dependencies["@opentui/core"] = $core |
         .dependencies["@opentui/solid"] = $solid |
         .dependencies["solid-js"] = $js |
         del(.optionalDependencies["@opentui/core"],
             .optionalDependencies["@opentui/solid"],
             .optionalDependencies["solid-js"])' \
        "$out/package.json" > "$out/package.json.tmp"
      mv "$out/package.json.tmp" "$out/package.json"
      runHook postInstall
    '';
  };
in
prev.runCommand "oh-my-opencode-slim-${version}.tgz"
  {
    nativeBuildInputs = [ prev.gnutar prev.gzip ];
    passthru = {
      inherit version src patches nodeModules package;
      skills = "${package}/src/skills";
    };
  }
  ''
    cp -r ${package} package
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > "$out"
  ''
