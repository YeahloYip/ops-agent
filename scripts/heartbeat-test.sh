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

# 强制 IPv4：部分服务器 IPv6 不通，而 healthchecks 有 AAAA 记录，curl 会先试 IPv6 而超时
rc=1
for attempt in 1 2 3; do
    if curl -4 -fsS -m 15 -o /dev/null "$url"; then rc=0; break; fi
    [ "$attempt" -lt 3 ] && sleep 2
done

if [ "$rc" -eq 0 ]; then
    echo "ping ok（第 ${attempt} 次尝试）"
    echo "请到 healthchecks 面板确认该 Check 的 Last Ping 已更新"
    exit 0
else
    echo "ping 失败：检查服务器网络/DNS，或 HEARTBEAT_URL 是否正确" >&2
    echo "提示：本机 IPv6 不通时脚本已强制 IPv4；若仍失败，用 curl -4 -v 手动排查" >&2
    exit 1
fi
