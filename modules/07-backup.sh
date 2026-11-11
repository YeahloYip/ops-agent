#!/bin/bash
# 07-备份有效性检查（本地新鲜度 / 完整性 / 大小异常 / 云端回读）
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

# ---- 今日备份日志 ----
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
                "$(grep -B2 '上传失败' "$TODAY_LOG" | tail -3 | tr '\n' ';')" "检查 qshell 授权与网络，手动重跑 backup.sh daily"
        fi
    fi
else
    finding WARN "backup:missing-log" "今日无备份日志" "缺少 ${TODAY_LOG}" "检查 cron：5 0 * * * backup.sh daily"
fi

# ---- 本地备份新鲜度 ----
newest_sql="$(ls -t "${SQL_DIR}"/*.sql.gz 2>/dev/null | head -1)"
if [ -z "$newest_sql" ]; then
    finding CRIT "backup:no-files" "本地没有任何 SQL 备份" "目录 ${SQL_DIR} 为空" "立即手动执行 scripts/backup.sh daily"
else
    age_h=$(( ( $(now_epoch) - $(stat -c %Y "$newest_sql") ) / 3600 ))
    if [ "$age_h" -gt "${BACKUP_SQL_MAX_AGE_HOURS:-26}" ]; then
        finding CRIT "backup:stale" "最新 SQL 备份已 ${age_h} 小时未更新" \
            "$(basename "$newest_sql")" "检查备份 cron 与磁盘空间；手动重跑 backup.sh daily"
    else
        finding INFO "backup:fresh" "最新 SQL 备份 ${age_h} 小时前" "$(basename "$newest_sql")" ""
    fi

    # 完整性
    if ! gzip -t "$newest_sql" 2>/dev/null; then
        finding CRIT "backup:corrupt" "最新备份文件损坏" "$(basename "$newest_sql") gzip -t 失败" \
            "立即重跑备份并保留损坏样本排查"
    fi

    # 大小异常（对比近 7 份中位数）
    size_now=$(stat -c %s "$newest_sql")
    median=$(ls -t "${SQL_DIR}"/*.sql.gz 2>/dev/null | head -8 | tail -7 | xargs -r stat -c %s | sort -n | awk '{a[NR]=$1} END{if(NR) print a[int((NR+1)/2)]}')
    if [ -n "${median:-}" ] && [ "$median" -gt 0 ]; then
        if [ $(( size_now * 100 / median )) -lt $(( 100 - ${BACKUP_SIZE_DROP_PERCENT:-50} )) ]; then
            finding WARN "backup:size" "备份体积异常偏小" \
                "$(basename "$newest_sql") ${size_now} 字节，近 7 份中位数 ${median} 字节" \
                "确认数据库是否被清空/迁移；检查 mysqldump 是否部分失败"
        fi
    fi
fi

# ---- 云端回读（七牛） ----
if [ "${QINIU_VERIFY:-true}" = "true" ] && [ -x "${QINIU_QSHELL:-}" ]; then
    key="sql/$(date +%Y%m%d)_yu.sql.gz"
    out="$(timeout 40 "$QINIU_QSHELL" stat "${QINIU_BUCKET:-backup}" "$key" 2>&1 || true)"
    if printf '%s' "$out" | grep -q 'Fsize'; then
        finding INFO "backup:cloud" "云端备份可回读" "$key $(printf '%s' "$out" | grep 'Fsize' | head -1)" ""
    else
        finding WARN "backup:cloud-missing" "云端未找到今日备份" "$key：$(printf '%s' "$out" | head -2 | tr '\n' ' ')" \
            "检查 qshell fput 结果与七牛额度"
    fi
elif [ "${QINIU_VERIFY:-true}" = "true" ]; then
    finding WARN "backup:cloud-tool" "qshell 不可执行，跳过云端校验" "${QINIU_QSHELL:-未配置}" "检查 qshell 路径与权限"
fi

# ---- 文件备份（月度） ----
newest_file="$(ls -t "${FILE_DIR}"/*.tar.gz 2>/dev/null | head -1)"
if [ -n "$newest_file" ]; then
    file_age_d=$(( ( $(now_epoch) - $(stat -c %Y "$newest_file") ) / 86400 ))
    finding INFO "backup:file" "最新文件备份 ${file_age_d} 天前" "$(basename "$newest_file")" ""
    [ "$file_age_d" -gt 40 ] && finding WARN "backup:file-stale" "文件备份已 ${file_age_d} 天未更新" \
        "$(basename "$newest_file")" "检查每月 1 日的 cron：backup.sh file"
fi

exit 0
