# Radxa Orion O6N 声明式分区配置（disko）
#
# ⚠️ 部署前必须修改：
#   1. 把下面 `main.device` 的 nvme-CHANGEME 替换为真实的设备 ID
#   2. 查询方法：在安装介质上执行 `ls -l /dev/disk/by-id/`
#   3. 推荐用 by-id 而不是 by-path，避免 PCIe 端口号变动
#
# 分区结构（参考 MakiseKurisu/nixos-config 的 orion-o6 配置）：
#   /dev/nvme0n1
#     ├── ESP  (1 GiB, vfat, /boot)
#     └── root (剩余, btrfs, compress=zstd, subvolumes: @, @nix, @persistent)

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # ⚠️ 部署前替换为真实设备 ID
        device = "/dev/disk/by-id/nvme-CHANGEME_REPLACE_BEFORE_INSTALL";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "--checksum blake2"
                ];
                mountpoint = "/media/root";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
                subvolumes = {
                  "/@" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };

                  "/@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };

                  "/@persistent" = {
                    mountpoint = "/persistent";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
