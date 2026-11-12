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

# 数据库表数（BASE TABLE），失败时输出空
db_table_count() {
    local db="$1" n
    if command -v mysql >/dev/null 2>&1; then
        if [ -f "${MYSQL_CNF:-/root/.my.cnf}" ]; then
            n="$(mysql --defaults-extra-file="${MYSQL_CNF}" -Nse \
                "select count(*) from information_schema.tables where table_schema='${db}' and table_type='BASE TABLE'" 2>/dev/null)"
        else
            n="$(mysql -Nse \
                "select count(*) from information_schema.tables where table_schema='${db}' and table_type='BASE TABLE'" 2>/dev/null)"
        fi
        printf '%s' "${n:-}"
    fi
}

# 校验 dump 完整性：返回 0 通过；失败时把原因写到 stdout
verify_dump() {
    local file="$1" db="$2"
    local dump_tables live_tables

    # 1) 压缩流 CRC
    if ! gzip -t "$file" 2>/dev/null; then
        printf 'gzip 校验失败（压缩流损坏）'
        return 1
    fi

    # 2) mysqldump 正常结束时会写 "-- Dump completed on ..."；缺失=中途被中断
    if ! gzip -dc "$file" 2>/dev/null | tail -c 4000 | grep -q 'Dump completed'; then
        printf '缺少 "Dump completed" 结尾标记（dump 被中断或截断）'
        return 1
    fi

    # 3) 表数：dump 内的 CREATE TABLE 不应少于当前库的 BASE TABLE
    dump_tables="$(gzip -dc "$file" 2>/dev/null | grep -c '^CREATE TABLE' || true)"
    live_tables="$(db_table_count "$db")"
    if [ -n "$live_tables" ] && [ "${dump_tables:-0}" -lt "$live_tables" ]; then
        printf '表数不符（dump=%s / 库=%s）' "${dump_tables:-0}" "$live_tables"
        return 1
    fi

    printf 'dump_tables=%s live_tables=%s' "${dump_tables:-0}" "${live_tables:-?}"
    return 0
}

backup_db() {
    local db="$1"
    local filename target err_file rcs size raw
    filename="$(date +%Y%m%d)_${db}.sql.gz"
    target="${SQL_DIR}/${filename}"
    err_file="$(mktemp)"

    log "  备份数据库: ${db}"

    # 关键：必须拿到 mysqldump 自己的退出码。
    # 直接写 `if mysqldump ... | gzip > f` 时，if 判定的是 gzip 的退出码，
    # mysqldump 中途失败会被静默吞掉（产出"能通过 gzip -t 的残缺备份"）。
    mysqldump_cmd --single-transaction --quick --routines "$db" 2>"$err_file" | gzip > "$target"
    rcs=("${PIPESTATUS[@]}")
    local rc_dump="${rcs[0]:-1}" rc_gzip="${rcs[1]:-1}"

    if [ "$rc_dump" -ne 0 ] || [ "$rc_gzip" -ne 0 ]; then
        log "    [ERROR] 备份失败: ${db} (mysqldump=${rc_dump}, gzip=${rc_gzip})"
        [ -s "$err_file" ] && sed -n '1,3p' "$err_file" | sed 's/^/      /' >> "$LOG_FILE"
        rm -f "$target" "$err_file"
        return 1
    fi

    local verify_msg
    if ! verify_msg="$(verify_dump "$target" "$db")"; then
        log "    [ERROR] 备份不完整: ${filename} — ${verify_msg}"
        rm -f "$target" "$err_file"
        return 1
    fi

    size="$(du -h "$target" | awk '{print $1}')"
    raw="$(gzip -l "$target" 2>/dev/null | tail -1 | awk '{print $2}')"
    log "    完成: ${filename} (${size}${raw:+, 原始 $(awk -v b="$raw" 'BEGIN{printf "%.1fMB", b/1048576}')}, ${verify_msg})"

    if [ "${QINIU_ENABLED}" = "true" ]; then
        upload_qiniu "$QINIU_BUCKET" "sql/${filename}" "$target" || true
    fi
    rm -f "$err_file"
    return 0
}

backup_files() {
    local dir="$1"
    local dir_name filename target size
    dir_name="$(basename "$dir")"
    filename="$(date +%Y%m%d)_${dir_name}.tar.gz"
    target="${FILE_DIR}/${filename}"

    log "  备份文件: ${dir}"
    if tar -zcf "$target" -C "$(dirname "$dir")" "$dir_name" 2>/dev/null; then
        # 完整性：tar 退出码可靠，再校验 gzip 流 CRC（可发现截断/磁盘满）
        if ! gzip -t "$target" 2>/dev/null; then
            log "    [ERROR] 备份文件损坏: ${filename}（gzip 校验失败）"
            rm -f "$target"
            return 1
        fi
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
