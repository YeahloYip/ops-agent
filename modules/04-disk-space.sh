#!/bin/bash
# 04-磁盘空间与 inode 检查（含增长趋势）
OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "${OPS_ROOT}/config.env"
# shellcheck disable=SC1091
source "${OPS_ROOT}/lib/common.sh"

today_epoch="$(now_epoch)"

df -P -h 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// && $1 !~ /loop/' | while read -r fs size used avail pct mount; do
    pct_num="${pct%\%}"
    case "$pct_num" in ''|*[!0-9]*) continue ;; esac

    if [ "$pct_num" -ge "${DISK_CRIT_PERCENT:-90}" ]; then
        finding CRIT "disk:${mount}" "磁盘 ${mount} 使用率 ${pct_num}%（严重）" \
            "已用 ${used} / 剩余 ${avail}" \
            "立即清理日志/备份/临时文件：du -xh --max-depth=1 / | sort -h"
    elif [ "$pct_num" -ge "${DISK_WARN_PERCENT:-85}" ]; then
        finding WARN "disk:${mount}" "磁盘 ${mount} 使用率 ${pct_num}%" \
            "已用 ${used} / 剩余 ${avail}" "清理过期日志、旧备份，或扩容"
    else
        finding INFO "disk:${mount}" "磁盘 ${mount} 使用率 ${pct_num}%" "剩余 ${avail}" ""
    fi

    # 日增长检测（对比上次运行记录）
    prev="$(state_kv_get "disk:${mount}")"
    if [ -n "$prev" ]; then
        prev_pct="${prev%%:*}"
        prev_epoch="${prev##*:}"
        gap=$(( today_epoch - prev_epoch ))
        if [ "${prev_pct:-0}" -lt "$pct_num" ] && [ "$gap" -gt 3600 ]; then
            days=$(( gap / 86400 )); [ "$days" -lt 1 ] && days=1
            growth=$(( (pct_num - prev_pct) / days ))
            if [ "$growth" -ge "${DISK_GROWTH_PERCENT:-5}" ]; then
                finding WARN "disk-growth:${mount}" "磁盘 ${mount} 每天增长约 ${growth}%" \
                    "${prev_pct}% → ${pct_num}%（${days} 天）" \
                    "确认增长来源（日志/备份/网站上传），设置日志轮转或清理任务"
            fi
        fi
    fi
    state_kv_set "disk:${mount}" "${pct_num}:${today_epoch}"
done

# inode 使用率
df -P -i 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// && $1 !~ /loop/' | while read -r fs itotal iused ifree ipct mount; do
    ipct_num="${ipct%\%}"
    case "$ipct_num" in ''|*[!0-9]*) continue ;; esac
    if [ "$ipct_num" -ge "${INODE_WARN_PERCENT:-85}" ]; then
        finding WARN "inode:${mount}" "inode ${mount} 使用率 ${ipct_num}%" \
            "已用 ${iused}/${itotal}" "查找小文件堆积：find ${mount} -xdev -type f | wc -l"
    fi
done
