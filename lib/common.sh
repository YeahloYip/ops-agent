#!/bin/bash
# 公共工具函数：配置加载、finding 输出、状态读写、文本处理

# 定位仓库根目录（lib/ 的上一级）
OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 统一 PATH：cron 默认 PATH 只有 /usr/bin:/bin，缺少 /usr/sbin，
# 会导致 iptables / ss / nginx 等系统命令找不到而产生误报。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# 查找 iptables 可执行文件（PATH 异常时兜底绝对路径）
iptables_bin() {
    local b
    b="$(command -v iptables 2>/dev/null || true)"
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
    for b in /usr/sbin/iptables /sbin/iptables /usr/local/sbin/iptables; do
        [ -x "$b" ] && { printf '%s' "$b"; return 0; }
    done
    return 1
}

# 加载配置（调用方通常已 source，这里做兜底）
if [ ! -f "${OPS_ROOT}/config.env" ]; then
    echo "缺少 ${OPS_ROOT}/config.env" >&2
    echo "请先执行：cp ${OPS_ROOT}/config.env.example ${OPS_ROOT}/config.env && chmod 600 ${OPS_ROOT}/config.env" >&2
    exit 1
fi
if [ -z "${SERVER_NAME:-}" ]; then
    # shellcheck disable=SC1090
    source "${OPS_ROOT}/config.env"
fi

STATE_DIR="${OPS_ROOT}/logs/.state"
mkdir -p "$STATE_DIR"

# ---- finding 输出 -----------------------------------------------------------
# 格式：LEVEL|KEY|TITLE|DETAIL|SUGGEST
# LEVEL: CRIT / WARN / INFO / OK
finding() {
    local level="$1" key="$2" title="$3" detail="${4:-}" suggest="${5:-}"
    # 去除换行与分隔符，保证单行输出
    detail="$(printf '%s' "$detail" | tr '\n|' '  ' | sed 's/  */ /g' | cut -c1-500)"
    suggest="$(printf '%s' "$suggest" | tr '\n|' '  ' | sed 's/  */ /g' | cut -c1-300)"
    printf '%s|%s|%s|%s|%s\n' "$level" "$key" "$title" "$detail" "$suggest"
}

# ---- 时间与数值 -------------------------------------------------------------
now_epoch() { date +%s; }
today()     { date "+%Y-%m-%d"; }

# 整数安全比较：ge_num A B  → A >= B 时返回 0
ge_num() { [ "$(printf '%s' "${1:-0}" | tr -dc '0-9')" -ge "$(printf '%s' "${2:-0}" | tr -dc '0-9')" ] 2>/dev/null; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ---- 状态文件 ---------------------------------------------------------------
# 键值状态：state_kv_get KEY / state_kv_set KEY VALUE
state_kv_get() {
    local file="${STATE_DIR}/kv.tsv"
    [ -f "$file" ] || { echo ""; return; }
    awk -F'\t' -v k="$1" '$1==k{print $2; found=1} END{if(!found) print ""}' "$file"
}

state_kv_set() {
    local file="${STATE_DIR}/kv.tsv" key="$1" val="$2" tmp
    touch "$file"
    tmp="$(mktemp)"
    awk -F'\t' -v k="$key" '$1!=k' "$file" > "$tmp"
    printf '%s\t%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$file"
}

# 告警去重表：alert_state_get KEY → 上次发送的 epoch（无则 0）
alert_state_get() {
    local file="${STATE_DIR}/alerted.tsv"
    [ -f "$file" ] || { echo 0; return; }
    local v
    v="$(awk -F'\t' -v k="$1" '$1==k{print $2}' "$file" | tail -1)"
    echo "${v:-0}"
}

alert_state_set() {
    local file="${STATE_DIR}/alerted.tsv" key="$1" epoch="$2" level="$3" tmp
    touch "$file"
    tmp="$(mktemp)"
    awk -F'\t' -v k="$key" '$1!=k' "$file" > "$tmp"
    printf '%s\t%s\t%s\n' "$key" "$epoch" "$level" >> "$tmp"
    mv "$tmp" "$file"
}

# ---- 通用文本处理 -----------------------------------------------------------
# 安全计数：不产生 "0\n0"
count_lines() { grep -c . 2>/dev/null || true; }

# 取第一个数字（无则 0）
first_num() { grep -oE '[0-9]+' <<<"${1:-}" | head -1 | grep . || echo 0; }
