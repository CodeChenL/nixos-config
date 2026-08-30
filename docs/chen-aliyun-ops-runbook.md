# ChenAliyun Ops Runbook

## 主机信息

- IP：`47.254.74.103`
- 主机名：`ChenAliyun`
- NixOS：`26.05.20260825.f4f6986`（Xantusia）
- 内核：`6.18.46`
- 磁盘：
  - `/dev/vda1`：191M vfat ESP
  - `/dev/vda2`：39.8G Btrfs
  - Btrfs 子卷：`@` `/`、`@nix` `/nix`、`@home` `/home`
- 登录：
  - `root` 和 `chen` 当前使用相同密码，密码登录已启用
  - 同时保留 SSH key 登录
- 用户账户为 `users.mutableUsers = false`，密码由 NixOS 配置声明式强制维护。

## 日常更新

```sh
nixos-rebuild switch \
  --flake 'path:/home/chen/nixos-config#Aliyun' \
  --target-host root@47.254.74.103
```

更新后检查：

```sh
ssh root@47.254.74.103 'systemctl is-system-running; systemctl --failed --no-legend'
```

## Secrets

已复制到远端：

```text
/home/chen/nixos-config/secrets/
```

该目录不在 Git 中，远端目录权限为 `700`，敏感文件为 `600`。

Sub2API 管理员密码文件：

```text
/home/chen/nixos-config/secrets/sub2api/admin-password
```

## Sub2API

当前配置状态：`services.sub2api.enable = true`。

验证：

```sh
systemctl status sub2api.service
systemctl status postgresql.service redis.service
ss -lntp | grep 8080
```

`sub2api.nix` 模块默认会添加本机 PostgreSQL、Redis、服务账号和防火端口 8080；
Aliyun 保持该默认行为并额外开放 `5432`、`6379`，ChenIdeaCentre 则设置
`services.sub2api.externalDatabase = true`，只运行 Sub2API 本身，不再启动本机数据库。

**数据库关系**：ChenIdeaCentre 和 ChenAliyun 已经共用同一套后端：

- `ChenAliyun` 运行 PostgreSQL `0.0.0.0:5432` 和 Redis `0.0.0.0:6379`，是共享后端。
- `ChenIdeaCentre` 的 Sub2API 通过 `DATABASE_HOST/REDIS_HOST = 47.254.74.103` 连接远程后端，
  本地不再运行 PostgreSQL/Redis。
- 两端使用同一份 Sub2API 数据库密码、JWT secret 和 Redis 密码。

迁移本地数据库到 Aliyun 的步骤（已执行一次）：

```sh
# 本地：用可读权限读取本地数据库密码后导出
DBPW=$(sudo cat /var/lib/sub2api/secrets/db-password | tr -d '\r\n')
PGPASSWORD="$DBPW" pg_dump \
  -h 127.0.0.1 -p 5432 -U sub2api -d sub2api -Fc \
  -f /tmp/sub2api-local.dump

# 将 dump 传到 Aliyun，作为 postgres 用户在临时库中恢复并检查，
# 然后停止 Sub2API，把临时库改名为 sub2api 并重启服务。
```

迁移前 Aliyun 的旧库保留在 `sub2api_pre_restore`，迁移前的 dump 位于
`/tmp/sub2api-aliyun-before.*.dump`（远端，权限为 postgres:postgres）。

当前两端日志都会提示 `TOTP_ENCRYPTION_KEY` 自动生成；这不影响普通 API，
但如需支付恢复 token 跨实例生效，应在两端声明同一个 `TOTP_ENCRYPTION_KEY`。

注意：Aliyun 的 `5432` 和 `6379` 向公网开放，当前依赖密码认证；
如果允许按来源网段收紧，优先用防火墙只放行 ChenIdeaCentre 的公网出口 IP。

## WireGuard

Aliyun 通过 OpenWrt 的 `chen` WireGuard 隧道接入内网：

- 接口：`chen`，地址 `10.0.33.2/32`
- 私钥来源：`/home/chen/nixos-config/secrets/o6n-openwrt.env` 的 `WG_CHEN_PEER1_PRIVATE_KEY`
- 对端公钥：`hoJX1qGLQ2M2k7YjwXUAVTPCROhyUawLj1zIs6iewXQ=`
- 对端 endpoint：`frp-ski.com:51888`
- 路由：`10.0.33.0/24`、`192.168.33.0/24`

私钥由 `wireguard-chen.service` 的 `preStart` 在 WireGuard 启动前写入
`/run/secrets/wireguard-chen.key`，不会进入 Nix store。

验证：

```sh
systemctl list-units --type=service --no-pager | grep wireguard
ip -4 address show dev chen
wg show chen
ip route get 10.0.33.1
ip route get 192.168.33.1
```

## 回滚

```sh
ssh root@47.254.74.103 'nixos-rebuild switch --rollback'
```

如果系统已不能登录，请使用阿里云控制台 VNC/串口；NixOS 使用 EFI NVRAM 启动项
`NixOS-boot-efi`。若 UEFI 启动项丢失，可手动执行：

```text
chainloader (hd0,gpt1)/EFI/NixOS-boot-efi/grubx64.efi
boot
```

## 救援/急修

- 查看当前磁盘和挂载：
  ```sh
  lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS
  btrfs filesystem show /
  ```
- 查看启动日志：
  ```sh
  journalctl -b -x -n 200
  ```
- 系统卡住时，GRUB 编辑 `linux` 行追加：
  ```text
  systemd.log_level=debug console=ttyS0,115200n8 loglevel=7
  ```
- 当前 GRUB 已关闭图形 splash，使用文本/串口控制台。
