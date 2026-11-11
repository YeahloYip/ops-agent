#!/bin/bash
# mysql-guard.sh —— MySQL 3306 端口公网访问守卫
#
# 作用：
#   用 iptables/ip6tables 专用链（MYSQL_GUARD）控制 3306 的对外访问：
#     - 本机回环（lo）永远放行（PHP/应用连 127.0.0.1 不受影响）
#     - 公网默认 DROP
#     - 需要临时/长期放行时，按 IP/CIDR 加白名单（可带过期时间）
#
# 为什么用防火墙而不是改 bind-address：
#   改 bind-address 需要重启 MySQL 才能切换；防火墙可以随时开关、可自动过期，
#   且无需动数据库配置。
#
# 用法：
#   mysql-guard.sh apply                     # 创建/重建守卫链并挂到 INPUT（幂等）
#   mysql-guard.sh status                    # 查看当前状态（链规则、白名单、是否仍有裸放行）
#   mysql-guard.sh open <IP|CIDR> [分钟] [备注]
#                                            # 放行指定来源（默认 60 分钟后自动关闭，
#                                            # 填 0 表示长期放行）
#   mysql-guard.sh close [IP|CIDR]           # 撤销指定来源；不带参数=撤销全部白名单
#   mysql-guard.sh list                      # 列出白名单
#   mysql-guard.sh expire                    # 清理已过期白名单（建议 cron 每 5 分钟跑）
#
# 文件：
#   白名单：/etc/ops-agent/mysql-allow.list（每行：IP|CIDR 过期epoch 备注）
#   日志：  /var/log/mysql-guard.log
#
# 推荐替代方案：SSH 隧道（无需放行任何端口）
#   ssh -p 22 -i ~/.ssh/key -L 3306:127.0.0.1:3306 user@server
#   然后本地客户端连 127.0.0.1:3306 即可。

set -u

CHAIN="MYSQL_GUARD"
ALLOW_DIR="/etc/ops-agent"
ALLOW_FILE="${MYSQL_GUARD_ALLOW_FILE:-${ALLOW_DIR}/mysql-allow.list}"
LOG_FILE="/var/log/mysql-guard.log"
DEFAULT_MINUTES=60

log() {
    local msg="$(date '+%F %T') $*"
    echo "$msg"
    [ -d "$(dirname "$LOG_FILE")" ] && echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限运行" >&2
        exit 1
    fi
}

have_ip6() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    ip6tables -S >/dev/null 2>&1
}

# 校验 IPv4/CIDR 或 IPv6/CIDR，拒绝 0.0.0.0/0 与 ::/0
valid_addr() {
    local a="$1"
    case "$a" in
        0.0.0.0/0|::/0|0.0.0.0|::|"") return 1 ;;
    esac
    if printf '%s' "$a" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'; then
        return 0
    fi
    if printf '%s' "$a" | grep -qE '^[0-9a-fA-F:]+(/[0-9]{1,3})?$'; then
        return 0
    fi
    return 1
}

is_v6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

save_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

# 重建 IPv4 守卫链
rebuild4() {
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN" || return 1
    iptables -A "$CHAIN" -i lo -j ACCEPT
    local addr exp note
    while IFS=' ' read -r addr exp note; do
        [ -z "$addr" ] && continue
        is_v6 "$addr" && continue
        iptables -A "$CHAIN" -s "$addr" -j ACCEPT
    done < "$ALLOW_FILE"
    iptables -A "$CHAIN" -j DROP

    # 去掉历史上的“裸放行”规则
    while iptables -C INPUT -p tcp -m tcp --dport 3306 -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp -m tcp --dport 3306 -j ACCEPT
    done
    # 挂载守卫链（去重后只保留一条，放在最前）
    while [ "$(iptables -S INPUT | grep -c -- "-p tcp -m tcp --dport 3306 -j ${CHAIN}")" -gt 1 ]; do
        iptables -D INPUT -p tcp -m tcp --dport 3306 -j "$CHAIN"
    done
    iptables -C INPUT -p tcp -m tcp --dport 3306 -j "$CHAIN" 2>/dev/null || \
        iptables -I INPUT 1 -p tcp -m tcp --dport 3306 -j "$CHAIN"
}

# 重建 IPv6 守卫链（本机 IPv6 不可用时也保留 DROP，防止日后开启 IPv6 变成裸奔）
rebuild6() {
    have_ip6 || return 0
    ip6tables -N "$CHAIN" 2>/dev/null || true
    ip6tables -F "$CHAIN" || return 1
    ip6tables -A "$CHAIN" -i lo -j ACCEPT
    local addr exp note
    while IFS=' ' read -r addr exp note; do
        [ -z "$addr" ] && continue
        is_v6 "$addr" || continue
        ip6tables -A "$CHAIN" -s "$addr" -j ACCEPT
    done < "$ALLOW_FILE"
    ip6tables -A "$CHAIN" -j DROP

    while ip6tables -C INPUT -p tcp -m tcp --dport 3306 -j ACCEPT 2>/dev/null; do
        ip6tables -D INPUT -p tcp -m tcp --dport 3306 -j ACCEPT
    done
    while [ "$(ip6tables -S INPUT | grep -c -- "-p tcp -m tcp --dport 3306 -j ${CHAIN}")" -gt 1 ]; do
        ip6tables -D INPUT -p tcp -m tcp --dport 3306 -j "$CHAIN"
    done
    ip6tables -C INPUT -p tcp -m tcp --dport 3306 -j "$CHAIN" 2>/dev/null || \
        ip6tables -I INPUT 1 -p tcp -m tcp --dport 3306 -j "$CHAIN"
}

rebuild_all() {
    rebuild4 || { echo "IPv4 守卫链重建失败" >&2; return 1; }
    rebuild6 || true
    save_rules
}

ensure_allow_file() {
    mkdir -p "$ALLOW_DIR"
    chmod 700 "$ALLOW_DIR"
    [ -f "$ALLOW_FILE" ] || { : > "$ALLOW_FILE"; chmod 600 "$ALLOW_FILE"; }
}

cmd_apply() {
    ensure_allow_file
    rebuild_all
    local n
    n="$(grep -c . "$ALLOW_FILE" 2>/dev/null || true)"
    log "已应用守卫：3306 仅允许本机回环 + 白名单（${n:-0} 条）"
}

cmd_status() {
    echo "===== IPv4 ====="
    iptables -S INPUT | grep -E "dport 3306" || echo "  （INPUT 无 3306 相关规则）"
    iptables -L "$CHAIN" -n -v 2>/dev/null | sed 's/^/  /'
    echo
    if have_ip6; then
        echo "===== IPv6 ====="
        ip6tables -S INPUT | grep -E "dport 3306" || echo "  （INPUT 无 3306 相关规则）"
        ip6tables -L "$CHAIN" -n -v 2>/dev/null | sed 's/^/  /'
        echo
    fi
    echo "===== 白名单（${ALLOW_FILE}）====="
    if [ -s "$ALLOW_FILE" ]; then
        local now addr exp note left
        now="$(date +%s)"
        while IFS=' ' read -r addr exp note; do
            [ -z "$addr" ] && continue
            if [ "${exp:-0}" -eq 0 ]; then
                left="长期"
            else
                left="$(( (exp - now) / 60 )) 分钟后过期"
            fi
            echo "  ${addr}  ${left}  ${note}"
        done < "$ALLOW_FILE"
    else
        echo "  （空：仅本机回环可访问）"
    fi
    echo
    echo "===== 风险检查 ====="
    if iptables -S INPUT | grep -q -- "-p tcp -m tcp --dport 3306 -j ACCEPT"; then
        echo "  ⚠️ 仍存在 3306 裸放行规则（建议执行 apply）"
    else
        echo "  ✅ 无 3306 裸放行规则"
    fi
}

cmd_open() {
    local addr="${1:-}" minutes="${2:-$DEFAULT_MINUTES}" note="${3:-manual}"
    if [ -z "$addr" ] || ! valid_addr "$addr"; then
        echo "用法：$0 open <IP|CIDR> [分钟，0=长期] [备注]" >&2
        exit 1
    fi
    ensure_allow_file
    local now exp
    now="$(date +%s)"
    if [ "$minutes" -eq 0 ] 2>/dev/null; then
        exp=0
    else
        exp=$(( now + minutes * 60 ))
    fi
    # 覆盖同地址旧条目
    grep -v "^${addr} " "$ALLOW_FILE" > "${ALLOW_FILE}.tmp" 2>/dev/null || true
    printf '%s %s %s\n' "$addr" "$exp" "${note// /_}" >> "${ALLOW_FILE}.tmp"
    mv "${ALLOW_FILE}.tmp" "$ALLOW_FILE"
    chmod 600 "$ALLOW_FILE"
    rebuild_all
    log "已放行 ${addr}（${minutes:-0} 分钟，备注 ${note}）"
}

cmd_close() {
    local addr="${1:-}"
    ensure_allow_file
    if [ -z "$addr" ]; then
        : > "$ALLOW_FILE"
        log "已清空全部白名单"
    else
        grep -v "^${addr} " "$ALLOW_FILE" > "${ALLOW_FILE}.tmp" 2>/dev/null || true
        mv "${ALLOW_FILE}.tmp" "$ALLOW_FILE"
        log "已撤销放行 ${addr}"
    fi
    rebuild_all
}

cmd_list() {
    if [ -s "$ALLOW_FILE" ]; then
        cat "$ALLOW_FILE"
    else
        echo "（白名单为空，仅本机回环可访问 3306）"
    fi
}

cmd_expire() {
    ensure_allow_file
    local now changed=0 addr exp note
    now="$(date +%s)"
    local tmp="${ALLOW_FILE}.tmp"
    : > "$tmp"
    while IFS=' ' read -r addr exp note; do
        [ -z "$addr" ] && continue
        if [ "${exp:-0}" -ne 0 ] && [ "${exp:-0}" -le "$now" ]; then
            log "白名单到期自动移除：${addr}（${note:-}）"
            changed=1
            continue
        fi
        printf '%s %s %s\n' "$addr" "$exp" "$note" >> "$tmp"
    done < "$ALLOW_FILE"
    mv "$tmp" "$ALLOW_FILE"
    chmod 600 "$ALLOW_FILE"
    if [ "$changed" -eq 1 ]; then
        rebuild_all
    fi
}

need_root
ensure_allow_file

case "${1:-}" in
    apply)  cmd_apply ;;
    status) cmd_status ;;
    open)   shift; cmd_open "$@" ;;
    close)  shift; cmd_close "$@" ;;
    list)   cmd_list ;;
    expire) cmd_expire ;;
    *)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
