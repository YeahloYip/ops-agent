#!/bin/bash
# 统一备份脚本（改进版：口令走 ~/.my.cnf，不再出现在命令行/ps 中；上传后回读校验）
# 用法: backup.sh [daily|weekly|monthly|file|all]

set -u
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
if [ ! -f "${OPS_ROOT}/config/backup.conf" ]; then
    echo "缺少 ${OPS_ROOT}/config/backup.conf，请先：" >&2
    echo "  cp ${OPS_ROOT}/config/backup.conf.example ${OPS_ROOT}/config/backup.conf" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${OPS_ROOT}/config/backup.conf"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

LOG_DATE="$(date "+%Y-%m-%d")"
LOG_FILE="${OPS_ROOT}/logs/${LOG_DATE}-backup.log"
SQL_DIR="${BACKUP_DIR}/sql"
FILE_DIR="${BACKUP_DIR}/file"

mkdir -p "$SQL_DIR" "$FILE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

mysqldump_cmd() {
    if [ -f "${MYSQL_CNF:-/root/.my.cnf}" ]; then
        mysqldump --defaults-extra-file="${MYSQL_CNF}" "$@"
    else
        mysqldump "$@"
    fi
}

# 上传并回读校验
upload_qiniu() {
    local bucket="$1" key="$2" file="$3"
    local stat_out
    [ -x "${QINIU_QSHELL:-}" ] || { log "    [WARN] qshell 不存在，跳过上传"; return 1; }

    if ! timeout 300 "$QINIU_QSHELL" fput "$bucket" "$key" "$file" --overwrite --silent >/dev/null 2>&1; then
        # 兼容旧版 qshell（不支持 --silent）
        timeout 300 "$QINIU_QSHELL" fput "$bucket" "$key" "$file" --overwrite >/dev/null 2>&1 || {
            log "    [WARN] 上传失败: ${key}"; return 1
        }
    fi

    stat_out="$(timeout 40 "$QINIU_QSHELL" stat "$bucket" "$key" 2>/dev/null || true)"
    if printf '%s' "$stat_out" | grep -q 'Fsize'; then
        log "    上传成功并已回读校验: ${key}"
        return 0
    fi
    log "    [WARN] 上传后回读校验失败: ${key}"
    return 1
}

backup_db() {
    local db="$1"
    local filename
    filename="$(date +%Y%m%d)_${db}.sql.gz"
    local target="${SQL_DIR}/${filename}"

    log "  备份数据库: ${db}"
    if mysqldump_cmd --single-transaction --quick --routines "$db" 2>/dev/null | gzip > "$target"; then
        if ! gzip -t "$target" 2>/dev/null; then
            log "    [ERROR] 备份文件损坏: ${filename}"
            rm -f "$target"
            return 1
        fi
        local size
        size="$(du -h "$target" | awk '{print $1}')"
        log "    完成: ${filename} (${size})"
        if [ "${QINIU_ENABLED}" = "true" ]; then
            upload_qiniu "$QINIU_BUCKET" "sql/${filename}" "$target" || true
        fi
        return 0
    else
        log "    [ERROR] 备份失败: ${db}"
        rm -f "$target"
        return 1
    fi
}

backup_files() {
    local dir="$1"
    local dir_name filename target size
    dir_name="$(basename "$dir")"
    filename="$(date +%Y%m%d)_${dir_name}.tar.gz"
    target="${FILE_DIR}/${filename}"

    log "  备份文件: ${dir}"
    if tar -zcf "$target" -C "$(dirname "$dir")" "$dir_name" 2>/dev/null; then
        size="$(du -h "$target" | awk '{print $1}')"
        log "    完成: ${filename} (${size})"
        if [ "${QINIU_ENABLED}" = "true" ]; then
            upload_qiniu "$QINIU_BUCKET" "file/${filename}" "$target" || true
        fi
        return 0
    else
        log "    [ERROR] 备份失败: ${dir}"
        rm -f "$target"
        return 1
    fi
}

cleanup_old() {
    local dir="$1" days="$2" count
    count="$(find "$dir" -name "*.gz" -mtime "+${days}" 2>/dev/null | wc -l)"
    if [ "${count:-0}" -gt 0 ]; then
        find "$dir" -name "*.gz" -mtime "+${days}" -delete 2>/dev/null
        log "  清理 ${count} 个超过 ${days} 天的旧备份"
    fi
}

MODE="${1:-all}"
ERRORS=0
log "===== 开始备份 (模式: ${MODE}) ====="

case "$MODE" in
    daily)   for db in $DAILY_DBS;   do backup_db "$db" || ERRORS=$((ERRORS+1)); done ;;
    weekly)  for db in $WEEKLY_DBS;  do backup_db "$db" || ERRORS=$((ERRORS+1)); done ;;
    monthly) for db in $MONTHLY_DBS; do backup_db "$db" || ERRORS=$((ERRORS+1)); done ;;
    file)    for dir in $FILE_BACKUP_DIRS; do backup_files "${WEBROOT}/${dir}" || ERRORS=$((ERRORS+1)); done ;;
    all)
        for db in $DAILY_DBS $WEEKLY_DBS $MONTHLY_DBS; do backup_db "$db" || ERRORS=$((ERRORS+1)); done
        for dir in $FILE_BACKUP_DIRS; do backup_files "${WEBROOT}/${dir}" || ERRORS=$((ERRORS+1)); done
        ;;
    *) echo "用法: $0 [daily|weekly|monthly|file|all]"; exit 1 ;;
esac

cleanup_old "$SQL_DIR" "$LOCAL_RETAIN_DAYS"
cleanup_old "$FILE_DIR" "$LOCAL_RETAIN_DAYS"

log "===== 备份完成 (错误: ${ERRORS}) ====="
exit 0
