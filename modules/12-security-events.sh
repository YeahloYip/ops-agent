#!/bin/bash
# 12-安全事件检查：SSH 暴力破解 / fail2ban 封禁 / WAF 拦截量
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

# ---- SSH 登录失败 ----
AUTH_LOG="/var/log/auth.log"
if [ -f "$AUTH_LOG" ]; then
    today_tag="$(date '+%b %e')"   # 例：Nov 11（注意日志里日期为空格填充）
    failed=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | grep -c "$today_tag" || true)
    invalid=$(grep -c "Invalid user" "$AUTH_LOG" 2>/dev/null || true)
    top_ips=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | grep "$today_tag" | \
        awk '{for(i=1;i<=NF;i++) if ($i=="from") print $(i+1)}' | sort | uniq -c | sort -rn | head -3 | \
        awk '{printf "%s(%s次) ", $2, $1}')

    if [ "${failed:-0}" -ge "${BRUTE_FORCE_WARN:-200}" ]; then
        finding WARN "attack:bruteforce" "SSH 暴力破解尝试 ${failed} 次（今日）" \
            "来源 TOP: ${top_ips:-无}" \
            "确认仅密钥登录；fail2ban sshd jail 生效；必要时改端口/加 IP 白名单"
    else
        finding INFO "attack:ssh" "SSH 今日登录失败 ${failed} 次" "TOP: ${top_ips:-无}" ""
    fi
    [ "${invalid:-0}" -gt 0 ] && finding INFO "attack:ssh-invalid" "SSH 今日无效用户尝试 ${invalid} 次" "" ""
fi

# ---- fail2ban ----
if command -v fail2ban-client >/dev/null 2>&1; then
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/[ \t]/,"",$2); print $2}' | tr ',' ' ')"
    total_banned_now=0; total_banned_all=0
    for j in $jails; do
        st="$(fail2ban-client status "$j" 2>/dev/null || true)"
        cur="$(printf '%s' "$st" | awk -F'[:,]' '/Currently banned/{gsub(/ /,"",$2); print $2}' | head -1)"
        all="$(printf '%s' "$st" | awk -F'[:,]' '/Total banned/{gsub(/ /,"",$2); print $2}' | head -1)"
        total_banned_now=$(( total_banned_now + ${cur:-0} ))
        total_banned_all=$(( total_banned_all + ${all:-0} ))
    done

    if [ "$total_banned_all" -ge "${FAIL2BAN_BAN_WARN:-50}" ]; then
        finding WARN "attack:fail2ban" "fail2ban 累计封禁 ${total_banned_all} 次（自启动以来）" \
            "jails: ${jails}，当前封禁 ${total_banned_now} 个 IP" \
            "确认封禁是否覆盖攻击源；若均为扫描器正常拦截可忽略"
    else
        finding INFO "attack:fail2ban" "fail2ban 累计封禁 ${total_banned_all} 次，当前 ${total_banned_now} 个" "jails: ${jails}" ""
    fi
fi

# ---- WAF 拦截量（当日） ----
DAY_TAG="$(date '+%d/%b/%Y')"
waf_total=0
for f in "${LOGDIR}"/*.log; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *error*) continue ;; esac
    n=$(grep -F "$DAY_TAG" "$f" 2>/dev/null | grep -c '" 403 ' || true)
    waf_total=$(( waf_total + ${n:-0} ))
done
finding INFO "attack:waf" "WAF 今日拦截 ${waf_total} 次" "扫描器探测属正常，仅作参考" ""
