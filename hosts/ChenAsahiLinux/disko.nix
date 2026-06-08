# ChenAsahiLinux 声明式分区配置（disko）
#
# ⚠️ 仅适用于当前 192.168.2.35 Apple M1 Mac mini 的现有 GPT 布局。
# p1-p5 和 p8 是 Apple/Asahi/macOS/Recovery/UEFI 相关分区，只作为占位保留；
# disko 只格式化并挂载 p6 (/boot) 与 p7 (/)。p5 ESP 由 hardware-configuration.nix 只声明挂载。

{
  disko.devices = {
    disk = {
      internal-nvme = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-APPLE_SSD_AP0512Q_0ba0161281e0d808";
        content = {
          type = "gpt";
          partitions = {
            iBootSystemContainer = {
              priority = 1;
              name = "iBootSystemContainer";
              type = "69646961-6700-11aa-aa11-00306543ecac";
              uuid = "ac3b96a3-ef31-4707-8729-9639964881e9";
              start = "48s";
              end = "1024047s";
              content = null;
            };

            macos = {
              priority = 2;
              type = "7c3457ef-0000-11aa-aa11-00306543ecac";
              uuid = "2ffca9bc-fa46-4359-a490-6b8042774b30";
              start = "1024048s";
              end = "195878959s";
              content = null;
            };

            asahi-stub = {
              priority = 3;
              type = "7c3457ef-0000-11aa-aa11-00306543ecac";
              uuid = "e73d7cb4-72e1-497b-a69b-18983264d6c0";
              start = "195878960s";
              end = "200761391s";
              content = null;
            };

            asahi-system = {
              priority = 4;
              type = "7c3457ef-0000-11aa-aa11-00306543ecac";
              uuid = "f6a47216-fe81-4f3e-97ad-bb257e1f8c09";
              start = "200761392s";
              end = "205643823s";
              content = null;
            };

            asahi-esp = {
              priority = 5;
              type = "EF00";
              uuid = "7029a9db-5103-4a23-b979-21010fb19db8";
              start = "205643824s";
              end = "206667823s";
              content = null;
            };

            boot = {
              priority = 6;
              type = "8300";
              uuid = "ebe4f8eb-0c48-42c7-8e87-473a7ff87886";
              start = "206667824s";
              end = "209813551s";
              content = {
                type = "filesystem";
                format = "ext4";
                extraArgs = [
                  "-F"
                  "-U"
                  "a6107966-abbe-4605-829b-1eeb837343db"
                  "-L"
                  "nixos-boot"
                ];
                mountpoint = "/boot";
              };
            };

            root = {
              priority = 7;
              type = "8300";
              uuid = "4815c1fe-58f9-4369-ae82-a4a86858f3e4";
              start = "209813552s";
              end = "966619183s";
              content = {
                type = "filesystem";
                format = "ext4";
                extraArgs = [
                  "-F"
                  "-U"
                  "34acb2be-d977-498a-8abd-bb0f0ae12d8a"
                  "-L"
                  "nixos"
                ];
                mountpoint = "/";
              };
            };

            RecoveryOSContainer = {
              priority = 8;
              name = "RecoveryOSContainer";
              type = "52637672-7900-11aa-aa11-00306543ecac";
              uuid = "e03f0c24-5006-45dc-8bbd-3c803b4653bc";
              start = "966619352s";
              end = "977105023s";
              content = null;
            };
          };
        };
      };
    };
  };
}
