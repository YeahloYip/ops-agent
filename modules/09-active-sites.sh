#!/bin/bash
# 09-域名解析检查（以 nginx vhost 里的 server_name 为准，带重试避免网络抖动误报）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

# 收集 vhost 中的域名（权威来源）
domains=""
for conf in "${NGINX_VHOST_DIR}"/*.conf; do
    [ -f "$conf" ] || continue
    for d in $(grep -oE 'server_name\s+[^;]+' "$conf" 2>/dev/null | sed 's/server_name\s*//' | tr ' ' '\n' | grep -v '^$' | grep -v '^_$'); do
        domains="$domains $d"
    done
done
[ -z "$domains" ] && domains="${SITES}"

resolve_ip() {
    local d="$1" ip=""
    local i
    for i in 1 2 3; do
        ip="$(timeout 6 getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        [ -n "$ip" ] && break
        ip="$(timeout 6 getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        [ -n "$ip" ] && break
        sleep 1
    done
    printf '%s' "$ip"
}

ok=0; bad=0
for d in $(printf '%s\n' $domains | sort -u); do
    ip="$(resolve_ip "$d")"
    if [ -z "$ip" ]; then
        bad=$((bad + 1))
        finding WARN "dns:${d}" "${d} 无法解析（重试 3 次仍失败）" "getent 无结果" "检查 DNS 记录与域名到期时间"
    elif [ "$ip" != "$SERVER_IP" ]; then
        bad=$((bad + 1))
        finding WARN "dns:${d}" "${d} 解析到 ${ip}" "与本机 ${SERVER_IP} 不一致" "确认是否走 CDN；否则修正 A 记录"
    else
        ok=$((ok + 1))
    fi
done

finding INFO "dns:summary" "域名解析检查完成" "${ok} 个正常 / ${bad} 个异常" ""
