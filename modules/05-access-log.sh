#!/bin/bash
# 05-访问日志统计（只统计当日；仅输出 INFO，不参与告警）
# 说明：每天有大量扫描器流量被 WAF 拦截，按"整份日志"统计会产生大量误报，故只做当日占比统计。
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

DAY_TAG="$(date '+%d/%b/%Y')"
total_all=0

for log_file in "${LOGDIR}"/*.log; do
    [ -f "$log_file" ] || continue
    base="$(basename "$log_file")"
    case "$base" in
        *error*|nginx_error.log|cron.log|*ops-agent*|access.log.bak*) continue ;;
    esac
    [ -s "$log_file" ] || continue

    today_req=$(grep -cF "$DAY_TAG" "$log_file" 2>/dev/null || true)
    [ "${today_req:-0}" -eq 0 ] && continue

    waf_403=$(grep -F "$DAY_TAG" "$log_file" 2>/dev/null | grep -c '" 403 ' || true)
    auth_401=$(grep -F "$DAY_TAG" "$log_file" 2>/dev/null | grep -c '" 401 ' || true)
    err_5xx=$(grep -F "$DAY_TAG" "$log_file" 2>/dev/null | grep -cE '" 5[0-9][0-9] ' || true)

    total_all=$(( total_all + today_req ))

    # 被 WAF 拦截的扫描器路径 TOP3
    top_paths=$(grep -F "$DAY_TAG" "$log_file" 2>/dev/null | grep '" 403 ' | \
        grep -oE '(GET|POST|HEAD) /[^ ]*' | awk '{print $2}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(%s) ", $2, $1}')

    finding INFO "access:${base}" "${base} 今日请求 ${today_req}" \
        "403(拦截) ${waf_403} / 401 ${auth_401} / 5xx ${err_5xx}；TOP403: ${top_paths:-无}" ""

    # 5xx 异常：绝对值达阈值即告警（低流量站点也能发现真实应用错误）
    if [ "${err_5xx:-0}" -ge "${ERROR_5XX_WARN:-10}" ]; then
        pct="$(awk -v a="$err_5xx" -v b="$today_req" 'BEGIN{printf "%.2f", (b>0)? a*100/b : 0}')"
        # 展示 5xx 最多的请求路径（比 403 路径更有诊断价值）
        top5xx=$(grep -F "$DAY_TAG" "$log_file" 2>/dev/null | grep -E '" 5[0-9][0-9] ' | \
            grep -oE '(GET|POST|HEAD) /[^ ]*' | awk '{print $2}' | sed 's/?.*//' | \
            sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(%s) ", $2, $1}')
        finding WARN "access5xx:${base}" "${base} 今日 5xx ${err_5xx} 次（占 ${pct}%）" \
            "TOP5xx: ${top5xx:-无}" "查该站点 error_log 与 PHP 异常日志中对应时间点的报错"
    fi
done

finding INFO "access:total" "今日访问日志合计 ${total_all} 请求" "" ""
