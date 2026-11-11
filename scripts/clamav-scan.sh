#!/bin/bash
# ClamAV 独立病毒扫描脚本
# 每日凌晨1:02执行，扫描结果写入日志

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

LOG_DATE=$(date "+%Y-%m-%d")
SCAN_LOG="${SCRIPT_DIR}/logs/${LOG_DATE}-clamav.log"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SCAN_LOG"
}

# 初始化日志
echo "======================================" > "$SCAN_LOG"
echo "  ClamAV 病毒扫描报告" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"
echo "扫描时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SCAN_LOG"
echo "主机: ${SERVER_NAME} (${SERVER_IP})" >> "$SCAN_LOG"
echo "" >> "$SCAN_LOG"

log "开始病毒扫描..."

# 更新病毒库（不等待，失败继续）
freshclam --quiet 2>/dev/null

# 确保 clamscan 可用
if ! command -v clamscan >/dev/null 2>&1; then
    log "[ERROR] clamscan 未安装，扫描终止"
    exit 1
fi

# 统计变量
total_infected=0
total_scanned=0
site_results=""

# 遍历网站目录
for site_dir in "$WEBROOT"/*/; do
    [ -d "$site_dir" ] || continue
    site_name=$(basename "$site_dir")

    # 跳过备份和默认目录
    case "$site_name" in
        backup|default) continue ;;
    esac

    log "--- 扫描站点: ${site_name} ---"

    # 创建临时目录存放感染文件列表
    infected_file=$(mktemp)

    # 执行 ClamAV 扫描（每个站点最多180秒超时）
    scan_output=$(timeout 180 clamscan -r --infected \
        --exclude-dir="^${site_dir}vendor" \
        --exclude-dir="^${site_dir}node_modules" \
        --exclude-dir="^${site_dir}storage" \
        --exclude-dir="^${site_dir}.git" \
        --exclude-dir="^${site_dir}bootstrap/cache" \
        --max-filesize=20M \
        --max-scansize=50M \
        "$site_dir" 2>&1)

    exit_code=$?

    # 提取扫描统计
    site_scanned=$(echo "$scan_output" | grep "Scanned files:" | awk '{print $NF}')
    site_infected=$(echo "$scan_output" | grep "Infected files:" | awk '{print $NF}')
    site_data=$(echo "$scan_output" | grep "Data scanned:" | awk '{print $NF}')
    site_time=$(echo "$scan_output" | grep "Time:" | awk '{print $2, $3}')

    site_scanned=${site_scanned:-0}
    site_infected=${site_infected:-0}

    total_scanned=$((total_scanned + site_scanned))
    total_infected=$((total_infected + site_infected))

    # 记录扫描结果
    log "扫描文件数: ${site_scanned}, 感染文件数: ${site_infected}, 数据量: ${site_data:-N/A}, 耗时: ${site_time:-N/A}"

    # 如果发现感染文件，记录详细路径
    if [ "$site_infected" -gt 0 ]; then
        log "[ALERT] 发现 ${site_infected} 个感染文件:"
        echo "$scan_output" | grep "FOUND$" | while IFS= read -r line; do
            log "  -> ${line}"
        done
        site_results+="  [${site_name}] 发现 ${site_infected} 个感染文件\n"
    elif [ $exit_code -eq 124 ]; then
        log "[WARN] 扫描超时(180s)，可能未完成"
        site_results+="  [${site_name}] 扫描超时\n"
    else
        log "扫描通过，未发现病毒"
        site_results+="  [${site_name}] 扫描通过 (${site_scanned} 文件)\n"
    fi

    rm -f "$infected_file"
done

# 汇总
echo "" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"
echo "  扫描汇总" >> "$SCAN_LOG"
echo "======================================" >> "$SCAN_LOG"
log "总扫描文件: ${total_scanned}, 总感染文件: ${total_infected}"

if [ "$total_infected" -gt 0 ]; then
    log "[CRITICAL] 发现 ${total_infected} 个感染文件，需要人工处理"
    # 输出感染文件完整路径（供 agent.sh 读取）
    echo "" >> "$SCAN_LOG"
    echo "感染文件列表:" >> "$SCAN_LOG"
    grep "FOUND$" "${SCRIPT_DIR}/logs/${LOG_DATE}-clamav.log" | while IFS= read -r line; do
        echo "  ${line}" >> "$SCAN_LOG"
    done
else
    log "[OK] 所有站点扫描通过，未发现病毒"
fi

log "扫描完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
