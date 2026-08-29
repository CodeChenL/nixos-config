# ChenRadxaOrionO6N OpenWrt 容器运行手册

这是 O6N OpenWrt 基础设施的唯一当前态 runbook。旧的 bootstrap/cutover 模式和
switch-to-custom-image.sh 已不存在；主机始终使用双桥拓扑。网络、容器、镜像和
secret 变更必须先构建、保留本地或串口控制台，再进行可回滚验证。

## 当前拓扑

    enp49s0 -> vmbr1 -> OpenWrt eth0  (LAN)
    enp1s0  -> vmbr0 -> OpenWrt eth1  (WAN/PPPoE, MAC 88:c3:97:9b:92:03)

- OpenWrt 容器：o6n-openwrt
- Incus profile / storage pool：o6n-openwrt
- 主机 LAN 地址：192.168.33.100/24，接口 vmbr1
- 主机默认网关：192.168.33.1（OpenWrt LAN）
- OpenWrt 镜像别名：openwrt-custom

相关声明：

- 主机桥和地址：../networking.nix
- Incus、镜像和 reconcile：../openwrt-container.nix
- 镜像定义：../openwrt-image.yaml
- 原生 UCI 模板：config/
- 额外托管文件：plugins/

## 声明式流程

o6n-openwrt-ensure.service：

1. 确认 openwrt-custom 镜像存在。
2. openwrt-image.yaml 或 distrobuilder 变化时，先完成新镜像构建，再替换别名。
3. 确认 o6n-openwrt 容器存在、使用 o6n-openwrt profile，并处于运行状态。

o6n-openwrt-reconcile.service 依赖 ensure：

1. 从 /etc/nixos/secrets/o6n-openwrt.env 更新运行时 secret 副本。
2. 在 root-only 临时目录渲染 config/ 与 plugins/ 中的占位符。
3. 删除上一次由 Nix 管理、但本次 manifest 已移除的 /etc/config 文件。
4. 推送全部托管文件，重载 network/firewall/cron，并同步容器 root 密码。

不要在新镜像构建成功前手工删除当前容器或 openwrt-custom 镜像。

## Secrets

源文件和运行时副本都必须是 root-only：

    /etc/nixos/secrets/o6n-openwrt.env
    /var/lib/o6n-openwrt/secrets.env

首次准备：

    sudo install -d -m 0700 /etc/nixos/secrets
    sudo install -m 0600 \
      hosts/ChenRadxaOrionO6N/openwrt/o6n-openwrt.env.example \
      /etc/nixos/secrets/o6n-openwrt.env
    sudoedit /etc/nixos/secrets/o6n-openwrt.env

当前必需键：

    WAN_PPPOE_USERNAME
    WAN_PPPOE_PASSWORD
    WG_VAMRS_PRIVATE_KEY
    WG_CHEN_INTERFACE_PRIVATE_KEY
    WG_CHEN_PEER1_PRIVATE_KEY
    WG_CHEN_PEER2_PRIVATE_KEY
    OPENCLASH_DASHBOARD_PASSWORD
    OPENCLASH_SUBSCRIBE_ADDRESS
    OPENCLASH_SUBSCRIBE_INFO_URL
    RPCD_ROOT_PASSWORD_HASH

RPCD_ROOT_PASSWORD_HASH 必须是以 $ 开头的 crypt hash，并同时用于 LuCI/rpcd
和容器 root。特殊内容可写成 NAME=base64:<base64-value>。reconcile 会在 secret
缺失、权限过宽、键缺失或 hash 格式错误时失败，不会推送半渲染配置。

## 安全部署

涉及 networking.nix、openwrt-container.nix、openwrt-image.yaml、config/
或 plugins/ 时，不要只保留当前 SSH 会话作为恢复路径。

1. 打开本地显示器/键盘或稳定的串口控制台。
2. 记录当前系统与容器状态，并创建容器快照：

       readlink -f /run/current-system
       sudo incus info o6n-openwrt
       snapshot=pre-nix-$(date +%Y%m%d-%H%M%S)
       sudo incus snapshot o6n-openwrt "$snapshot"
       printf '%s\n' "$snapshot"

3. 先构建，不激活：

       sudo nixos-rebuild build \
         --flake 'path:/etc/nixos#ChenRadxaOrionO6N'

4. 从本地/串口控制台临时激活：

       sudo nixos-rebuild test \
         --flake 'path:/etc/nixos#ChenRadxaOrionO6N'

5. 完成下面的主机、容器、LAN、DNS 和外网验证后，才执行 switch。

## 验证

主机与 systemd：

    systemctl is-active incus.service incus-preseed.service
    systemctl --no-pager --full status \
      o6n-openwrt-ensure.service o6n-openwrt-reconcile.service
    ip -br link show vmbr0 vmbr1 enp1s0 enp49s0
    ip -br address show vmbr1
    ip route show default

容器与 OpenWrt：

    sudo incus info o6n-openwrt
    sudo incus exec o6n-openwrt -- ubus call system board
    sudo incus exec o6n-openwrt -- ip -br address
    sudo incus exec o6n-openwrt -- uci show network
    sudo incus exec o6n-openwrt -- uci show firewall
    sudo incus exec o6n-openwrt -- logread -e pppd

从 LAN 客户端验证：

    ping -c 3 192.168.33.1
    nslookup openwrt.org 192.168.33.1
    curl -I --max-time 10 https://openwrt.org/

## 故障恢复

先在本地/串口控制台保存日志；不要先删容器、profile、storage pool 或镜像：

    sudo journalctl -u o6n-openwrt-ensure.service \
      -u o6n-openwrt-reconcile.service -b --no-pager -n 300
    sudo incus info o6n-openwrt --show-log

若新 NixOS generation 导致主机网络异常：

    sudo nixos-rebuild switch --rollback

若只有 reconcile 失败，修复 secret 或模板后重放：

    sudo systemctl restart o6n-openwrt-reconcile.service

若容器停止但配置仍完整：

    sudo incus start o6n-openwrt
    sudo systemctl restart o6n-openwrt-reconcile.service

若必须恢复部署前容器快照，操作期间网络会中断，只能从本地/串口控制台执行：

    sudo incus stop o6n-openwrt
    sudo incus restore o6n-openwrt <snapshot-name>
    sudo incus start o6n-openwrt

恢复后重新执行完整验证；确认稳定后再删除旧快照。
