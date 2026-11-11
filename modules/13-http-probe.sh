#!/bin/bash
# 13-HTTP 探活：各站点状态码与响应时间（走本机，避免依赖外部 DNS）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

probe() {
    local host="$1" url="$2"
    local out code time
    out="$(timeout 15 curl -sk -o /dev/null -m 10 \
        --resolve "${host}:443:${SERVER_IP}" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
    code="${out%% *}"; time="${out##* }"
    [ -z "$code" ] && code="000"

    if [ "$code" = "000" ]; then
        finding CRIT "http:${host}" "${host} 无法连接（HTTPS 探活失败）" \
            "curl ${url} 连接超时/失败" "检查 nginx、PHP-FPM、防火墙；手动 curl -vk ${url}"
    elif [ "${code#5}" != "$code" ]; then
        finding CRIT "http:${host}" "${host} 返回 ${code}" "响应时间 ${time}s" \
            "查看 error_log 对应时间点；检查后端 php-fpm/mysql"
    elif awk -v t="${time:-0}" 'BEGIN{exit !(t+0>5)}'; then
        finding WARN "http:${host}" "${host} 响应缓慢 ${time}s（HTTP ${code}）" "" \
            "查慢查询与 PHP 执行时间"
    else
        finding INFO "http:${host}" "${host} 正常（HTTP ${code}, ${time}s）" "" ""
    fi
}

for site in ${SITES}; do
    probe "$site" "https://${site}/"
done
