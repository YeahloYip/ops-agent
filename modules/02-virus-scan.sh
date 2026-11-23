#!/bin/bash
# 02-病毒扫描结果检查（读取当日 ClamAV 日志 + 校验病毒库年龄）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

LOG_DATE="$(today)"
SCAN_LOG="${OPS_ROOT}/logs/${LOG_DATE}-clamav.log"

# ---------- 病毒库年龄检查 ----------
# 动机：扫描"通过"只说明扫过的文件没命中，若病毒库陈旧，等于拿旧名单查新病毒，
#       属于"假安心"。freshclam 失败常被忽略（本机即因 0.103.9 被 CDN 403 拒绝，
#       且 scripts/clamav-scan.sh 旧版把 stderr 丢弃，连续失败 4 周无人发现）。
#       因此必须独立校验库年龄，不能只看扫描日志。
VIRUS_DB_WARN_DAYS="${VIRUS_DB_WARN_DAYS:-7}"
VIRUS_DB_CRIT_DAYS="${VIRUS_DB_CRIT_DAYS:-30}"

# 取病毒库构建时间 → epoch
# 注意：daily.cvd 与 daily.cld 可能同时存在（.cvd 是下载的新格式，.cld 是本地压缩的旧文件）。
# ClamAV 实际会选版本号更高的那个，所以这里也取"最新的"而非"最先找到的"，
# 否则残留的旧 .cld 会让年龄检查永远报旧——那正是本机踩过的坑。
virus_db_epoch() {
    local f build_epoch epoch best=0
    command -v sigtool >/dev/null 2>&1 || return 1
    for f in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld /var/lib/clamav/main.cvd; do
        [ -f "$f" ] || continue
        build_epoch="$(sigtool --info "$f" 2>/dev/null | awk -F': ' '/^Build time:/{print $2}')"
        [ -z "${build_epoch:-}" ] && continue
        epoch="$(date -d "$build_epoch" +%s 2>/dev/null)" || continue
        [ -n "${epoch:-}" ] && [ "$epoch" -gt "$best" ] && best="$epoch"
    done
    [ "$best" -gt 0 ] && { printf '%s' "$best"; return 0; }
    return 1
}

# 取"最新那个库"的版本号（与 virus_db_epoch 保持同一口径）
virus_db_version() {
    local f v best_epoch=0 best_ver=""
    command -v sigtool >/dev/null 2>&1 || return 1
    for f in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld; do
        [ -f "$f" ] || continue
        v="$(sigtool --info "$f" 2>/dev/null | awk -F': ' '/^Version:/{print $2; exit}')"
        [ -z "${v:-}" ] && continue
        local e
        e="$(sigtool --info "$f" 2>/dev/null | awk -F': ' '/^Build time:/{print $2}' | xargs -r -I{} date -d "{}" +%s 2>/dev/null)"
        if [ -n "${e:-}" ] && [ "$e" -gt "$best_epoch" ]; then
            best_epoch="$e"; best_ver="$v"
        fi
    done
    printf '%s' "$best_ver"
}

db_epoch="$(virus_db_epoch || true)"
if [ -n "${db_epoch:-}" ]; then
    db_age_d=$(( ( $(now_epoch) - db_epoch ) / 86400 ))
    [ "$db_age_d" -lt 0 ] && db_age_d=0
    db_ver="$(virus_db_version || true)"
    db_detail="病毒库版本 ${db_ver:-未知}，构建于 $(date -d "@${db_epoch}" '+%Y-%m-%d')（${db_age_d} 天前）"
    if [ "$db_age_d" -ge "$VIRUS_DB_CRIT_DAYS" ]; then
        finding CRIT "virus:db-stale" "病毒库已 ${db_age_d} 天未更新（超过 ${VIRUS_DB_CRIT_DAYS} 天）" \
            "${db_detail}" \
            "freshclam 大概率已失败：查 /var/log/clamav/freshclam.log；若 ClamAV 版本过旧被 CDN 拒绝需升级"
    elif [ "$db_age_d" -ge "$VIRUS_DB_WARN_DAYS" ]; then
        finding WARN "virus:db-old" "病毒库已 ${db_age_d} 天未更新（超过 ${VIRUS_DB_WARN_DAYS} 天）" \
            "${db_detail}" \
            "检查 freshclam 是否成功：freshclam --verbose；确认网络与 ClamAV 版本是否受支持"
    else
        finding INFO "virus:db" "病毒库较新（${db_age_d} 天前）" "${db_detail}" ""
    fi
else
    finding WARN "virus:db-unknown" "无法确认病毒库年龄" \
        "sigtool 不可用或 /var/lib/clamav 下无 daily/main 库文件" \
        "确认 clamav 已安装：command -v sigtool；ls -la /var/lib/clamav/"
fi

# ---------- 当日扫描结果 ----------
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
