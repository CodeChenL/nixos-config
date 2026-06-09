{ config, pkgs, lib, ... }:

{
  # ── Git commit 模板文件 ──────────────────────────────────────────
  home.file.".gitmessage.txt".text = ''

    Signed-off-by: Jiali Chen <chenjiali@radxa.com>
  '';

  # Git 签名私钥从运行时 secrets 导入，避免私钥进入 nix store。
  home.activation.importGitSigningKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        GPG_SECRET_KEY="$HOME/nixos-config/secrets/gpg-secret.key"
        GPG_OWNERTRUST="$HOME/nixos-config/secrets/gpg-ownertrust.txt"
        GPG_STATE_DIR="$HOME/.local/state/home-manager"
        GPG_STAMP="$GPG_STATE_DIR/git-signing-key.sha256"

        if [ -f "$GPG_SECRET_KEY" ]; then
          mkdir -p "$GPG_STATE_DIR"
          chmod 700 "$GPG_STATE_DIR"
          GPG_CURRENT_HASH=$(
            {
              ${pkgs.coreutils}/bin/sha256sum "$GPG_SECRET_KEY"
              if [ -f "$GPG_OWNERTRUST" ]; then
                ${pkgs.coreutils}/bin/sha256sum "$GPG_OWNERTRUST"
              fi
            } | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
          )
          GPG_PREVIOUS_HASH=""
          if [ -f "$GPG_STAMP" ]; then
            GPG_PREVIOUS_HASH=$(${pkgs.coreutils}/bin/cat "$GPG_STAMP")
          fi

          if [ "$GPG_CURRENT_HASH" != "$GPG_PREVIOUS_HASH" ]; then
            ${pkgs.gnupg}/bin/gpg --batch --import "$GPG_SECRET_KEY"
            if [ -f "$GPG_OWNERTRUST" ]; then
              ${pkgs.gnupg}/bin/gpg --batch --import-ownertrust "$GPG_OWNERTRUST"
            fi
            printf '%s\n' "$GPG_CURRENT_HASH" > "$GPG_STAMP"
            chmod 600 "$GPG_STAMP"
          fi
        fi
  '';

  programs.git = {
    enable = true;

    signing = {
      key = "0CD0983EE24BB4F21897E92075B292EBF683FF87";
      signByDefault = true;
      format = "openpgp";
    };

    lfs.enable = true;

    settings = {
      user = {
        name = "Jiali Chen";
        email = "chenjiali@radxa.com";
      };

      core.editor = "code --wait";

      pull.rebase = true;
      rebase = {
        autoStash = true;
        autoSquash = true;
      };

      commit = {
        signoff = true;
        template = "${config.home.homeDirectory}/.gitmessage.txt";
      };

      format.signoff = true;

      http.postBuffer = 2048576000;

      credential = {
        "https://github.com" = {
          helper = [
            ""
            "!/usr/bin/env gh auth git-credential"
          ];
        };
        "https://gist.github.com" = {
          helper = [
            ""
            "!/usr/bin/env gh auth git-credential"
          ];
        };
      };

      alias.commits = "commit -s";

      trailer.changeid.key = "Change-Id";
    };
  };
}
