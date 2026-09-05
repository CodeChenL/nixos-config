#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/tmp/.radxa-packager-make-deb.lock"
LOCK_TIMEOUT=1800  # 30 分钟

# === 参数解析 ===
CLEAN=false TEST=false

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --clean      构建前执行 make clean（仅明确需要时使用，会显著增加时间）
  --test       构建前执行 make test（即 make test deb）
  -h, --help   显示帮助
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)    CLEAN=true; shift ;;
    --test)     TEST=true; shift ;;
    -h|--help)  usage ;;
    *)          echo "未知参数: $1"; exit 1 ;;
  esac
done

# === 环境检测 ===
in_container() {
  [[ -f /.dockerenv ]] && return 0
  [[ "${container:-}" == "true" ]] && return 0
  return 1
}

# === 构建命令组装 ===
build_cmd() {
  local cmd=""
  if $CLEAN; then cmd="make clean && "; fi
  if $TEST; then
    cmd="${cmd}make test deb"
  else
    cmd="${cmd}make deb"
  fi
  echo "$cmd"
}

# === 执行 ===
CMD=$(build_cmd)

if in_container; then
  echo "[INFO] 检测到容器环境，直接执行"
  flock --timeout "$LOCK_TIMEOUT" "$LOCK_FILE" bash -c "$CMD"
else
  echo "[INFO] 检测到 Host 环境，通过 devcontainer 执行"
  if ! command -v devcontainer &>/dev/null; then
    echo "ERROR: devcontainer CLI 未安装" >&2; exit 1
  fi
  devcontainer exec --workspace-folder ./ bash -c "flock --timeout $LOCK_TIMEOUT $LOCK_FILE bash -c '$CMD'"
fi

echo "[DONE] 构建完成"
