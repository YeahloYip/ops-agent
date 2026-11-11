#!/bin/bash
# 10-系统资源检查：负载 / 内存 / swap（新增）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

cores="$(nproc 2>/dev/null || echo 1)"
read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null

warn_load="$(awk -v c="$cores" -v f="${LOAD_WARN_FACTOR:-1.5}" 'BEGIN{printf "%.2f", c*f}')"
crit_load="$(awk -v c="$cores" -v f="${LOAD_CRIT_FACTOR:-3}" 'BEGIN{printf "%.2f", c*f}')"

if awk -v l="$load1" -v t="$crit_load" 'BEGIN{exit !(l+0>t+0)}'; then
    finding CRIT "res:load" "系统负载过高：1 分钟负载 ${load1}（${cores} 核）" \
        "load1=${load1} load5=${load5} load15=${load15}，阈值 ${crit_load}" \
        "top 查看高 CPU 进程：ps aux --sort=-%cpu | head; 检查是否有异常进程/被挖矿"
elif awk -v l="$load1" -v t="$warn_load" 'BEGIN{exit !(l+0>t+0)}'; then
    finding WARN "res:load" "系统负载偏高：1 分钟负载 ${load1}（${cores} 核）" \
        "load1=${load1} load5=${load5} load15=${load15}" \
        "观察是否持续；查 TOP CPU 进程与慢查询"
else
    finding INFO "res:load" "系统负载正常 ${load1}（${cores} 核）" "" ""
fi

# ---- 内存 ----
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
[ -z "${mem_avail_kb:-}" ] && mem_avail_kb=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
mem_avail_mb=$(( mem_avail_kb / 1024 ))
mem_used_pct=$(( (mem_total_kb - mem_avail_kb) * 100 / mem_total_kb ))

if [ "$mem_avail_mb" -lt "${MEM_AVAIL_CRIT_MB:-150}" ]; then
    finding CRIT "res:mem" "可用内存不足：剩余 ${mem_avail_mb}MB（已用 ${mem_used_pct}%）" \
        "MemAvailable ${mem_avail_mb}MB / MemTotal $((mem_total_kb/1024))MB" \
        "ps aux --sort=-%mem | head 定位占用；必要时重启异常服务"
elif [ "$mem_used_pct" -ge 90 ]; then
    finding WARN "res:mem" "内存使用率 ${mem_used_pct}%（剩余 ${mem_avail_mb}MB）" "" "观察是否持续升高；检查 PHP-FPM 进程数"
else
    finding INFO "res:mem" "内存使用率 ${mem_used_pct}%（剩余 ${mem_avail_mb}MB）" "" ""
fi

# ---- swap ----
swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
swap_free_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
if [ "${swap_total_kb:-0}" -gt 0 ]; then
    swap_used_pct=$(( (swap_total_kb - swap_free_kb) * 100 / swap_total_kb ))
    if [ "$swap_used_pct" -ge "${SWAP_WARN_PERCENT:-80}" ]; then
        finding WARN "res:swap" "swap 使用率 ${swap_used_pct}%" \
            "$(( (swap_total_kb - swap_free_kb) / 1024 ))MB / $(( swap_total_kb / 1024 ))MB" \
            "内存不足的表现，检查 PHP-FPM pm.max_children 与 MySQL 缓冲池"
    else
        finding INFO "res:swap" "swap 使用率 ${swap_used_pct}%" "" ""
    fi
fi

# ---- TOP CPU 进程（供人工参考）----
top_cpu="$(ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && NR<=6 {printf "%s(%s%%,%s%%mem) ", $3,$1,$2}')"
finding INFO "res:top" "占用最高的进程" "${top_cpu:-N/A}" ""
