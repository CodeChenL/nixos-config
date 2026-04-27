#!/bin/bash
# IPKVM 控制接口快速调用脚本
# 用法: ./send_control.sh '{"events":[["text","hello"],["delay",300]]}'

set -e

IPKVM_URL="${IPKVM_URL:-http://192.168.2.224:8080}"
API_URL="${IPKVM_URL}/api/control"

if [ $# -eq 0 ]; then
    echo "用法: $0 '<json_payload>'"
    echo "示例:"
    echo "  $0 '{\"events\":[[\"text\",\"hello\"],[\"delay\",300]]}'"
    echo ""
    echo "环境变量:"
    echo "  IPKVM_URL - IPKVM设备URL (默认: http://192.168.2.224:8080)"
    exit 1
fi

echo "发送请求到: ${API_URL}"
curl -X POST "${API_URL}"     -H "Content-Type: application/json"     -d "$1" | jq .
