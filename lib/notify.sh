#!/bin/bash
# 邮件通知模块（HTML 报告，使用 /etc/msmtprc 账户 qq）

MAIL_LOG="${OPS_ROOT:-$(dirname "$0")/..}/logs/.state/mail.log"

# RFC 2047 编码邮件主题（中文主题必须编码，否则客户端显示乱码）
encode_subject() {
    local s="$1"
    # 按字符截断，避免切坏多字节（需 UTF-8 locale）
    s="${s:0:60}"
    printf '=?UTF-8?B?%s?=' "$(printf '%s' "$s" | base64 | tr -d '\n')"
}

# 发送 HTML 邮件；返回 0 成功
# 用法：send_email "主题" "<html>正文</html>" [收件人]
send_email() {
    local subject="$1"
    local body="$2"
    local recipient="${3:-${MAIL_TO:-ops@example.com}}"
    local err rc subject_enc

    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
    subject_enc="$(encode_subject "$subject")"

    mkdir -p "$(dirname "$MAIL_LOG")"
    err="$(mktemp)"

    {
        printf 'From: %s\n' "${MAIL_FROM:-$recipient}"
        printf 'To: %s\n' "$recipient"
        printf 'Subject: %s\n' "$subject_enc"
        printf 'Date: %s\n' "$(date -R)"
        printf 'Message-ID: <ops-agent-%s.%s@%s>\n' "$(date +%s)" "$$" "${SERVER_NAME:-localhost}"
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: text/html; charset=UTF-8\n'
        printf 'Content-Transfer-Encoding: 8bit\n'
        printf 'X-Mailer: ops-agent\n'
        printf 'Precedence: bulk\n'
        printf '\n'
        printf '%s\n' "$body"
    } | /usr/bin/msmtp -a "${MSMTP_ACCOUNT:-default}" -t >/dev/null 2>"$err"
    rc=$?

    {
        printf '%s rc=%s to=%s subject=%s\n' "$(date '+%F %T')" "$rc" "$recipient" "$subject"
        [ -s "$err" ] && sed 's/^/  stderr: /' "$err"
    } >> "$MAIL_LOG"
    rm -f "$err"
    return $rc
}

# HTML 转义
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# 级别 → 展示样式
level_color() {
    case "$1" in
        CRIT) echo "#c62828" ;;
        WARN) echo "#ef6c00" ;;
        INFO) echo "#1565c0" ;;
        *)    echo "#2e7d32" ;;
    esac
}
