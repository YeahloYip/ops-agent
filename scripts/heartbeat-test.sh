#!/bin/bash
# 心跳手动测试：向 HEARTBEAT_URL 发一次 ping
# 用法：
#   bash scripts/heartbeat-test.sh          # 发正常 ping（面板显示 Up）
#   bash scripts/heartbeat-test.sh --fail   # 发 fail ping（面板显示 Down，可能触发告警邮件）
set -u
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"

if [ "${HEARTBEAT_ENABLED:-true}" != "true" ]; then
    echo "心跳未启用（HEARTBEAT_ENABLED != true）" >&2
    exit 1
fi
if [ -z "${HEARTBEAT_URL:-}" ]; then
    echo "HEARTBEAT_URL 为空。请先在 https://healthchecks.io 创建 Check，并把 ping URL 填入 config.env" >&2
    echo "详细步骤见 docs/heartbeat.md" >&2
    exit 1
fi

url="$HEARTBEAT_URL"
if [ "${1:-}" = "--fail" ]; then
    url="${url%/}/fail"
    echo "注意：fail ping 会让面板显示 Down，可能触发告警通知"
fi

if curl -fsS -m 10 -o /dev/null "$url"; then
    echo "ping ok: ${url%%/?*}"
    echo "请到 healthchecks 面板确认该 Check 的 Last Ping 已更新"
    exit 0
else
    echo "ping 失败：检查服务器网络/DNS，或 HEARTBEAT_URL 是否正确" >&2
    exit 1
fi
