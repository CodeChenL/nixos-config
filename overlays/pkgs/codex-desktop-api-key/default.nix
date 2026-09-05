{ inputs, final, prev }:

let
  system = prev.stdenv.hostPlatform.system;
  ultraPatchScript = ./unlock-api-key-ultra.js;
  apiKeyUltraGatesScript = ./api-key-ultra-gates.js;
  bundleSourceMapScript = ./bundle-source-map.js;
  dreamSkinPatchScript = ./dreamskin-patch.js;
  dreamSkinSource = final.fetchFromGitHub {
    owner = "Fei-Away";
    repo = "Codex-Dream-Skin";
    rev = "e0341de41e3a4490194bf1fa3e7f3735ed6103df";
    hash = "sha256-nrE3Zs9huPrpx52eYUpwcxKKnoywj6Ckjc3J/unVOxA=";
  };
in
# Desktop-only API-key UI patch. The provider still owns the actual
# service-tier/reasoning semantics; this package only exposes the controls.
{
      linuxFeatureIds ? [ ],
      enableComputerUseUi ? false,
      # Small opt-in escape hatch: expose the existing upstream Ultra candidate
      # for API-key hosts; the provider still decides whether Ultra is accepted.
      enableApiKeyUltraUiPatch ? false,
      dreamSkinThemePackage ? null,
      dreamSkinAllowPlatformMismatch ? false,
    }:
    let
      featureIds = final.lib.unique (
        linuxFeatureIds
        ++ [
          "api-key-model-visibility"
          "api-key-service-tier"
        ]
      );
      base = inputs.codex-desktop-linux.packages.${system}.codex-desktop.override {
        linuxFeatureIds = featureIds;
        inherit enableComputerUseUi;
      };
      dreamSkinPlatformFlag = final.lib.optionalString dreamSkinAllowPlatformMismatch " --allow-platform-mismatch";
      dreamSkinInstall = final.lib.optionalString (dreamSkinThemePackage != null) ''
        dreamskin_zip=${dreamSkinThemePackage}
        dreamskin_listing="$TMPDIR/codex-dreamskin-zip-list"
        dreamskin_zip_bytes="$(${final.coreutils}/bin/stat -c '%s' "$dreamskin_zip")"
        if [ "$dreamskin_zip_bytes" -gt 33554432 ]; then
          echo "DreamSkin ZIP exceeds the 32 MiB limit: $dreamskin_zip_bytes" >&2
          exit 1
        fi
        ${final.unzip}/bin/unzip -Z1 "$dreamskin_zip" > "$dreamskin_listing"
        dreamskin_entries="$(${final.coreutils}/bin/wc -l < "$dreamskin_listing")"
        if [ "$dreamskin_entries" -gt 32 ]; then
          echo "DreamSkin ZIP has too many entries: $dreamskin_entries" >&2
          exit 1
        fi
        while IFS= read -r dreamskin_entry; do
          case "$dreamskin_entry" in
            /*|../*|*/../*|*\\*)
              echo "Unsafe DreamSkin ZIP path: $dreamskin_entry" >&2
              exit 1
              ;;
          esac
        done < "$dreamskin_listing"
        ${final.unzip}/bin/unzip -q -n "$dreamskin_zip" -d "$TMPDIR/codex-dreamskin-theme"
        dreamskin_expanded_bytes="$(${final.coreutils}/bin/du -sb "$TMPDIR/codex-dreamskin-theme" | cut -f1)"
        if [ "$dreamskin_expanded_bytes" -gt 67108864 ]; then
          echo "DreamSkin ZIP expands beyond the 64 MiB limit: $dreamskin_expanded_bytes" >&2
          exit 1
        fi
        CODEX_BUNDLE_SOURCE_MAP=${bundleSourceMapScript} ${final.nodejs}/bin/node ${dreamSkinPatchScript} "$extracted" \
          --source ${dreamSkinSource} \
          --theme "$TMPDIR/codex-dreamskin-theme"${dreamSkinPlatformFlag}
        install -Dm0644 "$extracted/.codex-linux/dreamskin-native-patch.json" \
          "$app/.codex-linux/dreamskin-native-patch.json"
        install -Dm0644 "${dreamSkinSource}/LICENSE" \
          "$app/.codex-linux/dreamskin-runtime-LICENSE"
      '';
      apiKeyUltraInstall = final.lib.optionalString enableApiKeyUltraUiPatch ''
        CODEX_API_KEY_ULTRA_GATES=${apiKeyUltraGatesScript} \
          CODEX_BUNDLE_SOURCE_MAP=${bundleSourceMapScript} \
          ${final.nodejs}/bin/node ${ultraPatchScript} "$extracted" || exit 1
        install -Dm0644 "$extracted/.codex-linux/api-key-ultra-patch.json" \
          "$app/.codex-linux/api-key-ultra-patch.json"
      '';
      watchboundEnabled = final.lib.elem "directory-only-working-tree-watch" featureIds;
      watchboundDigestUpdate = final.lib.optionalString watchboundEnabled ''
        set -- "$extracted"/node_modules/@gadicc/watchbound-node-linux-*-gnu/package.json
        if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
          echo "Expected exactly one Watchbound native package" >&2
          exit 1
        fi
        watchbound_package="$1"
        watchbound_digest="$(${final.nodejs}/bin/node - "$watchbound_package" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const packagePath = process.argv[2];
const descriptor = JSON.parse(fs.readFileSync(packagePath, "utf8"));
const binary = descriptor.watchbound?.binary;
if (typeof binary !== "string" || path.basename(binary) !== binary) {
  throw new Error("Invalid Watchbound native binary declaration");
}
const digest = crypto.createHash("sha256")
  .update(fs.readFileSync(path.join(path.dirname(packagePath), binary)))
  .digest("hex");
descriptor.watchbound.nativeSha256 = digest;
fs.writeFileSync(packagePath, JSON.stringify(descriptor, null, 2) + "\n");
process.stdout.write(digest);
NODE
        )"
      '';
      watchboundDigestCheck = final.lib.optionalString watchboundEnabled ''
        set -- "$rebuilt.unpacked"/node_modules/@gadicc/watchbound-node-linux-*-gnu/*.node
        if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
          echo "Expected exactly one rebuilt Watchbound native module" >&2
          exit 1
        fi
        printf '%s  %s\n' "$watchbound_digest" "$1" | ${final.coreutils}/bin/sha256sum -c -
      '';
    in
      base.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        app="$out/opt/codex-desktop"
        resources="$app/resources"
        asar="$resources/app.asar"
        unpacked="$resources/app.asar.unpacked"
        extracted="$TMPDIR/codex-desktop-api-key-asar"
        rebuilt="$TMPDIR/codex-desktop-api-key-app.asar"
        ordering="$TMPDIR/codex-desktop-api-key-ordering"

        ${final.asar}/bin/asar extract "$asar" "$extracted"
        if [ -d "$unpacked" ]; then
          # asar extract does not include Electron's external native files.
          # Put them back into the staging tree so --unpack recreates the
          # corresponding app.asar.unpacked directory and header flags.
          cp -a "$unpacked/." "$extracted/"
        fi
        ${apiKeyUltraInstall}
        ${dreamSkinInstall}
        rm -f "$extracted/.codex-linux/api-key-ui-patch.json" \
          "$extracted/.codex-linux/api-key-ultra-patch.json" \
          "$extracted/.codex-linux/dreamskin-native-patch.json"
        ${watchboundDigestUpdate}
        (cd "$extracted" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$ordering"
        ${final.asar}/bin/asar pack "$extracted" "$rebuilt" \
          --ordering "$ordering" \
          --unpack "{*.node,*.so,*.dylib}"
        ${watchboundDigestCheck}
        install -m 0644 "$rebuilt" "$asar"
        if [ -d "$rebuilt.unpacked" ]; then
          rm -rf "$unpacked"
          mv "$rebuilt.unpacked" "$unpacked"
        fi
      '';
    })
