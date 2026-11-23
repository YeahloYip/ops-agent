#!/bin/bash
# 14-db-write-audit.sh —— 数据库写操作审计
#
# 背景（2026-11-21）：
#   一次事故中，AI 为验证接口修复，在生产库发起了真实 POST 请求，
#   导致向 customer_message 表写入了一条测试记录（id=562）。
#   虽然已清理，但暴露出一个结构性缺陷：
#     - 生产 DB 账号是 root，拥有 ALL PRIVILEGES ON *.*
#     - 也就是说"AI 只读"完全依赖操作纪律，没有任何技术边界
#
# 本模块职责：
#   1. 从 binlog 中解析出"数据变更"事件，统计各库的写入次数与时间分布
#   2. 与"已知的合法写入来源"（cron 备份、应用正常业务）对比，
#      发现异常的写入量/写入时间
#   3. 检查 DB 账号权限是否被放宽（root@% 等）
#
# 说明：binlog 本身是 MySQL 的既有功能（log_bin=ON, MIXED 格式, 保留 10 天），
#       本模块只读解析，不修改 binlog 配置，也不开启 general_log（避免磁盘膨胀）。
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

MYSQL_CNF="${MYSQL_CNF:-/root/.my.cnf}"

# 统一 mysql 调用（带 .my.cnf）
mysql_q() {
    if [ -f "$MYSQL_CNF" ]; then
        mysql --defaults-extra-file="$MYSQL_CNF" -Nse "$1" 2>/dev/null
    else
        mysql -Nse "$1" 2>/dev/null
    fi
}

if ! command -v mysql >/dev/null 2>&1; then
    finding WARN "db:audit-no-client" "无法审计数据库写操作" "mysql 客户端不可用" "确认 MySQL 客户端已安装"
    exit 0
fi

# ---------- 1. 权限面检查：是否有过宽的账号 ----------
# root 拥有 ALL PRIVILEGES 是既定事实（应用需要），但 root@% 允许远程登录是额外风险。
# 结合 mysql-guard 的公网 DROP，root@% 目前不可达，但仍应显式记录。
root_remote="$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user='root' AND host NOT IN ('localhost','127.0.0.1','::1')")"
if [ "${root_remote:-0}" -gt 0 ]; then
    finding WARN "db:root-remote" "存在可远程登录的 root 账号（${root_remote} 个）" \
        "mysql.user 中 root 的 host 包含非本机地址" \
        "确认 mysql-guard 已 DROP 公网 3306；建议删除 root@% 或限制为内网白名单"
else
    finding INFO "db:root-remote" "root 仅允许本机登录" "" ""
fi

# ---------- 2. 应用账号权限宽度 ----------
# 应用用 root 是历史遗留（.env 里 DB_USERNAME=root）。这本身不算漏洞，
# 但意味着"AI 一旦拿到 .env 就能写任何库"。这里只做提示，不擅自改配置。
app_root_cnt=0
for envf in "${WEBROOT}"/*/.env; do
    [ -f "$envf" ] || continue
    u="$(grep -E '^DB_USERNAME=' "$envf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"'"'"' ')"
    [ "$u" = "root" ] && app_root_cnt=$((app_root_cnt + 1))
done
if [ "$app_root_cnt" -gt 0 ]; then
    finding INFO "db:app-root" "${app_root_cnt} 个站点使用 root 连接数据库" \
        "应用账号权限为 ALL PRIVILEGES，AI 只读无技术边界" \
        "建议为应用建最小权限账号（见 docs/db-safety.md），AI 侧另用只读账号"
fi

# ---------- 3. binlog 写入量统计 ----------
# 用 mysqlbinlog 解析最近一段 binlog，统计 Write_rows/Update_rows/Delete_rows 事件数。
# 目的：给出"每小时正常写入量"的基线，异常时能被发现。
#
# 注意：mysqlbinlog 常不在默认 PATH（本机在 /usr/local/mysql/bin/），需显式查找。
mysqlbinlog_bin() {
    local b
    b="$(command -v mysqlbinlog 2>/dev/null || true)"
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    for b in /usr/local/mysql/bin/mysqlbinlog /usr/bin/mysqlbinlog /usr/local/bin/mysqlbinlog; do
        [ -x "$b" ] && { printf '%s' "$b"; return 0; }
    done
    return 1
}

MB="$(mysqlbinlog_bin || true)"
if [ -z "${MB:-}" ]; then
    finding INFO "db:binlog-tool" "未找到 mysqlbinlog，跳过写入量统计" \
        "常见路径 /usr/local/mysql/bin/mysqlbinlog" "确认 MySQL 安装路径，或忽略此项"
    exit 0
fi

binlog_on="$(mysql_q "SHOW VARIABLES LIKE 'log_bin'" | cut -f2)"
if [ "${binlog_on:-OFF}" != "ON" ]; then
    finding INFO "db:binlog-off" "binlog 未开启，无法审计历史写入" "" \
        "如需写入审计，评估开启 binlog（有磁盘成本）"
    exit 0
fi

# 取审计时间窗内可能涉及的 binlog 文件。
# 注意：不能只取"最新一个"——若 24h 内发生 binlog 切换（或 MySQL 重启），
# 跨文件窗口的写入会整段漏掉，审计就失去意义。
# 这里按"修改时间晚于起始时间"筛出所有候选文件，交给 mysqlbinlog 逐个解析。
binlog_dir="$(mysql_q "SHOW VARIABLES LIKE 'log_bin_basename'" | cut -f2 | xargs dirname 2>/dev/null)"
[ -z "${binlog_dir:-}" ] && binlog_dir="/usr/local/mysql/var"

AUDIT_HOURS="${DB_AUDIT_HOURS:-24}"
since_ts=$(( $(now_epoch) - AUDIT_HOURS * 3600 ))
since_str="$(date -d "@${since_ts}" '+%Y-%m-%d %H:%M:%S')"

# 候选 binlog：文件名形如 mysql-bin.000031，且修改时间在窗口之后
binlog_files=""
for f in "${binlog_dir}"/mysql-bin.[0-9]*; do
    [ -f "$f" ] || continue
    f_mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    # 文件最后修改时间早于窗口起点 → 该文件内不可能有窗口内的写入，跳过
    [ "${f_mtime:-0}" -lt "$since_ts" ] && continue
    binlog_files="${binlog_files} ${f}"
done

# 兜底：若一个都没匹配到（例如时间判断异常），退回用最新文件
if [ -z "${binlog_files// /}" ]; then
    latest_binlog="$(ls -t "${binlog_dir}"/mysql-bin.[0-9]* 2>/dev/null | head -1)"
    binlog_files="${latest_binlog:-}"
fi

if [ -z "${binlog_files// /}" ]; then
    finding INFO "db:binlog-none" "未找到 binlog 文件" "${binlog_dir}" ""
    exit 0
fi

binlog_count="$(printf '%s\n' $binlog_files | grep -c . || true)"

# 统计写入事件（遍历窗口内所有 binlog 文件）。
# 注意：binlog_format=MIXED 时，普通 DML 常以 statement 格式记录（直接是 SQL 语句），
# 只有不确定的场景才转 row 格式（产生 ### INSERT INTO 行事件）。
# 所以两种都要匹配，否则会漏掉绝大多数写入（本机实测：MIXED 下 row 事件为 0，
# 而 statement 格式有上万条）。
write_stats="$("$MB" --start-datetime="$since_str" $binlog_files 2>/dev/null | \
    grep -oE '(### (INSERT INTO|UPDATE|DELETE FROM) `[^`]+`\.`[^`]+`)|(^(INSERT INTO|UPDATE|DELETE FROM) `?[a-zA-Z0-9_]+`?[.`])' | \
    sed -E 's/^### (INSERT INTO|UPDATE|DELETE FROM) //; s/^(INSERT INTO|UPDATE|DELETE FROM) //' | \
    sed -E 's/^`([^`]+)`\.`([^`]+)`$/\1.\2/; s/^`([^`]+)`\.$/\1/; s/^([a-zA-Z0-9_]+)\.$/\1/' | \
    sort | uniq -c | sort -rn | head -12)"

# 总写入条数（含未识别出表名的）
total_write_events="$("$MB" --start-datetime="$since_str" $binlog_files 2>/dev/null | \
    grep -cE '^(INSERT INTO|UPDATE|DELETE FROM)|### (INSERT INTO|UPDATE|DELETE FROM)' || true)"

total_writes="$(printf '%s\n' "$write_stats" | grep -c . || true)"

if [ "${total_write_events:-0}" -gt 0 ]; then
    detail="$(printf '%s\n' "$write_stats" | awk 'NF>=2{printf "%s(%s次) ", $2, $1}' | cut -c1-400)"
    finding INFO "db:write-audit" "近 ${AUDIT_HOURS} 小时共 ${total_write_events} 条写入，涉及 ${total_writes} 个表" \
        "${detail:-表名未能解析}（binlog 文件 ${binlog_count} 个）" ""
else
    finding INFO "db:write-audit" "近 ${AUDIT_HOURS} 小时 binlog 无写入事件" \
        "binlog 文件 ${binlog_count} 个，起始 ${since_str}" ""
fi

# ---------- 4. 关键表行数快照对比 ----------
# 对"不应随意变动"的表做行数检查（如 admin_users 突然少人、customer_message 暴增）。
# 用状态文件记录上次值，本次对比。首次运行只记录基线。
SNAP_FILE="${STATE_DIR}/db-rowcount.tsv"
SNAP_NEW="$(mktemp)"
: > "$SNAP_NEW"

check_rowcount() {
    local db="$1" tbl="$2" cur prev delta
    cur="$(mysql_q "SELECT COUNT(*) FROM \`${db}\`.\`${tbl}\`")"
    [ -z "${cur:-}" ] && return 0
    prev="$(awk -F'\t' -v k="${db}.${tbl}" '$1==k{print $2}' "$SNAP_FILE" 2>/dev/null)"
    printf '%s\t%s\n' "${db}.${tbl}" "$cur" >> "$SNAP_NEW"
    [ -z "${prev:-}" ] && return 0
    delta=$(( cur - prev ))
    # 阈值：单次变动超过 DB_ROWCOUNT_WARN（默认 100）条才提示
    if [ "${delta#-}" -ge "${DB_ROWCOUNT_WARN:-100}" ]; then
        finding WARN "db:rowcount:${db}.${tbl}" "表 ${db}.${tbl} 行数大幅变动" \
            "${prev} → ${cur}（变化 ${delta}）" \
            "确认是否为正常业务增长；异常则查 binlog 定位来源"
    fi
}

# 审计重点表（可按需扩展）
for pair in "brilliancesteel customer_message" "brilliancesteel admin_users" \
            "yeahlo users" "yu user"; do
    set -- $pair
    check_rowcount "$1" "$2"
done

# 保存本次快照
[ -s "$SNAP_NEW" ] && mv -f "$SNAP_NEW" "$SNAP_FILE" || rm -f "$SNAP_NEW"
