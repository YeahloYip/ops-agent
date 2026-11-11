#!/bin/bash
# ops-agent 主入口
# 职责：采集 → 生成报告 → 分级 → LLM 判定 → 仅在「需要处理」时发邮件
#
# 用法：
#   bash agent.sh                # 正常巡检（仅在需要处理时发信）
#   bash agent.sh --dry-run      # 只跑检查并打印结论，不发信
#   bash agent.sh --force        # 强制发送（用于验证邮件链路）
#   bash agent.sh --report-only  # 生成报告，不做判定、不发信
#   bash agent.sh --crit-only    # 只检查并只发 P0（CRIT），不发 WARN、不调 AI（21:00 巡检用）
#   说明：正常运行时若配置了 HEARTBEAT_URL，会自动向外部位心跳服务 ping（CRIT 时 ping /fail）

set -u
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

OPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "${OPS_ROOT}/config.env" ]; then
    echo "缺少 ${OPS_ROOT}/config.env，请先：" >&2
    echo "  cp ${OPS_ROOT}/config.env.example ${OPS_ROOT}/config.env && chmod 600 ${OPS_ROOT}/config.env" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/notify.sh"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/alert.sh"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/judge.sh"

MODE="normal"
CRIT_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)     MODE="dry-run" ;;
        --force)       MODE="force" ;;
        --report-only) MODE="report-only" ;;
        --crit-only)   CRIT_ONLY=true ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

DATE="$(date '+%Y-%m-%d')"
TIME="$(date '+%Y-%m-%d %H:%M:%S')"
if [ "$CRIT_ONLY" = true ]; then
    REPORT_FILE="${OPS_ROOT}/logs/${DATE}-report-crit.log"
    RUN_DESC="仅 CRIT 巡检（${TIME}）"
else
    REPORT_FILE="${OPS_ROOT}/logs/${DATE}-report.log"
    RUN_DESC="完整巡检"
fi
TMP_DIR="$(mktemp -d)"
FINDINGS="${TMP_DIR}/findings.tsv"
CRIT_NEW="${TMP_DIR}/crit.tsv"
WARN_NEW="${TMP_DIR}/warn.tsv"
SUPPRESSED="${TMP_DIR}/suppressed.tsv"
: > "$FINDINGS"; : > "$CRIT_NEW"; : > "$WARN_NEW"; : > "$SUPPRESSED"

MODULES=(
    "01-software-update"
    "02-virus-scan"
    "03-vulnerability"
    "04-disk-space"
    "05-access-log"
    "06-error-log"
    "07-backup"
    "08-cert-renewal"
    "09-active-sites"
    "10-system-resources"
    "11-service-health"
    "12-security-events"
    "13-http-probe"
)

RAW_LOG="${TMP_DIR}/raw.log"
: > "$RAW_LOG"

for m in "${MODULES[@]}"; do
    file="${OPS_ROOT}/modules/${m}.sh"
    if [ ! -f "$file" ]; then
        finding WARN "module:${m}" "检查模块缺失" "${m}.sh 不存在" "补回模块或从 MODULES 列表移除" >> "$FINDINGS"
        continue
    fi
    echo "### ${m}" >> "$RAW_LOG"
    out="$(bash "$file" 2>>"$RAW_LOG")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        finding WARN "module:${m}" "检查模块执行异常" "退出码 ${rc}，详见报告" "检查 ${m}.sh" >> "$FINDINGS"
    fi
    printf '%s\n' "$out" | awk -F'|' 'NF>=4 && ($1=="CRIT"||$1=="WARN"||$1=="INFO"||$1=="OK")' >> "$FINDINGS"
    printf '%s\n' "$out" | awk -F'|' 'NF<4 || !($1=="CRIT"||$1=="WARN"||$1=="INFO"||$1=="OK")' | sed '/^$/d' >> "$RAW_LOG"
done

# ---------------- 生成文本报告 ----------------
crit_count=$(awk -F'|' '$1=="CRIT"' "$FINDINGS" | wc -l | tr -d ' ')
warn_count=$(awk -F'|' '$1=="WARN"' "$FINDINGS" | wc -l | tr -d ' ')
info_count=$(awk -F'|' '$1=="INFO"' "$FINDINGS" | wc -l | tr -d ' ')

{
    echo "======================================"
    echo "        运维检查报告"
    echo "======================================"
    echo "时间: ${TIME}"
    echo "主机: ${SERVER_NAME} (${SERVER_IP})"
    echo "模式: ${RUN_DESC}"
    echo "统计: CRIT ${crit_count} / WARN ${warn_count} / INFO ${info_count}"
    echo ""
    echo "---- 需要处理 ----"
    awk -F'|' '$1=="CRIT"||$1=="WARN" {if($4!=""){printf "[%s] %s\n   %s\n   建议: %s\n",$1,$3,$4,$5}else{printf "[%s] %s\n   建议: %s\n",$1,$3,$5}}' "$FINDINGS"
    echo ""
    echo "---- 其他 ----"
    awk -F'|' '$1=="INFO"||$1=="OK" {if($4!=""){printf "[%s] %s: %s\n",$1,$3,$4}else{printf "[%s] %s\n",$1,$3}}' "$FINDINGS"
    echo ""
    echo "---- 原始输出（调试）----"
    sed 's/^/  /' "$RAW_LOG"
} > "$REPORT_FILE"

# ---------------- 分级与去重 ----------------
alert_decide "$FINDINGS" "$CRIT_NEW" "$WARN_NEW" "$SUPPRESSED"
new_crit=$(wc -l < "$CRIT_NEW" | tr -d ' ')
new_warn=$(wc -l < "$WARN_NEW" | tr -d ' ')

DECISION="no-mail"
MAIL_LEVEL=""
MAIL_SUMMARY=""
JUDGE_NOTE=""

if [ "$CRIT_ONLY" = true ]; then
    # 21:00 巡检：只看 CRIT，不调 AI、不发 WARN，避免重复打扰
    if [ "$new_crit" -gt 0 ]; then
        DECISION="send"
        MAIL_LEVEL="P0"
        MAIL_SUMMARY="发现 ${new_crit} 项 P0 级问题，需立即处理"
    fi
elif [ "$new_crit" -gt 0 ]; then
    DECISION="send"
    MAIL_LEVEL="P0"
    MAIL_SUMMARY="发现 ${new_crit} 项 P0 级问题，需立即处理"
elif [ "$new_warn" -gt 0 ]; then
    if judge_available; then
        if judge_should_notify "$CRIT_NEW" "$WARN_NEW" "$FINDINGS"; then
            JUDGE_NOTE="LLM(${JUDGE_MODEL_USED}) 判定: ${JUDGE_SUMMARY:-无摘要}"
            if [ "${JUDGE_NOTIFY}" = "true" ]; then
                DECISION="send"
                MAIL_LEVEL="P1"
                MAIL_SUMMARY="${JUDGE_SUMMARY:-LLM 判定 ${new_warn} 项 WARN 中存在问题需要处理}"
            fi
        else
            JUDGE_NOTE="LLM 判定不可用，按规则回退"
            if [ "${JUDGE_FALLBACK_NOTIFY:-false}" = "true" ] \
               || { [ "${JUDGE_FALLBACK_WARN_MIN:-0}" -gt 0 ] && [ "$new_warn" -ge "${JUDGE_FALLBACK_WARN_MIN:-0}" ]; }; then
                DECISION="send"
                MAIL_LEVEL="P1"
                MAIL_SUMMARY="LLM 不可用，按规则回退发送 ${new_warn} 项 WARN"
            fi
        fi
    else
        JUDGE_NOTE="LLM 未启用/opencode 缺失，按规则回退"
        if [ "${JUDGE_FALLBACK_NOTIFY:-false}" = "true" ] \
           || { [ "${JUDGE_FALLBACK_WARN_MIN:-0}" -gt 0 ] && [ "$new_warn" -ge "${JUDGE_FALLBACK_WARN_MIN:-0}" ]; }; then
            DECISION="send"
            MAIL_LEVEL="P1"
            MAIL_SUMMARY="LLM 不可用，按规则回退发送 ${new_warn} 项 WARN"
        fi
    fi
fi

[ "$MODE" = "report-only" ] && DECISION="no-mail"
[ "$MODE" = "force" ] && { DECISION="send"; MAIL_LEVEL="${MAIL_LEVEL:-P1}"; MAIL_SUMMARY="${MAIL_SUMMARY:-强制发送测试（--force）}"; }
[ "$MODE" = "dry-run" ] && DECISION="dry-run-${DECISION}"

# ---------------- 心跳（外部 cron 监控）----------------
heartbeat_ping() {
    local status="$1" url="${HEARTBEAT_URL:-}"
    [ "${HEARTBEAT_ENABLED:-true}" = "true" ] || return 0
    if [ -z "$url" ]; then
        echo "心跳未配置（HEARTBEAT_URL 为空），跳过"
        return 0
    fi
    [ "$status" = "fail" ] && url="${url%/}/fail"
    # 说明：部分服务器 IPv6 不可用，而 healthchecks 有 AAAA 记录，
    #       curl 默认会先试 IPv6 导致超时，因此强制 -4，并做 3 次重试。
    local err attempt rc=1
    err="$(mktemp)"
    for attempt in 1 2 3; do
        if curl -4 -fsS -m 15 -o /dev/null "$url" 2>"$err"; then
            rc=0
            break
        fi
        [ "$attempt" -lt 3 ] && sleep 2
    done
    if [ "$rc" -eq 0 ]; then
        echo "$(date '+%F %T') ping ok (${status}, attempt=${attempt})" >> "${STATE_DIR}/heartbeat.log"
    else
        echo "$(date '+%F %T') ping FAIL (${status}): $(tail -1 "$err")" >> "${STATE_DIR}/heartbeat.log"
        echo "心跳 ping 失败（见 logs/.state/heartbeat.log）"
    fi
    rm -f "$err"
}

# crit-only：邮件只保留 CRIT 内容
if [ "$CRIT_ONLY" = true ]; then
    : > "$WARN_NEW"
    : > "$SUPPRESSED"
fi

# ---------------- 发送邮件 ----------------
SEND_RC=0
if [ "$DECISION" = "send" ] || [ "$MODE" = "force" ]; then
    html_file="${TMP_DIR}/mail.html"
    {
        cat <<HTML
<html><head><meta charset="UTF-8"></head><body style="font-family:-apple-system,'PingFang SC',Arial,sans-serif;font-size:14px;color:#222;line-height:1.6">
<h2 style="margin:0 0 2px;color:$(level_color "$MAIL_LEVEL")">[需处理][${MAIL_LEVEL}] ${SERVER_NAME} 巡检告警</h2>
<p style="margin:0 0 14px;color:#666;font-size:12px">${TIME} ｜ ${SERVER_IP} ｜ ${MAIL_SUMMARY}</p>
HTML
        if [ "$MAIL_LEVEL" = "P1" ] && [ -n "${JUDGE_SUMMARY:-}" ]; then
            echo "<p style=\"background:#fff8e1;border-left:4px solid #ffb300;padding:8px 12px;margin:0 0 14px\">AI 判定：$(printf '%s' "$JUDGE_SUMMARY" | html_escape)</p>"
        fi
        echo '<table style="border-collapse:collapse;width:100%">'
        echo '<tr style="background:#f5f5f5"><th align="left" style="padding:6px;border:1px solid #ddd">级别</th><th align="left" style="padding:6px;border:1px solid #ddd">问题</th><th align="left" style="padding:6px;border:1px solid #ddd">证据</th><th align="left" style="padding:6px;border:1px solid #ddd">建议动作</th></tr>'
        while IFS='|' read -r level key title detail suggest; do
            [ -z "${level:-}" ] && continue
            printf '<tr><td style="padding:6px;border:1px solid #ddd;color:%s;font-weight:600">%s</td><td style="padding:6px;border:1px solid #ddd">%s</td><td style="padding:6px;border:1px solid #ddd">%s</td><td style="padding:6px;border:1px solid #ddd">%s</td></tr>\n' \
                "$(level_color "$level")" "$level" "$(printf '%s' "$title" | html_escape)" "$(printf '%s' "$detail" | html_escape)" "$(printf '%s' "$suggest" | html_escape)"
        done < <(cat "$CRIT_NEW" "$WARN_NEW" 2>/dev/null)
        echo '</table>'

        if [ -s "${JUDGE_ITEMS_FILE:-/dev/null}" ]; then
            echo '<h4 style="margin:16px 0 4px">AI 建议的处理顺序</h4><ol style="margin:0;padding-left:22px">'
            while IFS='|' read -r k why action; do
                [ -z "${k:-}" ] && continue
                printf '<li><b>%s</b>：%s<br><span style="color:#666">→ %s</span></li>\n' \
                    "$(printf '%s' "$k" | html_escape)" "$(printf '%s' "$why" | html_escape)" "$(printf '%s' "$action" | html_escape)"
            done < "$JUDGE_ITEMS_FILE"
            echo '</ol>'
        fi

        if [ -s "$SUPPRESSED" ]; then
            echo '<h4 style="margin:16px 0 4px">已抑制（近期已提醒过）</h4><ul style="margin:0;padding-left:22px;color:#666;font-size:12px">'
            while IFS='|' read -r level key title why; do
                printf '<li>%s: %s（%s）</li>\n' "$(printf '%s' "$title" | html_escape)" "$(printf '%s' "$why" | html_escape)" "$level"
            done < "$SUPPRESSED"
            echo '</ul>'
        fi

        cat <<HTML
<p style="margin:18px 0 0;padding-top:12px;border-top:1px solid #eee;color:#888;font-size:12px">
完整报告：服务器 ${REPORT_FILE}（日常报告不再每天邮件推送，仅在有需处理事项时通知）<br>
手动查看：<code>ssh aoyo 'cat ${REPORT_FILE}'</code>
</p></body></html>
HTML
    } > "$html_file"

    subject="[需处理][${MAIL_LEVEL}] ${SERVER_NAME} - ${MAIL_SUMMARY}"
    subject="${subject:0:110}"
    if send_email "$subject" "$(cat "$html_file")"; then
        alert_mark_sent "$CRIT_NEW"
        alert_mark_sent "$WARN_NEW"
        echo "邮件已发送: ${subject}"
    else
        SEND_RC=1
        echo "邮件发送失败: ${subject}（详见 logs/.state/mail.log）"
    fi
else
    echo "无需处理，未发送邮件（CRIT ${crit_count} / WARN ${warn_count}，本次待发 CRIT ${new_crit} / WARN ${new_warn}）"
fi

# 当日结论写回报告，便于追溯
{
    echo ""
    echo "---- 结论 ----"
    echo "模式: ${RUN_DESC}"
    echo "决策: ${DECISION}"
    echo "待发: CRIT ${new_crit} / WARN ${new_warn}"
    [ -n "$JUDGE_NOTE" ] && echo "AI: ${JUDGE_NOTE}"
    echo "报告: ${REPORT_FILE}"
} >> "$REPORT_FILE"

# 心跳：只在真正巡检的两种模式发送（dry-run / report-only 不发，避免掩盖故障）
if [ "$MODE" != "dry-run" ] && [ "$MODE" != "report-only" ]; then
    if [ "${crit_count:-0}" -gt 0 ]; then
        heartbeat_ping "fail"
    else
        heartbeat_ping "ok"
    fi
fi

rm -rf "$TMP_DIR"
exit "$SEND_RC"
