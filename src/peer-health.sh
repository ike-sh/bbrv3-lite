# -----------------------------------------------------------------------------
# Public iperf peer health: bounded, local-only and strictly parsed state.
# Health affects candidate ordering only; every endpoint is still prechecked.
# -----------------------------------------------------------------------------

PEER_HEALTH_SCHEMA="1"
PEER_HEALTH_WINDOW_SIZE=12

peer_health_reset_values() {
    PH_HOST=""; PH_FAMILY=""; PH_ADDRESS=""; PH_PORT=""
    PH_LAST_SUCCESS=0; PH_LAST_FAILURE=0
    PH_SUCCESS_COUNT=0; PH_FAILURE_COUNT=0; PH_BUSY_COUNT=0; PH_RESET_COUNT=0
    PH_TIMEOUT_COUNT=0; PH_PATH_DIRTY_COUNT=0; PH_SLOW_PEER_COUNT=0; PH_UNSTABLE_COUNT=0
    PH_LAST_RTT_MS=na; PH_LAST_RECEIVER_MBIT=na; PH_LAST_PATH_CONTROL_QUALITY=unknown
    PH_LAST_FAILURE_REASON=none; PH_TEMPORARY_PENALTY_UNTIL=0; PH_RECENT_WINDOW=""
    PH_LAST_RESULT=unknown; PH_UPDATED_AT=0
}

peer_health_is_public_host() {
    local wanted="$1" host _
    while IFS='|' read -r host _; do
        [[ -n "$host" ]] || continue
        [[ "$host" == "$wanted" ]] && return 0
    done <<< "$PUBLIC_PEER_POOL"
    return 1
}

peer_health_key() {
    local host="$1" family="$2" address="$3" port="$4" digest
    if command_exists sha256sum; then
        digest=$(printf '%s\n' "$host|$family|$address|$port" | sha256sum | awk '{print $1}')
    elif command_exists openssl; then
        digest=$(printf '%s\n' "$host|$family|$address|$port" | openssl dgst -sha256 | awk '{print $NF}')
    else
        return 1
    fi
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'endpoint-%s.tsv\n' "$digest"
}

peer_health_file() {
    local key
    key=$(peer_health_key "$@") || return 1
    printf '%s/%s\n' "$PEER_HEALTH_DIR" "$key"
}

peer_health_counter_valid() {
    is_uint "$1" && (( 10#$1 <= 1000000000 ))
}

peer_health_timestamp_valid() {
    is_uint "$1" && (( 10#$1 <= 4294967295 ))
}

peer_health_load() {
    local file="$1" line key value lineno=0 schema=""
    local required
    local -A seen=()
    peer_health_reset_values
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno+=1)); line="${line%$'\r'}"
        [[ "$line" == *$'\t'* ]] || return 1
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$value" != *$'\t'* && "$value" != *$'\n'* ]] || return 1
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        case "$key" in
            SCHEMA) schema="$value" ;;
            HOST) PH_HOST="$value" ;;
            FAMILY) PH_FAMILY="$value" ;;
            ADDRESS) PH_ADDRESS="$value" ;;
            PORT) PH_PORT="$value" ;;
            LAST_SUCCESS) PH_LAST_SUCCESS="$value" ;;
            LAST_FAILURE) PH_LAST_FAILURE="$value" ;;
            SUCCESS_COUNT) PH_SUCCESS_COUNT="$value" ;;
            FAILURE_COUNT) PH_FAILURE_COUNT="$value" ;;
            BUSY_COUNT) PH_BUSY_COUNT="$value" ;;
            RESET_COUNT) PH_RESET_COUNT="$value" ;;
            TIMEOUT_COUNT) PH_TIMEOUT_COUNT="$value" ;;
            PATH_DIRTY_COUNT) PH_PATH_DIRTY_COUNT="$value" ;;
            SLOW_PEER_COUNT) PH_SLOW_PEER_COUNT="$value" ;;
            UNSTABLE_COUNT) PH_UNSTABLE_COUNT="$value" ;;
            LAST_RTT_MS) PH_LAST_RTT_MS="$value" ;;
            LAST_RECEIVER_MBIT) PH_LAST_RECEIVER_MBIT="$value" ;;
            LAST_PATH_CONTROL_QUALITY) PH_LAST_PATH_CONTROL_QUALITY="$value" ;;
            LAST_FAILURE_REASON) PH_LAST_FAILURE_REASON="$value" ;;
            TEMPORARY_PENALTY_UNTIL) PH_TEMPORARY_PENALTY_UNTIL="$value" ;;
            RECENT_WINDOW) PH_RECENT_WINDOW="$value" ;;
            LAST_RESULT) PH_LAST_RESULT="$value" ;;
            UPDATED_AT) PH_UPDATED_AT="$value" ;;
            *) return 1 ;;
        esac
    done < "$file"
    for required in SCHEMA HOST FAMILY ADDRESS PORT LAST_SUCCESS LAST_FAILURE SUCCESS_COUNT FAILURE_COUNT \
        BUSY_COUNT RESET_COUNT TIMEOUT_COUNT PATH_DIRTY_COUNT SLOW_PEER_COUNT UNSTABLE_COUNT LAST_RTT_MS \
        LAST_RECEIVER_MBIT LAST_PATH_CONTROL_QUALITY LAST_FAILURE_REASON TEMPORARY_PENALTY_UNTIL \
        RECENT_WINDOW LAST_RESULT UPDATED_AT; do
        [[ -n "${seen[$required]+x}" ]] || return 1
    done
    is_uint "$schema" || return 1
    (( 10#$schema <= PEER_HEALTH_SCHEMA )) || return 2
    [[ "$schema" == "$PEER_HEALTH_SCHEMA" ]] || return 1
    validate_peer "$PH_HOST" "$PH_PORT" 2>/dev/null || return 1
    [[ "$PH_FAMILY" == 4 || "$PH_FAMILY" == 6 ]] || return 1
    measure_source_address_is_valid "$PH_FAMILY" "$PH_ADDRESS" || return 1
    for value in "$PH_SUCCESS_COUNT" "$PH_FAILURE_COUNT" "$PH_BUSY_COUNT" "$PH_RESET_COUNT" \
        "$PH_TIMEOUT_COUNT" "$PH_PATH_DIRTY_COUNT" "$PH_SLOW_PEER_COUNT" "$PH_UNSTABLE_COUNT"; do
        peer_health_counter_valid "$value" || return 1
    done
    for value in "$PH_LAST_SUCCESS" "$PH_LAST_FAILURE" "$PH_TEMPORARY_PENALTY_UNTIL" "$PH_UPDATED_AT"; do
        peer_health_timestamp_valid "$value" || return 1
    done
    [[ "$PH_LAST_RTT_MS" == na ]] || is_decimal "$PH_LAST_RTT_MS" || return 1
    [[ "$PH_LAST_RECEIVER_MBIT" == na ]] || is_decimal "$PH_LAST_RECEIVER_MBIT" || return 1
    [[ "$PH_LAST_PATH_CONTROL_QUALITY" =~ ^(unknown|clean|good|dirty|slow-peer)$ ]] || return 1
    [[ "$PH_LAST_FAILURE_REASON" =~ ^[a-z0-9-]{1,64}$ ]] || return 1
    [[ "$PH_RECENT_WINDOW" =~ ^[SBRDTLUFIK]{0,12}$ ]] || return 1
    [[ "$PH_LAST_RESULT" =~ ^[a-z0-9-]{1,64}$ ]] || return 1
}

peer_health_write() {
    local file="$1" temp
    ensure_state_layout || return 1
    [[ ! -L "$PEER_HEALTH_DIR" ]] || { die "peer health 目录不能是符号链接"; return 1; }
    mkdir -p -- "$PEER_HEALTH_DIR" || return 1
    chmod 0700 "$PEER_HEALTH_DIR" 2>/dev/null || true
    temp=$(mktemp "${PEER_HEALTH_DIR}/.endpoint.XXXXXX") || return 1
    if ! printf 'SCHEMA\t%s\nHOST\t%s\nFAMILY\t%s\nADDRESS\t%s\nPORT\t%s\nLAST_SUCCESS\t%s\nLAST_FAILURE\t%s\nSUCCESS_COUNT\t%s\nFAILURE_COUNT\t%s\nBUSY_COUNT\t%s\nRESET_COUNT\t%s\nTIMEOUT_COUNT\t%s\nPATH_DIRTY_COUNT\t%s\nSLOW_PEER_COUNT\t%s\nUNSTABLE_COUNT\t%s\nLAST_RTT_MS\t%s\nLAST_RECEIVER_MBIT\t%s\nLAST_PATH_CONTROL_QUALITY\t%s\nLAST_FAILURE_REASON\t%s\nTEMPORARY_PENALTY_UNTIL\t%s\nRECENT_WINDOW\t%s\nLAST_RESULT\t%s\nUPDATED_AT\t%s\n' \
        "$PEER_HEALTH_SCHEMA" "$PH_HOST" "$PH_FAMILY" "$PH_ADDRESS" "$PH_PORT" \
        "$PH_LAST_SUCCESS" "$PH_LAST_FAILURE" "$PH_SUCCESS_COUNT" "$PH_FAILURE_COUNT" \
        "$PH_BUSY_COUNT" "$PH_RESET_COUNT" "$PH_TIMEOUT_COUNT" "$PH_PATH_DIRTY_COUNT" \
        "$PH_SLOW_PEER_COUNT" "$PH_UNSTABLE_COUNT" "$PH_LAST_RTT_MS" "$PH_LAST_RECEIVER_MBIT" \
        "$PH_LAST_PATH_CONTROL_QUALITY" "$PH_LAST_FAILURE_REASON" "$PH_TEMPORARY_PENALTY_UNTIL" \
        "$PH_RECENT_WINDOW" "$PH_LAST_RESULT" "$PH_UPDATED_AT" > "$temp"; then
        rm -f -- "$temp"; return 1
    fi
    chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
    mv -f -- "$temp" "$file"
}

peer_health_penalty_seconds() {
    case "$1" in
        peer-busy) printf '300\n' ;;
        peer-reset) printf '900\n' ;;
        peer-timeout|peer-unavailable) printf '600\n' ;;
        path-dirty) printf '180\n' ;;
        peer-too-slow|measurement-unstable) printf '600\n' ;;
        protocol-failure) printf '1800\n' ;;
        *) printf '300\n' ;;
    esac
}

peer_health_window_code() {
    case "$1" in
        success) printf 'S' ;;
        peer-busy) printf 'B' ;;
        peer-reset) printf 'R' ;;
        peer-timeout|peer-unavailable) printf 'T' ;;
        path-dirty) printf 'D' ;;
        peer-too-slow) printf 'L' ;;
        measurement-unstable|sample-contaminated) printf 'U' ;;
        measurement-inconclusive) printf 'I' ;;
        knee-not-located) printf 'K' ;;
        *) printf 'F' ;;
    esac
}

peer_health_record() {
    local host="$1" family="$2" address="$3" port="$4" outcome="$5" reason="${6:-none}"
    local rtt="${7:-na}" receiver="${8:-na}" quality="${9:-unknown}" file rc now penalty code
    peer_health_is_public_host "$host" || return 0
    validate_peer "$host" "$port" || return 1
    [[ "$family" == 4 || "$family" == 6 ]] && measure_source_address_is_valid "$family" "$address" || return 1
    file=$(peer_health_file "$host" "$family" "$address" "$port") || return 1
    now=$(date +%s); is_uint "$now" || return 1
    if [[ -e "$file" || -L "$file" ]]; then
        peer_health_load "$file" || rc=$?
        if (( ${rc:-0} == 2 )); then
            log WARN "peer health 使用更新 schema，当前版本不会覆盖: $file"
            return 1
        elif (( ${rc:-0} != 0 )); then
            log WARN "忽略损坏的 peer health 记录并原子重建: $file"
            peer_health_reset_values
        fi
    else
        peer_health_reset_values
    fi
    PH_HOST="$host"; PH_FAMILY="$family"; PH_ADDRESS="$address"; PH_PORT="$port"; PH_UPDATED_AT="$now"
    [[ "$rtt" == na ]] || is_decimal "$rtt" || rtt=na
    [[ "$receiver" == na ]] || is_decimal "$receiver" || receiver=na
    [[ "$quality" =~ ^(unknown|clean|good|dirty|slow-peer)$ ]] || quality=unknown
    PH_LAST_RTT_MS="$rtt"; PH_LAST_RECEIVER_MBIT="$receiver"; PH_LAST_PATH_CONTROL_QUALITY="$quality"
    if [[ "$outcome" == success ]]; then
        ((PH_SUCCESS_COUNT+=1)); PH_LAST_SUCCESS="$now"; PH_LAST_RESULT=clean
        PH_TEMPORARY_PENALTY_UNTIL=0
    elif [[ "$outcome" == inconclusive ]]; then
        [[ "$reason" == measurement-inconclusive || "$reason" == knee-not-located ]] || reason=measurement-inconclusive
        PH_LAST_RESULT="$reason"
        # A clean path that did not locate a knee is evidence, not a peer or
        # path failure.  Preserve its relative delivered-capacity hint without
        # incrementing failure/path-dirty counters or creating a blacklist.
        PH_TEMPORARY_PENALTY_UNTIL=0
    else
        [[ "$reason" =~ ^[a-z0-9-]{1,64}$ ]] || reason=protocol-failure
        ((PH_FAILURE_COUNT+=1)); PH_LAST_FAILURE="$now"; PH_LAST_FAILURE_REASON="$reason"; PH_LAST_RESULT="$reason"
        case "$reason" in
            peer-busy) ((PH_BUSY_COUNT+=1)) ;;
            peer-reset) ((PH_RESET_COUNT+=1)) ;;
            peer-timeout|peer-unavailable) ((PH_TIMEOUT_COUNT+=1)) ;;
            path-dirty) ((PH_PATH_DIRTY_COUNT+=1)) ;;
            peer-too-slow) ((PH_SLOW_PEER_COUNT+=1)) ;;
            measurement-unstable|sample-contaminated) ((PH_UNSTABLE_COUNT+=1)) ;;
        esac
        penalty=$(peer_health_penalty_seconds "$reason")
        PH_TEMPORARY_PENALTY_UNTIL=$((now + penalty))
    fi
    code=$(peer_health_window_code "$([[ "$outcome" == success ]] && printf success || printf '%s' "$reason")")
    PH_RECENT_WINDOW="${PH_RECENT_WINDOW}${code}"
    if (( ${#PH_RECENT_WINDOW} > PEER_HEALTH_WINDOW_SIZE )); then
        PH_RECENT_WINDOW="${PH_RECENT_WINDOW:$((${#PH_RECENT_WINDOW}-PEER_HEALTH_WINDOW_SIZE))}"
    fi
    peer_health_write "$file"
}

peer_health_reason_from_text() {
    local reason="${1,,}"
    case "$reason" in
        *busy*|*running*a*test*) printf 'peer-busy\n' ;;
        *reset*|*broken*pipe*|*control*socket*closed*) printf 'peer-reset\n' ;;
        *timed*out*|*timeout*) printf 'peer-timeout\n' ;;
        *refused*|*unreachable*|*no*route*|*unable*to*connect*) printf 'peer-unavailable\n' ;;
        *) printf 'protocol-failure\n' ;;
    esac
}

peer_health_host_reset_count() {
    local host="$1" family="$2" address="$3" file count=0 now
    [[ -d "$PEER_HEALTH_DIR" && ! -L "$PEER_HEALTH_DIR" ]] || { printf '0\n'; return 0; }
    now=$(date +%s); is_uint "$now" || { printf '0\n'; return 0; }
    for file in "$PEER_HEALTH_DIR"/endpoint-*.tsv; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        if peer_health_load "$file" 2>/dev/null && [[ "$PH_HOST" == "$host" && "$PH_FAMILY" == "$family" && "$PH_ADDRESS" == "$address" ]] &&
           (( PH_TEMPORARY_PENALTY_UNTIL > now )) && [[ "$PH_LAST_FAILURE_REASON" == peer-reset ]]; then
            ((count+=PH_RESET_COUNT))
        fi
    done
    printf '%s\n' "$count"
}

peer_health_score() {
    local host="$1" family="$2" address="$3" port="$4" rtt="${5:-9999}" file score=35 rtt_score=0 success_score=10
    local now total host_resets=0 reason="no-history" age=0 history_weight=100 delta=0 recent_success recent_failure
    if is_decimal "$rtt"; then
        if awk -v v="$rtt" 'BEGIN {exit !(v<=30)}'; then rtt_score=25
        elif awk -v v="$rtt" 'BEGIN {exit !(v<=60)}'; then rtt_score=20
        elif awk -v v="$rtt" 'BEGIN {exit !(v<=100)}'; then rtt_score=14
        elif awk -v v="$rtt" 'BEGIN {exit !(v<=150)}'; then rtt_score=7
        fi
    fi
    score=$((score + rtt_score))
    file=$(peer_health_file "$host" "$family" "$address" "$port" 2>/dev/null || true)
    if [[ -n "$file" && -f "$file" ]] && peer_health_load "$file" 2>/dev/null; then
        now=$(date +%s)
        if is_uint "$now" && (( now >= PH_UPDATED_AT )); then age=$((now-PH_UPDATED_AT)); fi
        if (( age >= 604800 )); then
            # A week without observations returns the endpoint to the same
            # neutral prior as a never-tested peer.  Live precheck remains the
            # final authority whenever it is selected again.
            score=$((score + success_score)); reason="history-expired"
            printf '%s\t%s\n' "$score" "$reason"
            return
        fi
        (( age < 86400 )) || history_weight=50
        recent_success=$(tr -cd 'S' <<< "$PH_RECENT_WINDOW" | wc -c)
        recent_failure=$(tr -cd 'BRDTLUF' <<< "$PH_RECENT_WINDOW" | wc -c)
        total=$((recent_success + recent_failure)); reason="history"
        if (( total > 0 )); then success_score=$((recent_success * 20 / total)); fi
        delta=$success_score
        [[ "$PH_LAST_PATH_CONTROL_QUALITY" != clean && "$PH_LAST_PATH_CONTROL_QUALITY" != good ]] || delta=$((delta+10))
        [[ "$PH_RECENT_WINDOW" != *B* ]] || delta=$((delta-5))
        [[ "$PH_RECENT_WINDOW" != *R* ]] || delta=$((delta-10))
        [[ "$PH_RECENT_WINDOW" != *D* ]] || delta=$((delta-8))
        [[ "$PH_RECENT_WINDOW" != *L* ]] || delta=$((delta-8))
        [[ "$PH_RECENT_WINDOW" != *U* ]] || delta=$((delta-8))
        score=$((score + delta * history_weight / 100))
        if is_uint "$now" && (( PH_TEMPORARY_PENALTY_UNTIL > now )); then score=$((score - 25)); reason="${reason}+temporary-penalty"; fi
    else
        score=$((score + success_score))
    fi
    host_resets=$(peer_health_host_reset_count "$host" "$family" "$address")
    if is_uint "$host_resets" && (( host_resets >= 2 )); then score=$((score - 10)); reason="${reason}+host-reset"; fi
    (( score < 0 )) && score=0; (( score > 100 )) && score=100
    printf '%s\t%s\n' "$score" "$reason"
}

peer_health_rank_candidates() {
    local candidate host address family source iface port rtt region provider score reason receiver=0 file
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        IFS='|' read -r host address family source iface port rtt region provider <<< "$candidate"
        IFS=$'\t' read -r score reason <<< "$(peer_health_score "$host" "$family" "$address" "$port" "$rtt")"
        receiver=0; file=$(peer_health_file "$host" "$family" "$address" "$port" 2>/dev/null || true)
        if [[ -n "$file" && -f "$file" ]] && peer_health_load "$file" 2>/dev/null && is_decimal "$PH_LAST_RECEIVER_MBIT"; then
            receiver=$(awk -v v="$PH_LAST_RECEIVER_MBIT" 'BEGIN {printf "%012.3f",v}')
        fi
        # Delivered capacity is deliberately a relative tie-breaker within the
        # current candidate set; there is no global "slow below X Mbit" cutoff.
        printf '%03d\t%s\t%09d\t%s\n' "$score" "$receiver" "${rtt%.*}" "$candidate"
    done | sort -t$'\t' -k1,1nr -k2,2nr -k3,3n | cut -f4-
}

peers_show() {
    local file score reason success total now penalty
    printf 'Public iperf peer health\n\n'
    printf '%-43s %-5s %-7s %-9s %-6s %-6s %s\n' 'Endpoint' 'RTT' 'Score' 'Success' 'Busy' 'Reset' 'Last result'
    if [[ ! -d "$PEER_HEALTH_DIR" || -L "$PEER_HEALTH_DIR" ]]; then
        printf '%s\n' '(no local peer health history)'
        return 0
    fi
    for file in "$PEER_HEALTH_DIR"/endpoint-*.tsv; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        if ! peer_health_load "$file" 2>/dev/null; then
            printf '%-43s %s\n' "${file##*/}" 'invalid/newer schema (ignored)'
            continue
        fi
        IFS=$'\t' read -r score reason <<< "$(peer_health_score "$PH_HOST" "$PH_FAMILY" "$PH_ADDRESS" "$PH_PORT" "$PH_LAST_RTT_MS")"
        total=$((PH_SUCCESS_COUNT + PH_FAILURE_COUNT)); success="${PH_SUCCESS_COUNT}/${total}"
        now=$(date +%s); penalty=""
        if (( PH_TEMPORARY_PENALTY_UNTIL > now )); then penalty=" (penalty $((PH_TEMPORARY_PENALTY_UNTIL-now))s)"; fi
        printf '%-43s %-5s %-7s %-9s %-6s %-6s %s%s\n' \
            "${PH_HOST}:${PH_PORT}/IPv${PH_FAMILY}" "${PH_LAST_RTT_MS}ms" "$score" "$success" \
            "$PH_BUSY_COUNT" "$PH_RESET_COUNT" "$PH_LAST_RESULT" "$penalty"
    done
    printf '\nHealth is a local ordering hint; every formal test still performs live precheck and route/path validation.\n'
}

peers_reset() {
    require_root || return 1; acquire_lock || return 1
    if [[ ! -e "$PEER_HEALTH_DIR" && ! -L "$PEER_HEALTH_DIR" ]]; then
        log OK "peer health cache 已为空"
        return 0
    fi
    [[ -d "$PEER_HEALTH_DIR" && ! -L "$PEER_HEALTH_DIR" ]] || { die "peer health 路径类型不安全"; return 1; }
    remove_tree_within "$PEER_HEALTH_DIR" "$STATE_DIR" || return 1
    log OK "仅 peer health cache 已删除；baseline、history、config 和网络状态均未改变"
}
