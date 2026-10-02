{ final, prev, ... }:

let
  version = "5.0.0-beta.84";
  testSource = prev.lib.fileset.toSource {
    root = ./.;
    fileset = prev.lib.fileset.fileFilter (file: file.hasExt "mjs") ./.;
  };
  remedaSource = prev.fetchurl {
    url = "https://registry.npmjs.org/remeda/-/remeda-2.26.0.tgz";
    hash = "sha256-cM5zzLIQiEPSgIU/4AF0jc5KtdTxCtBoJhF0yKsDVx0=";
  };
in
prev.runCommand "oh-my-openagent-${version}.tgz"
  {
    src = prev.fetchurl {
      url = "https://registry.npmjs.org/oh-my-openagent/-/oh-my-openagent-${version}.tgz";
      hash = "sha256-Jp0sSsfnDp63YgXk741tGVGfzJ06EcKCfMIWdc6DKbo=";
    };
    nativeBuildInputs = [ prev.gnutar prev.gzip prev.patch prev.nodejs ];
    passthru = { inherit version; };
  }
  ''
    tar xzf $src
    patch -p1 --fuzz=0 --no-backup-if-mismatch < ${./background-lifecycle.patch}
    patch -p1 --fuzz=0 --no-backup-if-mismatch < ${./junior-reasoning.patch}
    node --check package/dist/index.js
    mkdir remeda
    tar xzf ${remedaSource} -C remeda
    OMO_BUNDLE="$PWD/package/dist/index.js" \
      OPENCODE_SOURCE=${final.unstable.opencode.src} \
      REMEDA_ENTRY="$PWD/remeda/package/dist/index.cjs" \
      node --test ${testSource}/*.test.mjs
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > $out
  ''
