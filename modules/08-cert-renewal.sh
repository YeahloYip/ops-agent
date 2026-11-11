#!/bin/bash
# 08-证书检查：到期时间 / 线上与磁盘一致性 / acme 续签状态
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

now="$(now_epoch)"

# ---- 1. 磁盘证书到期时间 ----
for site in ${SITES}; do
    conf="${NGINX_VHOST_DIR}/${site}.conf"
    [ -f "$conf" ] || continue
    cert_file="$(grep -E '^\s*ssl_certificate\s' "$conf" | awk '{print $2}' | tr -d ';' | grep -v ssl_certificate_key | head -1)"
    [ -f "$cert_file" ] || continue

    end="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -z "$end" ] && { finding WARN "cert:${site}" "${site} 证书无法解析" "$cert_file" "检查证书文件完整性"; continue; }
    end_epoch="$(date -d "$end" +%s 2>/dev/null)"
    [ -z "$end_epoch" ] && continue
    days=$(( (end_epoch - now) / 86400 ))

    if [ "$days" -lt 0 ]; then
        finding CRIT "cert:${site}" "${site} 证书已过期 ${days#-} 天" "文件 ${cert_file}，到期 ${end}" \
            "立即续签：${ACME_HOME}/acme.sh --renew -d ${site} --force; 然后 reload nginx"
    elif [ "$days" -le "${CERT_CRIT_DAYS:-7}" ]; then
        finding CRIT "cert:${site}" "${site} 证书 ${days} 天后过期" "文件 ${cert_file}，到期 ${end}" \
            "立即检查 acme 续签：${ACME_HOME}/acme.sh --list；必要时 --renew --force 后 reload nginx"
    elif [ "$days" -le "${CERT_WARN_DAYS:-14}" ]; then
        finding WARN "cert:${site}" "${site} 证书 ${days} 天后过期" "到期 ${end}" \
            "确认 acme.sh 自动续签正常，到期前 7 天仍未续签需手动处理"
    else
        finding INFO "cert:${site}" "${site} 证书有效（${days} 天）" "到期 ${end}" ""
    fi
done

# ---- 2. acme 续签计划是否已逾期 ----
if [ -x "${ACME_HOME}/acme.sh" ]; then
    while IFS= read -r line; do
        case "$line" in
            Main_Domain*|'') continue ;;
        esac
        domain="$(printf '%s' "$line" | awk '{print $1}')"
        renew="$(printf '%s' "$line" | awk '{print $NF}')"
        [ -z "$renew" ] && continue
        renew_epoch="$(date -d "$renew" +%s 2>/dev/null)"
        [ -z "$renew_epoch" ] && continue
        if [ "$renew_epoch" -lt "$now" ]; then
            finding CRIT "cert:renew-overdue" "acme 续签已逾期：${domain}" \
                "计划续签时间 ${renew} 已过" "手动续签：${ACME_HOME}/acme.sh --renew -d ${domain} --force"
        fi
    done < <("${ACME_HOME}/acme.sh" --list 2>/dev/null)
fi

# ---- 3. 线上证书 vs 磁盘证书（检测 nginx 未 reload 的旧证书）----
for site in ${SITES}; do
    conf="${NGINX_VHOST_DIR}/${site}.conf"
    [ -f "$conf" ] || continue
    cert_file="$(grep -E '^\s*ssl_certificate\s' "$conf" | awk '{print $2}' | tr -d ';' | head -1)"
    [ -f "$cert_file" ] || continue
    disk_end="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)"
    disk_epoch="$(date -d "$disk_end" +%s 2>/dev/null)"
    [ -z "$disk_epoch" ] && continue

    live_end="$(echo | timeout 8 openssl s_client -servername "$site" -connect 127.0.0.1:443 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    live_epoch="$(date -d "$live_end" +%s 2>/dev/null)"
    [ -z "$live_epoch" ] && continue

    diff=$(( live_epoch - disk_epoch ))
    [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -gt 86400 ]; then
        finding CRIT "cert:stale-nginx" "${site} 线上证书与磁盘不一致" \
            "线上到期 ${live_end}，磁盘到期 ${disk_end}（nginx 未加载新证书）" \
            "执行 ${NGINX_BIN} -s reload；并在 acme 续签 hook 中加入 reload"
    fi
done

# ---- 4. acme 日志真实错误（排除 _error_level/_stopRenewOnError 元数据）----
if [ -f "$ACME_LOG" ]; then
    real_err=$(tail -2000 "$ACME_LOG" 2>/dev/null | \
        grep -iE '(^|[^_a-z])(error|failed)' | \
        grep -viE '_error_level|_stopRenewOnError|renewalInfo|error_level' | \
        tail -3)
    if [ -n "$real_err" ]; then
        finding WARN "cert:acme-errors" "acme.sh 日志有错误记录" \
            "$(printf '%s' "$real_err" | tr '\n' ';' | cut -c1-300)" \
            "查看 ${ACME_LOG} 完整上下文"
    fi
fi
