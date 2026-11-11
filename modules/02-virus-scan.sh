#!/bin/bash
# 02-病毒扫描结果检查（读取当日 ClamAV 日志）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

LOG_DATE="$(today)"
SCAN_LOG="${OPS_ROOT}/logs/${LOG_DATE}-clamav.log"

if [ ! -f "$SCAN_LOG" ]; then
    finding WARN "virus:scan-missing" "今日 ClamAV 扫描未执行" \
        "缺少 ${SCAN_LOG}" \
        "检查 scripts/clamav-scan.sh 与 cron；确认 clamav 已安装"
    exit 0
fi

if ! grep -q "扫描完成时间" "$SCAN_LOG" 2>/dev/null; then
    finding WARN "virus:scan-incomplete" "ClamAV 扫描未完成" \
        "$(tail -3 "$SCAN_LOG" | tr '\n' ' ')" \
        "检查是否超时或 clamscan 异常退出"
    exit 0
fi

scanned=$(grep -oE '总扫描文件: [0-9]+' "$SCAN_LOG" | tail -1 | grep -oE '[0-9]+' || echo 0)
infected=$(grep -oE '总感染文件: [0-9]+' "$SCAN_LOG" | tail -1 | grep -oE '[0-9]+' || echo 0)
finished=$(grep '扫描完成时间' "$SCAN_LOG" | tail -1 | sed 's/.*: //')

if [ "${infected:-0}" -gt 0 ]; then
    detail="$(grep -E 'FOUND$' "$SCAN_LOG" | head -5 | tr '\n' ';')"
    finding CRIT "virus:infected" "发现 ${infected} 个恶意文件" \
        "扫描 ${scanned} 个文件，命中：${detail}" \
        "立即隔离/删除文件、排查入侵入口、检查 crontab 与 webshell"
else
    finding INFO "virus:clean" "ClamAV 扫描通过（${scanned} 个文件）" "完成时间 ${finished}" ""
fi
