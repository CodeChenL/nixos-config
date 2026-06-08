# ChenAsahiLinux 安装 Runbook

本文档面向 `chen@192.168.2.35` 这台 Apple M1 Mac mini。该机器当前运行 Debian 13 + Asahi Linux，磁盘布局已经包含 macOS、Asahi UEFI 环境、Linux `/boot`、Linux `/` 和 Recovery 分区。

## 0. 风险边界

- 本 runbook 只适用于当前 `192.168.2.35` 的现有 `/dev/nvme0n1` GPT 布局。
- `hosts/ChenAsahiLinux/disko.nix` 会保留 p1-p5 与 p8 的 Apple/Asahi/macOS/Recovery 分区，只格式化 p6 与 p7；p5 ESP 只手动挂载，不交给 disko 格式化。
- 执行 disko 会清空当前 Debian root 与 `/boot`，必须先备份 `/home/chen` 和服务数据。
- 如果 GPT、iBootSystemContainer、RecoveryOSContainer 或 Asahi UEFI 分区被破坏，可能需要另一台机器通过 DFU/`idevicerestore` 恢复。

## 1. 控制机准备

当前仓库位于控制机 `/home/chen/nixos-config`。先确认新增文件已进入 Git index，否则 flake 纯评估看不到新文件：

```sh
git status --short
git add flake.nix flake.lock overlays/default.nix README.md \
  .github/workflows/nix-flake-check.yml \
  hosts/ChenAsahiLinux/default.nix \
  hosts/ChenAsahiLinux/hardware-configuration.nix \
  hosts/ChenAsahiLinux/disko.nix \
  home/chen/asahi.nix home/chen/openclaw.nix \
  docs/chen-asahi-linux-install-runbook.md
```

下载或构建 `nixos-apple-silicon` installer ISO。推荐直接下载 release ISO：

```sh
# 打开 release 页面，下载最新 installer-bootstrap ISO
xdg-open https://github.com/nix-community/nixos-apple-silicon/releases
```

写入 U 盘，注意 `of=` 必须是整盘设备，不是分区：

```sh
sudo dd if=nixos-apple-silicon.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

## 2. 目标机启动安装器

目标机是 `192.168.2.35`，不是当前控制机。当前机器已经能启动 Debian Asahi，所以优先复用现有 Asahi UEFI/U-Boot 环境，不要在控制机执行 Asahi installer。

1. 在目标 Mac mini 上插入 NixOS Apple Silicon installer U 盘。
2. 接 HDMI 显示器、键盘和网线。
3. 开机进入 U-Boot；如果自动启动旧 Debian，按键打断 autoboot。
4. 在 U-Boot 执行：

```text
bootmenu
```

选择 `usb 0`。如果没有菜单项，依次尝试：

```text
bootmenu -e
```

或：

```text
setenv boot_targets "usb" ; setenv bootmeths "efi" ; boot
```

进入 installer 后：

```sh
sudo su
setfont ter-v32n  # 可选，字体太小时使用
```

## 3. 确认目标分区

在 installer 中确认磁盘仍是当前布局：

```sh
lsblk -o NAME,START,SIZE,PARTTYPE,PARTLABEL,PARTUUID,UUID,LABEL,FSTYPE /dev/nvme0n1
```

必须匹配以下关键分区：

| 分区 | 用途 | 当前 UUID / PARTUUID |
| --- | --- | --- |
| `nvme0n1p5` | Asahi ESP，挂载 `/boot/efi` | UUID `30E1-58BA`，PARTUUID `7029a9db-5103-4a23-b979-21010fb19db8` |
| `nvme0n1p6` | NixOS `/boot` | UUID `a6107966-abbe-4605-829b-1eeb837343db`，PARTUUID `ebe4f8eb-0c48-42c7-8e87-473a7ff87886` |
| `nvme0n1p7` | NixOS `/` | UUID `34acb2be-d977-498a-8abd-bb0f0ae12d8a`，PARTUUID `4815c1fe-58f9-4369-ae82-a4a86858f3e4` |

如果分区号、起止 sector、PARTUUID 与 `hosts/ChenAsahiLinux/disko.nix` 不一致，立即停止，先更新 disko 文件再继续。

## 4. 获取配置仓库和 secrets

把配置放到 installer 的 `/mnt` 之前，可以先克隆到临时目录：

```sh
mkdir -p /tmp/install
cd /tmp/install
git clone <your-nixos-config-repo-url> nixos-config
cd nixos-config
```

如果没有远端 Git 仓库，可以从控制机拷贝：

```sh
scp -r /home/chen/nixos-config root@<installer-ip>:/tmp/install/nixos-config
```

准备 OpenClaw secrets。不要把 secret 提交进 Git；安装后它们应位于：

```text
/home/chen/nixos-config/secrets/opencode/minimax.key
/home/chen/nixos-config/secrets/openclaw/gateway-token
```

## 5. 用 disko 分区、格式化并挂载

确认当前工作目录是配置仓库：

```sh
cd /tmp/install/nixos-config
```

先查看 disko 将生成的脚本路径。disko CLI 当前支持的模式是 `format,mount`，旧文档中的 `disko` 等价于 `destroy,format,mount`，本 runbook 不使用 destroy 模式：

```sh
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- \
  --flake .#ChenAsahiLinux \
  --mode format,mount \
  --dry-run
```

确认无误后执行格式化与挂载。该步骤只应格式化 p6 与 p7，不会执行 destroy：

```sh
nix --extra-experimental-features 'nix-command flakes' \
  run github:nix-community/disko -- \
  --flake .#ChenAsahiLinux \
  --mode format,mount
```

执行完成后确认挂载：

```sh
findmnt /mnt /mnt/boot
```

手动挂载 Asahi ESP 到 `/mnt/boot/efi`。不要格式化该分区；其中包含 UEFI/m1n1/U-Boot 相关文件：

```sh
mkdir -p /mnt/boot/efi
mount /dev/disk/by-partuuid/7029a9db-5103-4a23-b979-21010fb19db8 /mnt/boot/efi
findmnt /mnt/boot/efi
```

## 6. 安装配置仓库到目标 root

把仓库复制到新系统 root 内的固定路径：

```sh
install -d -m 0755 /mnt/home/chen
rsync -a --delete /tmp/install/nixos-config/ /mnt/home/chen/nixos-config/
```

如果 secrets 不在仓库复制范围内，手动创建并复制：

```sh
install -d -m 0700 /mnt/home/chen/nixos-config/secrets/opencode
install -d -m 0700 /mnt/home/chen/nixos-config/secrets/openclaw
install -m 0600 /path/to/minimax.key /mnt/home/chen/nixos-config/secrets/opencode/minimax.key
install -m 0600 /path/to/gateway-token /mnt/home/chen/nixos-config/secrets/openclaw/gateway-token
```

## 7. 安装 NixOS

启用 flakes，并安装 `ChenAsahiLinux`：

```sh
mkdir -p /etc/nix
cat >> /etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
accept-flake-config = true
EOF

systemctl restart systemd-timesyncd

nixos-install --flake /mnt/home/chen/nixos-config#ChenAsahiLinux
```

安装最后会要求设置 root 密码。完成后重启：

```sh
reboot
```

## 8. 首次启动验证

登录 NixOS 后检查主机和 bootloader：

```sh
hostname
findmnt / /boot /boot/efi
bootctl status
```

检查 `chen` linger 和 OpenClaw 用户服务：

```sh
loginctl show-user chen -p Linger
sudo -iu chen systemctl --user status openclaw-gateway
sudo -iu chen journalctl --user -u openclaw-gateway -e --no-pager
```

检查 OpenClaw 端口：

```sh
ss -ltnp | grep 18789
curl -fsS http://127.0.0.1:18789 || true
```

## 9. 后续 rebuild

首次安装完成后，常规更新在目标机上执行：

```sh
cd /home/chen/nixos-config
sudo nixos-rebuild switch --flake .#ChenAsahiLinux
```

如果 U-Boot/m1n1 或 Apple Silicon 模块更新后启动异常，优先从 systemd-boot 选择上一代；无法进入系统时，从 USB installer 启动，重新执行 disko mount 或手工挂载后再 `nixos-install --no-root-password --no-channel-copy --flake /mnt/home/chen/nixos-config#ChenAsahiLinux`。
