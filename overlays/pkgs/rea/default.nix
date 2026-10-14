{
  final,
  prev,
  ghidra ? null,
}:

let
  inherit (final) lib;
  version = "6.4.0";
  lockfile = prev.fetchurl {
    url = "https://raw.githubusercontent.com/morluto/rea/rea-agents-${version}/package-lock.json";
    hash = "sha256-tlXiEYl71yAy72kmG+hxDlA3se3neBBsj+9zAwetAFk=";
  };
  wrapperArgs =
    lib.optionals (ghidra != null) [
      "--set-default"
      "REA_ANALYSIS_PROVIDER"
      "ghidra"
      "--set-default"
      "GHIDRA_INSTALL_DIR"
      "${ghidra}/lib/ghidra"
      "--set-default"
      "JAVA_HOME"
      prev.jdk21.home
    ]
    ++ [
      "--suffix"
      "PATH"
      ":"
      (lib.makeBinPath (
        # REA verifies ownership with ps before any PTY/provider child launch.
        [
          prev.nodejs_24
          prev.procps
        ]
        ++ lib.optionals (ghidra != null) [
          prev.jdk21
          prev.bash
          prev.coreutils
          prev.gnugrep
          prev.gnused
        ]
      ))
    ];
in
prev.buildNpmPackage (attrs: {
  pname = "rea";
  inherit version;
  nodejs = prev.nodejs_24;

  # The published artifact includes dist/ and the generated skills. Do not run
  # prepare/prepack: those are source/release workflows, not offline installs.
  src = prev.fetchurl {
    url = "https://registry.npmjs.org/rea-agents/-/rea-agents-${version}.tgz";
    hash = "sha512-Vj1zWfSlna5bphGoaoI/TcVBuYvze9u+OyPC3Shz8YkBqaCTqB4COnnRoX7XDwMpwI24ZlFEel2yEj0k8LTWEQ==";
  };

  postPatch = ''
    # Keep the upstream resolutions and integrity hashes, excluding only
    # development dependencies of the already-built release.
    ${prev.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.tmp
    mv package.json.tmp package.json
    ${prev.jq}/bin/jq '
      del(.packages[""].devDependencies)
      | .packages |= with_entries(select(.value.dev != true))
    ' ${lockfile} > package-lock.json
  '';

  npmDepsHash = "sha256-swbjGsWX/zoQXgR2F5R22Ff8qedS4ZHCz67QBf7phaE=";
  npmFlags = [ "--ignore-scripts" ];
  npmInstallFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  nativeBuildInputs = [
    prev.autoPatchelfHook
    prev.makeWrapper
  ];
  # @lydell/node-pty selects the matching Linux x64/arm64 optional package.
  buildInputs = [ prev.stdenv.cc.cc.lib ];

  # Everything in the tarball is already an intended release artifact. Copy it
  # directly rather than invoking npm pack (and possibly its release hooks).
  installPhase = ''
    runHook preInstall
    packageRoot="$out/lib/node_modules/rea-agents"
    mkdir -p "$packageRoot" "$out/bin" "$out/share/agents/skills"
    cp -r dist bridge native scripts skills third_party licenses \
      package.json node_modules install.sh README.md LICENSE "$packageRoot/"
    # Export a real tree: aggregation copies this with cp -r, which would keep
    # the relative symlink produced by Nix fixup and break it at the new root.
    # Per-file links also fail REA's doctor.
    cp -r "$packageRoot/skills/reverse-engineer-anything" "$out/share/agents/skills/"
    makeWrapper ${attrs.nodejs}/bin/node "$out/bin/rea" \
      --add-flags "$packageRoot/scripts/rea.mjs" \
      ${lib.escapeShellArgs wrapperArgs}
    ln -s rea "$out/bin/rea-agents"
    runHook postInstall
  '';

  passthru = {
    skills = "${attrs.finalPackage}/share/agents/skills";
    tests.smoke = prev.runCommand "rea-${version}-smoke" { } ''
      ${attrs.nodejs}/bin/node ${./smoke.mjs} ${attrs.finalPackage} \
        ${prev.bash}/bin/bash ${lib.optionalString (ghidra != null) "ghidra"}
      touch "$out"
    '';
  };

  meta = {
    description = "Reverse engineering CLI, MCP server and agent skill";
    homepage = "https://github.com/morluto/rea";
    license = lib.licenses.mit;
    mainProgram = "rea";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
