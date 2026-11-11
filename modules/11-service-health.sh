#!/bin/bash
# 11-服务健康检查：关键服务存活 / nginx 配置 / MySQL / PHP-FPM
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

down=0
for svc in ${REQUIRED_SERVICES}; do
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    if [ "$state" != "active" ]; then
        down=$((down + 1))
        finding CRIT "svc:${svc}" "服务 ${svc} 未运行（${state:-unknown}）" \
            "systemctl status ${svc}" \
            "systemctl restart ${svc}；并查看日志 journalctl -u ${svc} -n 100"
    fi
done
[ "$down" -eq 0 ] && finding INFO "svc:all" "关键服务全部运行中" "${REQUIRED_SERVICES}" ""

# nginx 配置语法
if [ -x "${NGINX_BIN}" ]; then
    if ! out="$("${NGINX_BIN}" -t 2>&1)"; then
        finding CRIT "svc:nginx-config" "nginx 配置检查失败" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')" \
            "修正配置后 ${NGINX_BIN} -t && ${NGINX_BIN} -s reload"
    fi
fi

# MySQL 连接
if command -v mysqladmin >/dev/null 2>&1; then
    if [ -f "${MYSQL_CNF:-/root/.my.cnf}" ]; then
        mysql_ok="$(timeout 10 mysqladmin --defaults-extra-file="${MYSQL_CNF}" ping 2>&1 || true)"
    else
        mysql_ok="$(timeout 10 mysqladmin ping 2>&1 || true)"
    fi
    if printf '%s' "$mysql_ok" | grep -q 'alive'; then
        finding INFO "svc:mysql" "MySQL 响应正常" "" ""
    else
        finding CRIT "svc:mysql" "MySQL 无响应" "$(printf '%s' "$mysql_ok" | tail -2 | tr '\n' ' ')" \
            "systemctl status mysql; tail /var/log/mysql/error.log"
    fi
fi

# PHP-FPM socket（如果存在）
for sock in /tmp/php-cgi.sock /dev/shm/php-cgi.sock; do
    [ -S "$sock" ] || continue
    owner="$(stat -c '%U:%G' "$sock" 2>/dev/null)"
    finding INFO "svc:php-sock" "PHP-FPM socket 正常" "${sock} (${owner})" ""
done
