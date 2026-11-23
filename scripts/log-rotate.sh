#!/bin/bash
# 日志月度轮转：网站日志归档 + ops-agent 自身日志清理
set -u
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

RETAIN_MONTHS="${LOG_RETAIN_MONTHS:-12}"
LAST_MONTH="$(date -d 'last month' '+%Y-%m')"
ARCHIVE_DAYS=$(( RETAIN_MONTHS * 30 ))

echo "$(date '+%F %T') 开始日志轮转..."

# ---- 1. 网站日志（nginx） ----
for log_file in "${LOGDIR}"/*.log; do
    [ -f "$log_file" ] || continue
    size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
    [ "$size" -eq 0 ] && continue

    archive="${LOGDIR}/$(basename "${log_file%.log}")-${LAST_MONTH}.log.gz"
    if gzip -c "$log_file" > "$archive" 2>/dev/null; then
        truncate -s 0 "$log_file"
        echo "  已归档: $(basename "$log_file") -> $(basename "$archive")"
    else
        echo "  归档失败: $(basename "$log_file")"
    fi
done

if [ -x "${NGINX_BIN}" ]; then
    "${NGINX_BIN}" -s reopen 2>/dev/null && echo "  Nginx 日志已重新打开"
fi

find "${LOGDIR}" -name "*.log.gz" -type f -mtime "+${ARCHIVE_DAYS}" -delete 2>/dev/null

# ---- 2. ops-agent 自身日志 ----
# 每日报告/扫描日志：超过 90 天压缩，超过 365 天删除（保留归档）
for f in "${OPS_ROOT}"/logs/*.log; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in cron.log) continue ;; esac
    age_d=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
    if [ "$age_d" -gt 365 ]; then
        gzip -c "$f" > "${f}.gz" 2>/dev/null && rm -f "$f" && echo "  压缩归档: $(basename "$f")"
    elif [ "$age_d" -gt 90 ]; then
        gzip -c "$f" > "${f}.gz" 2>/dev/null && rm -f "$f" && echo "  压缩: $(basename "$f")"
    fi
done

# cron.log 超过 10MB 时截断归档
CRON_LOG="${OPS_ROOT}/logs/cron.log"
if [ -f "$CRON_LOG" ]; then
    size=$(stat -c %s "$CRON_LOG")
    if [ "$size" -gt $((10 * 1024 * 1024)) ]; then
        gzip -c "$CRON_LOG" > "${CRON_LOG}.$(date +%Y%m).gz"
        : > "$CRON_LOG"
        echo "  cron.log 已归档并清空"
    fi
fi

# 状态目录清理：judge 审计与 items 保留 90 天
find "${OPS_ROOT}/logs/.state" -type f -name 'judge-*' -mtime "+90" -delete 2>/dev/null
find "${OPS_ROOT}/logs/.state" -type f -name '*.tsv' -mtime "+90" -delete 2>/dev/null

echo "$(date '+%F %T') 日志轮转完成"
