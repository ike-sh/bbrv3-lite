# -----------------------------------------------------------------------------
# Reliability/diagnostics: failure taxonomy, bounded history, preflight,
# read-only doctor/export, and auto dry-run. No runtime networking is changed.
# -----------------------------------------------------------------------------

FAILURE_SCHEMA="1"
HISTORY_SCHEMA="1"
MAX_HISTORY_ENTRIES="${BBRV3_MAX_HISTORY_ENTRIES:-20}"
if ! is_uint "$MAX_HISTORY_ENTRIES" || (( MAX_HISTORY_ENTRIES < 1 || MAX_HISTORY_ENTRIES > 1000 )); then MAX_HISTORY_ENTRIES=20; fi
FAILURE_STAGE=""
FAILURE_REASON=""
FAILURE_DETAIL=""
FAILURE_SUGGESTION=""

failure_reset() {
    FAILURE_STAGE=""; FAILURE_REASON=""; FAILURE_DETAIL=""; FAILURE_SUGGESTION=""
}

failure_pending_write() {
    local file="${MEASURE_RUN_DIR:-}/.failure-pending.tsv" temp
    [[ -n "${MEASURE_RUN_DIR:-}" && "$MEASURE_RUN_DIR" == "$HISTORY_DIR/"* && -d "$MEASURE_RUN_DIR" && ! -L "$MEASURE_RUN_DIR" ]] || return 0
    temp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! printf 'STAGE\t%s\nREASON\t%s\nDETAIL\t%s\nSUGGESTION\t%s\n' \
        "$FAILURE_STAGE" "$FAILURE_REASON" "$FAILURE_DETAIL" "$FAILURE_SUGGESTION" > "$temp"; then
        rm -f -- "$temp"; return 1
    fi
    chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
    mv -f -- "$temp" "$file"
}

failure_pending_load() {
    local file="$1" line key value stage="" reason="" detail="" suggestion=""
    local -A seen=()
    [[ -f "$file" && ! -L "$file" && "$file" == "$HISTORY_DIR/"*/.failure-pending.tsv ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* ]] || return 1
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -z "${seen[$key]+x}" && "$value" != *$'\t'* && "$value" != *$'\n'* ]] || return 1
        seen[$key]=1
        case "$key" in
            STAGE) stage="$value" ;; REASON) reason="$value" ;; DETAIL) detail="$value" ;; SUGGESTION) suggestion="$value" ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ "$stage" =~ ^[A-Z][A-Z0-9_]{1,47}$ ]] && failure_reason_valid "$reason" || return 1
    [[ -n "${seen[DETAIL]+x}" && -n "${seen[SUGGESTION]+x}" ]] || return 1
    FAILURE_STAGE="$stage"; FAILURE_REASON="$reason"; FAILURE_DETAIL="$detail"; FAILURE_SUGGESTION="$suggestion"
}

failure_reason_valid() {
    case "$1" in
        peer-unavailable|peer-busy|peer-reset|peer-timeout|peer-too-slow|path-dirty|path-changed|endpoint-changed|\
        route-ambiguous|nexthop-unresolved|sample-contaminated|cpu-busy|high-steal|measurement-unstable|\
        budget-exceeded|no-clean-reference|no-knee-confidence|candidate-confirm-failed|verify-throughput-failed|\
        verify-retrans-failed|tc-ownership-conflict|runtime-verify-failed|rollback-failed|protocol-failure|\
        dependency-missing|disk-space-low|memory-low|background-traffic|internal-error|none) return 0 ;;
        *) return 1 ;;
    esac
}

failure_reason_explanation() {
    case "$1" in
        peer-unavailable) printf '测速对端当前不可用' ;;
        peer-busy) printf '测速对端正在服务其他测试' ;;
        peer-reset) printf '测速连接被对端重置' ;;
        peer-timeout) printf '测速连接或测试超时' ;;
        peer-too-slow) printf '对端吞吐不足以建立可靠控制样本' ;;
        path-dirty) printf '低速路径控制样本存在显著重传' ;;
        path-changed) printf '测量期间网络路径发生变化' ;;
        endpoint-changed) printf '测量期间测速端点发生变化' ;;
        route-ambiguous) printf '无法证明唯一且稳定的出口路径' ;;
        nexthop-unresolved) printf 'Linux nexthop object 无法解析为唯一 leaf' ;;
        sample-contaminated) printf '样本受到背景流量或本机资源竞争污染' ;;
        cpu-busy) printf 'CPU 忙碌度过高，测速结果可能受本机限制' ;;
        high-steal) printf '虚拟机 CPU steal 过高' ;;
        measurement-unstable) printf '重复样本离散度过高' ;;
        budget-exceeded) printf '测量流量或时间硬预算已耗尽' ;;
        no-clean-reference) printf '无法建立低速干净参考' ;;
        no-knee-confidence) printf '没有足够证据定位拐点' ;;
        candidate-confirm-failed) printf '候选速率未通过确认测试' ;;
        verify-throughput-failed) printf '最终复验吞吐未达到安全门槛' ;;
        verify-retrans-failed) printf '最终复验重传超过安全门槛' ;;
        tc-ownership-conflict) printf 'root qdisc 不属于本项目，拒绝接管' ;;
        runtime-verify-failed) printf '运行时状态与预期配置不一致' ;;
        rollback-failed) printf '系统状态自动回滚未完整完成' ;;
        dependency-missing) printf '缺少所需的本地命令' ;;
        disk-space-low) printf '状态目录或临时目录可用空间不足' ;;
        memory-low) printf '可用内存不足以安全执行测速' ;;
        background-traffic) printf '接口现有背景流量过高' ;;
        protocol-failure) printf 'iperf3 协议或结果解析失败' ;;
        none) printf '无' ;;
        *) printf '内部操作失败' ;;
    esac
}

failure_default_suggestion() {
    case "$1" in
        peer-*) printf '稍后重试，或使用自有 iperf3 服务端。' ;;
        path-*|endpoint-*|route-*|nexthop-*) printf '检查路由、策略路由与默认出口稳定性，然后重新测量。' ;;
        cpu-busy|high-steal|sample-contaminated|background-traffic) printf '停止其他高负载任务并等待线路空闲后重试。' ;;
        budget-exceeded) printf '提高显式预算或改用 quick profile 后重新开始；本次不会复用未验证候选。' ;;
        tc-ownership-conflict) printf '先确认并由原管理工具移除第三方 qdisc；本项目不会强制覆盖。' ;;
        rollback-failed) printf '立即运行 bbr doctor，并依据保留的事务快照人工检查。' ;;
        *) printf '运行 bbr doctor 查看只读诊断，再根据具体差异处理。' ;;
    esac
}

state_safe_text() {
    local value="$1" limit="${2:-512}"
    value=${value//$'\t'/ }; value=${value//$'\r'/ }; value=${value//$'\n'/ }
    value=$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\010\013\014\016-\037\177')
    printf '%s' "${value:0:limit}"
}

failure_set() {
    local stage="$1" reason="$2" detail="${3:-}" suggestion="${4:-}" rc="${5:-1}"
    [[ "$stage" =~ ^[A-Z][A-Z0-9_]{1,47}$ ]] || stage=UNKNOWN
    failure_reason_valid "$reason" || reason=internal-error
    detail=$(state_safe_text "$detail" 240); suggestion=$(state_safe_text "$suggestion" 240)
    FAILURE_STAGE="$stage"; FAILURE_REASON="$reason"; FAILURE_DETAIL="$detail"
    FAILURE_SUGGESTION="${suggestion:-$(failure_default_suggestion "$reason")}"; : "$rc"
    failure_pending_write || true
}

failure_from_rc() {
    local rc="$1" stage="${2:-MEASUREMENT}"
    case "$rc" in
        "$IPERF_UNAVAILABLE_RC") failure_set "$stage" peer-unavailable "public endpoint unavailable" "" "$rc" ;;
        "$IPERF_CONTAMINATED_RC") failure_set "$stage" sample-contaminated "sample contamination threshold exceeded" "" "$rc" ;;
        "$IPERF_UNSTABLE_RC") failure_set "$stage" measurement-unstable "sample spread threshold exceeded" "" "$rc" ;;
        "$MEASURE_PATH_QUALITY_RC") failure_set PATH_CONTROL path-dirty "low-rate path control was not clean" "" "$rc" ;;
        "$MEASURE_ROUTE_MISMATCH_RC") failure_set ROUTE_GUARD path-changed "route fingerprint changed" "" "$rc" ;;
        "${MEASURE_BUDGET_RC:-70}") failure_set "${MEASURE_BUDGET_STAGE:-$stage}" budget-exceeded "measurement hard budget reached" "" "$rc" ;;
        "$MEASUREMENT_PREFLIGHT_RC") [[ -n "$FAILURE_REASON" ]] || failure_set PREFLIGHT sample-contaminated "environment preflight rejected measurement" "" "$rc" ;;
        "$ROLLBACK_FAILURE_RC") failure_set ROLLBACK rollback-failed "restoration did not complete" "" "$rc" ;;
        2) [[ -n "$FAILURE_REASON" ]] || failure_set "$stage" no-knee-confidence "measurement evidence was inconclusive" "" "$rc" ;;
        *) [[ -n "$FAILURE_REASON" ]] || failure_set "$stage" internal-error "operation exited with rc=$rc" "" "$rc" ;;
    esac
}

failure_record_write() {
    local dir="$1" stage="$2" reason="$3" detail="$4" rc="$5" rollback="$6" persistent="$7"
    local original_stage="${8:-}" original_reason="${9:-}" original_rc="${10:-}" failure_file="$dir/failure.tsv" temp
    [[ "$dir" == "$HISTORY_DIR/"* && -d "$dir" && ! -L "$dir" ]] || return 1
    temp=$(mktemp "${failure_file}.tmp.XXXXXX") || return 1
    if ! printf 'SCHEMA\t%s\nSTAGE\t%s\nREASON\t%s\nEXPLANATION\t%s\nDETAIL\t%s\nRC\t%s\nROLLBACK\t%s\nPERSISTENT_CHANGES\t%s\nSUGGESTION\t%s\n' \
        "$FAILURE_SCHEMA" "$stage" "$reason" "$(failure_reason_explanation "$reason")" \
        "$(history_safe_value "$detail")" "$rc" "$rollback" "$persistent" \
        "$(history_safe_value "$(failure_default_suggestion "$reason")")" > "$temp"; then
        rm -f -- "$temp"; return 1
    fi
    if [[ -n "$original_reason" ]]; then
        printf 'ORIGINAL_STAGE\t%s\nORIGINAL_REASON\t%s\nORIGINAL_RC\t%s\n' \
            "$original_stage" "$original_reason" "$original_rc" >> "$temp" || { rm -f -- "$temp"; return 1; }
    fi
    chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
    mv -f -- "$temp" "$failure_file"
}

history_safe_value() {
    state_safe_text "$1" 512
}

history_summary_update() {
    local file="$1" temp key value
    local -A replace=()
    [[ "$file" == "$HISTORY_DIR/"*/summary.tsv && ! -L "$file" ]] || return 1
    shift
    (( $# % 2 == 0 )) || return 1
    while (($# >= 2)); do
        key="$1"; value="$2"; shift 2
        [[ "$key" =~ ^[A-Z][A-Z0-9_]{1,63}$ ]] || return 1
        replace[$key]="$(history_safe_value "$value")"
    done
    temp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if [[ -f "$file" ]]; then
        awk -F'\t' -v keys="$(printf '%s,' "${!replace[@]}")" '
            BEGIN {n=split(keys,a,","); for(i=1;i<=n;i++) drop[a[i]]=1}
            !($1 in drop) {print}
        ' "$file" > "$temp" || { rm -f -- "$temp"; return 1; }
    fi
    for key in "${!replace[@]}"; do printf '%s\t%s\n' "$key" "${replace[$key]}" >> "$temp"; done
    chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
    mv -f -- "$temp" "$file"
}

measurement_finalize_run() {
    local kind="$1" peer="$2" port="$3" iface="$4" rc="$5" rollback="${6:-complete}"
    local summary="${MEASURE_RUN_DIR:-}/summary.tsv" pending="${MEASURE_RUN_DIR:-}/.failure-pending.tsv"
    local result=SUCCESS reason=none stage=COMPLETE detail="" suggestion="" persistent=none
    [[ -n "${MEASURE_RUN_DIR:-}" && "$MEASURE_RUN_DIR" == "$HISTORY_DIR/"* && -d "$MEASURE_RUN_DIR" ]] || return 0
    if declare -F measurement_usage_update >/dev/null; then measurement_usage_update || true; fi
    if (( rc != 0 )); then
        failure_pending_load "$pending" 2>/dev/null || failure_from_rc "$rc" "${MEASURE_BUDGET_STAGE:-MEASUREMENT}"
        result=FAILURE; reason="$FAILURE_REASON"; stage="$FAILURE_STAGE"; detail="$FAILURE_DETAIL"; suggestion="$FAILURE_SUGGESTION"
    fi
    [[ "$rollback" != failed ]] || persistent=temporary-state-unknown
    history_summary_update "$summary" \
        HISTORY_SCHEMA "$HISTORY_SCHEMA" TYPE "$kind" PEER "$peer" PORT "${port:-none}" INTERFACE "$iface" RESULT "$result" \
        FAILURE_STAGE "$stage" FAILURE_REASON "$reason" FAILURE_DETAIL "$detail" SUGGESTED_ACTION "$suggestion" \
        INTERNAL_RC "$rc" ROLLBACK_RESULT "$rollback" PERSISTENT_CHANGES "$persistent" COMPLETED_AT "$(utc_now)" \
        MEASUREMENT_PROFILE "${MEASUREMENT_PROFILE:-standard}" TEST_TX_BYTES_USED "${TEST_TX_BYTES_USED:-0}" \
        TEST_RX_BYTES_USED "${TEST_RX_BYTES_USED:-0}" TEST_DURATION_USED "${TEST_DURATION_USED:-0}" \
        MAX_TEST_TX_BYTES "${MEASURE_MAX_TX_BYTES:-0}" MAX_TEST_DURATION_SECONDS "${MEASURE_MAX_DURATION_SECONDS:-0}" || return 1
    if (( rc != 0 )); then
        failure_record_write "$MEASURE_RUN_DIR" "$stage" "$reason" "$detail" "$rc" "$rollback" "$persistent" || return 1
    fi
    rm -f -- "$pending"
}

failure_finalize_outer_rollback() {
    local summary="$1" original_rc="$2" rollback_rc="$3" dir
    local stage reason detail suggestion final_rc="$original_rc" rollback=complete persistent=none
    local original_stage="" original_reason="" original_detail="" original_suggestion=""
    [[ "$summary" == "$HISTORY_DIR/"*/summary.tsv && -f "$summary" && ! -L "$summary" ]] || return 1
    dir="${summary%/summary.tsv}"
    stage=$(summary_value "$summary" FAILURE_STAGE); reason=$(summary_value "$summary" FAILURE_REASON)
    detail=$(summary_value "$summary" FAILURE_DETAIL); suggestion=$(summary_value "$summary" SUGGESTED_ACTION)
    if [[ -z "$reason" || "$reason" == none ]]; then
        failure_reset; failure_from_rc "$original_rc" AUTO_TUNE
        stage="$FAILURE_STAGE"; reason="$FAILURE_REASON"; detail="$FAILURE_DETAIL"; suggestion="$FAILURE_SUGGESTION"
    fi
    if (( rollback_rc != 0 )); then
        original_stage="$stage"; original_reason="$reason"; original_detail="$detail"; original_suggestion="$suggestion"
        stage=ROLLBACK; reason="rollback-failed"; final_rc="$ROLLBACK_FAILURE_RC"; rollback=failed
        persistent=unknown-review-transaction
        detail="outer rollback rc=$rollback_rc after ${original_reason:-unknown} (original rc=$original_rc)"
        suggestion=$(failure_default_suggestion rollback-failed)
    fi
    history_summary_update "$summary" RESULT FAILURE FAILURE_STAGE "$stage" FAILURE_REASON "$reason" \
        FAILURE_DETAIL "$detail" SUGGESTED_ACTION "$suggestion" INTERNAL_RC "$final_rc" \
        ROLLBACK_RESULT "$rollback" PERSISTENT_CHANGES "$persistent" \
        ORIGINAL_FAILURE_STAGE "$original_stage" ORIGINAL_FAILURE_REASON "$original_reason" \
        ORIGINAL_FAILURE_DETAIL "$original_detail" ORIGINAL_FAILURE_SUGGESTION "$original_suggestion" \
        ORIGINAL_INTERNAL_RC "$([[ -n "$original_reason" ]] && printf '%s' "$original_rc")" COMPLETED_AT "$(utc_now)" || return 1
    failure_record_write "$dir" "$stage" "$reason" "$detail" "$final_rc" "$rollback" "$persistent" \
        "$original_stage" "$original_reason" "$original_rc"
}

failure_summary_print() {
    local summary="${1:-${MEASURE_RUN_DIR:-}/summary.tsv}" final="${2:-0}" reason rollback persistent original
    if [[ -n "${ACTION_TRANSACTION_DIR:-}" && "$final" != 1 ]]; then return 0; fi
    [[ -f "$summary" && ! -L "$summary" ]] || return 1
    [[ "$(summary_value "$summary" RESULT)" == FAILURE ]] || return 0
    reason=$(summary_value "$summary" FAILURE_REASON)
    printf '\nFailure summary\n\n'
    printf '%-20s %s\n' Stage "$(summary_value "$summary" FAILURE_STAGE)"
    printf '%-20s %s (%s)\n' Reason "$reason" "$(failure_reason_explanation "$reason")"
    printf '%-20s %s:%s\n' Peer "$(summary_value "$summary" PEER)" "$(summary_value "$summary" PORT)"
    printf '%-20s %s\n' 'Traffic used' "$(human_bytes "$(summary_value "$summary" TEST_TX_BYTES_USED)") TX"
    rollback=$(summary_value "$summary" ROLLBACK_RESULT); persistent=$(summary_value "$summary" PERSISTENT_CHANGES)
    [[ -n "$persistent" ]] || persistent=unknown
    if [[ "$rollback" == failed ]]; then printf '%-20s %s\n' Rollback 'ROLLBACK FAILED'
    else printf '%-20s %s\n' Rollback "$rollback"
    fi
    original=$(summary_value "$summary" ORIGINAL_FAILURE_REASON)
    [[ -z "$original" ]] || printf '%-20s %s\n' 'Original reason' "$original"
    printf '%-20s %s\n' 'Persistent changes' "$persistent"
    printf '\nSuggested action\n  %s\n' "$(summary_value "$summary" SUGGESTED_ACTION)"
}

history_id_valid() {
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-(path|path-check|probe|sweep|verify|compare)(-[0-9]+)?$ ]]
}

history_summary_files() {
    [[ -d "$HISTORY_DIR" && ! -L "$HISTORY_DIR" ]] || return 0
    find "$HISTORY_DIR" -mindepth 2 -maxdepth 2 -type f -name summary.tsv -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
}

history_field() {
    [[ "$2" =~ ^[A-Z][A-Z0-9_]{1,63}$ ]] || return 1
    awk -F'\t' -v key="$2" '$1==key {print $2; exit}' "$1" 2>/dev/null
}

history_summary_well_formed() {
    local file="$1" line key value
    local -A seen=()
    [[ -f "$file" && ! -L "$file" && "$file" == "$HISTORY_DIR/"*/summary.tsv ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* ]] || return 1
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]{1,63}$ && "$value" != *$'\t'* && "$value" != *$'\r'* ]] || return 1
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        if LC_ALL=C grep -q $'[\001-\010\013\014\016-\037\177]' <<< "$value"; then return 1; fi
    done < "$file"
}

history_schema_supported() {
    local schema
    history_summary_well_formed "$1" || return 1
    schema=$(history_field "$1" HISTORY_SCHEMA)
    [[ -z "$schema" ]] && return 0 # v8.0.5 and earlier history remains readable.
    is_uint "$schema" && (( 10#$schema <= HISTORY_SCHEMA ))
}

history_print_one() {
    local file="$1" id result decision knee recommend verify traffic reason peer time schema
    [[ -f "$file" && ! -L "$file" && "$file" == "$HISTORY_DIR/"*/summary.tsv ]] || return 1
    schema=$(history_field "$file" HISTORY_SCHEMA)
    history_schema_supported "$file" || { die "history 使用不支持的更新 schema: ${schema:-invalid}"; return 1; }
    id="${file%/summary.tsv}"; id="${id##*/}"
    time=$(history_field "$file" COMPLETED_AT); [[ -n "$time" ]] || time="${id%%-*}"
    result=$(history_field "$file" RESULT); [[ -n "$result" ]] || result=LEGACY
    decision=$(history_field "$file" SCAN_DECISION); [[ -n "$decision" ]] || decision=$(history_field "$file" TYPE)
    knee=$(history_field "$file" KNEE_MBIT); recommend=$(history_field "$file" RECOMMEND)
    verify=$(history_field "$file" VERDICT); [[ -n "$verify" ]] || verify=$(history_field "$file" FINAL_VERIFY_MODE)
    traffic=$(history_field "$file" TEST_TX_BYTES_USED); [[ -n "$traffic" ]] || traffic=0
    reason=$(history_field "$file" FAILURE_REASON); [[ -n "$reason" ]] || reason=none
    peer=$(history_field "$file" PEER); [[ -n "$peer" ]] || peer=unknown
    printf '%s\n' "ID                 $id" "Time               $time" "Operation          $(history_field "$file" TYPE)" \
        "Peer               $peer" "Result             $result" "Decision           ${decision:-unknown}" \
        "Knee               ${knee:-none}" "Recommendation     ${recommend:-none}" "Verify             ${verify:-none}" \
        "Traffic TX         $(human_bytes "$traffic")" "Failure reason     $reason"
}

history_show() {
    local id="$1" file
    history_id_valid "$id" || { die "非法 history ID: $id"; return 1; }
    file="$HISTORY_DIR/$id/summary.tsv"
    [[ -f "$file" && ! -L "$file" ]] || { die "history 不存在: $id"; return 1; }
    history_print_one "$file"
}

history_latest() {
    local file
    file=$(history_summary_files | head -n1)
    [[ -n "$file" ]] || { printf 'No measurement history.\n'; return 0; }
    history_print_one "$file"
}

history_list() {
    local file id type result decision reason count=0
    printf '%-31s %-9s %-9s %-28s %s\n' ID Type Result Decision/verify Failure
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        id="${file%/summary.tsv}"; id="${id##*/}"; type=$(history_field "$file" TYPE)
        if ! history_schema_supported "$file"; then
            printf '%-31s %-9s %-9s %-28s %s\n' "$id" unknown INVALID unsupported-schema ignored
            continue
        fi
        result=$(history_field "$file" RESULT); [[ -n "$result" ]] || result=LEGACY
        decision=$(history_field "$file" SCAN_DECISION); [[ -n "$decision" ]] || decision=$(history_field "$file" VERDICT)
        reason=$(history_field "$file" FAILURE_REASON); [[ -n "$reason" ]] || reason=none
        printf '%-31s %-9s %-9s %-28s %s\n' "$id" "${type:-unknown}" "$result" "${decision:-none}" "$reason"
        ((count+=1)); (( count < MAX_HISTORY_ENTRIES )) || break
    done < <(history_summary_files)
    (( count > 0 )) || printf '%s\n' '(no measurement history)'
}

history_prune_internal() {
    local keep="${1:-$MAX_HISTORY_ENTRIES}" dir id count=0
    is_uint "$keep" && (( keep >= 1 && keep <= 1000 )) || keep=20
    [[ ! -L "$HISTORY_DIR" ]] || return 1
    [[ -d "$HISTORY_DIR" ]] || return 0
    while IFS= read -r dir; do
        [[ -d "$dir" && ! -L "$dir" && "$dir" == "$HISTORY_DIR/"* ]] || continue
        id="${dir##*/}"
        history_id_valid "$id" || continue
        ((count+=1)); (( count <= keep )) && continue
        [[ "$dir" != "${MEASURE_RUN_DIR:-}" ]] || continue
        remove_tree_within "$dir" "$HISTORY_DIR" || return 1
    done < <(find "$HISTORY_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
}

history_prune() {
    require_root || return 1; acquire_lock || return 1
    history_prune_internal "$MAX_HISTORY_ENTRIES" || return 1
    log OK "measurement history 已清理，仅保留最近 $MAX_HISTORY_ENTRIES 次；baseline/config/transaction 未改变"
}

history_latest_matching() {
    local wanted="$1" file value
    while IFS= read -r file; do
        history_schema_supported "$file" || continue
        value=$(history_field "$file" RESULT)
        [[ "$value" == "$wanted" ]] || continue
        printf '%s\n' "$file"; return 0
    done < <(history_summary_files)
    return 1
}

history_latest_type() {
    local wanted_type="$1" file
    while IFS= read -r file; do
        history_schema_supported "$file" || continue
        [[ "$(history_field "$file" TYPE)" == "$wanted_type" ]] || continue
        printf '%s\n' "$file"
        return 0
    done < <(history_summary_files)
    return 1
}

history_latest_type_result() {
    local wanted_type="$1" wanted_result="$2" file
    while IFS= read -r file; do
        history_schema_supported "$file" || continue
        [[ "$(history_field "$file" TYPE)" == "$wanted_type" ]] || continue
        [[ "$(history_field "$file" RESULT)" == "$wanted_result" ]] || continue
        printf '%s\n' "$file"
        return 0
    done < <(history_summary_files)
    return 1
}

status_measurement_details() {
    local file profile completed age decision delivered shaping stored_fp family address source iface current current_fp state=unknown
    file=$(history_latest_type_result sweep SUCCESS 2>/dev/null || true)
    if [[ -z "$file" ]]; then
        printf '%-20s %s\n' 'Last measurement' none 'Measurement age' n/a Measurement none Decision none \
            'Delivered capacity' 'not measured' 'Shaping rate' none
        return 0
    fi
    completed=$(history_field "$file" COMPLETED_AT); age=$(history_age_brief "$completed")
    decision=$(history_field "$file" MEASUREMENT_STATE)
    [[ -n "$decision" ]] || decision=$(history_field "$file" SCAN_DECISION)
    delivered=$(history_field "$file" CAPACITY_RECEIVER_MBIT)
    [[ -n "$delivered" ]] || delivered=$(history_field "$file" SATURATION_RECEIVER_MBIT)
    shaping=$(history_field "$file" RECOMMEND)
    profile=$(path_profile_for_sweep "$file")
    stored_fp=$(path_summary_value "$profile" PATH_ROUTE_FINGERPRINT); family=$(path_summary_value "$profile" LOCKED_FAMILY)
    address=$(path_summary_value "$profile" LOCKED_ADDRESS); source=$(path_summary_value "$profile" LOCKED_SOURCE)
    iface=$(path_summary_value "$profile" LOCKED_INTERFACE)
    if [[ "$stored_fp" =~ ^[0-9a-f]{64}$ && ( "$family" == 4 || "$family" == 6 ) && -n "$address" && -n "$source" && -n "$iface" ]]; then
        current=$(path_capture_route_identity "$family" "$address" "$source" "$iface" 2>/dev/null || true)
        current_fp="${current%%$'\t'*}"
        if [[ "$current_fp" == "$stored_fp" ]]; then state=verified
        elif [[ -n "$current_fp" ]]; then state=stale
        else state=unverifiable
        fi
    fi
    [[ -n "$delivered" ]] && delivered="$delivered Mbit" || delivered='not measured'
    [[ -n "$shaping" ]] && shaping="$shaping Mbit" || shaping=none
    printf '%-20s %s\n' 'Last measurement' "${completed:-unknown}" 'Measurement age' "$age" \
        Measurement "$state" Decision "${decision:-unknown}" \
        'Delivered capacity' "$delivered" 'Shaping rate' "$shaping"
}

history_age_brief() {
    local timestamp="$1" then_epoch now seconds
    then_epoch=$(date -u -d "$timestamp" +%s 2>/dev/null || true); now=$(date +%s)
    is_uint "$then_epoch" && is_uint "$now" && (( now >= then_epoch )) || { printf 'unknown\n'; return; }
    seconds=$((now-then_epoch))
    if (( seconds < 3600 )); then printf '%sm\n' "$((seconds/60))"
    elif (( seconds < 86400 )); then printf '%sh %sm\n' "$((seconds/3600))" "$(((seconds%3600)/60))"
    else printf '%sd %sh\n' "$((seconds/86400))" "$(((seconds%86400)/3600))"; fi
}

measurement_environment_preflight() {
    local iface="$1" capacity="${2:-0}" seconds="${BBRV3_PREFLIGHT_SECONDS:-2}"
    local cpu_before cpu_after metrics busy steal tx_before tx_after rx_before rx_after tx_rate rx_rate ratio
    local available_kib load cpus state_target tmp_available established=0 hard_busy="${BBRV3_PREFLIGHT_MAX_CPU_BUSY:-95}"
    local hard_steal="${BBRV3_PREFLIGHT_MAX_STEAL:-15}" hard_background="${BBRV3_PREFLIGHT_MAX_BACKGROUND_PERCENT:-15}"
    # Deterministic unit tests may bypass only the observation delay.  Formal
    # CLI runs do not set this internal switch.
    [[ "${BBRV3_SKIP_MEASUREMENT_PREFLIGHT:-0}" != 1 ]] || return 0
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1
    is_uint "$seconds" && (( seconds >= 1 && seconds <= 3 )) || seconds=2
    is_decimal "$hard_busy" || hard_busy=95; is_decimal "$hard_steal" || hard_steal=15
    is_decimal "$hard_background" || hard_background=15
    available_kib=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    if is_uint "$available_kib" && (( available_kib < 65536 )); then
        failure_set PREFLIGHT memory-low "MemAvailable=${available_kib}KiB"
        die "可用内存仅 $(human_bytes "$((available_kib*1024))")，拒绝开始高流量测速"
        return "$MEASUREMENT_PREFLIGHT_RC"
    fi
    state_target="$STATE_DIR"; [[ -e "$state_target" ]] || state_target=$(dirname "$STATE_DIR")
    tmp_available=$(df -Pk "$state_target" /tmp 2>/dev/null | awk 'NR>1 {if(min=="" || $4<min)min=$4} END {print min+0}')
    if is_uint "$tmp_available" && (( tmp_available < 32768 )); then
        failure_set PREFLIGHT disk-space-low "minimum available=${tmp_available}KiB"
        die "状态目录或 /tmp 可用空间不足 32 MiB，拒绝开始测速"
        return "$MEASUREMENT_PREFLIGHT_RC"
    fi
    cpu_before=$(cpu_snapshot); tx_before=$(interface_counter "$iface" tx_bytes); rx_before=$(interface_counter "$iface" rx_bytes)
    sleep "$seconds"
    cpu_after=$(cpu_snapshot); tx_after=$(interface_counter "$iface" tx_bytes); rx_after=$(interface_counter "$iface" rx_bytes)
    metrics=$(cpu_delta_metrics "$cpu_before" "$cpu_after"); IFS=$'\t' read -r busy steal <<< "$metrics"
    tx_rate=$(awk -v a="$tx_before" -v b="$tx_after" -v s="$seconds" 'BEGIN {d=b-a;if(d<0)d=0;printf "%.2f",d*8/s/1000000}')
    rx_rate=$(awk -v a="$rx_before" -v b="$rx_after" -v s="$seconds" 'BEGIN {d=b-a;if(d<0)d=0;printf "%.2f",d*8/s/1000000}')
    cpus=$(cpu_count); load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf 'na')
    command_exists ss && established=$(ss -Htan state established 2>/dev/null | awk 'END {print NR+0}')
    log INFO "测速环境预检: CPU ${busy}% / steal ${steal}% / load ${load}/${cpus} CPU / 背景 TX ${tx_rate} Mbit/s / RX ${rx_rate} Mbit/s / established ${established}"
    if is_decimal "$steal" && awk -v v="$steal" -v m="$hard_steal" 'BEGIN {exit !(v>m)}'; then
        failure_set PREFLIGHT high-steal "steal=${steal}% > ${hard_steal}%"
        die "CPU steal ${steal}% 过高，拒绝开始测速；请稍后重试"
        return "$MEASUREMENT_PREFLIGHT_RC"
    fi
    if is_decimal "$busy" && awk -v v="$busy" -v m="$hard_busy" 'BEGIN {exit !(v>m)}'; then
        failure_set PREFLIGHT cpu-busy "cpu=${busy}% > ${hard_busy}%"
        die "CPU 忙碌度 ${busy}% 过高，拒绝开始测速；请稍后重试"
        return "$MEASUREMENT_PREFLIGHT_RC"
    fi
    if is_decimal "$capacity" && awk -v c="$capacity" 'BEGIN {exit !(c>0)}'; then
        ratio=$(awk -v tx="$tx_rate" -v rx="$rx_rate" -v c="$capacity" 'BEGIN {v=(tx>rx?tx:rx)*100/c;printf "%.2f",v}')
        if awk -v v="$ratio" -v m="$hard_background" 'BEGIN {exit !(v>m)}'; then
            failure_set PREFLIGHT background-traffic "background=${ratio}% of ${capacity}Mbit"
            die "当前 $iface 已有约 TX ${tx_rate}/RX ${rx_rate} Mbit/s 背景流量（${ratio}%），拒绝生成自动推荐"
            return "$MEASUREMENT_PREFLIGHT_RC"
        elif awk -v v="$ratio" 'BEGIN {exit !(v>5)}'; then
            log WARN "当前 $iface 背景流量约占参考容量 ${ratio}%，可能降低测量置信度"
        fi
    elif awk -v tx="$tx_rate" -v rx="$rx_rate" 'BEGIN {v=(tx>rx?tx:rx);exit !(v>25)}'; then
        log WARN "容量未知且 $iface 已有明显背景流量（TX ${tx_rate}/RX ${rx_rate} Mbit/s）"
    fi
    if is_decimal "$load" && is_uint "$cpus" && awk -v l="$load" -v c="$cpus" 'BEGIN {exit !(l>c*2)}'; then
        log WARN "load average ${load} 相对 ${cpus} CPU 偏高；单个样本仍会执行逐核污染门禁"
    fi
}

doctor_command_state() {
    command_exists "$1" && printf available || printf missing
}

doctor_default_route_summary() {
    local family="$1" output count record iface gateway gateway_family nhid
    output=$(default_route_output "$family" 2>/dev/null || true)
    count=$(awk '$1=="default" {n++} END {print n+0}' <<< "$output")
    (( count > 0 )) || { printf 'absent\n'; return; }
    (( count == 1 )) || { printf 'ambiguous (%s defaults)\n' "$count"; return; }
    record=$(route_unique_path_record "$output" "doctor IPv${family#-} default" "${family#-}" 2>/dev/null || true)
    [[ -n "$record" ]] || { printf 'unresolved/ECMP\n'; return; }
    IFS=$'\t' read -r iface gateway gateway_family nhid <<< "$record"
    printf '%s / gateway %s / nhid %s\n' "$iface" "$gateway" "$nhid"
}

doctor_latest_brief() {
    local wanted="$1" wanted_type="${2:-}" file id
    if [[ -n "$wanted_type" ]]; then
        file=$(history_latest_type_result "$wanted_type" "$wanted" 2>/dev/null || true)
    else
        file=$(history_latest_matching "$wanted" 2>/dev/null || true)
    fi
    [[ -n "$file" ]] || { printf 'none\n'; return; }
    id="${file%/summary.tsv}"; id="${id##*/}"
    printf '%s / %s / %s\n' "$id" "$(history_field "$file" TYPE)" "$(history_field "$file" FAILURE_REASON)"
}

doctor_peer_summary() {
    local total=0 valid=0 penalized=0 file now
    [[ -d "$PEER_HEALTH_DIR" && ! -L "$PEER_HEALTH_DIR" ]] || { printf 'none\n'; return; }
    now=$(date +%s)
    for file in "$PEER_HEALTH_DIR"/endpoint-*.tsv; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        ((total+=1))
        if peer_health_load "$file" 2>/dev/null; then
            ((valid+=1)); (( PH_TEMPORARY_PENALTY_UNTIL <= now )) || ((penalized+=1))
        fi
    done
    printf '%s valid / %s total / %s temporarily penalized\n' "$valid" "$total" "$penalized"
}

doctor_report() {
    local config_state=absent baseline_state=missing service_state=absent service_active=inactive iface interfaces iface_line
    local cc available profile_state=absent persist_state latest_verify=none persist_version=absent persist_sync=OUT_OF_SYNC
    if [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]; then
        if load_config 2>/dev/null; then config_state=valid; else config_state=invalid; reset_config; fi
    else reset_config
    fi
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf unknown)
    [[ ! -f "$SYSCTL_FILE" ]] || profile_state=installed
    [[ ! -f "$SERVICE_FILE" ]] || service_state=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || printf disabled)
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && service_active=active
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]]; then
        if tcp_baseline_validate "$BASELINE_DIR" >/dev/null 2>&1; then baseline_state="valid / $(baseline_provenance)"; else baseline_state=invalid; fi
    fi
    persist_state=$(persistence_script_state)
    if [[ -f "$PERSIST_SCRIPT" && ! -L "$PERSIST_SCRIPT" ]]; then
        persist_version=$(awk -F'"' '$1=="SCRIPT_VERSION=" {print $2; exit}' "$PERSIST_SCRIPT" 2>/dev/null)
        [[ "$persist_version" == "$SCRIPT_VERSION" && "$persist_state" != *differs* && "$persist_state" != *foreign* && "$persist_state" != *not\ executable* ]] && persist_sync=SYNCED
    fi
    printf 'bbrv3-lite doctor (read-only)\n\n'
    printf '%-25s %s\n' Version "v$SCRIPT_VERSION" Kernel "$(uname -r 2>/dev/null || printf unknown)" \
        OS "$(os_id 2>/dev/null || printf unknown) / $(os_codename 2>/dev/null || printf unknown)" \
        Virtualization "$(virtualization_type 2>/dev/null || printf unknown)" \
        'BBR availability' "$available" 'Current congestion control' "$cc" \
        'Sysctl profile' "$SYSCTL_PROFILE / $profile_state" Config "$config_state / $CONFIG_FILE" \
        'Persistence service' "$service_state / $service_active" 'CLI script' "v$SCRIPT_VERSION" \
        'Persistence copy' "v${persist_version:-unknown}" 'Persistence sync' "$persist_sync ($persist_state)" \
        'Disk baseline' "$baseline_state"
    printf '%-25s %s\n' 'IPv4 default route' "$(doctor_default_route_summary -4)" \
        'IPv6 default route' "$(doctor_default_route_summary -6)"
    printf '%-25s %s\n' 'IPv4 policy rules' "$(ip -4 rule show 2>/dev/null | awk 'END {print NR+0}')" \
        'IPv6 policy rules' "$(ip -6 rule show 2>/dev/null | awk 'END {print NR+0}')" \
        'Nexthop objects' "$(ip nexthop show 2>/dev/null | awk 'END {print NR+0}')"
    interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/,"",$2); print $2}' | awk '!seen[$0]++')
    printf '\nInterfaces\n'
    while IFS= read -r iface; do
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || continue
        iface_line="driver $(detect_driver "$iface") / MTU $(detect_mtu "$iface") / RX:TX $(detect_rx_queues "$iface"):$(detect_tx_queues "$iface") / qdisc $(root_qdisc_kind "$iface" 2>/dev/null || printf unreadable)"
        printf '  %-20s %s\n' "$iface" "$iface_line"
        printf '  %-20s offloads %s\n' '' "$(detect_offload_summary "$iface" 2>/dev/null || printf unavailable)"
    done <<< "$interfaces"
    latest_verify=$(history_latest_type verify 2>/dev/null || true)
    printf '\nRecent state\n'
    printf '%-25s %s\n' 'Latest successful measurement' "$(doctor_latest_brief SUCCESS sweep)" \
        'Latest failed measurement' "$(doctor_latest_brief FAILURE)" \
        'Latest verify' "${latest_verify:-none}" 'Peer health' "$(doctor_peer_summary)"
    printf '\nTC ownership\n'
    while IFS= read -r iface; do
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || continue
        if managed_htb "$iface" 2>/dev/null; then
            printf '  %s: managed HTB/FQ (%s Mbit)\n' "$iface" "$(managed_rate_mbit "$iface" 2>/dev/null || printf unknown)"
        else
            printf '  %s: %s root; %s\n' "$iface" "$(root_qdisc_kind "$iface" 2>/dev/null || printf unreadable)" \
                "$(managed_htb_diagnostic "$iface" 2>/dev/null || printf ownership-unavailable)"
        fi
    done <<< "$interfaces"
    printf '\nNo network settings were changed.\n'
}

diagnostic_capture() {
    local file="$1"; shift
    { "$@" 2>&1 || printf '\n[command failed: rc=%s]\n' "$?"; } > "$file"
    chmod 0600 "$file" 2>/dev/null || true
}

diagnostic_copy_latest_history() {
    local type="$1" destination="$2" source temp attempt
    for attempt in 1 2 3; do
        source=$(history_latest_type "$type" 2>/dev/null || true)
        [[ -n "$source" ]] || { : > "$destination"; chmod 0600 "$destination" 2>/dev/null || true; return 0; }
        temp=$(mktemp "${destination}.snapshot.XXXXXX") || return 1
        if cp -- "$source" "$temp" 2>/dev/null; then
            chmod 0600 "$temp" && mv -f -- "$temp" "$destination"
            return
        fi
        rm -f -- "$temp"
    done
    : > "$destination"; chmod 0600 "$destination" 2>/dev/null || true
}

diagnostic_redact_stream() {
    local hostname_value="${1:-}" include_addresses="${2:-0}" address_map="${3:-/dev/null}"
    awk -F'\t' -v host="$hostname_value" -v include_addresses="$include_addresses" '
        function literal_replace(text, old, new, p) {
            if(old=="") return text
            while((p=index(text,old))>0) text=substr(text,1,p-1) new substr(text,p+length(old))
            return text
        }
        FILENAME != "-" {if($1!="__MAP__") {address[++address_count]=$1; replacement[address_count]=$2}; next}
        {
            low=tolower($0)
            if(low ~ /(token|password|secret|credential|authorization|(^|[^a-z])psk([^a-z]|$))/) {print "[REDACTED SENSITIVE LINE]"; next}
            if(low ~ /(machine[-_ ]?id|boot[-_ ]?id|product[-_ ]?uuid|dmi.*uuid|instance[-_ ]?id|ssh.*host.*key)/) {print "[REDACTED MACHINE IDENTITY]"; next}
            line=literal_replace($0,host,"HOST_REDACTED")
            if(include_addresses==0) for(i=1;i<=address_count;i++) line=literal_replace(line,address[i],replacement[i])
            print line
        }
    ' "$address_map" - | sed -E \
        -e 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/MAC_REDACTED/g' \
        -e 's/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/UUID_REDACTED/g' \
        -e 's/(^|[^[:xdigit:]])[[:xdigit:]]{32}([^[:xdigit:]]|$)/\1MACHINE_ID_REDACTED\2/g' \
        -e 's/(^|[^[:alnum:]])i-[[:xdigit:]]{8,}([^[:alnum:]]|$)/\1INSTANCE_ID_REDACTED\2/g'
}

diagnostic_address_map_build() {
    local dir="$1" map="$2" address digest
    printf '__MAP__\t__MAP__\n' > "$map" || return 1
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        [[ "$address" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] && continue
        digest=$(printf '%s' "$address" | sha256sum | awk '{print substr($1,1,12)}') || return 1
        [[ "$digest" =~ ^[0-9a-f]{12}$ ]] || return 1
        printf '%s\tADDR#%s\n' "$address" "$digest" >> "$map" || return 1
    done < <(
        grep -ERho '([0-9]{1,3}[.]){3}[0-9]{1,3}|[[:xdigit:]:]*::[[:xdigit:]:]*|([[:xdigit:]]{1,4}:){3,7}[[:xdigit:]]{1,4}' "$dir" 2>/dev/null |
            awk 'NF {print length($0) "\t" $0}' | sort -t$'\t' -k1,1nr -k2,2 | cut -f2- | awk '!seen[$0]++'
    )
}

doctor_export() {
    local include_addresses="${1:-0}" stamp id final file hostname_value tmp_available address_map
    [[ "$include_addresses" == 0 || "$include_addresses" == 1 ]] || return 1
    require_commands awk cp cut df find grep gzip hostname mktemp chmod mv sed sha256sum sort tar || return 1
    tmp_available=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4+0}')
    if ! is_uint "$tmp_available" || (( tmp_available < 32768 )); then
        failure_set DIAGNOSTIC_EXPORT disk-space-low "/tmp available=${tmp_available:-unknown}KiB"
        die "/tmp 可用空间不足 32 MiB，未创建诊断包"
        return "$DIAGNOSTIC_EXPORT_RC"
    fi
    umask 077
    stamp=$(date -u +'%Y%m%d-%H%M%S'); id="diag-${stamp}-$$"
    DIAGNOSTIC_TEMP_DIR=$(mktemp -d "/tmp/.bbrv3-lite-diagnostic.XXXXXX") || return "$DIAGNOSTIC_EXPORT_RC"
    printf 'DIAGNOSTIC_ID\t%s\nCREATED_AT\t%s\nVERSION\t%s\nADDRESSES_INCLUDED\t%s\n' "$id" "$(utc_now)" "$SCRIPT_VERSION" "$include_addresses" > "$DIAGNOSTIC_TEMP_DIR/meta.txt"
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/status.txt" doctor_report
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/verify.txt" verify_system_state
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/sysctl.txt" bash -c 'for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog; do sysctl "$key" 2>&1 || true; done'
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/routes-v4.txt" ip -4 route show table all
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/routes-v6.txt" ip -6 route show table all
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/rules-v4.txt" ip -4 rule show
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/rules-v6.txt" ip -6 rule show
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/nexthops.txt" ip nexthop show
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/tc-qdisc.txt" sh -c 'for i in /sys/class/net/*; do n=${i##*/}; echo "## $n"; tc qdisc show dev "$n" 2>&1 || true; done'
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/tc-class.txt" sh -c 'for i in /sys/class/net/*; do n=${i##*/}; echo "## $n"; tc class show dev "$n" 2>&1 || true; done'
    diagnostic_capture "$DIAGNOSTIC_TEMP_DIR/tc-filter.txt" sh -c 'for i in /sys/class/net/*; do n=${i##*/}; echo "## $n"; tc filter show dev "$n" 2>&1 || true; done'
    {
        printf 'enabled='; systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true
        printf 'active='; systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
        printf 'persistence-copy=%s\n' "$(persistence_script_state)"
    } > "$DIAGNOSTIC_TEMP_DIR/service.txt"
    if load_config 2>/dev/null; then write_config_stream > "$DIAGNOSTIC_TEMP_DIR/config.redacted.txt"; else printf 'CONFIG_UNAVAILABLE\n' > "$DIAGNOSTIC_TEMP_DIR/config.redacted.txt"; fi
    # Copy through an archive-local temporary file.  If prune unlinks the
    # source after cp opens it, Unix keeps that file descriptor readable; if
    # the unlink wins the open race, retry against the new latest entry.
    diagnostic_copy_latest_history sweep "$DIAGNOSTIC_TEMP_DIR/latest-sweep-summary.tsv" || return "$DIAGNOSTIC_EXPORT_RC"
    diagnostic_copy_latest_history verify "$DIAGNOSTIC_TEMP_DIR/latest-verify-summary.tsv" || return "$DIAGNOSTIC_EXPORT_RC"
    peers_show > "$DIAGNOSTIC_TEMP_DIR/peer-health.tsv" 2>&1 || printf 'peer health unavailable\n' > "$DIAGNOSTIC_TEMP_DIR/peer-health.tsv"
    chmod 0600 "$DIAGNOSTIC_TEMP_DIR"/*
    (( include_addresses == 0 )) || log WARN "诊断包将包含完整网络地址；hostname、MAC、机器身份与 secret 仍会脱敏"
    hostname_value=$(hostname 2>/dev/null || true)
    address_map=$(mktemp "$DIAGNOSTIC_TEMP_DIR/.redaction-map.XXXXXX") || return "$DIAGNOSTIC_EXPORT_RC"
    if (( include_addresses == 0 )); then diagnostic_address_map_build "$DIAGNOSTIC_TEMP_DIR" "$address_map" || return "$DIAGNOSTIC_EXPORT_RC"
    else printf '__MAP__\t__MAP__\n' > "$address_map"
    fi
    for file in "$DIAGNOSTIC_TEMP_DIR"/*; do
        [[ -f "$file" ]] || continue
        diagnostic_redact_stream "$hostname_value" "$include_addresses" "$address_map" < "$file" > "$file.redacted"
        chmod 0600 "$file.redacted" && mv -f -- "$file.redacted" "$file"
    done
    rm -f -- "$address_map"
    if grep -ERiq '(token|password|secret|credential|authorization|(^|[^a-z])psk([^a-z]|$))' "$DIAGNOSTIC_TEMP_DIR"; then
        rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""
        die "诊断包 secret deny-list 校验失败；没有生成归档"
        return "$DIAGNOSTIC_EXPORT_RC"
    fi
    final="/tmp/bbrv3-lite-diagnostic-${stamp}.tar.gz"; [[ ! -e "$final" && ! -L "$final" ]] || final="/tmp/bbrv3-lite-diagnostic-${stamp}-$$.tar.gz"
    DIAGNOSTIC_TEMP_ARCHIVE=$(mktemp "/tmp/.bbrv3-lite-diagnostic-archive.XXXXXX") || {
        rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""; return "$DIAGNOSTIC_EXPORT_RC";
    }
    if ! tar -C "$DIAGNOSTIC_TEMP_DIR" -czf "$DIAGNOSTIC_TEMP_ARCHIVE" .; then
        rm -f -- "$DIAGNOSTIC_TEMP_ARCHIVE"; DIAGNOSTIC_TEMP_ARCHIVE=""; rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""; return "$DIAGNOSTIC_EXPORT_RC"
    fi
    chmod 0600 "$DIAGNOSTIC_TEMP_ARCHIVE" || { rm -f -- "$DIAGNOSTIC_TEMP_ARCHIVE"; DIAGNOSTIC_TEMP_ARCHIVE=""; rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""; return "$DIAGNOSTIC_EXPORT_RC"; }
    if ! mv -n -- "$DIAGNOSTIC_TEMP_ARCHIVE" "$final" || [[ -e "$DIAGNOSTIC_TEMP_ARCHIVE" || ! -f "$final" || -L "$final" ]]; then
        rm -f -- "$DIAGNOSTIC_TEMP_ARCHIVE"; DIAGNOSTIC_TEMP_ARCHIVE=""; rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""
        die "诊断包目标发生并发冲突；没有覆盖现有文件"
        return "$DIAGNOSTIC_EXPORT_RC"
    fi
    DIAGNOSTIC_TEMP_ARCHIVE=""
    rm -rf -- "$DIAGNOSTIC_TEMP_DIR"; DIAGNOSTIC_TEMP_DIR=""
    printf 'Diagnostic ID: %s\nDiagnostic bundle: %s\nPermissions: 600\nUpload: never automatic\n' "$id" "$final"
}

auto_dry_run() {
    local requested="${1:-auto}" profile="${2:-standard}" max_bytes="${3:-0}" max_duration="${4:-900}" peer="${5:-}"
    local iface qdisc cap duration estimate dependency_state=ready route_state dependency first_plan
    local first_stage first_rate first_duration first_reserved
    measurement_profile_configure "$profile" || return 1
    iface=$(detect_interface "$requested") || return 1
    qdisc=$(root_qdisc_kind "$iface" 2>/dev/null || printf unreadable)
    hardware_profile_values "$iface" 0 || return 1
    cap=$(recommended_scan_cap "$iface" 0) || return 1
    duration=$(recommended_measure_duration "$iface" 0) || return 1
    first_plan=$(measurement_first_sample_plan auto 0 "$cap" "$duration") || return 1
    IFS=$'\t' read -r first_stage first_rate first_duration _ _ first_reserved _ <<< "$first_plan"
    estimate=$(estimate_measurement_plan_bytes "$((cap*40/100))" "$duration" "$cap" "$duration" "$cap" "$duration" "$((duration+2))" 1)
    (( max_bytes > 0 && estimate > max_bytes )) && estimate="$max_bytes"
    for dependency in ip tc sysctl systemctl iperf3 jq ping timeout; do command_exists "$dependency" || dependency_state="missing: $dependency"; done
    if [[ -n "$peer" ]]; then route_state=$(target_route_records "$peer" 2>/dev/null || printf unresolved); else route_state="not selected (formal run will freeze one endpoint)"; fi
    printf 'Dry-run\n\n'
    printf '%-25s %s\n' 'Managed interface' "$iface" 'IPv4 default' "$(doctor_default_route_summary -4)" \
        'IPv6 default' "$(doctor_default_route_summary -6)" 'Peer route' "$route_state" \
        'Current CC' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)" \
        'Current qdisc' "$qdisc" 'Hardware profile' "$HARDWARE_CLASS" 'Measurement mode' "$profile" \
        'Peer mode' "$([[ -n "$peer" ]] && printf explicit || printf public-selection-at-run-time)" \
        'Planning bandwidth' "${EFFECTIVE_BANDWIDTH_MBIT:-unknown} Mbit (${EFFECTIVE_BANDWIDTH_SOURCE:-unknown})" \
        'First-sample safety ceiling' "${first_rate} Mbit (${first_stage})" \
        'Minimum first-sample budget' "~$(human_bytes "$first_reserved") (${first_duration}s sample)" \
        'Dependencies' "$dependency_state" 'Estimated max traffic' "$(human_bytes "$estimate")" \
        'Hard traffic budget' "$(human_bytes "$max_bytes")" 'Estimated duration' '3–8 min' \
        'Hard duration budget' "${max_duration}s"
    printf '\nWould:\n  temporarily enable BBR/FQ\n  run PATH_CONTROL, SATURATION, coarse/fine scan and final verify\n  apply HTB only if a verified knee is found\n  persist only after final verify\n\nDiscovery boundary:\n  local route/sysctl/qdisc inspection is performed\n  an explicit --peer may trigger DNS/route discovery only\n  no ping, TCP precheck or iperf throughput test is performed\n\nNo system changes were made.\nNo throughput measurement was performed.\n'
}
