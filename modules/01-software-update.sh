#!/bin/bash
# 01-软件更新检查：安全更新 / 系统 EOL / 源状态
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

# 是否处于 EOL 归档源
if grep -qriE "archive\.debian\.org|old-releases" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    finding WARN "os:eol" "系统已停止维护（${OS_NAME}）" \
        "apt 源指向归档库，自 ${OS_EOL_DATE} 起无安全更新可安装" \
        "规划系统升级（如 Debian 12）或迁移；过渡期加强 WAF/fail2ban 与入侵检测"
fi

upgradable="$(timeout 60 apt list --upgradable 2>/dev/null || true)"
security_count=$(printf '%s\n' "$upgradable" | grep -ci 'security' || true)
total_count=$(printf '%s\n' "$upgradable" | grep -v '^Listing' | grep -c . || true)

if [ "${security_count:-0}" -gt 0 ]; then
    finding CRIT "update:security" "有 ${security_count} 个安全更新待安装" \
        "$(printf '%s\n' "$upgradable" | grep -i security | head -5 | tr '\n' ';')" \
        "执行 apt-get upgrade 并重启相关服务"
elif [ "${total_count:-0}" -gt 0 ]; then
    finding INFO "update:normal" "有 ${total_count} 个非安全更新可安装" "" ""
else
    finding INFO "update:none" "无可用更新（归档源已冻结）" "" ""
fi

# apt 元数据是否长期未更新
lists_dir="/var/lib/apt/lists"
if [ -d "$lists_dir" ]; then
    newest="$(find "$lists_dir" -name '*Release' -newermt '-30 days' 2>/dev/null | head -1)"
    if [ -z "$newest" ]; then
        finding WARN "update:apt-stale" "apt 索引超过 30 天未更新" "无法确认补丁状态" "检查 apt update 是否可用（EOL 后归档源可正常更新索引）"
    fi
fi
