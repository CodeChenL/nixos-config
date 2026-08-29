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

      _flash_stream() {
        local src="$1" dst="$2" decompress="$3"
        _flash_require_path "$src" || return 1
        _flash_require_path "$dst" || return 1
        echo "Flash $src to $dst"
        (
          set -o pipefail
          {
            case "$decompress" in
              xz) ${pkgs.xz}/bin/xzcat "$src" ;;
              gz) ${pkgs.gzip}/bin/zcat "$src" ;;
              *) ${pkgs.coreutils}/bin/cat "$src" ;;
            esac
          } | sudo ${pkgs.coreutils}/bin/dd of="$dst" bs=52M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      _flash_url() {
        local url="$1" dst="$2" decompress="$3"
        _flash_require_path "$dst" || return 1
        echo "Flash $url to $dst"
        (
          set -o pipefail
          ${pkgs.curl}/bin/curl -L --fail "$url" \
            | "$decompress" \
            | sudo ${pkgs.coreutils}/bin/dd of="$dst" bs=5M status=progress oflag=direct iflag=fullblock
        ) && sudo ${pkgs.coreutils}/bin/sync
      }

      fxz() { _flash_stream "$1" "$2" xz; }
      fgz() { _flash_stream "$1" "$2" gz; }
      fimg() { _flash_stream "$1" "$2" cat; }
      fxzu() {
        if [ -z "$1" ]; then
          echo "usage: fxzu <url> <dest>" >&2
          return 1
        fi
        _flash_url "$1" "$2" "${pkgs.xz}/bin/xzcat"
      }
      fgzu() {
        if [ -z "$1" ]; then
          echo "usage: fgzu <url> <dest>" >&2
          return 1
        fi
        _flash_url "$1" "$2" "${pkgs.gzip}/bin/zcat"
      }
      fimgu() {
        if [ -z "$1" ]; then
          echo "usage: fimgu <url> <dest>" >&2
          return 1
        fi
        _flash_url "$1" "$2" "${pkgs.coreutils}/bin/cat"
      }
    '';
  };
}
