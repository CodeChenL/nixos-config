#!/usr/bin/env bash
# radxa-kernel-deployer 辅助函数库
# 由 deploy.sh source 引入

retry_scp() {
  local max=3 delay=2
  for i in $(seq 1 $max); do
    sshpass -p "${PASSWORD}" scp -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SCP] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SCP] 重试${max}次后仍失败" >&2; return 1
}

retry_ssh() {
  local max=3 delay=5
  for i in $(seq 1 $max); do
    sshpass -p "${PASSWORD}" ssh -o StrictHostKeyChecking=no "$@" && return 0
    echo "[SSH] 第${i}次失败，${delay}s后重试" >&2; sleep $delay; delay=$((delay * 2))
  done
  echo "[SSH] 重试${max}次后仍失败" >&2; return 1
}

sudo_remote() {
  local host="$1" cmd="$2"
  sshpass -p "${PASSWORD}" ssh -tt -o StrictHostKeyChecking=no "${host}" "echo '${PASSWORD}' | sudo -S bash -c '${cmd}'"
}

wait_for_device() {
  local host="$1" max=5 delay=10
  for i in $(seq 1 $max); do
    sshpass -p "${PASSWORD}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${host}" "echo ok" >/dev/null 2>&1 && \
      { echo "[wait] 设备已恢复（第${i}次）"; return 0; }
    echo "[wait] 等待上线 ${i}/${max}（${delay}s）" >&2; sleep $delay; delay=$((delay + delay / 2))
  done
  echo "[wait] ${max}次尝试后无响应" >&2; return 1
}
