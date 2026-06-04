{ config, pkgs, ... }:

{
  # ── Git commit 模板文件 ──────────────────────────────────────────
  home.file.".gitmessage.txt".text = ''

    Signed-off-by: Jiali Chen <chenjiali@radxa.com>
  '';

  programs.git = {
    enable = true;

    signing = {
      key = "75B292EBF683FF87";
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

      safe.directory = [
        "/mnt"
        "/run/media/chen/rootfs/home"
        "/home/chen/Documents/GitHub/build"
        "/run/media/chen/edad4323-81aa-4673-8abd-d5ccf39a3ef0"
      ];
    };
  };
}
