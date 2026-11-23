#!/bin/bash
# 更新 ClamAV / rkhunter 数据库
# 关键修复：rkhunter --propupd 不再每天执行（否则每天把篡改写进基线，完整性检查失效）
#         改为每周一次（PROPUPDATE_INTERVAL_DAYS），或手动 `update-databases.sh --propupd`
set -u
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

LOG_FILE="${OPS_ROOT}/logs/$(today)-update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

PROPUPDATE_DAYS="${PROPUPDATE_INTERVAL_DAYS:-7}"
FORCE_PROPUPDATE=false
[ "${1:-}" = "--propupd" ] && FORCE_PROPUPDATE=true

log "===== 开始更新数据库 ====="

# ---- ClamAV ----
if command -v freshclam >/dev/null 2>&1; then
    log "更新 ClamAV 病毒库..."
    result="$(freshclam 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        log "[OK] ClamAV 病毒库更新成功"
    elif printf '%s' "$result" | grep -q "cool-down"; then
        log "[INFO] ClamAV 仍在冷却期，跳过"
    else
        log "[WARN] ClamAV 更新失败: $(printf '%s' "$result" | tail -3 | tr '\n' ' ')"
    fi
else
    log "[WARN] freshclam 未安装"
fi

# ---- rkhunter 特征库 ----
if command -v rkhunter >/dev/null 2>&1; then
    log "更新 rkhunter 特征库..."
    result="$(rkhunter --update 2>&1)"
    if printf '%s' "$result" | grep -q "Update failed"; then
        log "[WARN] rkhunter 部分更新失败"
    else
        log "[OK] rkhunter 特征库更新成功"
    fi

    # 属性基线：仅每周或显式请求时刷新
    last_propupd="$(state_kv_get rkhunter:propupd_epoch)"
    last_propupd="${last_propupd:-0}"
    now="$(now_epoch)"
    if [ "$FORCE_PROPUPDATE" = true ] || [ $(( now - last_propupd )) -ge $(( PROPUPDATE_DAYS * 86400 )) ]; then
        rkhunter --propupd >/dev/null 2>&1
        state_kv_set rkhunter:propupd_epoch "$now"
        log "[OK] rkhunter 属性基线已刷新（每 ${PROPUPDATE_DAYS} 天一次，或手动 --propupd）"
    else
        log "[INFO] rkhunter 属性基线保持不动（距上次 $(( (now - last_propupd) / 86400 )) 天）"
    fi
else
    log "[WARN] rkhunter 未安装"
fi

log "===== 数据库更新完成 ====="
