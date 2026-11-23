#!/bin/bash
# rkhunter 独立扫描脚本
# 每日凌晨0:45执行，扫描结果写入日志

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

LOG_DATE=$(date "+%Y-%m-%d")
SCAN_LOG="${SCRIPT_DIR}/logs/${LOG_DATE}-rkhunter.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SCAN_LOG"
}

echo "======================================" > "$SCAN_LOG"
echo "  rkhunter 安全扫描报告" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"
log "扫描时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "主机: ${SERVER_NAME} (${SERVER_IP})"
echo "" >> "$SCAN_LOG"

# 确保 rkhunter 可用
if ! command -v rkhunter >/dev/null 2>&1; then
    log "[ERROR] rkhunter 未安装，扫描终止"
    exit 1
fi

log "开始安全扫描..."

# 执行 rkhunter 扫描（超时300秒）
scan_output=$(timeout 300 rkhunter --check --skip-keypress --quiet 2>&1)
exit_code=$?

if [ $exit_code -eq 124 ]; then
    log "[WARN] 扫描超时(300s)，部分检查可能未完成"
fi

# 提取警告和可疑项
warnings=$(echo "$scan_output" | grep "Warning" | head -20)
suspicious=$(echo "$scan_output" | grep -i "suspicious" | head -10)
hidden=$(echo "$scan_output" | grep -i "hidden" | head -10)
threats=$(echo "$scan_output" | grep -iE "(threat|infected|rootkit)" | head -10)

# 提取统计
total_warnings=0; [ -n "$warnings" ] && total_warnings=$(echo "$warnings" | wc -l)
total_suspicious=0; [ -n "$suspicious" ] && total_suspicious=$(echo "$suspicious" | wc -l)
total_hidden=0; [ -n "$hidden" ] && total_hidden=$(echo "$hidden" | wc -l)
total_threats=0; [ -n "$threats" ] && total_threats=$(echo "$threats" | wc -l)

# 记录结果
if [ -n "$warnings" ]; then
    log "[WARN] 发现 ${total_warnings} 个警告:"
    echo "$warnings" | while IFS= read -r line; do
        log "  ${line}"
    done
fi

if [ -n "$suspicious" ]; then
    log "[WARN] 发现 ${total_suspicious} 个可疑项:"
    echo "$suspicious" | while IFS= read -r line; do
        log "  ${line}"
    done
fi

if [ -n "$hidden" ]; then
    log "[WARN] 发现 ${total_hidden} 个隐藏文件/进程:"
    echo "$hidden" | while IFS= read -r line; do
        log "  ${line}"
    done
fi

if [ -n "$threats" ]; then
    log "[CRITICAL] 发现 ${total_threats} 个威胁:"
    echo "$threats" | while IFS= read -r line; do
        log "  ${line}"
    done
fi

echo "" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"
echo "  扫描汇总" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"

if [ "$total_threats" -gt 0 ]; then
    log "[CRITICAL] 发现 ${total_threats} 个威胁，需要人工处理"
elif [ "$total_warnings" -gt 0 ]; then
    log "[WARN] 发现 ${total_warnings} 个警告，建议检查"
else
    log "[OK] 扫描通过，未发现异常"
fi

log "扫描完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
