#!/bin/bash
# 告警决策：分级、去重、是否需要发信

# 静态类告警（变化慢，重复提醒间隔更长）
alert_is_static_key() {
    case "$1" in
        sshd:*|os:*|port:*|eol:*|backup:config) return 0 ;;
        *) return 1 ;;
    esac
}

# 某条告警的去重窗口（秒）
alert_window_seconds() {
    local level="$1" key="$2"
    if [ "$level" = "CRIT" ]; then
        echo $(( ${ALERT_CRIT_DEDUPE_HOURS:-24} * 3600 ))
        return
    fi
    if alert_is_static_key "$key"; then
        echo $(( ${ALERT_STATIC_DEDUPE_DAYS:-7} * 86400 ))
    else
        echo $(( ${ALERT_WARN_DEDUPE_DAYS:-3} * 86400 ))
    fi
}

# 拆分待发/已抑制
# 用法：alert_decide <findings.tsv> <crit_out> <warn_out> <suppressed_out>
alert_decide() {
    local findings="$1" crit_out="$2" warn_out="$3" suppressed_out="$4"
    : > "$crit_out"; : > "$warn_out"; : > "$suppressed_out"

    local now last window level key title detail suggest
    now="$(now_epoch)"

    while IFS='|' read -r level key title detail suggest; do
        [ -z "${level:-}" ] && continue
        case "$level" in CRIT|WARN) ;; *) continue ;; esac

        last="$(alert_state_get "$key")"
        last="${last:-0}"
        window="$(alert_window_seconds "$level" "$key")"

        if [ "$last" -eq 0 ] || [ $(( now - last )) -ge "$window" ]; then
            if [ "$level" = "CRIT" ]; then
                printf '%s|%s|%s|%s|%s\n' "$level" "$key" "$title" "$detail" "$suggest" >> "$crit_out"
            else
                printf '%s|%s|%s|%s|%s\n' "$level" "$key" "$title" "$detail" "$suggest" >> "$warn_out"
            fi
        else
            local ago=$(( (now - last) / 3600 ))
            printf '%s|%s|%s|%s\n' "$level" "$key" "$title" "${ago}h 前已提醒，本次抑制" >> "$suppressed_out"
        fi
    done < "$findings"
}

# 记录已发送（发送成功后调用）
alert_mark_sent() {
    local file="$1" level key _rest
    [ -s "$file" ] || return 0
    while IFS='|' read -r level key _rest; do
        [ -z "${key:-}" ] && continue
        alert_state_set "$key" "$(now_epoch)" "$level"
    done < "$file"
}

# 是否需要发信（返回 0=发）
# 用法：alert_should_send <crit_file> <warn_file>
alert_should_send() {
    local crit="$1" warn="$2"
    [ "${ALERT_ENABLED:-true}" = "true" ] || return 1
    [ -s "$crit" ] && return 0
    [ -s "$warn" ] && return 0
    return 1
}

# 邮件主题里的级别
alert_subject_level() {
    local crit="$1" warn="$2"
    if [ -s "$crit" ]; then echo "P0"; else echo "P1"; fi
}
