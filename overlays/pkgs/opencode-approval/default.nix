{ prev ? import <nixpkgs> { } }:

# opencode-approval：OpenCode v2「模型代审授权」插件（参考 Codex Guardian 审查器）。
# 产物是 npm tarball（不是可执行包），由 opencode 配置的 plugins 条目以
# `opencode-approval@file:<tgz>` 引用。插件零依赖（只用 node 内置模块），
# 所以不 vendor node_modules。
#
# 三层裁决：显式策略 → 同步确定性规则（fastpath / 硬拒绝 / 硬放行）→ 模型审查；
# 审查失败 fail-closed（默认 deny），连续 3 次失败触发 60 秒熔断。
#
# TUI 半（tui.js）：/approval-mode、/approval-model 两个 slash 命令（RPC + toast，
# 不向会话注入消息），以及侧栏 Approval 面板（模式/审查链/最近裁决，deny 时 toast）；
# 经 exports["./tui"] 由 TUI 自动加载。面板元素渲染走 render-lib.js 的
# opentui:runtime-module:* 虚拟标识（复用宿主 OpenTUI 实例）。
#
# prev 带默认值是为了让裸 `pkgs.callPackage ./overlays/pkgs/opencode-approval {}`
# 能直接构建（nixpkgs 的 pkgs 集合里没有 prev 属性）；overlay 里使用时请显式传
# `import ./pkgs/opencode-approval { inherit prev; }`。
let
  version = "0.7.9";
in
prev.runCommand "opencode-approval-${version}.tgz"
  {
    nativeBuildInputs = [ prev.nodejs ];
    passthru = { inherit version; };
  }
  ''
    cp -r ${./plugin} plugin
    chmod -R u+w plugin
    cp -r ${./tests} tests
    chmod -R u+w tests
    # 文档示例与发行版本也有回归测试，测试前提供对应源码快照。
    cp ${./README.md} README.md
    cp ${./default.nix} default.nix

    # 构建期校验：语法检查 + 全量单测（目录形式 node --test 不认，用 glob）
    node --check plugin/index.js
    node --check plugin/tui.js
    node --check plugin/render-lib.js
    node --test "tests/*.test.mjs"

    mkdir package
    cp plugin/package.json plugin/index.js plugin/tui.js plugin/render-lib.js README.md package/

    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > $out
  ''
