# O6N OpenWrt Bringup Runbook

## 概述

O6N (Radxa Orion O6, CIX Sky1 ARM SoC) 运行 NixOS，通过 Incus 容器运行 OpenWrt 24.10 作为家庭路由器。最终拓扑为双桥接模式：

- `enp49s0 → vmbr1 → OpenWrt eth0` (LAN, 192.168.33.0/24)
- `enp1s0  → vmbr0 → OpenWrt eth1` (WAN, PPPoE)

## 第一阶段：Bootstrap

### 1. 安装 NixOS

```bash
# 使用 disko 分区（参考 hosts/ChenRadxaOrionO6N/disko.nix）
# 首次安装后配置 o6n.openwrt.mode = "bootstrap"
```

### 2. 秘密文件

```bash
sudo install -d -m 0700 /etc/nixos/secrets
sudo cp hosts/ChenRadxaOrionO6N/openwrt/o6n-openwrt.env.example \
        /etc/nixos/secrets/o6n-openwrt.env
sudo chmod 0600 /etc/nixos/secrets/o6n-openwrt.env
sudoedit /etc/nixos/secrets/o6n-openwrt.env
```

必要字段：`WAN_PPPOE_USERNAME`, `WAN_PPPOE_PASSWORD`, `WG_*_PRIVATE_KEY`, `OPENCLASH_*`

### 3. Bootstrap 网络（临时 PPPoE）

```bash
sudo ip link set dev enp1s0 down
sudo ip link set dev enp1s0 address 88:C3:97:9B:92:03
sudo ip link set dev enp1s0 up
sudo pppoe-setup && sudo pppoe-start
```

### 4. 构建 OpenWrt 自定义镜像

```bash
# 安装 distrobuilder（通过 nix build）
nix build nixpkgs#distrobuilder

# 构建镜像（使用 USTC 镜像源，约 2 分钟）
sudo distrobuilder build-incus \
  hosts/ChenRadxaOrionO6N/openwrt-image.yaml \
  /tmp/openwrt-incus

# 导入 Incus
sudo incus image import \
  /tmp/openwrt-incus/incus.tar.xz \
  /tmp/openwrt-incus/rootfs.squashfs \
  --alias openwrt-custom

# 验证
sudo incus image list | grep openwrt-custom
```

### 5. 初始化容器

```bash
# 设置 mode = "bootstrap"（如果还没设置）
# 运行 NixOS rebuild
sudo nixos-rebuild switch

# 此时容器自动创建在 o6n-owrt-mgmt 管理桥上
sudo incus list
# 确认看到 o6n-openwrt RUNNING，IP 192.168.33.1
```

### 6. 验证基础功能

```bash
# 从 PC 访问管理界面
# 确保 PC 连接到 enp49s0 口，IP 设为 192.168.33.x/24
curl http://192.168.33.1
```

## 第二阶段：Cutover

### 7. 停止宿主 PPPoE

```bash
sudo pppoe-stop
```

### 8. 切换到自定义镜像

```bash
# 执行切换脚本（网络中断 5-10 秒）
bash hosts/ChenRadxaOrionO6N/switch-to-custom-image.sh
```

### 9. 切换到 cutover 模式

```bash
# 在 default.nix 中设置 o6n.openwrt.mode = "cutover"
sudo nixos-rebuild switch
```

### 10. 验证

```bash
sudo incus list
# 应看到 o6n-openwrt RUNNING，LAN IP 192.168.33.1，PPPoE WAN IP

# 从 PC ping
ping 192.168.33.1

# 检查已安装包
sudo incus exec o6n-openwrt -- opkg list-installed | grep -E "wireguard|htop|tcpdump|openclash"
```

## 更新镜像

```bash
# 1. 修改 openwrt-image.yaml 中的包列表
# 2. 重新构建
sudo distrobuilder build-incus \
  hosts/ChenRadxaOrionO6N/openwrt-image.yaml \
  /tmp/openwrt-incus

# 3. 导入覆盖旧镜像
sudo incus image import \
  /tmp/openwrt-incus/incus.tar.xz \
  /tmp/openwrt-incus/rootfs.squashfs \
  --alias openwrt-custom

# 4. 下次容器重建时自动使用新镜像
```

## 故障恢复

### 手机 USB 共享网络（应急联网）

当 PPPoE 或宿主网络不可用时，用手机 USB 共享提供临时网络：

```bash
# 1. 手机开启 USB 网络共享，连接到 O6N 的 USB 口
# 2. 查看新出现的网络接口（通常是 usb0 或 enx*)
ip link show | grep -E "usb|enx"

# 3. 请求 DHCP 租约
sudo dhcpcd usb0

# 4. 验证
ping -c 3 223.5.5.5

# 5. 用完后释放
sudo dhcpcd -k usb0
```

宿主机已预装 `dhcpcd`，无需额外安装。接口名可能是 `usb0`、`enx*` 或 `eth*`，用 `ip link show` 确认。

### 其他故障恢复

```bash
# 容器挂了，手动恢复
sudo incus launch openwrt-custom o6n-openwrt --profile o6n-openwrt

# 推送 UCI 配置
sudo systemctl restart o6n-openwrt-reconcile.service

# 如果镜像丢失，从 Nix store 恢复
# distrobuilder 需要重新构建
```

## 关键文件

| 文件 | 作用 |
|------|------|
| `openwrt-image.yaml` | distrobuilder 镜像定义 |
| `openwrt-container.nix` | 容器管理（ensure + reconcile） |
| `openwrt/uci.nix` | UCI 网络/DHCP/DNS/防火墙配置 |
| `networking.nix` | o6n.openwrt 选项定义 |
| `default.nix` | 模式切换、包列表 |
| `switch-to-custom-image.sh` | 手动切换 runbook |
