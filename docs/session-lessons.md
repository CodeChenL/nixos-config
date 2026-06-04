# 本次会话经验总结

## 核心教训

### 1. 永远不要停主容器
宿主机的默认路由指向 OpenWrt 容器（192.168.33.1），停止容器会导致宿主机断网。**构建优先，验证通过后再动容器。**

### 2. distrobuilder 是正确方案
经历了三种方案迭代：
- ❌ `fetchurl` + 手动解压 IPK → Nix sandbox 限制太多
- ❌ reconcile 时 opkg install → 容器内网络不可靠
- ✅ distrobuilder YAML → 在宿主机 chroot 中构建，所有包预装

**关键优势**：消除了容器内网络依赖，镜像构建完全可控。

### 3. Incus preseed 配置验证
`security.privileged` 和 `raw.lxc` 是 profile 配置，不能放在 network config 中。preseed 会校验并拒绝无效配置。

### 4. Nix `''...''` 多行字符串陷阱
`lib.optionalString` 内部的 `''` 会和外层 `text = ''` 冲突。解决方案：
- 用 `writeShellScript` / `writeText` 把 shell 脚本独立出去
- 或在 Nix 字符串中避免 `''`，改用字符串拼接 `+`

### 5. 子网冲突
管理桥和 LAN 不能共用同一子网（都是 192.168.33.0/24），会导致 ARP 表和路由表混乱。

### 6. 构建优先于销毁
```
# 正确流程
nixos-rebuild switch --dry-run  # 先验证
nixos-rebuild switch             # 再部署
# 不要先 incus stop/delete
```

### 7. OpenWrt opkg 依赖问题
- `opkg install local.ipk` 仍需要 `opkg update` 来解析依赖
- `dnsmasq-full` 与基础镜像的 `dnsmasq` 冲突，需先 remove
- 在 distrobuilder YAML 中预装 `dnsmasq-full` 可以从根本上解决

### 8. `nix-prefetch-url` 对特殊字符文件名
文件名含 `~` 的 IPK（如 luci-*）需要 `--name` 参数绕过 Nix store path 验证：
```bash
nix-prefetch-url --name "luci-compat.ipk" "https://..."
```

### 9. Git 提交习惯
- 实验性/修复性 commit 在 push 前 squash
- 用 `git reset --soft` 保持 working tree 再重新提交
- 一个功能点 = 一个 commit

### 10. Incus 网络模式
| 模式 | 用途 | 容器网卡 |
|------|------|----------|
| `nictype: bridged, parent: vmbr0` | WAN/PPPoE | eth1 |
| `nictype: bridged, parent: vmbr1` | LAN | eth0 |
| `network: o6n-owrt-mgmt` | NAT 管理 | eth2（已弃用） |

---

## 调试失败记录

### 失败 1：Nix derivation 用 opkg chroot 安装包
**方案**：`pkgs.runCommandLocal` + `__noChroot = true`，在 derivation 中 chroot 进 rootfs 用 opkg 安装包
**失败原因**：
- Nix sandbox 默认禁止 `__noChroot`，需要 `sandbox = "relaxed"`
- opkg 的 musl 二进制在 chroot 中执行报 `exec format error`
- `proot` 模拟 chroot 时 `/var/lock` 目录创建失败
- 包下载依赖网络，Nix derivation 不保证网络可用

**教训**：Nix sandbox 对 chroot/网络有严格限制，不适合在 derivation 中运行包管理器。

### 失败 2：Nix fetchurl + 手动解压 IPK
**方案**：`fetchurl` 下载每个 IPK，在 derivation 中解压 `data.tar.gz` 到 rootfs
**失败原因**：
- 需要获取所有依赖包的 URL 和 hash（196 个包）
- IPK 文件名含 `~` 字符导致 `nix-prefetch-url` 报 store path 错误
- 手动解压不执行 post-install 脚本，导致 LuCI 服务列表缺失
- `dnsmasq-full` 与 `dnsmasq` 冲突需要特殊处理

**教训**：手动解压 IPK 不等同于 opkg 安装，缺少依赖解析和 post-install 处理。

### 失败 3：proot 模拟 chroot
**方案**：用 `proot`（ptrace 模拟）在 Nix sandbox 中 chroot 进 rootfs
**失败原因**：
- `/var/lock/opkg.lock` 创建失败（proot 的文件系统映射问题）
- `/tmp` 目录映射冲突（proot 绑定 host `/tmp`）
- DNS 解析失败（proot 环境缺少 `/etc/resolv.conf`）

**教训**：proot 对文件系统映射有隐式行为，不适合复杂的包管理操作。

### 失败 4：OpenWrt ImageBuilder
**方案**：下载 ImageBuilder（x86_64），在 aarch64 主机上构建
**失败原因**：
- ImageBuilder 是 x86_64 二进制，aarch64 主机无法直接运行
- 没有 binfmt QEMU 支持

**教训**：跨架构构建需要 QEMU 用户态模拟，不是所有环境都支持。

### 失败 5：incus export 导出容器作为镜像
**方案**：`incus export` 导出运行中容器的 rootfs，导入为新镜像
**失败原因**：
- 导出的 rootfs 包含运行时状态（PID 文件、临时文件）
- 新容器从导出的 rootfs 启动时报 `lxc.hook.pre-start` 失败
- 需要先停止容器再导出，但停主容器会断网

**教训**：`incus export` 不是 `docker commit`，需要停止容器才能导出干净的 rootfs。

### 失败 6：Nix `__noChroot` + distrobuilder
**方案**：在 Nix derivation 中用 `__noChroot = true` 运行 distrobuilder
**失败原因**：
- `sandbox = "relaxed"` 需要先生效（需要 nixos-rebuild switch）
- distrobuilder 每次构建都重新下载包（不是 fixed-output derivation）
- `exec format error`：distrobuilder 的 `actions` 在 aarch64 上执行 shell 脚本失败

**教训**：`__noChroot` derivation 不是 hermetic 的，每次构建结果可能不同。`exec format error` 是 distrobuilder 在 aarch64 上的已知问题。

### 失败 7：Nix 字符串嵌套 `''...''`
**方案**：在 `text = ''...''` 中使用 `lib.optionalString ... ''...''`
**失败原因**：
- Nix 解析器把内层 `''` 当作外层 `text = ''` 的结束标记
- 导致 `syntax error, unexpected IN_KW, expecting INHERIT`
- 用 `cat -A` 和 grep 检查 `''` 标记位置来定位问题

**教训**：Nix 多行字符串中不要嵌套 `''...''`，改用 `writeShellScript` 或字符串拼接 `+`。

### 失败 8：opkg 安装 OpenClash 依赖解析
**方案**：`opkg install /tmp/openclash.ipk`（本地 IPK）
**失败原因**：
- opkg 需要包索引来解析依赖，即使 IPK 是本地的
- `opkg update` 在容器内失败（PPPoE 未拨通或 DNS 不通）
- `dnsmasq-full` 未安装导致 DNS 不通 → opkg update 失败 → 无法安装 OpenClash

**教训**：opkg 的依赖解析依赖包索引，本地 IPK 安装也需要 `opkg update` 先运行。

### 失败 9：distrobuilder actions 执行失败
**方案**：在 YAML 的 `actions` 节中用 `post-packages` 触发器安装 OpenClash
**失败原因**：
- `fork/exec /proc/self/fd/3: exec format error`
- distrobuilder 在 aarch64 上执行 shell 脚本的方式有问题
- 添加 `#!/bin/sh` shebang 后仍然失败

**教训**：distrobuilder 3.2 在 aarch64 上的 `actions` 有已知兼容性问题。

### 失败 10：dnsmasq-full 与 dnsmasq 冲突
**方案**：在 YAML 包列表中直接加 `dnsmasq-full`
**失败原因**：
- 基础 OpenWrt 镜像预装了 `dnsmasq`
- `dnsmasq-full` 与 `dnsmasq` 文件冲突，opkg 拒绝安装
- `opkg install --force-overwrite` 也不行

**解决**：在 distrobuilder 的 `actions` 中先 `opkg remove --force-depends dnsmasq`，再 `opkg install dnsmasq-full`。

---

## 容器启动失败调试记录

### 故障 1：`incus export` 导出的 rootfs 启动失败
**现象**：从运行中容器 `incus export` 导出 rootfs，导入为新镜像后启动容器报 `lxc.hook.pre-start` 失败
**原因**：导出的 rootfs 包含运行时状态（PID 文件、临时文件、lock 文件），不是干净的文件系统
**解决**：先 `incus stop` 再 `incus export`；或用 `incus publish` 代替
**教训**：`incus export` ≠ `docker commit`，需要先停容器

### 故障 2：`"The instance is already running"` 错误
**现象**：ensure 脚本报 `Error: The instance is already running`，但容器确实存在且运行中
**原因**：ensure 脚本的 `incus info` 检查通过（容器存在），进入 else 分支，但 `incus start` 被调用时容器已在运行
**解决**：`incus start ${containerName} || true` 容错
**教训**：`incus start` 对已运行容器报错，需要 `|| true` 或先检查状态

### 故障 3：profile 变更导致容器重建循环
**现象**：每次 `nixos-rebuild switch` 都重建容器，因为 `desired_profile` 字符串与 `profileStateFile` 不匹配
**原因**：`profileStateFile` 中存储的 profile 字符串格式与新生成的不一致（尾部换行符差异）
**解决**：用 `printf '%s\n'` 写入，读取时用 `$(cat ...)` 自动 trim
**教训**：字符串比较时注意尾部空白字符

### 故障 4：MAC 地址冲突
**现象**：`Error: MAC address "88:c3:97:9b:92:03" already defined on another NIC`
**原因**：旧容器的 eth1 使用了固定 MAC，新容器启动时 eth1 也尝试使用相同 MAC
**解决**：先删除旧容器再启动新容器，或使用不同 profile
**教训**：固定 MAC 地址的容器必须先删除才能用相同 profile 启动新容器

### 故障 5：distrobuilder `actions` 执行报 `exec format error`
**现象**：`Error: Failed to run post-packages: fork/exec /proc/self/fd/3: exec format error`
**原因**：distrobuilder 3.2 在 aarch64 上通过 `/proc/self/fd/N` 执行 shell 脚本，内核无法识别文件描述符指向的脚本格式
**解决**：在脚本首行加 `#!/bin/sh` shebang；或用 `files` section + `uci-defaults` 替代
**教训**：distrobuilder 的 `actions` 在 aarch64 上有兼容性问题，优先用 `files` + 首次启动脚本

### 故障 6：dnsmasq-full 安装冲突
**现象**：`opkg install dnsmasq-full` 报 `Cannot install package dnsmasq-full`
**原因**：基础 OpenWrt 镜像预装了 `dnsmasq`，`dnsmasq-full` 与之文件冲突
**解决**：先 `opkg remove --force-depends dnsmasq`，再 `opkg install dnsmasq-full`
**教训**：OpenWrt 的 `dnsmasq` 和 `dnsmasq-full` 互斥，distrobuilder YAML 中不能同时包含

### 故障 7：容器内 opkg 安装 IPK 依赖解析失败
**现象**：`opkg install /tmp/openclash.ipk` 报 `cannot find dependency dnsmasq-full`
**原因**：`opkg install` 本地 IPK 时仍需要包索引来解析依赖，`opkg update` 未运行
**解决**：先 `opkg update`（需要网络），或确保所有依赖已预装在镜像中
**教训**：opkg 的依赖解析依赖包索引，本地 IPK 安装也需要索引

### 故障 8：incus preseed 失败 - 无效配置选项
**现象**：`Error: Invalid option for network "o6n-owrt-mgmt" option "raw.lxc"`
**原因**：`raw.lxc` 和 `security.privileged` 是 profile/容器配置，错误地放在了 network config 中
**解决**：移到 profile 的 `config` 节
**教训**：Incus 的 network、profile、container 配置有明确的 schema，preseed 会校验

---

## 最终方案总结

```
distrobuilder YAML (openwrt-image.yaml)
├── packages: 20+ 包（bash, curl, htop, wireguard-tools 等）
├── actions/post-packages:
│   ├── remove dnsmasq → install dnsmasq-full
│   └── wget OpenClash IPK → opkg install
└── files:
    └── /etc/opkg/distfeeds.conf (USTC 镜像源)

Nix derivation (openwrt-container.nix)
├── customImage = runCommand + distrobuilder (__noChroot)
├── ensure: 导入镜像 → 创建/启动容器
└── reconcile: 推送 UCI 配置（不装包）
```

**关键成功因素**：
- distrobuilder 在 aarch64 上原生运行，不需要 QEMU
- `__noChroot = true` + `sandbox = "relaxed"` 允许网络访问
- actions 中先 remove dnsmasq 再 install dnsmasq-full 解决冲突
- OpenClash 通过 wget 下载 IPK 安装（不在 opkg 源中）
