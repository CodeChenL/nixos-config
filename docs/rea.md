# REA：声明式 headless 接线

REA 固定为 **6.4.0**，由 Nix 提供 `rea` 与 `rea-agents`，不运行
`npx`、`rea setup`、`rea update` 或上游安装流程。
包使用 npm 发布物及同版 Git tag 的 lockfile，分别锁定内容哈希；生产依赖
在 Nix 构建阶段安装，运行时无需下载 npm 包。更新版本请改
`overlays/pkgs/rea/default.nix` 的版本与哈希，而不是执行自更新。

## CLI、MCP 与技能

- CLI 包路径为 `${pkgs.rea}/bin/rea`、`${pkgs.rea}/bin/rea-agents`；配置生效后也可直接通过 PATH 调用。
- OpenCode V2 与 Codex 均使用绝对包路径启动 `rea mcp`，启动超时 30 秒、工具执行超时 600 秒；保留既有 MCP 配置。
- Codex 配置保持原有 x86 桌面门控，不扩展安装平台。
- 同版 `reverse-engineer-anything` 技能由 `pkgs.rea.skills` 整目录复制到技能聚合包，再由现有 `.agents/skills` 与 `.claude/skills` 接线提供。不能改成逐文件符号链接（上游 doctor 会拒绝），也无需重复加入 OpenCode 的 `skills` 数组。

## 后端与边界

x86_64 Linux 的 wrapper 默认选择 `provider=ghidra`，设置
`GHIDRA_INSTALL_DIR` 与 `JAVA_HOME`。Ghidra 使用 headless 模式，无需 GUI，
与既有独立 Ghidra MCP 不冲突。ARM 默认仅静态功能，不强装原生后端；
ARM 配置已求值，实际运行未验证。wrapper 使用默认环境值，可按需显式覆盖
后端与 Java 路径，不修改用户的全局 `JAVA_HOME`。

仅安装基础后端，不默认安装 Hopper、IDA、JEB、JADX、pwntools、Wireshark
等工具；额外目标工具按需提供。仅用于分析自有或已明确授权的目标。

## 构建与检查

在仓库根目录可构建包或完整配置：

```sh
nix build .#nixosConfigurations.ChenIdeaCentre.pkgs.rea
nix build .#nixosConfigurations.ChenIdeaCentre.pkgs.rea.tests.smoke --no-link
nix build .#nixosConfigurations.ChenIdeaCentre.config.system.build.toplevel
```

`build` 不会激活配置；`nixos-rebuild switch --flake .#ChenIdeaCentre` 会部署并
激活配置。此次配置没有执行 switch，也没有运行上游 setup 或重启现有服务。
部署后重开 Codex、在 OpenCode 中重载配置或重开客户端，再检查 REA MCP 连接。

配置生效后可检查（未 switch 时可用首次单独构建 REA 得到的输出路径；
完整系统构建会把 `result` 改指系统输出）：

```sh
rea --version
rea doctor --provider ghidra --json  # x86_64 Linux 的 Ghidra 检查
rea doctor --skill --json
```

## 验证记录（2026-10-13）

- REA 固定包离线构建及重建通过；CLI 版本为 6.4.0。
- 真实 MCP stdio 初始化、工具列表（170 项）及正常退出通过。
- 原生 PTY 捕获及进程清理通过；同版技能（37/170）经最终聚合目录验证通过。
- 最终 Nix 包调用 Ghidra 12.1.2 反编译自建 ELF，得到与源码一致的
  `return n * 7 + 0xb;`，分析结束后临时 Ghidra 目录无残留。
- OpenCode JSON 与 Codex TOML 的生成配置校验通过，既有 MCP 保留。
- ChenIdeaCentre 完整系统构建通过；Orion O6N（ARM）和 WSL 的 Home Manager
  generation 求值通过。其它分析后端和 ARM 实际执行不在本次验证范围内。
