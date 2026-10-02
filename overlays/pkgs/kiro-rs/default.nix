{ inputs, final, prev }:

let
  # 2026-09-29 master（v2026.3.1 后续提交）：kiro.rs —— Anthropic API ⇄ Kiro API 反代。
  # models-update.patch 补齐 kiro.dev 2026-09-28 最新模型目录（上游 PR #192/#199/#201
  # 已给出 wire ID 口径：gpt-5.6-{sol,terra,luna}、claude-opus-5.5、claude-fable-5.1
  # 点号形式），并补充 Sonnet 4.0 与开放权重模型（DeepSeek 3.2 / MiniMax M2.x /
  # GLM-5 / Qwen3 Coder Next）。
  # upstreamPatches 直接拉取上游未合并 PR 的提交（按顺序叠加，均可干净应用）。
  # anthropic-parity.patch 是本地改动，让下游 API 行为对齐 Anthropic。
  upstreamCommit =
    rev: hash:
    prev.fetchpatch {
      url = "https://github.com/hank9999/kiro.rs/commit/${rev}.patch";
      inherit hash;
    };
  upstreamPatches = [
    # PR #187：解析 Q 上游 reasoningContentEvent 独立推理流 → thinking content_block。
    # 新世代模型（opus-4.7+/5.x）思考只走该事件流，不移植时被当作 Unknown 丢弃。
    (upstreamCommit "8ec382f1c33bc4fe80e31ee10273bb39b238ee38" "sha256-nTWhtm7lJC1v0P538qfhG0l0P6oS4AwFIXCYD0ycfEA=")
    (upstreamCommit "804bf9acbf98728ab0f2b654b5605668d932022b" "sha256-cvJ/wmBZNQAQ8+8CycPKivK6a4yayLo6AiSw0Kl/UsQ=")
    # PR #173：effort 走真实协议字段 additionalModelRequestFields.output_config.effort。
    (upstreamCommit "b6b61938cc9e6e1978cc978fd1f06018defbee95" "sha256-meWh/jZGSXNuhK0D5tIZZ8UsfegcgsYL8aoNJf8U7OQ=")
    # PR #199：tool_result 中的 image 块不再被静默丢弃。
    (upstreamCommit "448a3655b5fed8c19ba03eb838c3d381b0370631" "sha256-mhjEex6xpKz+emYACljeKFKOmqpEQwtJ/K0yj8STFKw=")
  ];
  version = "2026.3.1";
  rev = "e09625c3e7dea40aa9463d517e63f916828ef92b";
  src = prev.fetchFromGitHub {
    owner = "hank9999";
    repo = "kiro.rs";
    inherit rev;
    hash = "sha256-YIKRZfqXJqOqMkFr9RmaGa5hAbwaCJ76VRw4zQkLR+E=";
  };
  # Admin UI（Vite/React/pnpm）——rust-embed 把 admin-ui/dist 编进二进制，
  # 配置 adminApiKey 后经 /admin 提供凭据在线管理（增删/禁用/优先级/余额）。
  adminUi = prev.stdenv.mkDerivation {
    pname = "kiro-rs-admin-ui";
    inherit version;
    src = src + "/admin-ui";
    sourceRoot = "admin-ui";

    nativeBuildInputs = [
      prev.nodejs
      prev.pnpm
      prev.pnpmConfigHook
    ];

    # fetcherVersion 2 与 pnpm 11 lockfile 兼容；nixpkgs 26.11 移除前迁移到 4 并重算 hash。
    pnpmDeps = prev.fetchPnpmDeps {
      pname = "kiro-rs-admin-ui";
      inherit version;
      src = src + "/admin-ui";
      fetcherVersion = 2;
      hash = "sha256-38iIk9nCxDgQrsjtqETHXR/zOLyAL/hw5b+E5D/Mt6U=";
    };

    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };
in
prev.rustPlatform.buildRustPackage {
  pname = "kiro-rs";
  inherit version src;

  cargoLock.lockFile = src + "/Cargo.lock";

  # anthropic-parity.patch：上游 error/exception 事件与中途断流映射为 Anthropic `error`
  # 事件（而非伪装成正常 end_turn）；支持 thinking.display=omitted；Opus 5.x/Sonnet 5/
  # Fable 未传 thinking 时默认 adaptive；Opus 4.7+ 的 enabled 映射为 adaptive；
  # 客户端显式 output_config.effort 不再被 -thinking 后缀覆写。
  # kiro-protocol.patch：补齐 Kiro 真实协议字段——解析 metadataEvent（精确 usage/缓存命中/
  # stopReason；FIXME(metadataEvent)：上游当前不下发该事件，疑似按客户端版本号门控，
  # 重试入口见 hosts/Aliyun/kiro-rs.nix 的 kiroVersion 选项注释）；下发 inferenceConfig（maxTokens，非 thinking 时 temperature/topP）；
  # effort 字段按上游 schema 门控（sonnet/haiku/opus 4.5 发送会 400，GPT-5.6 用 reasoning）；
  # 旧世代（Sonnet/Haiku 4.5）按 Anthropic 规则剥离往轮 thinking；分块写入约束扩展到
  # opencode 的 write/edit/bash 与 Claude Code 的 Bash（上游缓存整段工具输入、静默约 240s
  # 即断连），且仅在这些工具存在时注入；上下文溢出错误改用 "prompt is too long" 措辞以触发客户端压缩。
  # 上游连接加 TCP/HTTP2 keepalive（仅传输层兜底，实测挡不住上游约 240s 的应用层静默断连），
  # 流中断错误展开 source 链以便定位真实原因（reqwest 只报 "error decoding response body"）。
  # FIXME(max_tokens)：上游接受 inferenceConfig.maxTokens 但不遵守（实测 30 仍输出约 340 token）。
  # stream-resilience.patch：Kiro 偶发在 reasoning 之后直接收尾（无正文、无工具调用、无错误），
  # 客户端据此以 length 结束回合；此时透明重试一次（换新 agentContinuationId），输出续接到
  # 同一条消息。未知事件类型仍可忽略；已识别事件的畸形载荷立即终止为 SSE error / HTTP 502。
  patches = [
    ./models-update.patch
  ]
  ++ upstreamPatches
  ++ [
    ./anthropic-parity.patch
    ./kiro-protocol.patch
    ./stream-resilience.patch
  ];

  # openssl-src（native-tls-vendored）构建需要 perl。
  nativeBuildInputs = [ prev.perl ];

  # rust-embed 在编译期嵌入 admin-ui/dist：装入真实管理界面构建产物。
  postPatch = ''
    rm -rf admin-ui/dist
    cp -r ${adminUi} admin-ui/dist
  '';

  # 测试覆盖模型目录、thinking 策略，以及真实 loopback HTTP/eventstream 的畸形载荷与重试路径。
  doCheck = true;

  meta = with prev.lib; {
    description = "Anthropic-compatible proxy that exposes Kiro subscriptions as a Claude API";
    homepage = "https://github.com/hank9999/kiro.rs";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "kiro-rs";
  };
}
