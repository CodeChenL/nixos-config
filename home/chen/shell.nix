{ config, pkgs, lib, ... }:

{
  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" ];

    shellAliases = {
      prock = "reset && picocom -q -b 1500000 /dev/ttyUSB0";
      paml = "reset && picocom -q -b 115200 /dev/ttyUSB0";
    };

    profileExtra = ''
      export LANGUAGE=en_US
      export LANG=en_US.UTF-8
      export PATH="$PATH:$HOME/.local/bin"
    '';

    bashrcExtra = ''
      export PS1="[\u@\h \A]\n[\$? \w]\$ "

      fxz() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "xzcat \"$1\" | dd of=\"$2\" bs=52M status=progress oflag=direct iflag=fullblock && sync"
      }

      fgz() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "zcat \"$1\" | dd of=\"$2\" bs=52M status=progress oflag=direct iflag=fullblock && sync"
      }

      fimg() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "dd if=\"$1\" of=\"$2\" bs=52M status=progress oflag=direct iflag=fullblock && sync"
      }

      fxzu() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "curl -L $1 | xzcat | dd of=$2 bs=5M status=progress oflag=direct iflag=fullblock && sync"
      }

      fgzu() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "curl -L $1 | zcat | dd of=\"$2\" bs=5M status=progress oflag=direct iflag=fullblock && sync"
      }

      fimgu() {
        if [ -d "$2" ]; then
          echo "$2 not found"
          return 1
        fi
        echo "Flash $1 to $2"
        sudo sh -c "curl -L $1 | dd of=$2 bs=5M status=progress oflag=direct iflag=fullblock && sync"
      }
    '';
  };
}
