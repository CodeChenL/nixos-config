{ inputs, final, prev }:

let
  system = prev.stdenv.hostPlatform.system;
  patchScript = ./patch-desktop-app.js;
  ultraPatchScript = ./unlock-api-key-ultra.js;
  apiKeyUltraGatesScript = ./api-key-ultra-gates.js;
  bundleSourceMapScript = ./bundle-source-map.js;
  dreamSkinPatchScript = ./dreamskin-patch.js;
  dreamSkinSource = final.fetchFromGitHub {
    owner = "Fei-Away";
    repo = "Codex-Dream-Skin";
    rev = "95423d849f74b9824db2ba0c1121cc7a13b56d10";
    hash = "sha256-b+JR9l8XCoSMYqCUwmmCYXOFuxu8C8O24ZTvVsu37Jo=";
  };
in
{
  # Desktop-only API-key UI patch. The provider still owns the actual
  # service-tier/reasoning semantics; this package only exposes the controls.
  codex-desktop-api-key =
    {
      linuxFeatureIds ? [ ],
      enableComputerUseUi ? false,
      # Keep the upstream Linux feature path as the default. The direct
      # app-initial bundle patch remains available as an explicit escape hatch
      # for providers whose catalog cannot describe their reasoning options.
      enableCustomApiKeyUiPatch ? false,
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
      apiKeyUiInstall = final.lib.optionalString enableCustomApiKeyUiPatch ''
        CODEX_API_KEY_ULTRA_GATES=${apiKeyUltraGatesScript} \
          CODEX_BUNDLE_SOURCE_MAP=${bundleSourceMapScript} \
          ${final.nodejs}/bin/node ${patchScript} "$extracted"
        install -Dm0644 "$extracted/.codex-linux/api-key-ui-patch.json" \
          "$app/.codex-linux/api-key-ui-patch.json"
      '';
      apiKeyUltraInstall = final.lib.optionalString enableApiKeyUltraUiPatch ''
        CODEX_API_KEY_ULTRA_GATES=${apiKeyUltraGatesScript} \
          CODEX_BUNDLE_SOURCE_MAP=${bundleSourceMapScript} \
          ${final.nodejs}/bin/node ${ultraPatchScript} "$extracted"
        install -Dm0644 "$extracted/.codex-linux/api-key-ultra-patch.json" \
          "$app/.codex-linux/api-key-ultra-patch.json"
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
        ${apiKeyUiInstall}
        ${apiKeyUltraInstall}
        ${dreamSkinInstall}
        rm -f "$extracted/.codex-linux/api-key-ui-patch.json" \
          "$extracted/.codex-linux/api-key-ultra-patch.json" \
          "$extracted/.codex-linux/dreamskin-native-patch.json"
        (cd "$extracted" && find . -type f -printf '%P\n' | LC_ALL=C sort) > "$ordering"
        ${final.asar}/bin/asar pack "$extracted" "$rebuilt" \
          --ordering "$ordering" \
          --unpack "{*.node,*.so,*.dylib}"
        install -m 0644 "$rebuilt" "$asar"
        if [ -d "$rebuilt.unpacked" ]; then
          rm -rf "$unpacked"
          mv "$rebuilt.unpacked" "$unpacked"
        fi
      '';
    });
}
