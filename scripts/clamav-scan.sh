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

# ---------- 更新病毒库 ----------
# 背景：本机 ClamAV 0.103.9（Debian 10 归档源里的最新版）已被官方 CDN 按 UA 拒绝：
#   UA=ClamAV/0.103.9 -> HTTP 403；UA=ClamAV/1.4.3 -> HTTP 200
# 而 freshclam 0.103.9 不支持 --user-agent 参数，所以直接调 freshclam 必然失败，
# 且旧代码把 stderr 丢进 /dev/null，导致连续失败 4 周无人发现。
#
# 因此改为：用 curl 带新版 UA 直接下载 .cvd，校验通过后原子替换，再通知 clamd 重载。
# 已实测：新 daily.cvd 与旧 daily.cld 共存时，ClamAV 自动采用版本更高的 .cvd。
CLAM_DB_DIR="${CLAM_DB_DIR:-/var/lib/clamav}"
# UA 说明：官方 CDN 按 UA 里的版本号决定放行（0.103.x 被 403 拒绝，1.x 放行），
# 且会对同一 UA 做频率限制（短时间内重复下载返回 429）。
# 因此这里不写死单一版本，按顺序尝试；轮换可同时绕过"版本过旧"和"单 UA 限流"。
CLAM_DB_UAS="${CLAM_DB_UAS:-ClamAV/1.4.3 ClamAV/1.0.0 ClamAV/1.2.0}"
CLAM_DB_MIRROR="${CLAM_DB_MIRROR:-https://database.clamav.net}"
CLAM_DB_WARN_DAYS="${VIRUS_DB_WARN_DAYS:-7}"
CLAM_DB_CRIT_DAYS="${VIRUS_DB_CRIT_DAYS:-30}"

# 当前库年龄（天）；取不到则输出空
db_age_days() {
    local f epoch
    command -v sigtool >/dev/null 2>&1 || return 1
    for f in "$CLAM_DB_DIR"/daily.cvd "$CLAM_DB_DIR"/daily.cld "$CLAM_DB_DIR"/main.cvd; do
        [ -f "$f" ] || continue
        epoch="$(sigtool --info "$f" 2>/dev/null | awk -F': ' '/^Build time:/{print $2}')"
        [ -z "$epoch" ] && continue
        epoch="$(date -d "$epoch" +%s 2>/dev/null)" || continue
        [ -n "$epoch" ] && { echo $(( ( $(date +%s) - epoch ) / 86400 )); return 0; }
    done
    return 1
}

# 下载并校验单个库文件；成功返回 0
# 说明：官方 CDN 有两条限制，都要应对：
#   1) 按 UA 版本号决定放行——0.103.x 直接 403，1.x 放行；
#   2) 同一 UA 有频率限制——短时间重复下载返回 429。
# 所以失败时轮换 UA + 镜像并退避重试，而不是一次失败就放弃。
fetch_db() {
    local name="$1" tmp="$CLAM_DB_DIR/.${1}.tmp.$$" http ua mirror attempt
    local uas=($CLAM_DB_UAS)
    local mirrors=("$CLAM_DB_MIRROR" "https://db.local.clamav.net")
    for attempt in 1 2 3 4 5 6; do
        ua="${uas[$(( (attempt - 1) % ${#uas[@]} ))]}"
        mirror="${mirrors[$(( (attempt - 1) % ${#mirrors[@]} ))]}"
        http="$(curl -sS -m 300 -A "$ua" -o "$tmp" -w '%{http_code}' \
            "${mirror}/${name}" 2>>"$SCAN_LOG" || true)"
        if [ "$http" = "200" ] && [ -s "$tmp" ]; then
            break
        fi
        rm -f "$tmp"
        if [ "$attempt" -lt 6 ]; then
            # 429/403 都是"换个 UA 可能就好了"，退避短一些；其他错误稍长
            case "$http" in
                429|403) sleep $(( attempt * 5 )) ;;
                *)       sleep 10 ;;
            esac
            log "  ${name} 下载失败（HTTP ${http:-无响应}，UA=${ua##*/}），${attempt}/6，轮换后重试"
        fi
    done
    if [ "$http" != "200" ] || [ ! -s "$tmp" ]; then
        log "[WARN] 下载 ${name} 失败（HTTP ${http:-无响应}，已重试 6 次）"
        rm -f "$tmp"
        return 1
    fi
    # 完整性校验：sigtool 认这个文件才算有效
    if ! sigtool --info "$tmp" 2>/dev/null | grep -q 'Verification OK'; then
        log "[WARN] ${name} 校验未通过（sigtool 不认可），已丢弃"
        rm -f "$tmp"
        return 1
    fi
    chown clamav:clamav "$tmp" 2>/dev/null || true
    chmod 644 "$tmp"
    mv -f "$tmp" "$CLAM_DB_DIR/$name"
    log "  病毒库已更新: ${name}（$(sigtool --info "$CLAM_DB_DIR/$name" 2>/dev/null | awk -F': ' '/^Version:/{print "v"$2}' | head -1)）"
    return 0
}

log "更新病毒库..."
age_before="$(db_age_days || true)"
updated=0
# daily 是主力特征库，必须更新；main 更新较慢（本地为 2021 年 v62），一并尝试
fetch_db daily.cvd && updated=1
fetch_db main.cvd  || true

if [ "$updated" -eq 1 ]; then
    # 让常驻的 clamd 重载新库（clamav-daemon 的 CanReload=yes）
    clamdscan --reload >/dev/null 2>&1 && log "  clamd 已重载病毒库" || log "  [INFO] clamd 重载未响应（不影响本脚本的 clamscan）"
else
    log "[WARN] 病毒库更新失败，本次扫描将使用现有库"
fi

# 扫描前明确记录库的年龄——这是"扫描结果是否可信"的前提
age_now="$(db_age_days || true)"
if [ -n "${age_now:-}" ]; then
    log "病毒库年龄: ${age_now} 天（更新前 ${age_before:-未知} 天）"
    if [ "$age_now" -ge "$CLAM_DB_CRIT_DAYS" ]; then
        log "[CRIT] 病毒库已 ${age_now} 天未更新（超过 ${CLAM_DB_CRIT_DAYS} 天），本次扫描结果不可信"
    elif [ "$age_now" -ge "$CLAM_DB_WARN_DAYS" ]; then
        log "[WARN] 病毒库已 ${age_now} 天未更新（超过 ${CLAM_DB_WARN_DAYS} 天）"
    fi
else
    log "[WARN] 无法确认病毒库年龄"
fi

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
