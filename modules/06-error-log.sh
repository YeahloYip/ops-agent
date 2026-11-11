#!/bin/bash
# 06-错误日志检查：区分 WAF 拦截噪音与真实错误
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

DAY_TAG="$(date '+%d/%b/%Y')"
REAL_ERR_PATTERN='\[(error|crit|alert|emerg)\]'
WAF_NOISE='access forbidden by rule'

check_error_log() {
    local file="$1" name
    name="$(basename "$file")"
    [ -s "$file" ] || return 0

    # 只取今日（nginx error log 格式：2026/11/11 08:45:41）
    local today_tag
    today_tag="$(date '+%Y/%m/%d')"
    local today_lines
    today_lines=$(grep -cF "$today_tag" "$file" 2>/dev/null || true)
    [ "${today_lines:-0}" -eq 0 ] && { finding INFO "error:${name}" "${name} 今日无新增错误" "" ""; return 0; }

    local real_errors waf_noise downstream
    real_errors=$(grep -F "$today_tag" "$file" 2>/dev/null | grep -E "$REAL_ERR_PATTERN" | grep -vcF "$WAF_NOISE" || true)
    waf_noise=$(grep -F "$today_tag" "$file" 2>/dev/null | grep -cF "$WAF_NOISE" || true)
    downstream=$(grep -F "$today_tag" "$file" 2>/dev/null | grep -cE 'connect\(\) failed|upstream timed out|no live upstreams' || true)

    if [ "${downstream:-0}" -ge "${ERROR_5XX_WARN:-10}" ]; then
        finding WARN "error:upstream:${name}" "${name} 今日 ${downstream} 次后端连接失败" \
            "$(grep -F "$today_tag" "$file" | grep -E 'connect\(\) failed|upstream timed out' | tail -2 | sed 's/^ *//' | cut -c1-160 | tr '\n' ';')" \
            "确认 php-fpm 进程数/重启情况、MySQL 连接；必要时调大 pm.max_children"
    elif [ "${real_errors:-0}" -ge 50 ]; then
        finding WARN "error:${name}" "${name} 今日真实错误 ${real_errors} 条" \
            "$(grep -F "$today_tag" "$file" | grep -E "$REAL_ERR_PATTERN" | grep -vF "$WAF_NOISE" | tail -2 | cut -c1-160 | tr '\n' ';')" \
            "查看完整错误日志定位来源"
    else
        finding INFO "error:${name}" "${name} 今日错误 ${real_errors} 条（WAF 拦截 ${waf_noise} 条已忽略）" "" ""
    fi
}

# 全局错误日志
[ -f "${LOGDIR}/nginx_error.log" ] && check_error_log "${LOGDIR}/nginx_error.log"

# 各站点错误日志
for f in "${LOGDIR}"/*error*.log; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "nginx_error.log" ] && continue
    check_error_log "$f"
done
