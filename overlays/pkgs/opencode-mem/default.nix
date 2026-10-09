{ inputs, final, prev }:

# opencode-mem：OpenCode 记忆插件。产物是 npm tarball（不是可执行包），
# 由 opencode.json 的 plugin 条目以 `opencode-mem@file:<tgz>` 引用；opencode 仍按 npm
# 流程安装它的依赖（含 onnxruntime-node / libsql 原生模块），所以这里不 vendor node_modules。
#
# 2.28.3 的 dist/plugin.js 已双导出 `{ ...OpenCodeMemPluginV2, id, server }`：default.setup
# 供 OpenCode v2 loader 使用，server 供 v1，兼容 v2。
#
# 原 compaction-model.patch（压缩后注入 "Restored Session Memory" 时显式带上会话当前
# model/variant，避免自带模型的 agent 把会话切走）已由上游 PR tickernelz/opencode-mem#326
# 合入 2.27.0+，故不再打补丁。compaction-model.test.mjs 转为回归守护上游合入后的行为：
# 注入内容带会话当前 model/variant（"default" variant 按 OpenCode 归一化省略）。
let
  version = "2.29.2";
in
prev.runCommand "opencode-mem-${version}.tgz"
  {
    src = prev.fetchurl {
      url = "https://registry.npmjs.org/opencode-mem/-/opencode-mem-${version}.tgz";
      hash = "sha256-Ws8UIrd/3mw6b8efTw+w+We10LahA/ezsEJrYOMkN4Y=";
    };
    nativeBuildInputs = [ prev.gnutar prev.gzip prev.nodejs ];
    passthru = { inherit version; };
  }
  ''
    tar xzf $src
    node --check package/dist/index.js
    node --check package/dist/plugin.js
    MEM_BUNDLE="$PWD/package/dist/index.js" node --test ${./compaction-model.test.mjs}
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > $out
  ''
