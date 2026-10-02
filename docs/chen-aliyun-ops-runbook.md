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

Sub2API 的加密密钥（TOTP/支付/S3 等加密使用）必须固定：

```text
/home/chen/nixos-config/secrets/sub2api/totp-encryption-key
```

本模块从该文件读取并通过 `TOTP_ENCRYPTION_KEY` 注入服务；源文件缺失时，
setup 服务会失败，不会自动补建密钥。应用若绕过本模块、在未设置该环境变量
的情况下启动，可能生成临时密钥，使已有密文或跨实例解密不可用。

## Sub2API

当前配置状态：`services.sub2api.enable = true`。

验证：

```sh
systemctl status sub2api.service
systemctl status postgresql.service redis.service
ss -lntp | grep 8080
```

`sub2api.nix` 模块默认会添加本机 PostgreSQL、Redis、服务账号和防火端口 8080；
Aliyun 保持该默认行为并额外开放 `5432`、`6379`。ChenIdeaCentre 已设置
`services.sub2api.enable = false`，不再运行本地 Sub2API；客户端使用
`https://api.chenjaly.cn/v1`。原有 `externalDatabase = true` 配置仅在重新启用服务时生效。

**历史数据库关系**：迁移时 ChenIdeaCentre 和 ChenAliyun 曾共用同一套后端：

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

两端必须持久化并注入同一个 `TOTP_ENCRYPTION_KEY`，不能依赖每次启动自动生成。
升级或迁移前应确认它与已有加密数据使用的密钥一致；不要用新生成的密钥
覆盖旧密钥，否则已有密文可能无法解密。密钥从运行时 secret 文件加载，
不得写入本仓库或 Nix store；两端是否已部署相同密钥需分别验证。

注意：Aliyun 的 `5432` 和 `6379` 向公网开放，当前依赖密码认证；
如果允许按来源网段收紧，优先用防火墙只放行 ChenIdeaCentre 的公网出口 IP。

## HTTPS 与证书续签

`hosts/Aliyun/https.nix` 声明 Knot 权威 DNS、Let's Encrypt 泛域名证书和 nginx。
不需要阿里云 AccessKey，也不改变原来的监听地址、直连端口或访问权限。

| HTTPS 入口 | 后端 |
| --- | --- |
| `https://api.chenjaly.cn/` | Sub2API `127.0.0.1:8080` |
| `https://api.chenjaly.cn/kiro/v1/` | kiro-rs `127.0.0.1:8990/v1/` |
| `https://api.chenjaly.cn/kiro/admin` | kiro-rs 管理页面 |

`/kiro/` 转发时移除前缀；管理页面的资源地址和管理 API 地址在 nginx 层改写，
根路径 `/admin` 仍属于 Sub2API。升级 kiro-rs 后应复查管理页面和 JS 的绝对路径。
两个后端的流式响应均禁用 nginx 代理缓冲。

证书包含 `chenjaly.cn` 和 `*.chenjaly.cn`，以后新增一级子域的虚拟主机使用
`useACMEHost = "chenjaly.cn"` 即可复用。泛域名不覆盖二级以上子域。
证书不会自动添加新服务的 DNS 记录或 nginx 路由。

阿里云 DNS 中保留以下一次性配置：

| 主机记录 | 类型 | 值 |
| --- | --- | --- |
| `acme-ns` | A | `47.254.74.103` |
| `acme` | NS | `acme-ns.chenjaly.cn` |
| `_acme-challenge` | CNAME | `acme.chenjaly.cn` |
| `api` | A | `47.254.74.103` |

云端防火墙需允许公网 TCP/UDP `53`、TCP `443`；TCP `80` 用于 HTTP 跳转。
DNS-01 签发不依赖端口 `80`。这里不自动修改云端防火墙。

首次启动自动生成本机 TSIG 密钥，Knot 只允许带该密钥的本机 TXT 更新。
它不是阿里云管理密钥，不需要在 DNS 控制台配置，且不会写入 Nix store。
ACME 账户密钥、证书和 Knot journal 属于运行时状态，应随主机数据备份。
TSIG 密钥不要在 Knot 正在运行时直接删除，否则客户端与服务端密钥可能不一致。

首次部署和续签后检查：

```sh
systemctl status knot nginx acme-order-renew-chenjaly.cn.service
systemctl list-timers acme-renew-chenjaly.cn.timer
journalctl -u acme-order-renew-chenjaly.cn.service -n 100
dig @47.254.74.103 acme.chenjaly.cn SOA
dig +tcp @47.254.74.103 acme.chenjaly.cn SOA
openssl x509 -in /var/lib/acme/chenjaly.cn/fullchain.pem -noout -dates -ext subjectAltName
curl -I https://api.chenjaly.cn/
curl -I https://api.chenjaly.cn/kiro/admin
```

`security.acme` 的每日 timer 自动执行续签检查，成功更新证书后重新加载 nginx。
内部 unit 名称随 nixpkgs 版本可能变化，升级时复查初始化和续签服务的依赖关系。

## 单端口 HTTPS / SOCKS5 代理

`hosts/Aliyun/mixed-proxy.nix` 在同一个 TCP 端口提供两种代理协议，两者共用同一套认证：

| 客户端代理地址 | 协议 |
| --- | --- |
| `https://api.chenjaly.cn:8443` | TLS 加密的 HTTP 代理，支持 HTTP 转发和 CONNECT，仅承载 TCP |
| `socks5h://api.chenjaly.cn:8443` | 裸 SOCKS5，支持用户名/密码认证、TCP CONNECT 和标准 UDP ASSOCIATE |

这些是正向代理地址，API baseURL 仍是 `https://api.chenjaly.cn/v1`，
现有 `443` 端口上的 nginx API 与管理入口不变。
OpenCode、Codex 和 DSH 的声明式 API 配置均已迁移到该 HTTPS 地址；
应用配置更新后应重启对应客户端，OpenCode 不会热加载 provider 配置。

代理实现来自 `overlays/pkgs/mixed-proxy-rs`（按仓库 overlay 约定接收
`inputs`、`final`、`prev`），只有一个 Rust 二进制和一个 `systemd` 单元
`mixed-proxy`。进程在 `0.0.0.0:8443` 接受连接，读取首个字节后分流：
`0x05` 按明文 SOCKS5 处理，`0x16`（TLS 握手）进入 HTTPS 代理，HTTPS 侧
同时支持普通 HTTP 转发和 CONNECT。它取代了原来的 sslh 与 GOST 组合，链路中
没有 PROXY v2 头，也没有 `127.0.0.1:11080`、`127.0.0.1:19443` 回环后端；
代理只运行这一个 Rust 二进制，不再有独立的认证进程、脚本运行时或认证 HTTP 端口。

`systemd` 服务 `mixed-proxy` 以本机用户 `chen` 运行，加入 `nginx` 附加组读取
ACME 证书，并设置 `NoNewPrivileges = false`，让 `pam_unix` 能借助 setuid 的
`unix_chkpwd` 校验当前用户密码；启动命令为
`pkgs.mixed-proxy-rs/bin/mixed-proxy --config /etc/mixed-proxy/config.json`。

配置文件由 Nix 生成，只包含监听、证书和 UDP 三组字段，没有 `auth` 字段：

```json
{
  "listen": "0.0.0.0:8443",
  "tls": {
    "certFile": "/var/lib/acme/chenjaly.cn/fullchain.pem",
    "keyFile": "/var/lib/acme/chenjaly.cn/key.pem"
  },
  "udp": {
    "publicAddress": "47.254.74.103",
    "portRange": { "from": 20000, "to": 20127 }
  }
}
```

认证由同一个进程直接完成：应用经 Rust crate 在进程内调用系统 PAM（libpam），
PAM 服务 `mixed-proxy` 定义在 `security.pam.services.mixed-proxy`，`auth` 和
`account` 都使用 `pam_unix`，`authenticate` 与 `acct_mgmt` 都必须通过。
PAM 和 setuid 的 `unix_chkpwd` 属于系统正常依赖，不是说整个系统只有 Rust。
HTTPS 与 SOCKS5 两个入口共用一组凭据：用户名 `chen`，密码是该 NixOS 用户的
当前系统密码；其他用户名、错误密码，以及被锁定、已过期或要求强制改密的账户
都会被拒绝。密码只存在于认证期间的内存里，不硬编码、不写入配置文件、不缓存、不记日志。

认证时限 10 秒、并发上限 4，都是程序内置。PAM 是阻塞式 FFI 调用，超时后
线程无法被强制取消，迟到的结果会被拒绝，但并发名额要等调用返回才释放；
如果卡死的调用占满全部名额，认证会持续失败，应重启 `mixed-proxy`。
`systemd` 停止服务时等待 15 秒，之后强制结束进程。

密码由声明式账户配置维护（见“主机信息”中的 `users.mutableUsers = false`）。
修改密码需改 Nix 账户配置并重新部署应用，不适用普通 `passwd` 改密流程。

裸 SOCKS5 到代理这一段不加密，协议及口令协商为明文，内容是否加密由应用决定；
通过 SOCKS5 访问 HTTPS 网站时，网站 TLS 仍由客户端与网站端到端建立。
HTTPS 代理入口会加密客户端到代理这一段，但它仍是普通 HTTP 代理，只承载 TCP。

UDP 仅经 SOCKS5 的标准 UDP ASSOCIATE 提供，不支持 BIND：客户端保持一条
TCP 控制连接，mixed-proxy 进程在该连接上分配 UDP 中继端口，中继范围是 UDP `20000-20127`，
并在应答中公布公网 EIP `47.254.74.103`。代理进程实际绑定云主机网卡地址
`172.18.14.50`；EIP 不在网卡上，客户端也无法直达内网地址。中继只接受源 IP
与 TCP 控制连接对端一致的数据报文，控制连接断开后，该关联的中继立即停止。
公网地址和端口范围分别由 `services.mixed-proxy.publicUdpAddress` 和
`services.mixed-proxy.udpPortRange` 配置，修改后需重新部署。

每个关联最多同时维护 256 个目标套接字。目标连续 60 秒没有成功的双向转发时
会回收容量；只有入站或只有出站流量也能保活。再次访问已过期目标会重新创建
套接字，可能使用新的上游源端口，但 TCP 控制连接和关联的 UDP 中继端口不变。

云端防火墙需为这个代理放行 TCP `8443` 和 UDP `20000-20127`。
只放行 TCP 时，HTTPS 代理和 SOCKS5 TCP 可用，但 UDP ASSOCIATE 不可用。
使用 UDP 时还要求：客户端本机放行 UDP，且客户端发出的 UDP 报文与 TCP
控制连接在 NAT/防火墙看来来自同一个公网源地址。

在服务器上查看服务状态：

```sh
systemctl status mixed-proxy
journalctl -u mixed-proxy -n 100
ss -lntp | grep ':8443 '
ss -lunp | grep mixed-proxy
```

客户端示例：`--proxy-user` 只给用户名，curl 会交互式提示输入代理密码，
密码不会出现在命令行参数或 shell 历史里。

```sh
curl --noproxy '' --proxy https://api.chenjaly.cn:8443 \
  --proxy-user chen https://example.com/
curl --noproxy '' --proxy socks5h://api.chenjaly.cn:8443 \
  --proxy-user chen https://example.com/
```

HTTPS 代理复用 `chenjaly.cn` 的泛域名证书。ACME 成功更新后重启 `mixed-proxy`
读取新证书，已有代理隧道（含 UDP 关联）会断开，客户端需要重连。代理密码就是
`chen` 的系统账户密码，普通服务重启后不变，只在 NixOS 账户配置变更并重新部署时更新。

Rust 库测试用 `cfg(test)` 的假认证后端代替真实 PAM，这只用于测试；生产二进制
始终走系统 PAM。测试覆盖 TLS 与 SOCKS5 分流、HTTP 转发与 CONNECT、SOCKS5
认证往返和 UDP ASSOCIATE 关联行为。

黑盒 Node 驱动接收 2 个参数（二进制和模块生成的 JSON），读取模块生成的配置，
替换监听地址、端口和测试证书，密码从标准输入读取；它只在隔离 VM 内以假的
`chen` 账户运行（此时走真实 PAM），不使用宿主机真实密码。完整验收执行：

```sh
nix build --no-link .#checks.x86_64-linux.mixed-proxy
```

该 check 覆盖 Rust 库测试、Node 黑盒和真实 PAM 的 VM 验证；VM 使用合成账户密码
与私有测试证书，不读取真实服务器凭据。云端 EIP 与防火墙的 UDP 连通性仍需
部署后验收。

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
