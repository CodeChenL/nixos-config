#!/usr/bin/env bash
# radxa-kernel-deployer 辅助函数库
# 由 deploy.sh source 引入
#
# 安全说明：所有 sshpass 调用通过 -e 参数从 SSHPASS 环境变量读取密码，
# 避免密码出现在进程命令行（/proc/*/cmdline）中被其他用户窥探。
# 使用前请确保：
#   1. PASSWORD 已导出到 SSHPASS（见 deploy.sh）
#   2. shell 历史中不含 PASSWORD 明文

retry_scp() {
  local max=3 delay=2
  for i in $(seq 1 $max); do
    sshpass -e scp -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SCP] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SCP] 重试${max}次后仍失败" >&2; return 1
}

retry_ssh() {
  local max=3 delay=5
  for i in $(seq 1 $max); do
    sshpass -e ssh -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SSH] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SSH] 重试${max}次后仍失败" >&2; return 1
}

sudo_remote() {
  local host="$1" cmd="$2"
  # sshpass -e 用 SSHPASS 完成 SSH 登录；printf 再把同一个密码喂给远端 sudo -S。
  # 注意：用 -T（禁用 PTY）确保 stdin 正确转发给 sudo；-tt 会接管 stdin 导致密码丢失。
  printf '%s\n' "${SSHPASS}" | \
  sshpass -e ssh -T -o StrictHostKeyChecking=no "${host}" \
    "sudo -S bash -c '${cmd}'"
}

wait_for_device() {
  local host="$1" max=5 delay=10
  for i in $(seq 1 $max); do
    echo "[wait] 等待上线 ${i}/${max}（${delay}s）" >&2; sleep $delay; delay=$((delay + delay / 2))
    sshpass -e ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${host}" "echo ok" >/dev/null 2>&1 && \
      { echo "[wait] 设备已恢复（第${i}次）"; return 0; }
  done
  echo "[wait] ${max}次尝试后无响应" >&2; return 1
}
