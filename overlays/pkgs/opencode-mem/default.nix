{ inputs, final, prev }:

# opencode-mem：OpenCode 记忆插件。产物是打过补丁的 npm tarball（不是可执行包），
# 由 opencode.json 的 plugin 条目以 `opencode-mem@file:<tgz>` 引用；opencode 仍按 npm
# 流程安装它的依赖（含 onnxruntime-node / libsql 原生模块），所以这里不 vendor node_modules。
#
# compaction-model.patch：压缩后注入 "Restored Session Memory" 时显式带上会话当前
# model/variant。上游 2.26.0 只传 agent；服务端按 input.model ?? agent.model ?? session.model
# 取模型，自带模型的 agent（OMO Sisyphus）会把会话切到 agent 默认模型（实测切到
# gpt-5.6-sol medium）。
let
  version = "2.26.0";
in
prev.runCommand "opencode-mem-${version}.tgz"
  {
    src = prev.fetchurl {
      url = "https://registry.npmjs.org/opencode-mem/-/opencode-mem-${version}.tgz";
      hash = "sha256-AYLxr85aV2nDp5D+vC+/P4m9bKbpOHFxNRc8MCkHZVg=";
    };
    nativeBuildInputs = [ prev.gnutar prev.gzip prev.patch prev.nodejs ];
    passthru = { inherit version; };
  }
  ''
    tar xzf $src
    patch -p1 --fuzz=0 --no-backup-if-mismatch < ${./compaction-model.patch}
    node --check package/dist/index.js
    MEM_BUNDLE="$PWD/package/dist/index.js" node --test ${./compaction-model.test.mjs}
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > $out
  ''
