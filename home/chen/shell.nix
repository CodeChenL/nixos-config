{ config, pkgs, lib, ... }:

{
  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" ];

    shellAliases = {
      copilot = "${config.home.profileDirectory}/bin/copilot";
      prock = "reset && picocom -q -b 1500000 /dev/ttyUSB0";
      paml = "reset && picocom -q -b 115200 /dev/ttyUSB0";
    };

    profileExtra = ''
      export LANGUAGE=en_US
      export LANG=en_US.UTF-8
      export PATH="$PATH:$HOME/.cargo/bin:$HOME/.local/bin"
    '';

    bashrcExtra = ''
      export PS1="[\u@\h \A]\n[\$? \w]\$ "

      _flash_require_path() {
        if [ ! -e "$1" ]; then
          echo "$1 not found"
          return 1
        fi
      }

      fxz() {
        _flash_require_path "$1" || return 1
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        (
          set -o pipefail
          ${pkgs.xz}/bin/xzcat "$1" \
            | sudo ${pkgs.coreutils}/bin/dd of="$2" bs=52M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      fgz() {
        _flash_require_path "$1" || return 1
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        (
          set -o pipefail
          ${pkgs.gzip}/bin/zcat "$1" \
            | sudo ${pkgs.coreutils}/bin/dd of="$2" bs=52M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      fimg() {
        _flash_require_path "$1" || return 1
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        sudo ${pkgs.coreutils}/bin/dd if="$1" of="$2" bs=52M status=progress oflag=direct iflag=fullblock \
          && sudo ${pkgs.coreutils}/bin/sync
      }

      fxzu() {
        if [ -z "$1" ]; then
          echo "usage: fxzu <url> <dest>" >&2
          return 1
        fi
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        (
          set -o pipefail
          ${pkgs.curl}/bin/curl -L --fail "$1" \
            | ${pkgs.xz}/bin/xzcat \
            | sudo ${pkgs.coreutils}/bin/dd of="$2" bs=5M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      fgzu() {
        if [ -z "$1" ]; then
          echo "usage: fgzu <url> <dest>" >&2
          return 1
        fi
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        (
          set -o pipefail
          ${pkgs.curl}/bin/curl -L --fail "$1" \
            | ${pkgs.gzip}/bin/zcat \
            | sudo ${pkgs.coreutils}/bin/dd of="$2" bs=5M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      fimgu() {
        if [ -z "$1" ]; then
          echo "usage: fimgu <url> <dest>" >&2
          return 1
        fi
        _flash_require_path "$2" || return 1
        echo "Flash $1 to $2"
        (
          set -o pipefail
          ${pkgs.curl}/bin/curl -L --fail "$1" \
            | sudo ${pkgs.coreutils}/bin/dd of="$2" bs=5M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }
    '';
  };
}
