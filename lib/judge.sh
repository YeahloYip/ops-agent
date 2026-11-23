#!/bin/bash
# LLM 判定闸门：用 opencode zen 免费模型判断 WARN 项是否真的需要人工处理
#
# 设计原则：
#   1. CRIT 项由规则直接决定发信，不经过 LLM（LLM 只能升级，不能降级）
#   2. LLM 只负责过滤 WARN 噪音，减少每日邮件
#   3. 模型动态选择：优先 `opencode models` 中名字带 free 的模型，失败自动切换下一个
#      —— 免费模型随时可能下线/改名，因此不写死，按"free 关键字"动态发现
#   4. LLM 不可用时按配置回退（JUDGE_FALLBACK_NOTIFY / JUDGE_FALLBACK_WARN_MIN）

JUDGE_AUDIT="${STATE_DIR:-/tmp}/judge-$(date +%F).log"

judge_available() {
    [ "${JUDGE_ENABLED:-true}" = "true" ] || return 1
    if ! command -v opencode >/dev/null 2>&1; then
        for p in /root/.opencode/bin/opencode /root/.local/bin/opencode /usr/local/bin/opencode; do
            if [ -x "$p" ]; then
                PATH="$(dirname "$p"):$PATH"
                export PATH
                break
            fi
        done
    fi
    command -v opencode >/dev/null 2>&1
}

# 名字里带 free 的模型（排除视觉/小模型）
judge_list_free_models() {
    opencode models 2>/dev/null \
        | grep -i 'free' \
        | grep -vE 'vl|small|embed' \
        | sort -u
}

# 按偏好排序：推理/通用能力强的免费模型优先
_judge_rank_models() {
    local free="$1" ranked="" m pref
    for pref in deepseek glm minimax mimo qwen longcat nemotron flint inkling beam iceman; do
        for m in $free; do
            case "$m" in *"$pref"*) ranked="$ranked $m" ;; esac
        done
    done
    for m in $free; do
        case " $ranked " in *" $m "*) ;; *) ranked="$ranked $m" ;; esac
    done
    printf '%s' "$ranked"
}

# 生成候选模型列表：上次成功 → 配置 → 动态发现的 free 模型
judge_candidate_models() {
    local cached free configured out="" m
    cached="$(state_kv_get judge:model)"
    free="$(judge_list_free_models | tr '\n' ' ')"
    configured="${JUDGE_MODELS:-}"

    # 上次成功的模型仍然存在（或 free 列表为空时）优先
    if [ -n "$cached" ]; then
        if [ -z "$free" ] || printf ' %s ' "$free" | grep -qF " $cached "; then
            out="$out $cached"
        fi
    fi

    # 配置里显式列出的模型（JUDGE_FREE_ONLY=true 时只保留带 free 的）
    for m in $configured; do
        if [ "${JUDGE_FREE_ONLY:-true}" = "true" ]; then
            case "$m" in *free*) ;; *) continue ;; esac
        fi
        out="$out $m"
    done

    # 动态发现的免费模型（按偏好排序）
    out="$out $(_judge_rank_models "$free")"

    # 去重 + 截断
    local result="" seen=" " count=0 max="${JUDGE_MAX_ATTEMPTS:-6}"
    for m in $out; do
        case "$seen" in *" $m "*) continue ;; esac
        seen="$seen$m "
        result="$result $m"
        count=$((count + 1))
        [ "$count" -ge "$max" ] && break
    done
    printf '%s\n' $result
}

# 从模型输出里提取 JSON 并校验
_judge_extract_json() {
    local text="$1" raw json
    raw="$(printf '%s' "$text" | tr -d '\r\n' | sed -E 's/```(json)?//g')"
    json="$(printf '%s' "$raw" | grep -oE '\{.*\}' | head -1)"
    [ -z "$json" ] && return 1
    printf '%s' "$json" | jq -e 'has("notify")' >/dev/null 2>&1 || return 1
    printf '%s' "$json"
}

# 调用单模型，成功输出 JSON
_judge_call_model() {
    local model="$1" prompt_file="$2" out text
    out="$(timeout "${JUDGE_TIMEOUT:-120}" opencode run --format json -m "$model" \
            < "$prompt_file" 2>/dev/null)"
    text="$(printf '%s\n' "$out" | jq -r 'select(.type=="text") | .part.text' 2>/dev/null | tr -d '\n')"
    _judge_extract_json "$text"
}

# 主入口
# 用法：judge_should_notify <crit_tsv> <warn_tsv> <all_findings_tsv>
# 成功时设置 JUDGE_NOTIFY / JUDGE_SEVERITY / JUDGE_SUMMARY / JUDGE_ITEMS_FILE / JUDGE_MODEL_USED
# 返回 0=判定成功，1=LLM 不可用/全部模型失败
judge_should_notify() {
    local crit_file="$1" warn_file="$2" all_file="$3"
    JUDGE_NOTIFY=""; JUDGE_SEVERITY=""; JUDGE_SUMMARY=""; JUDGE_ITEMS_FILE=""; JUDGE_MODEL_USED=""

    judge_available || return 1

    local prompt_file tmpdir items_file
    tmpdir="$(mktemp -d)"
    prompt_file="${tmpdir}/prompt.txt"
    items_file="${tmpdir}/items.txt"
    : > "$items_file"

    local findings_text
    findings_text="$(awk -F'|' '{printf "[%s] %s: %s — %s\n", $1,$3,$4,$5}' "$all_file" 2>/dev/null | head -60)"
    [ -z "$findings_text" ] && { rm -rf "$tmpdir"; return 1; }

    cat > "$prompt_file" <<EOF
你是资深 SRE，负责判断服务器每日巡检结果中，哪些事项必须在 24 小时内人工处理。

服务器：${SERVER_NAME:-unknown} (${SERVER_IP:-unknown})，${OS_NAME:-Linux}，运行 Web 服务（nginx + PHP-FPM + MySQL）。
已知背景（这些属于正常，不要告警）：
- 公网每天有大量扫描器探测，WAF 会拦截并返回 403，属正常。
- 证书由 acme.sh 自动续签，续签成功即正常。
- 数据库每日自动备份并上传对象存储。
- 单机资源有限，swap 有使用较常见，只要内存可用不为 0 即可。

判定标准（严格）：
- 只有会导致「业务中断、数据丢失、安全事件、证书过期、资源耗尽、备份不可用」的才算需要处理。
- 扫描器探测、WAF 正常拦截、访问日志噪声、系统 EOL 提示（已多次提醒）、可延后数周的小问题 → 不算。
- 同一问题已持续多日且未恶化，可按"观察"处理，不要求立即处理。
- 不确定时倾向 false。

今日巡检结果：
${findings_text}

输出要求：
- 只输出一个 JSON 对象，不要 markdown 代码块，不要任何解释文字。
- 格式：
{"notify":true|false,"severity":"critical|warning|none","summary":"一句话结论","items":[{"key":"对应条目的标题关键词","why":"为什么必须处理","action":"建议动作"}]}
- notify=false 时 items 为空数组。
EOF

    local models model json rc=1 start dur
    models="$(judge_candidate_models)"
    if [ -z "$models" ]; then
        printf '%s 无可用的 free 模型（opencode models 为空）\n' "$(date '+%F %T')" >> "$JUDGE_AUDIT"
        rm -rf "$tmpdir"
        return 1
    fi

    for model in $models; do
        start="$(now_epoch)"
        if json="$(_judge_call_model "$model" "$prompt_file")"; then
            dur=$(( $(now_epoch) - start ))
            {
                printf '%s model=%s result=OK %ss json=%s\n' \
                    "$(date '+%F %T')" "$model" "$dur" "$(printf '%s' "$json" | cut -c1-400)"
            } >> "$JUDGE_AUDIT"

            JUDGE_NOTIFY="$(printf '%s' "$json" | jq -r '.notify // false')"
            JUDGE_SEVERITY="$(printf '%s' "$json" | jq -r '.severity // "none"')"
            JUDGE_SUMMARY="$(printf '%s' "$json" | jq -r '.summary // ""')"
            printf '%s' "$json" | jq -r '.items[]? | "\(.key // "-")|\(.why // "")|\(.action // "")"' > "$items_file"
            JUDGE_MODEL_USED="$model"
            # 记住可用模型，下次优先使用
            state_kv_set judge:model "$model"
            state_kv_set judge:model_ok_at "$(date '+%F %T')"
            cp "$items_file" "${STATE_DIR}/judge-items-$(date +%F).tsv" 2>/dev/null || true
            JUDGE_ITEMS_FILE="${STATE_DIR}/judge-items-$(date +%F).tsv"
            rc=0
            break
        else
            dur=$(( $(now_epoch) - start ))
            {
                printf '%s model=%s result=FAIL %ss\n' "$(date '+%F %T')" "$model" "$dur"
            } >> "$JUDGE_AUDIT"
        fi
    done

    if [ "$rc" -ne 0 ]; then
        printf '%s all-free-models-failed tried=%s\n' "$(date '+%F %T')" "$(printf '%s' "$models" | tr '\n' ' ')" >> "$JUDGE_AUDIT"
        state_kv_set judge:model ""
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}
