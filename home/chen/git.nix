{ config, pkgs, ... }:

{
  # ── Git commit 模板文件 ──────────────────────────────────────────
  home.file.".gitmessage.txt".text = ''

    Signed-off-by: Jiali Chen <chenjiali@radxa.com>
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
