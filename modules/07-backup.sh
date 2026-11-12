#!/bin/bash
# 07-备份有效性检查（完整性 / 新鲜度 / 体积趋势 / 覆盖缺口 / 云端回读）
#
# 判定原则（避免"只看体积"的弱信号）：
#   1. 完整性优先：gzip CRC、mysqldump 的 "Dump completed" 结尾标记、表数是否齐全
#      —— 这三项任一不满足即 CRIT，不依赖体积。
#   2. 体积只是趋势信号：改用「未压缩字节数」消除压缩率漂移；
#      阈值按同库历史变异系数（CV）自适应，避免小库/高波动库误报。
#   3. 所有时间判断统一用文件名日期（YYYYMMDD），不再混用 mtime。
#   4. 额外检查"库/站点是否根本没被纳入备份清单"——这是最容易漏的缺口。
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config/backup.conf"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

SQL_DIR="${BACKUP_DIR}/sql"
FILE_DIR="${BACKUP_DIR}/file"
TODAY_LOG="${OPS_ROOT}/logs/$(today)-backup.log"
ALL_DBS="${DAILY_DBS:-} ${WEEKLY_DBS:-} ${MONTHLY_DBS:-}"

# ---------- 工具函数 ----------

# 文件名日期 → epoch（YYYYMMDD_<name>.ext）；解析失败回退 mtime
file_date_epoch() {
    local f="$1" base d epoch
    base="$(basename "$f")"
    d="${base%%_*}"
    if printf '%s' "$d" | grep -qE '^[0-9]{8}$'; then
        epoch="$(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%s 2>/dev/null)"
        if [ -n "${epoch:-}" ]; then printf '%s' "$epoch"; return 0; fi
    fi
    stat -c %Y "$f" 2>/dev/null || echo 0
}

# 未压缩字节数（gzip 头里记录的原始长度，读取很快）
gzip_raw_size() {
    gzip -l "$1" 2>/dev/null | tail -1 | awk '{print $2}'
}

dump_tables() { gzip -dc "$1" 2>/dev/null | grep -c '^CREATE TABLE' || true; }

dump_complete() { gzip -dc "$1" 2>/dev/null | tail -c 4000 | grep -q 'Dump completed'; }

live_table_count() {
    local db="$1" n
    command -v mysql >/dev/null 2>&1 || return 0
    if [ -f "${MYSQL_CNF:-/root/.my.cnf}" ]; then
        n="$(mysql --defaults-extra-file="${MYSQL_CNF}" -Nse \
            "select count(*) from information_schema.tables where table_schema='${db}' and table_type='BASE TABLE'" 2>/dev/null)"
    else
        n="$(mysql -Nse \
            "select count(*) from information_schema.tables where table_schema='${db}' and table_type='BASE TABLE'" 2>/dev/null)"
    fi
    printf '%s' "${n:-}"
}

live_dbs() {
    command -v mysql >/dev/null 2>&1 || return 0
    if [ -f "${MYSQL_CNF:-/root/.my.cnf}" ]; then
        mysql --defaults-extra-file="${MYSQL_CNF}" -Nse \
            "select schema_name from information_schema.schemata
             where schema_name not in ('mysql','information_schema','performance_schema','sys')" 2>/dev/null
    else
        mysql -Nse \
            "select schema_name from information_schema.schemata
             where schema_name not in ('mysql','information_schema','performance_schema','sys')" 2>/dev/null
    fi
}

# 某库的备份文件（按文件名日期倒序）
db_files() { ls -1 "${SQL_DIR}"/*_"$1".sql.gz 2>/dev/null | sort -r; }

# ---------- 1. 今日备份日志 ----------
if [ -f "$TODAY_LOG" ]; then
    if ! grep -q "备份完成" "$TODAY_LOG"; then
        finding WARN "backup:incomplete" "今日数据库备份未完成" \
            "$(tail -3 "$TODAY_LOG" | tr '\n' ' ')" "检查 scripts/backup.sh 与 MySQL 连接"
    else
        errors=$(grep -oE '错误: [0-9]+' "$TODAY_LOG" | tail -1 | grep -oE '[0-9]+' || echo 0)
        if [ "${errors:-0}" -gt 0 ]; then
            finding WARN "backup:errors" "今日备份有 ${errors} 个错误" \
                "$(grep '\[ERROR\]' "$TODAY_LOG" | tail -2 | tr '\n' ';')" "查看 ${TODAY_LOG}"
        fi
        if grep -q "上传失败" "$TODAY_LOG"; then
            finding WARN "backup:cloud" "备份上传七牛云失败" \
                "$(grep -B2 '上传失败' "$TODAY_LOG" | tail -3 | tr '\n' ';')" \
                "检查 qshell 授权与网络，手动重跑 backup.sh daily"
        fi
    fi
else
    finding WARN "backup:missing-log" "今日无备份日志" "缺少 ${TODAY_LOG}" "检查 cron：5 0 * * * backup.sh daily"
fi

# ---------- 2. 逐库检查：完整性 / 新鲜度 / 体积趋势 ----------
MAX_AGE_H="${BACKUP_SQL_MAX_AGE_HOURS:-26}"
WEEKLY_MAX_AGE_H="${BACKUP_WEEKLY_MAX_AGE_HOURS:-192}"
MONTHLY_MAX_AGE_H="${BACKUP_MONTHLY_MAX_AGE_HOURS:-840}"

# 某库的新鲜度上限：按其所在清单（日/周/月）决定，避免把"周备份"误判为过期
db_max_age_hours() {
    local db="$1"
    case " ${DAILY_DBS:-} " in *" ${db} "*) printf '%s' "$MAX_AGE_H"; return 0 ;; esac
    case " ${WEEKLY_DBS:-} " in *" ${db} "*) printf '%s' "$WEEKLY_MAX_AGE_H"; return 0 ;; esac
    case " ${MONTHLY_DBS:-} " in *" ${db} "*) printf '%s' "$MONTHLY_MAX_AGE_H"; return 0 ;; esac
    printf '%s' "$MAX_AGE_H"
}
DROP_BASE="${BACKUP_SIZE_DROP_PERCENT:-50}"
CV_FACTOR="${BACKUP_SIZE_CV_FACTOR:-3}"
MIN_SAMPLES="${BACKUP_SIZE_MIN_SAMPLES:-5}"
now="$(now_epoch)"

check_db() {
    local db="$1" files newest prev newest_epoch age_h raw_now dump_n live_n prev_dump_n max_age
    files="$(db_files "$db")"

    if [ -z "$files" ]; then
        finding CRIT "backup:missing:${db}" "数据库 ${db} 没有任何备份文件" \
            "目录 ${SQL_DIR} 中找不到 *_${db}.sql.gz" \
            "检查 config/backup.conf 是否包含该库，以及 logs/$(today)-backup.log"
        return 0
    fi

    newest="$(printf '%s\n' "$files" | head -1)"
    prev="$(printf '%s\n' "$files" | sed -n '2p')"

    # --- 完整性 ---
    local bad=""
    if ! gzip -t "$newest" 2>/dev/null; then
        bad="gzip 校验失败（压缩流损坏）"
    elif ! dump_complete "$newest"; then
        bad="缺少 Dump completed 结尾标记（dump 被截断）"
    else
        dump_n="$(dump_tables "$newest")"
        live_n="$(live_table_count "$db")"
        if [ "${dump_n:-0}" -eq 0 ]; then
            bad="dump 中没有任何 CREATE TABLE"
        elif [ -n "$live_n" ] && [ "${dump_n:-0}" -lt "$live_n" ]; then
            bad="表数不符（dump=${dump_n} / 库=${live_n}）"
        fi
    fi
    if [ -n "$bad" ]; then
        finding CRIT "backup:integrity:${db}" "备份文件不完整（${db}）" \
            "$(basename "$newest")：${bad}" \
            "立即重跑：bash scripts/backup.sh daily；并查看备份日志中的 mysqldump 错误"
        return 0
    fi

    # --- 表数回归（schema 变少说明可能只备份了部分对象）---
    if [ -n "${prev:-}" ]; then
        prev_dump_n="$(dump_tables "$prev")"
        if [ -n "${prev_dump_n:-}" ] && [ "${prev_dump_n:-0}" -gt 0 ] && [ "${dump_n:-0}" -lt "$prev_dump_n" ]; then
            finding WARN "backup:tables-drop:${db}" "备份表数比上次减少（${db}）" \
                "$(basename "$prev") ${prev_dump_n} 张 → $(basename "$newest") ${dump_n} 张" \
                "确认是否删除过表/视图；若未改动需检查 dump 是否被截断"
        fi
    fi

    # --- 新鲜度（按文件名日期，避免 mtime 被复制/恢复扰动）---
    newest_epoch="$(file_date_epoch "$newest")"
    age_h=$(( ( now - ${newest_epoch:-0} ) / 3600 ))
    [ "$age_h" -lt 0 ] && age_h=0
    max_age="$(db_max_age_hours "$db")"
    if [ "$age_h" -gt "$max_age" ]; then
        finding CRIT "backup:stale:${db}" "数据库 ${db} 的备份已 ${age_h} 小时未更新" \
            "$(basename "$newest")" \
            "检查该库的备份任务是否失败（logs/$(today)-backup.log）"
        return 0
    fi

    # --- 体积趋势（未压缩字节；阈值按同库历史 CV 自适应）---
    raw_now="$(gzip_raw_size "$newest")"
    local hist="" f raw
    for f in $(printf '%s\n' "$files" | sed -n '2,8p'); do
        raw="$(gzip_raw_size "$f")"
        [ -n "${raw:-}" ] && hist="$hist $raw"
    done
    local n hist_stats median cv allowed drop_pct detail
    n="$(printf '%s\n' $hist | grep -c . || true)"
    detail="$(basename "$newest") 原始 $(awk -v b="${raw_now:-0}" 'BEGIN{printf "%.1fMB", b/1048576}')"

    if [ "${n:-0}" -ge "$MIN_SAMPLES" ] && [ "${raw_now:-0}" -gt 0 ]; then
        hist_stats="$(printf '%s\n' $hist | sort -n | awk -v cvf="$CV_FACTOR" '
            {a[NR]=$1; s+=$1}
            END{
                if(NR<2){print "0 0"; exit}
                m=s/NR
                for(i=1;i<=NR;i++){d=a[i]-m; ss+=d*d}
                sd=sqrt(ss/NR)
                med=a[int((NR+1)/2)]
                cv=(m>0)?sd/m:0
                allowed=cvf*cv*100
                if(allowed<'"$DROP_BASE"') allowed='"$DROP_BASE"'
                if(allowed>90) allowed=90
                printf "%.0f %.0f", med, allowed
            }')"
        median="$(printf '%s' "$hist_stats" | awk '{print $1}')"
        allowed="$(printf '%s' "$hist_stats" | awk '{print $2}')"
        if [ "${median:-0}" -gt 0 ]; then
            drop_pct=$(( (median - raw_now) * 100 / median ))
            if [ "$drop_pct" -gt "${allowed:-$DROP_BASE}" ]; then
                finding WARN "backup:size:${db}" "备份体积异常偏小（${db}）" \
                    "${detail}，同库近 ${n} 份中位数 $(awk -v b="$median" 'BEGIN{printf "%.1fMB", b/1048576}')（下降 ${drop_pct}%，阈值 ${allowed}%）" \
                    "确认该库是否被清空/迁移；对照备份日志中的 mysqldump 错误"
                return 0
            fi
            detail="${detail}，同库中位数 $(awk -v b="$median" 'BEGIN{printf "%.1fMB", b/1048576}')"
        fi
    fi

    finding INFO "backup:ok:${db}" "备份正常（${db}，${age_h} 小时前，${dump_n} 张表）" "${detail}" ""
}

_seen_dbs=" "
for _db in ${DAILY_DBS:-} ${WEEKLY_DBS:-} ${MONTHLY_DBS:-}; do
    case "$_seen_dbs" in *" ${_db} "*) continue ;; esac
    _seen_dbs="${_seen_dbs}${_db} "
    check_db "$_db"
done

# ---------- 3. 覆盖缺口：库/站点是否根本没被备份 ----------
if [ "${BACKUP_COVERAGE_CHECK:-true}" = "true" ]; then
    for _db in $(live_dbs | sort -u); do
        [ -z "$_db" ] && continue
        case " ${ALL_DBS} " in
            *" ${_db} "*) continue ;;
        esac
        case " ${BACKUP_IGNORED_DBS:-} " in
            *" ${_db} "*) finding INFO "backup:ignored-db:${_db}" "数据库 ${_db} 按配置不备份（BACKUP_IGNORED_DBS）" "" "" ; continue ;;
        esac
        finding WARN "backup:uncovered-db:${_db}" "数据库 ${_db} 未纳入备份清单" \
            "存在于 MySQL，但不在 DAILY_DBS/WEEKLY_DBS/MONTHLY_DBS" \
            "需要备份则加入 config/backup.conf；确认不需要则加入 BACKUP_IGNORED_DBS"
    done

    for _dir in "${WEBROOT}"/*/; do
        [ -d "$_dir" ] || continue
        _name="$(basename "$_dir")"
        case "$_name" in backup|default) continue ;; esac
        case " ${FILE_BACKUP_DIRS:-} " in
            *" ${_name} "*) continue ;;
        esac
        case " ${BACKUP_IGNORED_DIRS:-} " in
            *" ${_name} "*) finding INFO "backup:ignored-dir:${_name}" "站点目录 ${_name} 按配置不备份（BACKUP_IGNORED_DIRS）" "" "" ; continue ;;
        esac
        finding WARN "backup:uncovered-dir:${_name}" "站点目录 ${_name} 未纳入文件备份" \
            "存在于 ${WEBROOT}，但不在 FILE_BACKUP_DIRS" \
            "需要备份则加入 FILE_BACKUP_DIRS；确认不需要则加入 BACKUP_IGNORED_DIRS"
    done
fi

# ---------- 4. 云端回读（七牛 Kodo，仅 QINIU_ENABLED=true 时检查）----------
# qshell 安装/授权见 config/backup.conf.example 或官方文档：
# https://developer.qiniu.com/kodo/1302/qshell
if [ "${QINIU_ENABLED:-false}" != "true" ]; then
    finding INFO "backup:cloud-off" "对象存储备份未启用（QINIU_ENABLED=false）" "" ""
elif [ "${QINIU_VERIFY:-true}" = "true" ] && [ -x "${QINIU_QSHELL:-}" ]; then
    cloud_db="$(printf '%s' "${DAILY_DBS:-}" | awk '{print $1}')"
    [ -z "$cloud_db" ] && cloud_db="app_db"
    key="sql/$(date +%Y%m%d)_${cloud_db}.sql.gz"
    out="$(timeout 40 "$QINIU_QSHELL" stat "${QINIU_BUCKET:-backup}" "$key" 2>&1 || true)"
    if printf '%s' "$out" | grep -q 'Fsize'; then
        finding INFO "backup:cloud" "云端备份可回读" "$key $(printf '%s' "$out" | grep 'Fsize' | head -1)" ""
    else
        finding WARN "backup:cloud-missing" "云端未找到今日备份" "$key：$(printf '%s' "$out" | head -2 | tr '\n' ' ')" \
            "检查 qshell fput 结果与七牛额度"
    fi
elif [ "${QINIU_VERIFY:-true}" = "true" ]; then
    finding WARN "backup:cloud-tool" "qshell 不可执行，跳过云端校验" "${QINIU_QSHELL:-未配置}" \
        "按 https://developer.qiniu.com/kodo/1302/qshell 安装 qshell，或设 QINIU_ENABLED=false 关闭"
fi

# ---------- 5. 文件备份（月度）----------
newest_file="$(ls -t "${FILE_DIR}"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$newest_file" ]; then
    file_age_d=$(( ( now - $(file_date_epoch "$newest_file") ) / 86400 ))
    [ "$file_age_d" -lt 0 ] && file_age_d=0
    finding INFO "backup:file" "最新文件备份 ${file_age_d} 天前" "$(basename "$newest_file")" ""
    if [ "$file_age_d" -gt 40 ]; then
        finding WARN "backup:file-stale" "文件备份已 ${file_age_d} 天未更新" \
            "$(basename "$newest_file")" "检查每月 1 日的 cron：backup.sh file"
    fi
fi
