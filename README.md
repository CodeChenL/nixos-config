# ChenIdeaCentre NixOS 配置

ChenIdeaCentre 维护的 NixOS 多主机配置，使用 Nix Flakes + home-manager + 多个 overlay。

## 主机

| Host | 架构 | 用途 |
| --- | --- | --- |
| `ChenIdeaCentre` | x86_64-linux | 主桌面，KDE Plasma 6 Wayland + NVIDIA |
| `ChenWSL` | x86_64-linux | WSL2 中的 NixOS |
| `ChenRadxaOrionO6N` | aarch64-linux | Radxa Orion O6N (CIX Sky1)，运行 OpenWrt 容器 |
| `ChenAsahiLinux` | aarch64-linux | Apple M1 Mac mini，Asahi Linux + OpenClaw 网关 |

切换主机的标准命令：

```sh
sudo nixos-rebuild switch --flake .#ChenIdeaCentre
```

## 目录结构

```
.
├── flake.nix              # 入口：inputs、mkHost helper、多台主机定义
├── hosts/
│   ├── common.nix         # 三台主机共享的 Nix 设置、用户、基础包
│   ├── ChenIdeaCentre/    # 主桌面
│   ├── ChenWSL/           # WSL2 主机
│   ├── ChenRadxaOrionO6N/ # Radxa 板
│       └── openwrt/       # OpenWrt 容器：UCI 配置 + 启动脚本
│   └── ChenAsahiLinux/    # Apple M1 Mac mini / Asahi Linux
├── home/chen/             # home-manager：用户环境
│   ├── lsp.nix           # O6N 用的纯 LSP/工具集（不含桌面专属）
│   └── dev.nix           # 桌面主机的 LSP + 桌面工具 + 重资源 SDK
├── overlays/              # 自定义 packages
│   ├── default.nix        # 入口：unstable/master/NUR 通道 + 包聚合
│   ├── apply-debian-patches.nix
│   ├── linux-cix-main/    # 交叉编译的内核 overlay
│   ├── cix-*/             # CIX SoC 专用 VPU/NPU/固件 overlay
│   └── pkgs/              # 业务包（freedownloadmanager、trae-cn 等）
├── skills/                # AI Agent skills（ipkvm、lore-mail、radxa-*）
├── docs/                  # 故障排查与 bringup 笔记
└── .github/workflows/     # CI：flake check + overlay 构建
```

## 自定义 overlay

新增包约定：

1. 在 `overlays/pkgs/<name>/default.nix` 中按以下签名写包定义：
   ```nix
   { inputs, final, prev }:
   { <name> = final.callPackage ({ lib, ... }: stdenv.mkDerivation { ... }) { }; }
   ```
2. 包会被 `overlays/default.nix` 的 `collectPkgs` 自动发现、加入 overlay。
3. 包定义放在 `overlays/pkgs/<name>/default.nix`；少数共用 patch/lockfile 仍可放在 `overlays/` 顶层，由对应包显式引用。

如果包依赖 `inputs.*`（如 radxa-linkr-debuggerctl），仍可在 `overlays/pkgs/<name>/default.nix` 中访问 `inputs`。

## 密钥管理

- 密钥目录：`secrets/`（`.gitignore` 保护）
- `secrets/gpg-public.key` 为 ASCII armored 公钥文本，可直接复制到 GitHub GPG keys；`secrets/gpg-secret.key` 为本地私钥备份，不可上传
- 引用方式：Nix 配置中**不**直接 `builtins.readFile`，而是从运行时路径读取（`/var/lib/...`）
- `ChenAsahiLinux` 的 OpenClaw 网关声明式引用 `secrets/opencode/minimax.key` 和 `secrets/openclaw/gateway-token`
- `ChenAsahiLinux` 暂不在 flake 中直接引用 `/boot/efi/asahi` 的非再分发固件，以保持纯评估
- 部署到主机后立即 `chmod 0600`
- `o6n-openwrt-ensure` 启动时使用 `@@OWRT_SECRET:NAME@@` 占位符注入 `secrets/o6n-openwrt.env`

**绝不**在 `git add` 中包含 `secrets/` 内容。

## CI

| Workflow | 触发 | 检查项 |
| --- | --- | --- |
| `nix-flake-check.yml` | 每次 push/PR | flake 语法、secrets 未泄露、shellcheck |
| `nix-overlay-build.yml` | 手动 + 每周一 | 按支持架构验证自定义 overlay 包构建 |

CI 只用 GitHub 托管 runner + 公开免费的 `DeterminateSystems/nix-installer-action`，**不**依赖 Cachix 私有缓存（成本太高）。

## 系统清理策略

- 每日 `nix-collect-garbage`，删除 30 天前的 system profile（`hosts/common.nix`）
- 每日清理 30 天前的 home-manager generations（`home/chen/default.nix` 的 `services.home-manager.autoExpire`）
- Nix 2.18+ 已默认开启 store hard-link 合并，无需手动启用 `auto-optimise-store`

`maxGenerations` 严格按"保留 N 个最近 generation"控制时，需在 `boot.loader.<loader>.maxGenerations`（per-host）配置；本仓库走日期清理路线。

## 开发工具

`home/chen/dev.nix` 包含：VSCode（带 distrox 包装）、b4（patch 系列工具）、WakaTime。

`home/chen/opencode.nix` 管理 OpenCode 配置与 `auth.json` 注入；CLI/桌面包由 overlay 与 Home Manager 包列表引入。

## 故障排查

- 启动失败：参考 `docs/o6n-bringup.md`（Radxa 板 bringup runbook）
- OpenWrt 容器：`hosts/ChenRadxaOrionO6N/openwrt-container.nix` 的 systemd 单元 + `o6n-openwrt-reconcile --help`
- 内核/CIX 驱动：见 `docs/session-lessons.md` 中的相关章节
- skill 工作流：每个 skill 自带 `SKILL.md`（`skills/*/SKILL.md`）
