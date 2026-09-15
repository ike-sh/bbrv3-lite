# -----------------------------------------------------------------------------
# Measurement: iperf3 JSON probe and policer-knee sweep with automatic restore.
# -----------------------------------------------------------------------------

MEASURE_IFACE=""
MEASURE_SNAPSHOT=""
MEASURE_TX_START=0
MEASURE_RX_START=0
MEASURE_RESULT_FILE=""
MEASURE_RUN_DIR=""
MEASURE_IDLE_RTT_MS="na"
MEASURE_PEER_HOST=""
MEASURE_PEER_ADDRESS=""
MEASURE_PEER_SOURCE=""
MEASURE_PEER_FAMILY=""
MEASURE_PEER_IFACE=""
MEASURE_PEER_PORT=""
# Compatibility alias for callers written before the v8.0.5 experiment split.
# shellcheck disable=SC2034 # Public compatibility alias for sourced callers.
MEASURE_BASELINE_QUALITY_RC="$MEASURE_PATH_QUALITY_RC"
PUBLIC_PEER_CANDIDATES=()
MEASURE_LEVEL_ROW=""
MEASURE_LEVEL_SPIKE_HITS=0
MEASURE_LEVEL_SPIKE_CONFIRMED=0
MEASUREMENT_PROFILE="standard"
MEASURE_MAX_TX_BYTES=6442450944
MEASURE_MAX_DURATION_SECONDS=900
MEASURE_BUDGET_CONFIGURED=0
MEASURE_BUDGET_IFACE=""
MEASURE_BUDGET_TX_START=0
MEASURE_BUDGET_RX_START=0
MEASURE_BUDGET_STARTED_EPOCH=0
MEASURE_BUDGET_STAGE=""
MEASURE_BUDGET_INITIALIZATION_COUNT=0
MEASURE_BUDGET_PREBIND_TX_BYTES=0
MEASURE_BUDGET_PREBIND_RX_BYTES=0
TEST_TX_BYTES_USED=0
TEST_RX_BYTES_USED=0
TEST_DURATION_USED=0
MEASURE_IPERF_TIMEOUT_GUARD_SECONDS=20
MEASURE_CONTROL_SAMPLES=3
MEASURE_SATURATION_SAMPLES=2
MEASURE_CANDIDATE_SAMPLES=2
MEASURE_VERIFY_SAMPLES=2
MEASURE_CONTROL_MAX_SAMPLES=3
MEASURE_SATURATION_MAX_SAMPLES=3
MEASURE_CANDIDATE_MAX_SAMPLES=3
MEASURE_VERIFY_MAX_SAMPLES=3
MEASURE_COOLDOWN_PERCENT=100
MEASURE_ACTIVE_STAGE="MEASUREMENT"
IPERF_LAST_FAILURE_REASON="none"

measurement_profile_configure() {
    local profile="${1:-standard}"
    case "$profile" in
        quick)
            MEASURE_CONTROL_SAMPLES=2; MEASURE_SATURATION_SAMPLES=2
            MEASURE_CANDIDATE_SAMPLES=2; MEASURE_VERIFY_SAMPLES=2; MEASURE_COOLDOWN_PERCENT=60
            MEASURE_CONTROL_MAX_SAMPLES=2; MEASURE_SATURATION_MAX_SAMPLES=2
            MEASURE_CANDIDATE_MAX_SAMPLES=2; MEASURE_VERIFY_MAX_SAMPLES=2
            ;;
        standard)
            MEASURE_CONTROL_SAMPLES=3; MEASURE_SATURATION_SAMPLES=2
            MEASURE_CANDIDATE_SAMPLES=2; MEASURE_VERIFY_SAMPLES=2; MEASURE_COOLDOWN_PERCENT=100
            MEASURE_CONTROL_MAX_SAMPLES=3; MEASURE_SATURATION_MAX_SAMPLES=3
            MEASURE_CANDIDATE_MAX_SAMPLES=3; MEASURE_VERIFY_MAX_SAMPLES=3
            ;;
        strict)
            MEASURE_CONTROL_SAMPLES=4; MEASURE_SATURATION_SAMPLES=3
            MEASURE_CANDIDATE_SAMPLES=3; MEASURE_VERIFY_SAMPLES=3; MEASURE_COOLDOWN_PERCENT=150
            MEASURE_CONTROL_MAX_SAMPLES=5; MEASURE_SATURATION_MAX_SAMPLES=4
            MEASURE_CANDIDATE_MAX_SAMPLES=4; MEASURE_VERIFY_MAX_SAMPLES=4
            ;;
        *) die "measurement profile 必须是 quick、standard 或 strict"; return 1 ;;
    esac
    MEASUREMENT_PROFILE="$profile"
}

measurement_profile_stage_durations() {
    local base="$1" control saturation coarse confirm
    is_uint "$base" && (( base >= 3 && base <= 120 )) || return 1
    case "$MEASUREMENT_PROFILE" in
        quick)
            control="$base"; ((control < 4)) && control=4; ((control > 5)) && control=5
            saturation="$base"; ((saturation > 4)) && saturation=4
            coarse="$base"; ((coarse > 3)) && coarse=3
            confirm=$((base+1)); ((confirm < 5)) && confirm=5; ((confirm > 6)) && confirm=6
            ;;
        strict)
            control=$((base+2)); ((control < 7)) && control=7; ((control > 10)) && control=10
            saturation=$((base+2)); ((saturation > 10)) && saturation=10
            coarse=$((base+1)); ((coarse > 7)) && coarse=7
            confirm=$((base+3)); ((confirm < 8)) && confirm=8; ((confirm > 12)) && confirm=12
            ;;
        *)
            control="$base"; ((control < 5)) && control=5; ((control > 8)) && control=8
            saturation="$base"; ((saturation > 6)) && saturation=6
            coarse="$base"; ((coarse > 5)) && coarse=5
            confirm=$((base+2)); ((confirm < 6)) && confirm=6; ((confirm > 10)) && confirm=10
            ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$control" "$saturation" "$coarse" "$confirm"
}

measurement_profile_verify_duration() {
    local base="$1"
    case "$MEASUREMENT_PROFILE" in quick) (( base > 4 )) && base=4 ;; strict) (( base < 8 )) && base=8 ;; esac
    printf '%s\n' "$base"
}

measurement_budget_configure() {
    local max_bytes="${1:-6442450944}" max_seconds="${2:-900}"
    is_uint "$max_bytes" && (( max_bytes >= 1048576 && max_bytes <= 1099511627776 )) || {
        die "measurement TX budget 必须在 1 MiB 到 1 TiB 之间"; return 1;
    }
    is_uint "$max_seconds" && (( max_seconds >= 30 && max_seconds <= 86400 )) || {
        die "measurement duration budget 必须在 30–86400 秒之间"; return 1;
    }
    MEASURE_MAX_TX_BYTES="$max_bytes"; MEASURE_MAX_DURATION_SECONDS="$max_seconds"
    MEASURE_BUDGET_CONFIGURED=1; MEASURE_BUDGET_IFACE=""; MEASURE_BUDGET_TX_START=0; MEASURE_BUDGET_RX_START=0
    MEASURE_BUDGET_STARTED_EPOCH=$(date +%s); MEASURE_BUDGET_STAGE=""
    TEST_TX_BYTES_USED=0; TEST_RX_BYTES_USED=0; TEST_DURATION_USED=0
    MEASURE_BUDGET_PREBIND_TX_BYTES=0; MEASURE_BUDGET_PREBIND_RX_BYTES=0
    ((MEASURE_BUDGET_INITIALIZATION_COUNT+=1))
}

measurement_budget_ensure() {
    local iface="$1"
    (( MEASURE_BUDGET_CONFIGURED == 1 )) || measurement_budget_configure || return 1
    if [[ -z "$MEASURE_BUDGET_IFACE" ]]; then
        MEASURE_BUDGET_IFACE="$iface"
        MEASURE_BUDGET_TX_START=$(interface_counter "$iface" tx_bytes)
        MEASURE_BUDGET_RX_START=$(interface_counter "$iface" rx_bytes)
    elif [[ "$MEASURE_BUDGET_IFACE" != "$iface" ]]; then
        failure_set MEASUREMENT route-ambiguous "budget accounting interface changed from $MEASURE_BUDGET_IFACE to $iface" 2>/dev/null || true
        die "测量预算已绑定 $MEASURE_BUDGET_IFACE，不能切换到 $iface"
        return "$MEASURE_ROUTE_MISMATCH_RC"
    fi
}

measurement_usage_update() {
    local tx_now rx_now now
    (( MEASURE_BUDGET_CONFIGURED == 1 )) || return 0
    now=$(date +%s)
    TEST_TX_BYTES_USED="$MEASURE_BUDGET_PREBIND_TX_BYTES"; TEST_RX_BYTES_USED="$MEASURE_BUDGET_PREBIND_RX_BYTES"
    if [[ -n "$MEASURE_BUDGET_IFACE" ]]; then
        tx_now=$(interface_counter "$MEASURE_BUDGET_IFACE" tx_bytes); rx_now=$(interface_counter "$MEASURE_BUDGET_IFACE" rx_bytes)
        is_uint "$tx_now" && is_uint "$MEASURE_BUDGET_TX_START" && (( tx_now >= MEASURE_BUDGET_TX_START )) && TEST_TX_BYTES_USED=$((MEASURE_BUDGET_PREBIND_TX_BYTES+tx_now-MEASURE_BUDGET_TX_START))
        is_uint "$rx_now" && is_uint "$MEASURE_BUDGET_RX_START" && (( rx_now >= MEASURE_BUDGET_RX_START )) && TEST_RX_BYTES_USED=$((MEASURE_BUDGET_PREBIND_RX_BYTES+rx_now-MEASURE_BUDGET_RX_START))
    fi
    is_uint "$now" && is_uint "$MEASURE_BUDGET_STARTED_EPOCH" && (( now >= MEASURE_BUDGET_STARTED_EPOCH )) && TEST_DURATION_USED=$((now-MEASURE_BUDGET_STARTED_EPOCH))
}

measurement_budget_check() {
    local stage="${1:-MEASUREMENT}" reserved_bytes="${2:-0}" reserved_seconds="${3:-0}"
    local projected projected_duration remaining
    (( MEASURE_BUDGET_CONFIGURED == 1 )) || return 0
    is_uint "$reserved_bytes" || reserved_bytes=0
    is_uint "$reserved_seconds" || reserved_seconds=0
    measurement_usage_update
    projected=$((TEST_TX_BYTES_USED + reserved_bytes))
    projected_duration=$((TEST_DURATION_USED + reserved_seconds))
    if (( TEST_TX_BYTES_USED >= MEASURE_MAX_TX_BYTES || projected >= MEASURE_MAX_TX_BYTES ||
          TEST_DURATION_USED >= MEASURE_MAX_DURATION_SECONDS || projected_duration >= MEASURE_MAX_DURATION_SECONDS )); then
        MEASURE_BUDGET_STAGE="$stage"
        if declare -F failure_set >/dev/null; then
            failure_set "$stage" budget-exceeded "TX=${TEST_TX_BYTES_USED}/${MEASURE_MAX_TX_BYTES} bytes; reserved-next=${reserved_bytes}; duration=${TEST_DURATION_USED}/${MEASURE_MAX_DURATION_SECONDS}s; reserved-time-next=${reserved_seconds}s" "" "$MEASURE_BUDGET_RC"
        fi
        if (( reserved_bytes > 0 && TEST_TX_BYTES_USED < MEASURE_MAX_TX_BYTES )); then
            remaining=$((MEASURE_MAX_TX_BYTES-TEST_TX_BYTES_USED))
            log INFO "剩余 TX 预算 $(human_bytes "$remaining")；下一 ${stage} 样本预计至少需要 $(human_bytes "$reserved_bytes")"
        fi
        log ERR "测速硬预算不足：TX $(human_bytes "$TEST_TX_BYTES_USED") / $(human_bytes "$MEASURE_MAX_TX_BYTES")，时间 ${TEST_DURATION_USED}s / ${MEASURE_MAX_DURATION_SECONDS}s；为避免突破硬预算，不启动下一次 iperf"
        return "$MEASURE_BUDGET_RC"
    fi
}

measurement_sample_projected_tx() {
    local rate_mbit="$1" duration="$2" flows="$3" recent_sender="${4:-0}" recent_retrans="${5:-0}" recent_background="${6:-0}"
    local semantics="${7:-aggregate}"
    is_decimal "$rate_mbit" && awk -v r="$rate_mbit" 'BEGIN {exit !(r>0)}' || return 1
    is_uint "$duration" && (( duration > 0 )) || return 1
    is_uint "$flows" && (( flows > 0 )) || return 1
    is_decimal "$recent_sender" || recent_sender=0
    is_decimal "$recent_retrans" || recent_retrans=0
    is_decimal "$recent_background" || recent_background=0
    [[ "$semantics" == shaped || "$semantics" == unshaped || "$semantics" == aggregate ]] || return 1
    awk -v rate="$rate_mbit" -v duration="$duration" -v sender="$recent_sender" \
        -v retrans="$recent_retrans" -v background="$recent_background" -v semantics="$semantics" 'BEGIN {
        # Every caller supplies an aggregate rate. Parallel iperf streams share
        # that aggregate qdisc/link ceiling, so flows must never multiply bytes.
        if (semantics=="unshaped" && sender>rate) rate=sender
        if (retrans<0) retrans=0; if (retrans>50) retrans=50
        if (background<0) background=0; if (background>25) background=25
        factor=1.12+retrans/100+background/100
        nominal=rate*1000000/8*duration
        # Fixed headroom covers control packets, counter sampling skew and low
        # background traffic without replacing actual interface accounting.
        printf "%.0f\n", nominal*factor+1048576
    }'
}

measurement_first_sample_plan() {
    local mode="$1" nominal="$2" cap="$3" base_duration="$4"
    local control_duration saturation_duration coarse_duration confirm_duration
    local stage rate duration flows semantics reserved_bytes reserved_seconds
    [[ "$mode" == none || "$mode" == known || "$mode" == auto ]] || return 1
    is_uint "$nominal" && is_uint "$cap" && is_uint "$base_duration" || return 1
    IFS=$'\t' read -r control_duration saturation_duration coarse_duration confirm_duration <<< \
        "$(measurement_profile_stage_durations "$base_duration")" || return 1
    case "$mode" in
        none)
            printf 'NONE\t0\t0\t0\tnone\t0\t0\n'
            return 0
            ;;
        known)
            (( nominal > 0 )) || return 1
            stage=PATH_CONTROL; rate=$((nominal * 40 / 100)); (( rate < 1 )) && rate=1
            duration="$control_duration"; flows=1; semantics=shaped
            ;;
        auto)
            (( cap > 0 )) || return 1
            stage=SATURATION; rate="$cap"; duration="$saturation_duration"; flows=1; semantics=unshaped
            ;;
    esac
    reserved_bytes=$(measurement_sample_projected_tx "$rate" "$duration" "$flows" 0 0 0 "$semantics") || return 1
    reserved_seconds=$((duration + MEASURE_IPERF_TIMEOUT_GUARD_SECONDS))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$stage" "$rate" "$duration" "$flows" "$semantics" "$reserved_bytes" "$reserved_seconds"
}

measurement_first_sample_budget_check() {
    local max_bytes="$1" max_seconds="$2" mode="$3" nominal="$4" cap="$5" base_duration="$6"
    local plan stage rate duration flows semantics reserved_bytes reserved_seconds
    is_uint "$max_bytes" && is_uint "$max_seconds" || return 1
    plan=$(measurement_first_sample_plan "$mode" "$nominal" "$cap" "$base_duration") || return 1
    IFS=$'\t' read -r stage rate duration flows semantics reserved_bytes reserved_seconds <<< "$plan"
    [[ "$stage" == NONE ]] && return 0
    (( reserved_bytes < max_bytes && reserved_seconds < max_seconds )) || return "$MEASURE_BUDGET_RC"
}

measurement_budget_reserve_sample() {
    local stage="$1" rate_mbit="$2" duration="$3" flows="$4" recent_sender="${5:-0}"
    local recent_retrans="${6:-0}" recent_background="${7:-0}" semantics="${8:-aggregate}"
    local reserved_bytes reserved_seconds
    (( MEASURE_BUDGET_CONFIGURED == 1 )) || return 0
    if ! reserved_bytes=$(measurement_sample_projected_tx "$rate_mbit" "$duration" "$flows" \
        "$recent_sender" "$recent_retrans" "$recent_background" "$semantics"); then
        # A throughput session without a defensible aggregate rate cannot be
        # proven safe under a hard cap. Fail closed before spawning iperf.
        reserved_bytes="$MEASURE_MAX_TX_BYTES"
    fi
    if is_uint "$duration"; then reserved_seconds=$((duration + MEASURE_IPERF_TIMEOUT_GUARD_SECONDS))
    else reserved_seconds="$MEASURE_MAX_DURATION_SECONDS"
    fi
    measurement_budget_check "$stage" "$reserved_bytes" "$reserved_seconds"
}

measurement_peer_health_finalize() {
    local peer="$1" family="$2" address="$3" port="$4" rc="$5"
    local rtt="${6:-na}" receiver="${7:-na}" quality="${8:-unknown}" semantic="${9:-}" reason="${FAILURE_REASON:-measurement-unstable}"
    declare -F peer_health_record >/dev/null || return 0
    if (( rc == 0 )); then
        peer_health_record "$peer" "$family" "$address" "$port" success none "$rtt" "$receiver" "$quality"
        return
    fi
    if [[ "$semantic" == measurement-inconclusive || "$semantic" == knee-not-located ]]; then
        peer_health_record "$peer" "$family" "$address" "$port" inconclusive "$semantic" "$rtt" "$receiver" "$quality"
        return
    fi
    # Unavailable/busy/reset/timeout attempts are recorded at the exact
    # iperf failure site. Do not double-count the final failed attempt here.
    # Local budget, route, TC and rollback failures are not peer-health facts.
    case "$reason" in
        peer-unavailable|peer-busy|peer-reset|peer-timeout|budget-exceeded|path-changed|endpoint-changed|\
        route-ambiguous|nexthop-unresolved|tc-ownership-conflict|runtime-verify-failed|rollback-failed|\
        cpu-busy|high-steal|background-traffic|disk-space-low|memory-low) return 0 ;;
        path-dirty|peer-too-slow|measurement-unstable|sample-contaminated|protocol-failure)
            peer_health_record "$peer" "$family" "$address" "$port" failure "$reason" "$rtt" "$receiver" "$quality"
            ;;
        *) return 0 ;;
    esac
}

# Public endpoints are opt-in and used only by the interactive auto-tune wizard.
# Providers and test traffic are disclosed before execution; a private iperf3 peer is preferred.
PUBLIC_PEER_POOL=$(cat <<'EOF'
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
lon.speedtest.clouvider.net|伦敦|Clouvider
EOF
)

parse_peer_spec() {
    local spec="$1" default_port="${2:-5201}"
    PEER_HOST=""; PEER_PORT="$default_port"
    if [[ "$spec" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^([^:]+):([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    else
        PEER_HOST="$spec"
    fi
    validate_peer "$PEER_HOST" "$PEER_PORT"
}

public_peer_ports() {
    local host="$1" limit="${2:-1}" requested_iface="${3:-auto}" port found=0 rtt
    is_uint "$limit" && (( limit >= 1 && limit <= 4 )) || limit=1
    for port in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200; do
        if measure_lock_peer "$host" "$requested_iface" "$port" "" "" 1; then
            rtt=$(median_ping_ms "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_FAMILY" 2>/dev/null || true)
            [[ -n "$rtt" ]] || rtt=9999
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$port" "$MEASURE_PEER_ADDRESS" \
                "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE" "$rtt"
            measure_clear_peer_lock
            ((found+=1))
            (( found < limit )) || return 0
        fi
    done
    (( found > 0 ))
}

peer_route_rtt() {
    local host="$1" requested_iface="${2:-auto}" addresses ordered v6_records family address rtt
    addresses=$(resolve_route_target_addresses "$host") || return 1
    [[ -n "$addresses" ]] || return 1
    ordered=$(awk -F'\t' '$1==4 {print}' <<< "$addresses")
    v6_records=$(awk -F'\t' '$1==6 {print}' <<< "$addresses")
    if [[ -n "$v6_records" ]]; then
        if [[ -n "$ordered" ]]; then ordered+=$'\n'; fi
        ordered+="$v6_records"
    fi
    while IFS=$'\t' read -r family address; do
        [[ "$family" == 4 || "$family" == 6 ]] || continue
        if measure_lock_peer "$host" "$requested_iface" "" "$address" "" 1 2>/dev/null; then
            rtt=$(median_ping_ms "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_FAMILY" 2>/dev/null || true)
            measure_clear_peer_lock
            if [[ -n "$rtt" ]]; then
                printf '%s\n' "$rtt"
                return 0
            fi
        fi
    done <<< "$ordered"
    measure_clear_peer_lock
    return 1
}

auto_pick_peer() {
    require_commands ip getent ping timeout iperf3 jq || return 1
    local requested_iface="${1:-auto}" temp host region provider rtt port address family source iface endpoint_rtt
    local max_rtt="${BBRV3_PEER_MAX_RTT:-120}"
    local limit="${BBRV3_PUBLIC_PEER_CANDIDATES:-4}" per_host="${BBRV3_PUBLIC_PORTS_PER_HOST:-2}" candidate found rank
    local primary_host="" preferred_extra="" primary_take index
    local -a primary_candidates=() extra_candidates=() ordered_candidates=()
    is_uint "$max_rtt" && (( max_rtt >= 1 && max_rtt <= 10000 )) || max_rtt=120
    is_uint "$limit" && (( limit >= 2 && limit <= 8 )) || limit=4
    is_uint "$per_host" && (( per_host >= 1 && per_host <= 4 )) || per_host=2
    PUBLIC_PEER_CANDIDATES=()
    temp=$(mktemp -d) || return 1
    log INFO "正在按 RTT 筛选公共 iperf3 节点（Leaseweb / OVH / Clouvider）"
    while IFS='|' read -r host region provider; do
        [[ -n "$host" ]] || continue
        (
            rtt=$(peer_route_rtt "$host" "$requested_iface")
            [[ -n "$rtt" ]] && printf '%s\t%s\t%s\t%s\n' "$rtt" "$host" "$region" "$provider" > "$temp/${host//[^a-zA-Z0-9]/_}"
        ) &
    done <<< "$PUBLIC_PEER_POOL"
    wait || true
    while IFS=$'\t' read -r rtt host region provider; do
        (( rtt <= max_rtt )) || { log INFO "$host ($region/$provider) RTT ${rtt}ms，过远跳过"; continue; }
        found=0; rank=0
        while IFS=$'\t' read -r port address family source iface endpoint_rtt; do
            [[ -n "$port" && -n "$address" && -n "$source" && -n "$iface" ]] || continue
            if ! is_uint "$endpoint_rtt" || (( endpoint_rtt > max_rtt )); then
                log INFO "$host:$port -> $address (IPv${family:-?}) RTT ${endpoint_rtt:-unknown}ms，过远或不可测，跳过"
                continue
            fi
            candidate="$host|$address|$family|$source|$iface|$port|$endpoint_rtt|$region|$provider"
            if (( rank == 0 )); then primary_candidates+=("$candidate"); else extra_candidates+=("$candidate"); fi
            ((found+=1)); ((rank+=1))
        done < <(public_peer_ports "$host" "$per_host" "$requested_iface")
        (( found > 0 )) || log INFO "$host ($region/$provider) 当前无可用测试端口"
        # Prefer distinct hosts before reserving a second port on the same host.
        (( ${#primary_candidates[@]} < limit )) || break
    done < <(cat "$temp"/* 2>/dev/null | sort -n)
    rm -rf -- "$temp"
    if ((${#primary_candidates[@]} > 0)); then
        if declare -F peer_health_rank_candidates >/dev/null; then
            mapfile -t primary_candidates < <(printf '%s\n' "${primary_candidates[@]}" | peer_health_rank_candidates)
            if ((${#extra_candidates[@]} > 0)); then
                mapfile -t extra_candidates < <(printf '%s\n' "${extra_candidates[@]}" | peer_health_rank_candidates)
            fi
        fi
        primary_host="${primary_candidates[0]%%|*}"
        for candidate in "${extra_candidates[@]}"; do
            if [[ "${candidate%%|*}" == "$primary_host" ]]; then preferred_extra="$candidate"; break; fi
        done
        primary_take=$limit
        [[ -z "$preferred_extra" ]] || primary_take=$((limit - 1))
        for ((index=0; index<${#primary_candidates[@]} && index<primary_take; index++)); do
            ordered_candidates+=("${primary_candidates[$index]}")
        done
        [[ -z "$preferred_extra" ]] || ordered_candidates+=("$preferred_extra")
        for ((; index<${#primary_candidates[@]}; index++)); do ordered_candidates+=("${primary_candidates[$index]}"); done
        for candidate in "${extra_candidates[@]}"; do
            [[ "$candidate" == "$preferred_extra" ]] || ordered_candidates+=("$candidate")
        done
    fi
    for candidate in "${ordered_candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        PUBLIC_PEER_CANDIDATES+=("$candidate")
        IFS='|' read -r host address family source iface port rtt region provider <<< "$candidate"
        local health_score=na health_reason=no-history
        if declare -F peer_health_score >/dev/null; then IFS=$'\t' read -r health_score health_reason <<< "$(peer_health_score "$host" "$family" "$address" "$port" "$rtt")"; fi
        if (( ${#PUBLIC_PEER_CANDIDATES[@]} == 1 )); then
            log OK "公共对端已通过 IPv${family} iperf3 预检: $host:$port -> $address ($region/$provider, RTT ${rtt}ms, health ${health_score}/100 ${health_reason})"
        else
            log INFO "已保留备用公共对端: $host:$port -> $address (IPv${family}, $region/$provider, RTT ${rtt}ms, health ${health_score}/100 ${health_reason})"
        fi
        (( ${#PUBLIC_PEER_CANDIDATES[@]} < limit )) || break
    done
    ((${#PUBLIC_PEER_CANDIDATES[@]} > 0)) || { die "${max_rtt}ms 内没有可用公共 iperf3 节点；请使用自有对端"; return 1; }
}

interface_counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || printf '0\n'; }

measure_set_latency_baseline() {
    local peer="$1" path_samples="${2:-${BBRV3_PATH_SAMPLES:-7}}" path_pmtu="${3:-${BBRV3_PATH_PMTU:-1}}"
    local value="" target family="auto" guarded=0
    target="$peer"
    MEASURE_IDLE_RTT_MS="na"
    [[ "$(uname -s 2>/dev/null || true)" == Linux ]] || return 0
    command_exists ping || return 0
    if [[ -n "$MEASURE_PEER_ADDRESS" && ( "$peer" == "$MEASURE_PEER_HOST" || "$peer" == "$MEASURE_PEER_ADDRESS" ) ]]; then
        target="$MEASURE_PEER_ADDRESS"
        family="$MEASURE_PEER_FAMILY"
        measure_peer_route_guard || return 1
        guarded=1
    elif [[ "$peer" == *:* ]]; then
        family=6
    elif [[ "$peer" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        family=4
    fi
    if (( guarded )); then
        path_profile_capture "$path_samples" "$path_pmtu" || return 1
        value="$PATH_RTT_MEDIAN_MS"
    else
        value=$(median_ping_ms "$target" "$family" 2>/dev/null || true)
    fi
    (( guarded == 0 )) || measure_peer_route_guard || return 1
    if is_decimal "$value"; then
        MEASURE_IDLE_RTT_MS="$value"
        log INFO "空闲 RTT 基线: ${value} ms"
    else
        log WARN "未取得空闲 RTT；吞吐和重传仍会测量，但负载延迟与置信度会降级"
    fi
}

measure_begin() {
    local iface="$1" snapshot
    [[ -z "$MEASURE_SNAPSHOT" ]] || {
        die "已有未恢复的测量 qdisc 快照: $MEASURE_SNAPSHOT"
        return 1
    }
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || {
        rm -f -- "$snapshot"
        return 1
    }
    MEASURE_IFACE="$iface"
    MEASURE_SNAPSHOT="$snapshot"
    MEASURE_TX_START=$(interface_counter "$iface" tx_bytes)
    MEASURE_RX_START=$(interface_counter "$iface" rx_bytes)
    local budget_rc=0
    if measurement_budget_ensure "$iface"; then :; else
        budget_rc=$?
        rm -f -- "$snapshot"
        MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        return "$budget_rc"
    fi
    if measurement_budget_check PREFLIGHT; then :; else
        budget_rc=$?
        rm -f -- "$snapshot"
        MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        return "$budget_rc"
    fi
    trap 'measure_abort 130' INT TERM HUP
}

measure_restore() {
    local rc=0 iface="$MEASURE_IFACE" snapshot="$MEASURE_SNAPSHOT"
    if [[ -z "$iface" && -z "$snapshot" ]]; then
        trap - INT TERM HUP
        measure_clear_peer_lock
        return 0
    fi
    if [[ -z "$iface" || -z "$snapshot" || ! -f "$snapshot" ]]; then
        log ERR "测量 qdisc 回滚状态不完整；保留现场以便人工恢复（iface=${iface:-missing}, snapshot=${snapshot:-missing}）"
        return 1
    fi
    restore_action_qdisc "$iface" "$snapshot" || rc=$?
    if (( rc != 0 )); then
        log ERR "测量 qdisc 回滚失败；快照保留在 $snapshot，退出清理将再次尝试"
        return "$rc"
    fi
    rm -f -- "$snapshot"
    trap - INT TERM HUP
    MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
    measure_clear_peer_lock
    return "$rc"
}

measure_abort() {
    local rc="${1:-130}"
    log WARN "测试被中断，正在恢复操作前 qdisc"
    measure_restore || true
    release_lock
    exit "$rc"
}

traffic_report() {
    local tx_now rx_now tx rx
    tx_now=$(interface_counter "$1" tx_bytes); rx_now=$(interface_counter "$1" rx_bytes)
    tx=$((tx_now - MEASURE_TX_START)); rx=$((rx_now - MEASURE_RX_START))
    (( tx < 0 )) && tx=0; (( rx < 0 )) && rx=0
    measurement_usage_update
    log INFO "本轮接口流量: TX $(human_bytes "$tx"), RX $(human_bytes "$rx")"
    log INFO "测量预算累计: TX $(human_bytes "$TEST_TX_BYTES_USED") / $(human_bytes "$MEASURE_MAX_TX_BYTES"), 时间 ${TEST_DURATION_USED}s / ${MEASURE_MAX_DURATION_SECONDS}s"
}

validate_peer() {
    [[ "$1" != -* && "$1" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法 peer: $1"; return 1; }
    is_uint "$2" && (( $2 >= 1 && $2 <= 65535 )) || { die "非法端口: $2"; return 1; }
}

measure_clear_peer_lock() {
    MEASURE_PEER_HOST=""
    MEASURE_PEER_ADDRESS=""
    MEASURE_PEER_SOURCE=""
    MEASURE_PEER_FAMILY=""
    MEASURE_PEER_IFACE=""
    MEASURE_PEER_PORT=""
    path_state_reset
}

measure_route_output_sources() {
    awk '{for (i=1; i<NF; i++) if ($i=="src") print $(i+1)}' | awk '!seen[$0]++'
}

measure_source_address_is_valid() {
    local family="$1" source="$2" octet
    local -a octets=()
    [[ -n "$source" && "$source" != -* && "$source" != *[[:space:]]* ]] || return 1
    case "$family" in
        4)
            [[ "$source" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
            IFS=. read -r -a octets <<< "$source"
            ((${#octets[@]} == 4)) || return 1
            for octet in "${octets[@]}"; do
                [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( 10#$octet <= 255 )) || return 1
            done
            [[ "$source" != 0.0.0.0 ]]
            ;;
        6)
            [[ "$source" == *:* && "$source" =~ ^[0-9A-Fa-f:.]+$ && "$source" != :: ]]
            ;;
        *) return 1 ;;
    esac
}

measure_unique_route_iface() {
    route_unique_path_iface "$1" "$2" "${3:-}"
}

# Revalidate one already-resolved literal through the platform's strict
# route-get/fibmatch gate, then prove that binding the selected source address
# does not select another policy-routing path.
measure_capture_route_state() {
    local family="$1" address="$2" expected_iface="$3" expected_source="${4:-}"
    local records record_count record_family record_address record_iface output iface sources source source_count
    local bound_output bound_iface bound_fibmatch bound_fib_iface
    records=$(target_route_records "$address") || return 1
    record_count=$(awk 'NF {count++} END {print count+0}' <<< "$records")
    if ! is_uint "${record_count:-}" || (( record_count != 1 )); then
        die "测速地址 $address 的严格路由核验没有返回唯一记录"
        return 1
    fi
    IFS=$'\t' read -r record_family record_address record_iface <<< "$records"
    [[ "$record_family" == "$family" && "$record_address" == "$address" && "$record_iface" == "$expected_iface" ]] || {
        die "测速地址 $address 的冻结路由与预期不一致（IPv${record_family:-?}/${record_iface:-?}，预期 IPv${family}/$expected_iface）"
        return 1
    }

    if ! output=$(ip "-$family" route get "$address" 2>/dev/null) || [[ -z "$output" ]]; then
        die "测速地址 $address 无法取得 route-get 来源地址"
        return 1
    fi
    iface=$(measure_unique_route_iface "$output" "测速地址 $address 的 route-get" "$family") || return 1
    [[ "$iface" == "$expected_iface" ]] || {
        die "测速地址 $address 的出口已从 $expected_iface 漂移到 $iface"
        return 1
    }
    sources=$(measure_route_output_sources <<< "$output")
    source_count=$(awk 'NF {count++} END {print count+0}' <<< "$sources")
    if ! is_uint "${source_count:-}" || (( source_count != 1 )); then
        die "测速地址 $address 的 route-get 无法确定唯一来源地址"
        return 1
    fi
    source=$(head -n1 <<< "$sources")
    measure_source_address_is_valid "$family" "$source" || {
        die "测速地址 $address 返回非法 IPv${family} 来源地址: $source"
        return 1
    }
    if [[ -n "$expected_source" && "$source" != "$expected_source" ]]; then
        die "测速地址 $address 的来源地址已从 $expected_source 漂移到 $source"
        return 1
    fi

    if ! bound_output=$(ip "-$family" route get "$address" from "$source" 2>/dev/null) || [[ -z "$bound_output" ]]; then
        die "测速地址 $address 无法用冻结来源地址 $source 完成 route-get"
        return 1
    fi
    bound_iface=$(measure_unique_route_iface "$bound_output" "测速地址 $address 的来源绑定 route-get" "$family") || return 1
    [[ "$bound_iface" == "$expected_iface" ]] || {
        die "绑定来源地址 $source 后，测速出口从 $expected_iface 变为 $bound_iface"
        return 1
    }
    if ! bound_fibmatch=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || [[ -z "$bound_fibmatch" ]]; then
        die "无法用 fibmatch 核验测速地址 $address 的来源绑定路径"
        return 1
    fi
    bound_fib_iface=$(measure_unique_route_iface "$bound_fibmatch" "测速地址 $address 的来源绑定 fibmatch" "$family") || return 1
    [[ "$bound_fib_iface" == "$expected_iface" ]] || {
        die "绑定来源地址 $source 后，测速 fibmatch 出口从 $expected_iface 变为 $bound_fib_iface"
        return 1
    }
    printf '%s\t%s\n' "$iface" "$source"
}

# Resolve a hostname once, prefer IPv4 for broad public-server compatibility,
# and fall back to IPv6 only when the exact IPv4 endpoint is not route-safe or
# cannot complete a low-traffic iperf3 preflight. Explicit literals never
# change family. A preferred address/source comes from the interactive public
# preflight and deliberately bypasses DNS so the formal run uses that tuple.
measure_lock_peer() {
    local peer="$1" requested_iface="$2" port="${3:-}" preferred_address="${4:-}" preferred_source="${5:-}" quiet="${6:-0}"
    local addresses ordered family address state iface source record record_family record_address record_iface
    local is_literal=0 exact_candidate=0 resolved_count=0 route_candidates=0 service_candidates=0
    local pre_account=0 pre_tx_before=0 pre_tx_after=0 pre_rx_before=0 pre_rx_after=0

    # A failed re-lock must never leave a previous endpoint looking current.
    measure_clear_peer_lock
    [[ "$requested_iface" == auto ]] || validate_interface_name "$requested_iface" || {
        die "非法测速出口网卡: $requested_iface"
        return 1
    }
    [[ -z "$port" ]] || { is_uint "$port" && (( port >= 1 && port <= 65535 )); } || {
        die "非法测速端口: $port"
        return 1
    }
    [[ "$quiet" == 0 || "$quiet" == 1 ]] || return 1
    if [[ "$peer" == *:* ]]; then
        is_literal=1
    elif [[ "$peer" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        is_literal=1
    fi

    if [[ -n "$preferred_address" ]]; then
        exact_candidate=1
        if measure_source_address_is_valid 4 "$preferred_address"; then family=4
        elif measure_source_address_is_valid 6 "$preferred_address"; then family=6
        else
            die "预选测速地址无效: $preferred_address"
            return 1
        fi
        if (( is_literal )) && [[ "$peer" != "$preferred_address" ]]; then
            die "显式测速地址 $peer 与预选地址 $preferred_address 不一致"
            return 1
        fi
        addresses=$(printf '%s\t%s\n' "$family" "$preferred_address")
    else
        addresses=$(resolve_route_target_addresses "$peer") || return 1
        [[ -n "$addresses" ]] || {
            (( quiet )) || die "无法解析测速对端 $peer"
            return "$IPERF_UNAVAILABLE_RC"
        }
    fi

    if (( is_literal || exact_candidate )); then
        ordered="$addresses"
    else
        # Do not inherit libc/getent family order. Public iperf3 coverage is
        # substantially broader over IPv4, while IPv6 remains a real fallback.
        ordered=$(awk -F'\t' '$1==4 {print}' <<< "$addresses")
        record=$(awk -F'\t' '$1==6 {print}' <<< "$addresses")
        if [[ -n "$record" ]]; then
            if [[ -n "$ordered" ]]; then ordered+=$'\n'; fi
            ordered+="$record"
        fi
    fi

    while IFS=$'\t' read -r family address; do
        [[ "$family" == 4 || "$family" == 6 ]] || {
            measure_clear_peer_lock
            die "测速对端 $peer 返回非法地址族"
            return 1
        }
        measure_source_address_is_valid "$family" "$address" || {
            measure_clear_peer_lock
            die "测速对端 $peer 返回非法 IPv${family} 地址: $address"
            return 1
        }
        ((resolved_count+=1))

        if [[ "$requested_iface" == auto ]]; then
            if (( is_literal || exact_candidate )); then
                record=$(target_route_records "$address") || { measure_clear_peer_lock; return 1; }
            else
                record=$(target_route_records "$address" 2>/dev/null) || {
                    (( quiet )) || log WARN "跳过 $address（IPv${family}）：没有可严格核验的唯一出口"
                    continue
                }
            fi
            IFS=$'\t' read -r record_family record_address record_iface <<< "$record"
            [[ "$record_family" == "$family" && "$record_address" == "$address" ]] || {
                measure_clear_peer_lock
                die "测速地址 $address 的路由记录与解析结果不一致"
                return 1
            }
            iface="$record_iface"
            validate_interface_name "$iface" || { measure_clear_peer_lock; return 1; }
            interface_is_excluded "$iface" && {
                (( quiet )) || log WARN "跳过 $address（IPv${family}）：出口 $iface 是受保护的虚拟接口"
                continue
            }
        else
            iface="$requested_iface"
        fi

        if (( is_literal || exact_candidate )); then
            state=$(measure_capture_route_state "$family" "$address" "$iface" "$preferred_source") || {
                measure_clear_peer_lock
                return 1
            }
        else
            state=$(measure_capture_route_state "$family" "$address" "$iface" 2>/dev/null) || {
                (( quiet )) || log WARN "跳过 $address（IPv${family}）：路由、来源地址或出口 $iface 核验未通过"
                continue
            }
        fi
        IFS=$'\t' read -r record_iface source <<< "$state"
        [[ "$record_iface" == "$iface" ]] || { measure_clear_peer_lock; return 1; }
        ((route_candidates+=1))

        if [[ -n "$port" ]]; then
            pre_account=0
            if [[ "${MEASURE_BUDGET_CONFIGURED:-0}" == 1 && -z "${MEASURE_BUDGET_IFACE:-}" ]]; then
                pre_tx_before=$(interface_counter "$iface" tx_bytes); pre_rx_before=$(interface_counter "$iface" rx_bytes); pre_account=1
            fi
            if ! peer_port_open "$address" "$port" || ! iperf_peer_usable "$address" "$port" "$family" "$source"; then
                if (( pre_account )); then
                    pre_tx_after=$(interface_counter "$iface" tx_bytes); pre_rx_after=$(interface_counter "$iface" rx_bytes)
                    is_uint "$pre_tx_before" && is_uint "$pre_tx_after" && (( pre_tx_after >= pre_tx_before )) && MEASURE_BUDGET_PREBIND_TX_BYTES=$((MEASURE_BUDGET_PREBIND_TX_BYTES+pre_tx_after-pre_tx_before))
                    is_uint "$pre_rx_before" && is_uint "$pre_rx_after" && (( pre_rx_after >= pre_rx_before )) && MEASURE_BUDGET_PREBIND_RX_BYTES=$((MEASURE_BUDGET_PREBIND_RX_BYTES+pre_rx_after-pre_rx_before))
                fi
                (( quiet )) || log WARN "跳过 $address:$port（IPv${family}）：TCP/iperf3 预检不可用"
                if (( is_literal || exact_candidate )); then
                    measure_clear_peer_lock
                    return "$IPERF_UNAVAILABLE_RC"
                fi
                continue
            fi
            if (( pre_account )); then
                pre_tx_after=$(interface_counter "$iface" tx_bytes); pre_rx_after=$(interface_counter "$iface" rx_bytes)
                is_uint "$pre_tx_before" && is_uint "$pre_tx_after" && (( pre_tx_after >= pre_tx_before )) && MEASURE_BUDGET_PREBIND_TX_BYTES=$((MEASURE_BUDGET_PREBIND_TX_BYTES+pre_tx_after-pre_tx_before))
                is_uint "$pre_rx_before" && is_uint "$pre_rx_after" && (( pre_rx_after >= pre_rx_before )) && MEASURE_BUDGET_PREBIND_RX_BYTES=$((MEASURE_BUDGET_PREBIND_RX_BYTES+pre_rx_after-pre_rx_before))
            fi
            ((service_candidates+=1))
        fi

        MEASURE_PEER_HOST="$peer"
        MEASURE_PEER_ADDRESS="$address"
        MEASURE_PEER_SOURCE="$source"
        MEASURE_PEER_FAMILY="$family"
        MEASURE_PEER_IFACE="$iface"
        MEASURE_PEER_PORT="$port"
        if ! path_lock_route_identity; then
            measure_clear_peer_lock
            return 1
        fi
        (( quiet )) || log INFO "已冻结测速路径: $peer -> $MEASURE_PEER_ADDRESS（IPv${MEASURE_PEER_FAMILY}, src $MEASURE_PEER_SOURCE, dev $MEASURE_PEER_IFACE${port:+, port $port}, path ${PATH_ROUTE_FINGERPRINT:0:12}）"
        return 0
    done <<< "$ordered"

    measure_clear_peer_lock
    (( quiet )) || {
        if [[ -n "$port" && $route_candidates -gt 0 && $service_candidates -eq 0 ]]; then
            die "测速对端 $peer:$port 没有可用的 IPv4/IPv6 iperf3 端点"
        else
            die "测速对端 $peer 没有能通过严格路由与来源地址核验的候选端点"
        fi
    }
    (( resolved_count > 0 )) || return "$IPERF_UNAVAILABLE_RC"
    return "$IPERF_UNAVAILABLE_RC"
}

measure_lock_requested_peer() {
    local peer="$1" port="$2" requested="$3" preferred_address="${4:-}" preferred_source="${5:-}"
    local expected_iface="$requested" lock_rc=0
    # The wrapper may fail before measure_lock_peer is reached (for example an
    # invalid explicit interface); stale state must not survive that failure.
    measure_clear_peer_lock
    if [[ "$requested" != auto ]]; then
        expected_iface=$(detect_interface "$requested") || return 1
    fi
    # The auto wizard and explicit-interface measure commands already know the
    # operation interface.  Bind the ledger before their formal service
    # precheck; do not prematurely bind direct `--interface auto` discovery,
    # which must remain able to choose the only usable address family.
    if [[ "$expected_iface" != auto && "${MEASURE_BUDGET_CONFIGURED:-0}" == 1 ]]; then
        measurement_budget_ensure "$expected_iface" || return $?
        measurement_budget_check PEER_PREFLIGHT || return $?
    fi
    if measure_lock_peer "$peer" "$expected_iface" "$port" "$preferred_address" "$preferred_source"; then :; else lock_rc=$?; fi
    if (( lock_rc == 0 )) && [[ "${MEASURE_BUDGET_CONFIGURED:-0}" == 1 ]]; then
        measurement_budget_ensure "$MEASURE_PEER_IFACE" || return $?
    fi
    if [[ "${MEASURE_BUDGET_CONFIGURED:-0}" == 1 ]]; then measurement_budget_check PEER_PREFLIGHT || return $?; fi
    return "$lock_rc"
}

measure_peer_route_guard() {
    local state iface source
    [[ -n "$MEASURE_PEER_ADDRESS" && -n "$MEASURE_PEER_SOURCE" &&
       ( "$MEASURE_PEER_FAMILY" == 4 || "$MEASURE_PEER_FAMILY" == 6 ) && -n "$MEASURE_PEER_IFACE" ]] || {
        die "正式测速尚未冻结对端地址、来源地址和出口网卡"
        return 1
    }
    if [[ -n "$MEASURE_IFACE" && "$MEASURE_IFACE" != "$MEASURE_PEER_IFACE" ]]; then
        die "测量网卡 $MEASURE_IFACE 与冻结出口 $MEASURE_PEER_IFACE 不一致"
        return "$MEASURE_ROUTE_MISMATCH_RC"
    fi
    state=$(measure_capture_route_state "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_IFACE" "$MEASURE_PEER_SOURCE") || {
        die "测速路径已漂移；拒绝继续并恢复操作前 qdisc"
        return "$MEASURE_ROUTE_MISMATCH_RC"
    }
    IFS=$'\t' read -r iface source <<< "$state"
    [[ "$iface" == "$MEASURE_PEER_IFACE" && "$source" == "$MEASURE_PEER_SOURCE" ]] || {
        die "测速路径已漂移；拒绝使用本次样本"
        return "$MEASURE_ROUTE_MISMATCH_RC"
    }
    path_verify_route_identity || {
        die "测速路由、网关、路由表、MTU 或 FIB 指纹已经漂移"
        return "$MEASURE_ROUTE_MISMATCH_RC"
    }
}

measure_require_sample_lock() {
    local peer="$1" port="${2:-}" iface
    if [[ -z "$MEASURE_PEER_ADDRESS" ]]; then
        iface="${MEASURE_IFACE:-auto}"
        measure_lock_peer "$peer" "$iface" "$port" || return $?
    elif [[ "$peer" != "$MEASURE_PEER_HOST" && "$peer" != "$MEASURE_PEER_ADDRESS" ]]; then
        die "样本对端 $peer 与冻结对端 $MEASURE_PEER_HOST/$MEASURE_PEER_ADDRESS 不一致"
        return 1
    fi
    if [[ -n "$port" && -z "$MEASURE_PEER_PORT" ]]; then
        measure_require_locked_port "$peer" "$port" || return $?
    elif [[ -n "$port" && -n "$MEASURE_PEER_PORT" && "$port" != "$MEASURE_PEER_PORT" ]]; then
        die "样本端口 $port 与冻结端口 $MEASURE_PEER_PORT 不一致"
        return 1
    fi
    measure_peer_route_guard
}

measure_require_locked_port() {
    local peer="$1" port="$2"
    measure_peer_route_guard || return $?
    if [[ -n "$MEASURE_PEER_PORT" && "$MEASURE_PEER_PORT" != "$port" ]]; then
        die "请求端口 $port 与冻结端口 $MEASURE_PEER_PORT 不一致"
        return 1
    fi
    if [[ -z "$MEASURE_PEER_PORT" ]] &&
       { ! peer_port_open "$MEASURE_PEER_ADDRESS" "$port" ||
         ! iperf_peer_usable "$MEASURE_PEER_ADDRESS" "$port" "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_SOURCE"; }; then
        die "无法连接 $peer:$port（冻结地址 $MEASURE_PEER_ADDRESS / IPv${MEASURE_PEER_FAMILY}）"
        measure_clear_peer_lock
        return "$IPERF_UNAVAILABLE_RC"
    fi
    MEASURE_PEER_PORT="$port"
    measure_peer_route_guard
}

measure_append_locked_peer_summary() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    printf 'LOCKED_ADDRESS\t%s\nLOCKED_SOURCE\t%s\nLOCKED_INTERFACE\t%s\nLOCKED_FAMILY\t%s\nLOCKED_PORT\t%s\n' \
        "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE" "$MEASURE_PEER_FAMILY" "${MEASURE_PEER_PORT:-none}" >> "$file"
    path_profile_append_summary "$file"
}

peer_port_open() {
    local peer="$1" port="$2"
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$peer" "$port" >/dev/null 2>&1
}

iperf_peer_usable() {
    local peer="$1" port="$2" family="${3:-}" source="${4:-}" json rc=0 error bps
    local -a family_arg=() bind_arg=()
    [[ -z "$family" || "$family" == 4 || "$family" == 6 ]] || return 1
    [[ -z "$family" ]] || family_arg=("-$family")
    [[ -z "$source" ]] || bind_arg=(-B "$source")
    json=$(mktemp) || return 1
    if timeout 8 iperf3 "${family_arg[@]}" -c "$peer" "${bind_arg[@]}" -p "$port" -t 1 -P 1 -b 1M -J > "$json" 2>/dev/null; then
        error=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
        bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json" 2>/dev/null || printf '0\n')
        [[ -z "$error" ]] && is_decimal "$bps" && awk -v b="$bps" 'BEGIN {exit !(b>0)}' || rc=1
    else
        rc=$?
    fi
    rm -f -- "$json"
    return "$rc"
}

iperf_failure_is_unavailable() {
    local reason="${1,,}"
    case "$reason" in
        *server*busy*|*busy*running*a*test*|*unable*to*connect*|*connection*refused*|*connection*timed*out*|*connection*reset*|*control*socket*closed*|*network*is*unreachable*|*no*route*to*host*|*broken*pipe*|*temporarily*unavailable*) return 0 ;;
        *) return 1 ;;
    esac
}

percentile_95_numbers() {
    sort -n | awk '{a[NR]=$1} END {if(NR) {i=int((NR*95+99)/100); if(i<1)i=1; if(i>NR)i=NR; print a[i]}}'
}

max_numbers() { sort -n | tail -n 1; }

median_or_na() {
    if (($#)); then printf '%s\n' "$@" | median_numbers; else printf 'na\n'; fi
}

max_or_na() {
    if (($#)); then printf '%s\n' "$@" | max_numbers; else printf 'na\n'; fi
}

latency_stats_from_file() {
    local file="$1" values median p95
    values=$(sed -n -E 's/.*time[=<]([0-9]+([.][0-9]+)?)[[:space:]]*ms.*/\1/p' "$file" 2>/dev/null || true)
    if [[ -z "$values" ]]; then
        printf 'na\tna\n'
        return 0
    fi
    median=$(median_numbers <<< "$values")
    p95=$(percentile_95_numbers <<< "$values")
    printf '%s\t%s\n' "$median" "$p95"
}

cpu_snapshot() {
    local _ user nice system idle iowait irq softirq steal total idle_all value
    [[ -r /proc/stat ]] || { printf 'na\tna\tna\n'; return 0; }
    read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat || {
        printf 'na\tna\tna\n'
        return 0
    }
    for value in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "${steal:-0}"; do
        is_uint "$value" || { printf 'na\tna\tna\n'; return 0; }
    done
    total=$((user + nice + system + idle + iowait + irq + softirq + ${steal:-0}))
    idle_all=$((idle + iowait))
    printf '%s\t%s\t%s\n' "$total" "$idle_all" "${steal:-0}"
}

cpu_delta_metrics() {
    local before="$1" after="$2" total_before idle_before steal_before total_after idle_after steal_after
    local total_delta idle_delta steal_delta
    IFS=$'\t' read -r total_before idle_before steal_before <<< "$before"
    IFS=$'\t' read -r total_after idle_after steal_after <<< "$after"
    if ! is_uint "$total_before" || ! is_uint "$idle_before" || ! is_uint "$steal_before" ||
       ! is_uint "$total_after" || ! is_uint "$idle_after" || ! is_uint "$steal_after" ||
       (( total_after <= total_before )); then
        printf 'na\tna\n'
        return 0
    fi
    total_delta=$((total_after - total_before)); idle_delta=$((idle_after - idle_before)); steal_delta=$((steal_after - steal_before))
    (( idle_delta < 0 )) && idle_delta=0; (( steal_delta < 0 )) && steal_delta=0
    awk -v t="$total_delta" -v i="$idle_delta" -v s="$steal_delta" 'BEGIN {
        busy=(t-i)*100/t; if(busy<0)busy=0; if(busy>100)busy=100;
        steal=s*100/t; if(steal<0)steal=0; if(steal>100)steal=100;
        printf "%.2f\t%.2f\n", busy, steal
    }'
}

cpu_core_snapshot() {
    awk '/^cpu[0-9]+[[:space:]]/ {
        total=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; steal=$9;
        printf "%s\t%.0f\t%.0f\t%.0f\n", $1, total, idle, steal
    }' /proc/stat 2>/dev/null || true
}

cpu_core_delta_metrics() {
    local before="$1" after="$2"
    awk -v before="$before" -v after="$after" 'BEGIN {
        nb=split(before, b, "\n"); na=split(after, a, "\n"); found=0; peak_busy=0; peak_steal=0;
        for(i=1;i<=nb;i++) {n=split(b[i], f, "\t"); if(n==4) {bt[f[1]]=f[2]; bi[f[1]]=f[3]; bs[f[1]]=f[4]}}
        for(i=1;i<=na;i++) {
            n=split(a[i], f, "\t"); key=f[1]; if(n!=4 || !(key in bt)) continue;
            total=f[2]-bt[key]; idle=f[3]-bi[key]; steal=f[4]-bs[key]; if(total<=0) continue;
            busy=(total-idle)*100/total; if(busy<0)busy=0; if(busy>100)busy=100;
            stealp=steal*100/total; if(stealp<0)stealp=0; if(stealp>100)stealp=100;
            if(!found || busy>peak_busy)peak_busy=busy; if(!found || stealp>peak_steal)peak_steal=stealp; found=1;
        }
        if(found) printf "%.2f\t%.2f\n", peak_busy, peak_steal; else print "na\tna"
    }'
}

background_tx_percent() {
    local before="$1" after="$2" payload="$3"
    if ! is_uint "$before" || ! is_uint "$after" || ! is_uint "$payload" || (( after < before )); then
        printf 'na\n'
        return 0
    fi
    awk -v tx="$((after-before))" -v payload="$payload" 'BEGIN {
        # Permit link/IP/TCP overhead plus a small fixed control-traffic allowance.
        allowed=payload*1.12+65536;
        if(tx<=allowed || tx<=0) {printf "0.00\n"; exit}
        printf "%.2f\n", (tx-allowed)*100/tx
    }'
}

sample_is_contaminated() {
    local background="$1" steal="$2" busy="${3:-na}"
    local max_background="${BBRV3_MAX_BACKGROUND_TX_PERCENT:-15}" max_steal="${BBRV3_MAX_CPU_STEAL_PERCENT:-15}"
    local max_busy="${BBRV3_MAX_CPU_BUSY_PERCENT:-98}"
    is_decimal "$max_background" || max_background=15
    is_decimal "$max_steal" || max_steal=15
    is_decimal "$max_busy" || max_busy=98
    if is_decimal "$background" && awk -v v="$background" -v m="$max_background" 'BEGIN {exit !(v>m)}'; then return 0; fi
    if is_decimal "$steal" && awk -v v="$steal" -v m="$max_steal" 'BEGIN {exit !(v>m)}'; then return 0; fi
    if is_decimal "$busy" && awk -v v="$busy" -v m="$max_busy" 'BEGIN {exit !(v>m)}'; then return 0; fi
    return 1
}

iperf_sample() {
    local peer="$1" port="$2" duration="$3" parallel="$4" json error_file latency_file latency_pid=""
    local planning_rate="${5:-0}" recent_sender="${6:-0}" recent_retrans="${7:-0}" recent_background="${8:-0}"
    local rate_semantics="${9:-aggregate}"
    local rc=0 reason="" sender_bps receiver_bps sender_bytes receiver_bytes retrans delivered ratio retrans_per_gib
    local sender_mbit receiver_mbit receiver_fallback=0 loaded_median="na" loaded_p95="na"
    local tx_before=0 tx_after=0 background="na" cpu_before cpu_after cpu_busy="na" cpu_steal="na" contaminated=0
    local core_before core_after core_busy="na" core_steal="na" reason_parse_rc=0 cpu_metrics core_metrics latency_metrics
    local route_guard_rc=0
    local -a family_arg=()
    IPERF_LAST_FAILURE_REASON=none
    validate_peer "$peer" "$port" || return 1
    measure_require_sample_lock "$peer" "$port" || return $?
    measurement_budget_reserve_sample "$MEASURE_ACTIVE_STAGE" "$planning_rate" "$duration" "$parallel" \
        "$recent_sender" "$recent_retrans" "$recent_background" "$rate_semantics" || return $?
    family_arg=("-$MEASURE_PEER_FAMILY")
    json=$(mktemp) || return 1
    error_file=$(mktemp) || { rm -f -- "$json"; return 1; }
    latency_file=$(mktemp) || { rm -f -- "$json" "$error_file"; return 1; }
    if [[ "$(uname -s 2>/dev/null || true)" == Linux ]] && command_exists ping; then
        ping "${family_arg[@]}" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" \
            -n -i 0.2 -W 1 -c "$((duration * 5))" -- "$MEASURE_PEER_ADDRESS" > "$latency_file" 2>/dev/null &
        latency_pid=$!
    fi
    if [[ -n "$MEASURE_IFACE" ]]; then tx_before=$(interface_counter "$MEASURE_IFACE" tx_bytes); fi
    cpu_before=$(cpu_snapshot)
    core_before=$(cpu_core_snapshot)
    if timeout "$((duration + 20))" iperf3 "${family_arg[@]}" -c "$MEASURE_PEER_ADDRESS" -B "$MEASURE_PEER_SOURCE" \
        -p "$port" -t "$duration" -P "$parallel" -J > "$json" 2> "$error_file"; then
        if [[ -s "$json" ]]; then reason=$(jq -r '.error // empty' "$json" 2>/dev/null) || reason_parse_rc=$?; fi
        [[ -z "$reason" ]] || rc=1
    else
        rc=$?
        if [[ -s "$json" ]]; then reason=$(jq -r '.error // empty' "$json" 2>/dev/null) || reason_parse_rc=$?; fi
        [[ -n "$reason" ]] || reason=$(<"$error_file")
        [[ -n "$reason" ]] || { if (( rc == 124 )); then reason="连接或测试超时"; else reason="iperf3 退出码 $rc"; fi; }
    fi
    cpu_after=$(cpu_snapshot)
    core_after=$(cpu_core_snapshot)
    if [[ -n "$MEASURE_IFACE" ]]; then tx_after=$(interface_counter "$MEASURE_IFACE" tx_bytes); fi
    if [[ -n "$latency_pid" ]]; then
        if (( rc != 0 )); then kill "$latency_pid" 2>/dev/null || true; fi
        wait "$latency_pid" 2>/dev/null || true
    fi
    measure_peer_route_guard || route_guard_rc=$?
    if (( route_guard_rc != 0 )); then
        rm -f -- "$json" "$error_file" "$latency_file"
        log ERR "iperf3 $peer:$port 完成后检测到路径漂移；本样本无效"
        return "$route_guard_rc"
    fi
    if measurement_budget_check "$MEASURE_ACTIVE_STAGE"; then :; else
        rc=$?
        rm -f -- "$json" "$error_file" "$latency_file"
        return "$rc"
    fi
    rm -f -- "$error_file"
    if (( rc != 0 )); then
        reason=${reason//$'\n'/ }
        reason=${reason//$'\r'/}
        reason=${reason:0:240}
        log WARN "iperf3 $peer:$port（$MEASURE_PEER_ADDRESS）测试失败: $reason"
        rm -f -- "$json" "$latency_file"
        if (( rc == 124 )) || iperf_failure_is_unavailable "$reason"; then
            if (( rc == 124 )); then IPERF_LAST_FAILURE_REASON="peer-timeout"
            elif declare -F peer_health_reason_from_text >/dev/null; then IPERF_LAST_FAILURE_REASON=$(peer_health_reason_from_text "$reason")
            else IPERF_LAST_FAILURE_REASON="peer-unavailable"
            fi
            if declare -F failure_set >/dev/null; then failure_set "$MEASURE_ACTIVE_STAGE" "$IPERF_LAST_FAILURE_REASON" "$reason" "" "$IPERF_UNAVAILABLE_RC"; fi
            if declare -F peer_health_record >/dev/null; then
                peer_health_record "$MEASURE_PEER_HOST" "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" "$port" failure "$IPERF_LAST_FAILURE_REASON" na na unknown || log WARN "peer health 写入失败；网络事务不受影响"
            fi
            return "$IPERF_UNAVAILABLE_RC"
        fi
        IPERF_LAST_FAILURE_REASON=protocol-failure
        if declare -F failure_set >/dev/null; then failure_set "$MEASURE_ACTIVE_STAGE" protocol-failure "$reason" "" 1; fi
        return 1
    fi
    if (( reason_parse_rc != 0 )); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        IPERF_LAST_FAILURE_REASON=protocol-failure
        if declare -F failure_set >/dev/null; then failure_set "$MEASURE_ACTIVE_STAGE" protocol-failure "iperf JSON parse failed" "" "$IPERF_DATA_RC"; fi
        return "$IPERF_DATA_RC"
    fi
    if ! sender_bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json") ||
       ! receiver_bps=$(jq -r '.end.sum_received.bits_per_second // 0' "$json") ||
       ! sender_bytes=$(jq -r '.end.sum_sent.bytes // .end.sum.bytes // 0' "$json") ||
       ! receiver_bytes=$(jq -r '.end.sum_received.bytes // 0' "$json") ||
       ! retrans=$(jq -r '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0' "$json"); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    rm -f -- "$json"
    if ! is_decimal "$sender_bps" || ! is_uint "$sender_bytes" || ! is_uint "$retrans" || (( sender_bytes == 0 )) ||
       ! awk -v b="$sender_bps" 'BEGIN {exit !(b>0)}'; then
        log WARN "iperf3 $peer:$port 返回的 JSON 结果不完整"
        rm -f -- "$latency_file"
        IPERF_LAST_FAILURE_REASON=protocol-failure
        if declare -F failure_set >/dev/null; then failure_set "$MEASURE_ACTIVE_STAGE" protocol-failure "iperf JSON missing required sender fields" "" "$IPERF_DATA_RC"; fi
        return "$IPERF_DATA_RC"
    fi
    sender_mbit=$(awk -v b="$sender_bps" 'BEGIN {printf "%.2f", b/1000000}')
    if ! is_decimal "$receiver_bps" || ! is_uint "$receiver_bytes" || (( receiver_bytes == 0 )) ||
       ! awk -v b="$receiver_bps" 'BEGIN {exit !(b>0)}'; then
        receiver_bps="$sender_bps"; receiver_bytes="$sender_bytes"; receiver_fallback=1
    fi
    receiver_mbit=$(awk -v b="$receiver_bps" 'BEGIN {printf "%.2f", b/1000000}')
    delivered="$receiver_mbit"
    # An estimate, not packet loss: iperf retransmits / estimated MSS-sized segments.
    ratio=$(awk -v r="$retrans" -v b="$sender_bytes" 'BEGIN {n=b/1448; if(n<1)n=1; printf "%.5f", r*100/n}')
    retrans_per_gib=$(awk -v r="$retrans" -v b="$sender_bytes" 'BEGIN {printf "%.3f", r*1073741824/b}')
    latency_metrics=$(latency_stats_from_file "$latency_file"); rm -f -- "$latency_file"
    IFS=$'\t' read -r loaded_median loaded_p95 <<< "$latency_metrics"
    cpu_metrics=$(cpu_delta_metrics "$cpu_before" "$cpu_after")
    IFS=$'\t' read -r cpu_busy cpu_steal <<< "$cpu_metrics"
    core_metrics=$(cpu_core_delta_metrics "$core_before" "$core_after")
    IFS=$'\t' read -r core_busy core_steal <<< "$core_metrics"
    if is_decimal "$core_busy"; then
        if is_decimal "$cpu_busy"; then cpu_busy=$(printf '%s\n%s\n' "$cpu_busy" "$core_busy" | max_numbers); else cpu_busy="$core_busy"; fi
    fi
    if is_decimal "$core_steal"; then
        if is_decimal "$cpu_steal"; then cpu_steal=$(printf '%s\n%s\n' "$cpu_steal" "$core_steal" | max_numbers); else cpu_steal="$core_steal"; fi
    fi
    if [[ -n "$MEASURE_IFACE" ]]; then background=$(background_tx_percent "$tx_before" "$tx_after" "$sender_bytes"); fi
    sample_is_contaminated "$background" "$cpu_steal" "$cpu_busy" && contaminated=1
    # Column 1 keeps its compatibility position but now means receiver-delivered
    # throughput. Explicit endpoint fields are appended for auditability.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$delivered" "$retrans" "$sender_bytes" "$ratio" "$retrans_per_gib" "$loaded_median" "$loaded_p95" \
        "$background" "$cpu_busy" "$cpu_steal" "$contaminated" "$sender_mbit" "$receiver_mbit" \
        "$sender_bytes" "$receiver_bytes" "$receiver_fallback"
}

median_numbers() { sort -n | awk '{a[NR]=$1} END {if(NR) {if(NR%2) print a[(NR+1)/2]; else printf "%.5f\n", (a[NR/2]+a[NR/2+1])/2}}'; }

relative_spread_percent() {
    local count values median deviations
    values=$(printf '%s\n' "$@" | sort -n); count=$#
    median=$(median_numbers <<< "$values")
    if (( count < 3 )); then
        awk -v lo="$(head -n 1 <<< "$values")" -v hi="$(tail -n 1 <<< "$values")" -v m="$median" \
            'BEGIN {if(m<=0) print "999.00"; else printf "%.2f\n", (hi-lo)*100/m}'
        return 0
    fi
    deviations=$(awk -v m="$median" '{d=$1-m; if(d<0)d=-d; print d}' <<< "$values")
    awk -v mad="$(median_numbers <<< "$deviations")" -v m="$median" \
        'BEGIN {if(m<=0) print "999.00"; else printf "%.2f\n", mad*1.4826*100/m}'
}

bufferbloat_delta_ms() {
    local idle="$1" loaded="$2"
    if ! is_decimal "$idle" || ! is_decimal "$loaded"; then printf 'na\n'; return 0; fi
    awk -v i="$idle" -v l="$loaded" 'BEGIN {d=l-i; if(d<0)d=0; printf "%.2f\n", d}'
}

measurement_confidence() {
    local sample_count="$1" spread="$2" loaded_p95="$3" contaminated="$4" failovers="${5:-0}" path_score="${6:-na}"
    local receiver_fallback="${7:-0}"
    local score=100 grade reason path_penalty=0
    local -a reasons=()
    is_uint "$sample_count" || sample_count=0
    if ! is_uint "$contaminated"; then
        contaminated=0; score=$((score - 15)); reasons+=(contamination-unknown)
    fi
    is_uint "$failovers" || failovers=0
    if (( sample_count < 2 )); then score=$((score - 25)); reasons+=(single-sample); fi
    if ! is_decimal "$spread"; then
        score=$((score - 20)); reasons+=(spread-unknown)
    elif awk -v s="$spread" 'BEGIN {exit !(s>10)}'; then
        score=$((score - 40)); reasons+=(very-unstable)
    elif awk -v s="$spread" 'BEGIN {exit !(s>6)}'; then
        score=$((score - 20)); reasons+=(unstable)
    fi
    if ! is_decimal "$loaded_p95"; then score=$((score - 15)); reasons+=(loaded-rtt-unavailable); fi
    if (( contaminated )); then score=$((score - 50)); reasons+=(contaminated); fi
    if (( failovers > 0 )); then score=$((score - 10)); reasons+=(peer-failover); fi
    if [[ "$receiver_fallback" == 1 ]]; then score=$((score - 20)); reasons+=(receiver-fallback); fi
    if is_uint "$path_score" && (( path_score <= 100 )); then
        if (( path_score < 40 )); then path_penalty=35; reasons+=(path-unsafe)
        elif (( path_score < 65 )); then path_penalty=20; reasons+=(path-low-confidence)
        elif (( path_score < 90 )); then path_penalty=10; reasons+=(path-variable)
        fi
        score=$((score - path_penalty))
    fi
    (( score < 0 )) && score=0
    if (( score >= 90 )); then grade=high; elif (( score >= 65 )); then grade=medium; else grade=low; fi
    if ((${#reasons[@]})); then
        local IFS=,
        reason="${reasons[*]}"
    else
        reason=clean
    fi
    printf '%s\t%s\t%s\n' "$score" "$grade" "$reason"
}

compare_verdict() {
    local fq_goodput="$1" shaped_goodput="$2" fq_bloat="$3" shaped_bloat="$4" fq_retrans_gib="$5" shaped_retrans_gib="$6"
    if awk -v f="$fq_goodput" -v s="$shaped_goodput" 'BEGIN {exit !(f>0 && s<f*0.90)}'; then
        printf 'regressed\n'
    elif is_decimal "$fq_bloat" && is_decimal "$shaped_bloat" &&
         awk -v f="$fq_bloat" -v s="$shaped_bloat" -v fg="$fq_goodput" -v sg="$shaped_goodput" \
             'BEGIN {exit !(fg>0 && sg>=fg*0.90 && ((f>=5 && s<=f*0.80) || (f<5 && s<f)))}'; then
        printf 'improved\n'
    elif is_decimal "$fq_retrans_gib" && is_decimal "$shaped_retrans_gib" &&
         awk -v f="$fq_retrans_gib" -v s="$shaped_retrans_gib" -v fg="$fq_goodput" -v sg="$shaped_goodput" \
             'BEGIN {exit !(fg>0 && sg>=fg*0.90 && f>0 && s<=f*0.70)}'; then
        printf 'improved\n'
    else
        printf 'neutral\n'
    fi
}

sample_repeated() {
    local peer="$1" port="$2" duration="$3" parallel="$4" count="$5" label="$6"
    local max_count="${7:-$count}" stability_threshold="${8:-0}"
    local planning_rate="${9:-0}" rate_semantics="${10:-aggregate}"
    local recent_sender="${11:-0}" recent_retrans="${12:-0}" recent_background="${13:-0}"
    local -a delivered_rates=() rows=() backgrounds=() cpu_busies=() cpu_steals=() contaminations=()
    local row i attempt sample_rc=0 attempts="${BBRV3_IPERF_ATTEMPTS:-3}" target_count="$count" contamination_retry
    local contamination_retries="${BBRV3_CONTAMINATION_RETRIES:-1}"
    local g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated
    local sender_mbit receiver_mbit sender_bytes receiver_bytes receiver_fallback spread="0.00" bloat
    local median_rate selected_row selected_distance distance index
    is_uint "$attempts" && (( attempts >= 1 && attempts <= 5 )) || attempts=3
    is_uint "$contamination_retries" && (( contamination_retries <= 3 )) || contamination_retries=1
    is_uint "$max_count" && (( max_count >= count && max_count <= 5 )) || max_count="$count"
    is_decimal "$stability_threshold" || stability_threshold=0
    MEASURE_ACTIVE_STAGE="${label^^}"
    MEASURE_ACTIVE_STAGE="${MEASURE_ACTIVE_STAGE//[^A-Z0-9]/_}"
    for ((i=1; i<=target_count; i++)); do
        log INFO "$label: ${duration}s × ${parallel} flow(s), sample ${i}/${target_count}"
        contamination_retry=0
        while true; do
            row=""
            for ((attempt=1; attempt<=attempts; attempt++)); do
                if row=$(iperf_sample "$peer" "$port" "$duration" "$parallel" "$planning_rate" \
                    "$recent_sender" "$recent_retrans" "$recent_background" "$rate_semantics"); then
                    sample_rc=0
                    break
                else
                    sample_rc=$?
                fi
                if (( sample_rc != IPERF_UNAVAILABLE_RC )); then
                    die "iperf3 本地执行或结果解析失败（exit $sample_rc），不会切换公共对端"
                    return "$sample_rc"
                fi
                (( attempt < attempts )) && { log WARN "2 秒后重试（${attempt}/${attempts}）"; sleep 2; }
            done
            [[ -n "$row" ]] || {
                if (( sample_rc == 0 )); then
                    die "iperf3 成功退出但没有产生样本"
                    return "$IPERF_DATA_RC"
                fi
                die "当前 iperf3 对端连续 ${attempts} 次不可用"
                return "$sample_rc"
            }
            IFS=$'\t' read -r g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated \
                sender_mbit receiver_mbit sender_bytes receiver_bytes receiver_fallback <<< "$row"
            rpg="${rpg:-$(awk -v rv="$r" -v bv="$b" 'BEGIN {if(bv>0) printf "%.3f", rv*1073741824/bv; else print "0.000"}')}"
            loaded_med="${loaded_med:-na}"; loaded_tail="${loaded_tail:-na}"; background="${background:-na}"
            cpu_busy="${cpu_busy:-na}"; cpu_steal="${cpu_steal:-na}"; contaminated="${contaminated:-0}"
            sender_mbit="${sender_mbit:-$g}"; receiver_mbit="${receiver_mbit:-$g}"
            sender_bytes="${sender_bytes:-$b}"; receiver_bytes="${receiver_bytes:-$b}"; receiver_fallback="${receiver_fallback:-1}"
            is_decimal "$sender_mbit" && recent_sender="$sender_mbit"
            is_decimal "$l" && recent_retrans="$l"
            is_decimal "$background" && recent_background="$background"
            row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
                "$g" "$r" "$b" "$l" "$rpg" "$loaded_med" "$loaded_tail" "$background" "$cpu_busy" "$cpu_steal" \
                "$contaminated" "$sender_mbit" "$receiver_mbit" "$sender_bytes" "$receiver_bytes" "$receiver_fallback")
            bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$loaded_tail")
            [[ -n "$MEASURE_RESULT_FILE" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(utc_now)" "$label" "$sender_mbit" "$receiver_mbit" "$r" "$sender_bytes" "$receiver_bytes" "$l" "$rpg" \
                "$receiver_fallback" "$MEASURE_IDLE_RTT_MS" "$loaded_med" "$loaded_tail" "$bloat" "$background" "$cpu_busy" "$cpu_steal" \
                "$contaminated" "$duration" "$parallel" >> "$MEASURE_RESULT_FILE"
            if [[ "$contaminated" == 1 && "$contamination_retry" -lt "$contamination_retries" ]]; then
                ((contamination_retry+=1))
                log WARN "样本受到后台流量、CPU 饱和或 steal 污染，2 秒后重采（${contamination_retry}/${contamination_retries}）"
                sleep 2
                continue
            fi
            # The scan ceiling is the defensible bound before the first
            # unlimited sample. Once that same peer/path has produced usable,
            # uncontaminated sender telemetry, subsequent unlimited repeats
            # can reserve from the fresh observation plus the normal safety
            # margin instead of treating the initial ceiling as a permanently
            # reserved balance.
            if [[ "$contaminated" == 0 && "$rate_semantics" == unshaped ]] &&
               is_decimal "$sender_mbit" && awk -v r="$sender_mbit" 'BEGIN {exit !(r>0)}'; then
                planning_rate="$sender_mbit"
            fi
            break
        done
        if [[ "$contaminated" == 1 ]]; then
            die "连续样本受到后台流量、CPU 饱和或 steal 污染；停止测量以避免误判拐点"
            return "$IPERF_CONTAMINATED_RC"
        fi
        delivered_rates+=("$g"); rows+=("$row")
        is_decimal "$background" && backgrounds+=("$background")
        is_decimal "$cpu_busy" && cpu_busies+=("$cpu_busy")
        is_decimal "$cpu_steal" && cpu_steals+=("$cpu_steal")
        contaminations+=("$contaminated")
        spread=$(relative_spread_percent "${delivered_rates[@]}")
        if (( i >= count && i < max_count )) && awk -v s="$spread" -v t="$stability_threshold" 'BEGIN {exit !(t>0 && s>t)}'; then
            target_count=$((i + 1))
            log WARN "吞吐离散度 ${spread}% 超过 ${stability_threshold}%，追加第 ${target_count} 个样本"
        fi
        (( i < target_count )) && sleep 2
    done
    if awk -v s="$spread" -v t="$stability_threshold" 'BEGIN {exit !(t>0 && s>t)}'; then
        die "${target_count} 个样本后吞吐离散度仍为 ${spread}%（上限 ${stability_threshold}%）；停止测量以避免使用不稳定结果"
        return "$IPERF_UNSTABLE_RC"
    fi
    # Pick a real sample nearest the receiver median. The decision tuple is
    # never assembled from unrelated runs.
    median_rate=$(printf '%s\n' "${delivered_rates[@]}" | median_numbers)
    selected_distance=""; selected_row=""
    for ((index=0; index<${#rows[@]}; index++)); do
        distance=$(awk -v a="${delivered_rates[$index]}" -v b="$median_rate" 'BEGIN {d=a-b; if(d<0)d=-d; printf "%.8f",d}')
        if [[ -z "$selected_distance" ]] || awk -v a="$distance" -v b="$selected_distance" 'BEGIN {exit !(a<b)}'; then
            selected_distance="$distance"; selected_row="${rows[$index]}"
        fi
    done
    IFS=$'\t' read -r g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated \
        sender_mbit receiver_mbit sender_bytes receiver_bytes receiver_fallback <<< "$selected_row"
    bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$loaded_tail")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$g" "$r" "$b" "$l" "$rpg" "$loaded_med" "$loaded_tail" \
        "$(max_or_na "${backgrounds[@]}")" "$(max_or_na "${cpu_busies[@]}")" "$(max_or_na "${cpu_steals[@]}")" \
        "$(printf '%s\n' "${contaminations[@]}" | max_numbers)" "$spread" "$target_count" "$bloat" \
        "$sender_mbit" "$receiver_mbit" "$sender_bytes" "$receiver_bytes" "$receiver_fallback"
}

loss_spike() {
    local value="$1" threshold="$2" base="$3"
    awk -v v="$value" -v t="$threshold" -v b="$base" 'BEGIN {
        need=t;
        if (b > 0 && b*5 > need) need=b*5;
        if (need > 1) need=1;
        if (v <= need) exit 1;
        exit 0
    }'
}

measurement_cooldown() {
    local stage="$1" rate="${2:-0}" duration="${3:-3}" seconds reserved_seconds
    if [[ "${BBRV3_MEASUREMENT_COOLDOWN:-1}" == 0 ]]; then return 0; fi
    is_decimal "$rate" || rate=0; is_uint "$duration" || duration=3
    case "$stage" in
        PRE_SCAN) seconds=$(awk -v r="$rate" -v d="$duration" 'BEGIN {v=int(d*0.8+r/1000+0.99); if(v<3)v=3; if(v>10)v=10; print v}') ;;
        SPIKE_RECHECK) seconds=$(awk -v r="$rate" -v d="$duration" 'BEGIN {v=int(d*0.4+r/2000+0.99); if(v<2)v=2; if(v>6)v=6; print v}') ;;
        BETWEEN_LEVEL) seconds=$(awk -v r="$rate" -v d="$duration" 'BEGIN {v=int(d*0.25+r/4000+0.99); if(v<1)v=1; if(v>4)v=4; print v}') ;;
        PRE_VERIFY) seconds=$(awk -v r="$rate" -v d="$duration" 'BEGIN {v=int(d*0.8+r/1000+0.99); if(v<3)v=3; if(v>10)v=10; print v}') ;;
        *) die "未知测量冷却阶段: $stage"; return 1 ;;
    esac
    seconds=$(( (seconds * MEASURE_COOLDOWN_PERCENT + 99) / 100 ))
    (( seconds < 1 )) && seconds=1
    reserved_seconds=$((seconds + duration + MEASURE_IPERF_TIMEOUT_GUARD_SECONDS))
    measurement_budget_check "$stage" 0 "$reserved_seconds" || return $?
    log INFO "$stage 冷却 ${seconds}s（rate=${rate} Mbit/s, sample=${duration}s）"
    sleep "$seconds"
}

measure_level_with_confirmation() {
    local peer="$1" port="$2" duration="$3" confirm_duration="$4" parallel="$5" label="$6"
    local threshold="$7" base_loss="$8" planning_rate="${9:-0}" row loss rc=0 index hits=0 selected="" selected_loss="" gp
    local -a rows=() spike_rows=() clean_rows=()
    MEASURE_LEVEL_ROW=""; MEASURE_LEVEL_SPIKE_HITS=0; MEASURE_LEVEL_SPIKE_CONFIRMED=0
    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "$label" 1 0 "$planning_rate" shaped) || return $?
    rows+=("$row")
    loss=$(cut -f4 <<< "$row")
    if loss_spike "$loss" "$threshold" "$base_loss"; then
        hits=1; spike_rows+=("$row")
        for index in 2 3; do
            measurement_cooldown SPIKE_RECHECK "$(cut -f1 <<< "$row")" "$confirm_duration" || return 1
            row=$(sample_repeated "$peer" "$port" "$confirm_duration" "$parallel" 1 "${label}-recheck-${index}" 1 0 \
                "$planning_rate" shaped "$(cut -f15 <<< "$row")" "$(cut -f4 <<< "$row")" "$(cut -f8 <<< "$row")") || return $?
            rows+=("$row"); loss=$(cut -f4 <<< "$row")
            if loss_spike "$loss" "$threshold" "$base_loss"; then
                ((hits+=1)); spike_rows+=("$row")
            else
                clean_rows+=("$row")
            fi
        done
        if (( hits >= 2 )); then
            MEASURE_LEVEL_SPIKE_CONFIRMED=1
            for row in "${spike_rows[@]}"; do
                loss=$(cut -f4 <<< "$row")
                if [[ -z "$selected" ]] || awk -v a="$loss" -v b="$selected_loss" 'BEGIN {exit !(a<b)}'; then
                    selected="$row"; selected_loss="$loss"
                fi
            done
        else
            for row in "${clean_rows[@]}"; do
                gp=$(cut -f1 <<< "$row")
                if [[ -z "$selected" ]] || awk -v a="$gp" -v b="$(cut -f1 <<< "$selected")" 'BEGIN {exit !(a>b)}'; then selected="$row"; fi
            done
            [[ -n "$selected" ]] || selected="${rows[0]}"
        fi
    else
        clean_rows+=("$row"); selected="$row"
    fi
    MEASURE_LEVEL_ROW="$selected"
    # shellcheck disable=SC2034 # Exposed to diagnostics and regression tests.
    MEASURE_LEVEL_SPIKE_HITS="$hits"
    if (( MEASURE_LEVEL_SPIKE_CONFIRMED )); then
        log WARN "$label: 重传跳变经 3 次实验确认（${hits}/3）"
    elif (( hits > 0 )); then
        log INFO "$label: 单次重传尖峰未复现（${hits}/3），按瞬时公共对端竞争处理"
    fi
}

minimum_efficiency_ratio() {
    local goodput="$1" rate="$2"
    awk -v g="$goodput" -v r="$rate" 'BEGIN {
        if (r <= 0) {print "0.90"; exit}
        e=(g/r)*0.98;
        if (e < 0.75) e=0.75;
        if (e > 0.98) e=0.98;
        printf "%.5f\n", e
    }'
}

throughput_stalled() {
    local goodput="$1" previous_goodput="$2" rate="$3" previous_rate="$4" min_efficiency="$5"
    awk -v g="$goodput" -v p="$previous_goodput" -v r="$rate" -v pr="$previous_rate" -v e="$min_efficiency" 'BEGIN {
        delta=r-pr; gain=g-p;
        exit !(delta>=1 && gain<delta*0.25 && g<r*e)
    }'
}

measurement_sample_acceptable() {
    local goodput="$1" loss="$2" rate="$3" min_efficiency="$4" threshold="$5" clean_reference_loss="$6"
    loss_spike "$loss" "$threshold" "$clean_reference_loss" && return 1
    awk -v g="$goodput" -v r="$rate" -v e="$min_efficiency" 'BEGIN {exit !(r<=0 || g>=r*e)}'
}

estimate_sweep_bytes() {
    local high="$1" duration="$2" tests="$3"
    awk -v r="$high" -v d="$duration" -v n="$tests" 'BEGIN {printf "%.0f", r*1000000/8*d*n*1.08}'
}

estimate_measurement_plan_bytes() {
    local control_rate="$1" control_duration="$2" capacity_rate="$3" saturation_duration="$4"
    local high="$5" coarse_duration="$6" confirm_duration="$7" aggregate="${8:-0}"
    awk -v cr="$control_rate" -v cd="$control_duration" -v cap="$capacity_rate" -v sd="$saturation_duration" \
        -v hi="$high" -v coarse="$coarse_duration" -v confirm="$confirm_duration" -v aggregate="$aggregate" \
        -v control_samples="$MEASURE_CONTROL_MAX_SAMPLES" -v saturation_samples="$MEASURE_SATURATION_MAX_SAMPLES" \
        -v candidate_samples="$MEASURE_CANDIDATE_MAX_SAMPLES" -v verify_samples="$((MEASURE_VERIFY_MAX_SAMPLES*2))" 'BEGIN {
        # Includes adaptive extra samples, both 2/3 spike rechecks, candidate
        # confirmation and the single/multi final verify. Peer-failure retries
        # are excluded from this normal-path estimate but remain hard-budgeted.
        mbit_seconds=cr*cd*control_samples + cap*sd*saturation_samples + hi*((8*coarse+2*confirm)*2 + candidate_samples*confirm + verify_samples*confirm)
        if(aggregate) mbit_seconds+=cap*sd*saturation_samples
        printf "%.0f", mbit_seconds*1000000/8*1.08
    }'
}

estimate_control_saturation_bytes() {
    local control_rate="$1" control_duration="$2" capacity_rate="$3" saturation_duration="$4" aggregate="${5:-0}"
    awk -v cr="$control_rate" -v cd="$control_duration" -v cap="$capacity_rate" -v sd="$saturation_duration" -v aggregate="$aggregate" \
        -v control_samples="$MEASURE_CONTROL_MAX_SAMPLES" -v saturation_samples="$MEASURE_SATURATION_MAX_SAMPLES" 'BEGIN {
        mbit_seconds=cr*cd*control_samples + cap*sd*saturation_samples; if(aggregate) mbit_seconds+=cap*sd*saturation_samples
        printf "%.0f", mbit_seconds*1000000/8*1.08
    }'
}

new_measure_run() {
    local kind="$1" dir base suffix=0
    if declare -F failure_reset >/dev/null; then failure_reset; fi
    ensure_state_layout || return 1
    base="$HISTORY_DIR/$(history_stamp)-${kind}"
    dir="$base"
    while [[ -e "$dir" ]]; do
        ((suffix+=1))
        dir="${base}-${suffix}"
    done
    mkdir "$dir" || return 1
    chmod 0700 "$dir"
    MEASURE_RESULT_FILE="$dir/samples.tsv"
    MEASURE_RUN_DIR="$dir"
    if declare -F history_prune_internal >/dev/null; then history_prune_internal "${MAX_HISTORY_ENTRIES:-20}" || return 1; fi
    printf 'TIME\tLABEL\tSENDER_MBIT\tRECEIVER_MBIT\tRETRANSMITS\tSENDER_BYTES\tRECEIVER_BYTES\tRETRANS_RATIO_EST_PERCENT\tRETRANS_PER_GIB\tRECEIVER_FALLBACK\tIDLE_RTT_MS\tLOADED_RTT_MEDIAN_MS\tLOADED_RTT_P95_MS\tBUFFERBLOAT_P95_MS\tBACKGROUND_TX_PERCENT\tCPU_BUSY_PERCENT\tCPU_STEAL_PERCENT\tCONTAMINATED\tDURATION_SECONDS\tFLOWS\n' > "$MEASURE_RESULT_FILE"
}

measurement_abort_before_begin() {
    local kind="$1" peer="$2" port="$3" iface="$4" rc="$5"
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run "$kind" "$peer" "$port" "$iface" "$rc" not-needed || log WARN "measurement failure history finalization failed"
        failure_summary_print "$MEASURE_RUN_DIR/summary.tsv" || true
    fi
    measure_clear_peer_lock
    return "$rc"
}

measure_path_profile() {
    require_root || return 1; acquire_lock || return 1
    require_commands ip ping find sort awk || return 1
    local peer="$1" requested="${2:-auto}" samples="${3:-7}" pmtu_enabled="${4:-1}"
    local iface dir rc=0
    validate_peer "$peer" 5201 || return 1
    is_uint "$samples" && (( samples >= 3 && samples <= 20 )) || { die "路径画像样本数必须是 3–20"; return 1; }
    [[ "$pmtu_enabled" == 0 || "$pmtu_enabled" == 1 ]] || { die "PMTU 开关只能是 0/1"; return 1; }
    measure_lock_requested_peer "$peer" "" "$requested" || return $?
    iface="$MEASURE_PEER_IFACE"
    new_measure_run path || { measure_clear_peer_lock; return 1; }
    dir="$MEASURE_RUN_DIR"
    rm -f -- "$MEASURE_RESULT_FILE"; MEASURE_RESULT_FILE=""
    if measure_set_latency_baseline "$peer" "$samples" "$pmtu_enabled"; then
        printf 'TYPE\tpath\nPEER\t%s\nINTERFACE\t%s\n' "$peer" "$iface" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if (( rc == 0 )); then
            path_profile_report
            log INFO "路径画像: $dir"
        fi
    else
        rc=$?
    fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run path "$peer" none "$iface" "$rc" not-needed || log WARN "path history finalization failed"
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    measure_clear_peer_lock
    return "$rc"
}

measure_probe() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" preferred_address="${6:-}" preferred_source="${7:-}"
    local iface dir row rc=0 speed estimate planning_rate sender receiver receiver_fallback restore_rc=0 health_family health_address health_rtt
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        planning_rate="$speed"
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    else
        planning_rate=$(recommended_scan_cap "$iface" 0) || return 1
    fi
    new_measure_run probe || return 1
    dir="$MEASURE_RUN_DIR"
    if declare -F measurement_environment_preflight >/dev/null; then
        if measurement_environment_preflight "$iface" "${speed:-0}"; then :; else
            rc=$?; measurement_finalize_run probe "$peer" "$port" "$iface" "$rc" not-needed || true
            failure_summary_print "$dir/summary.tsv" || true; measure_clear_peer_lock; return "$rc"
        fi
    fi
    if measure_set_latency_baseline "$peer"; then :; else rc=$?; measurement_abort_before_begin probe "$peer" "$port" "$iface" "$rc"; return $?; fi
    if measure_begin "$iface"; then :; else rc=$?; measurement_abort_before_begin probe "$peer" "$port" "$iface" "$rc"; return $?; fi
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 unshaped 3 6 "$planning_rate" unshaped); then
        receiver=$(cut -f16 <<< "$row"); receiver="${receiver:-$(cut -f1 <<< "$row")}"; sender=$(cut -f15 <<< "$row"); sender="${sender:-$receiver}"
        receiver_fallback=$(cut -f19 <<< "$row"); receiver_fallback="${receiver_fallback:-1}"
        confidence=$(measurement_confidence "$(cut -f13 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f7 <<< "$row")" "$(cut -f11 <<< "$row")" 0 "$PATH_PROFILE_SCORE" "$receiver_fallback")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nSENDER_MBIT\t%s\nRECEIVER_MBIT\t%s\nRECEIVER_FALLBACK\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nRETRANS_PER_GIB\t%s\nIDLE_RTT_MS\t%s\nLOADED_RTT_P95_MS\t%s\nBUFFERBLOAT_P95_MS\t%s\nRECEIVER_SPREAD_PERCENT\t%s\nGOODPUT_SPREAD_PERCENT\t%s\nSAMPLE_COUNT\t%s\nBACKGROUND_TX_PERCENT_MAX\t%s\nCPU_BUSY_PERCENT_MAX\t%s\nCPU_STEAL_PERCENT_MAX\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$peer" "$port" "$iface" "$sender" "$receiver" "$receiver_fallback" \
            "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" "$(cut -f5 <<< "$row")" \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f7 <<< "$row")" "$(cut -f14 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f12 <<< "$row")" \
            "$(cut -f13 <<< "$row")" \
            "$(cut -f8 <<< "$row")" "$(cut -f9 <<< "$row")" "$(cut -f10 <<< "$row")" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "receiver 可用带宽代表样本: ${receiver} Mbit/s（sender ${sender}），重传 $(cut -f5 <<< "$row") 次/GiB"
        log INFO "测量置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})"
        log INFO "结果: $dir"
    else rc=$?; fi
    traffic_report "$iface"
    health_family="$MEASURE_PEER_FAMILY"; health_address="$MEASURE_PEER_ADDRESS"; health_rtt="${PATH_RTT_MEDIAN_MS:-na}"
    if measure_restore; then :; else restore_rc=$?; rc="$ROLLBACK_FAILURE_RC"; declare -F failure_set >/dev/null && failure_set ROLLBACK rollback-failed "temporary qdisc restore failed (restore rc=$restore_rc)" "" "$ROLLBACK_FAILURE_RC"; fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run probe "$peer" "$port" "$iface" "$rc" "$([[ "$restore_rc" == 0 ]] && printf complete || printf failed)" || log WARN "probe history finalization failed"
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    measurement_peer_health_finalize "$peer" "$health_family" "$health_address" "$port" "$rc" "$health_rtt" "${receiver:-na}" unknown || log WARN "peer health 写入失败"
    return "$rc"
}

measure_sweep() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" nominal="$4" low="$5" high="$6" step="$7"
    local duration="$8" parallel="$9" margin="${10}" threshold="${11}" force_scan="${12}" cap="${13}"
    local result_mode="${14:-manual}"
    local preferred_address="${15:-}" preferred_source="${16:-}"
    local iface dir saturation_row saturation_loss base_row base_gp base_loss rate row gp loss
    local path_control_row="" path_control_rate=0 path_control_sender="" path_control_receiver="" path_control_loss=""
    local path_control_quality=unknown saturation_sender="" saturation_receiver="" saturation_state=unstable
    local saturation_fallback=0 capacity_mode=single capacity_receiver="" policer_suspected=0 measurement_state=MEASUREMENT_UNSTABLE
    local clean_reference_rate="" clean_reference_receiver="" clean_reference_loss="" first_scan_lossy=0 lower_attempts=0
    local last_ok="" last_ok_gp="" broke_at="" fine_start fine_step recommend="" candidate="" confirm_row confirm_gp="" confirm_loss=""
    local min_efficiency="0.90" confirmed=0 reject_reason="" estimated tests rc=0 no_knee=0 above_cap=0
    local control_duration saturation_duration coarse_duration confirm_duration target_points scan_width saturation_planning_rate
    local auto_cap=0 nominal_was_auto=0 observed_cap
    local legacy_baseline_quality=unknown scan_decision=inconclusive no_knee_reason=""
    local confidence_row confidence confidence_score confidence_grade confidence_reasons preflight_capacity=0 restore_rc=0
    local health_family="" health_address="" health_rtt=na health_semantic=""
    local sample_confidence_score sample_confidence_grade sample_confidence_reasons
    local decision_confidence_score decision_confidence_grade decision_confidence_reasons
    validate_peer "$peer" "$port" || return 1
    [[ "$result_mode" == manual || "$result_mode" == auto ]] || { die "扫描结果模式只支持 manual/auto"; return 1; }
    for value in "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$force_scan" "$cap"; do is_uint "$value" || { die "扫描参数必须为非负整数"; return 1; }; done
    is_decimal "$threshold" || { die "loss threshold 必须是数字"; return 1; }
    (( duration >= 3 && duration <= 120 && parallel >= 1 && parallel <= 32 && margin <= 25 && force_scan <= 1 &&
       (cap == 0 || (cap >= 100 && cap <= 1000000)) )) || { die "扫描参数超出安全范围"; return 1; }
    (( nominal == 0 )) && nominal_was_auto=1
    if (( cap == 0 )) || [[ "$result_mode" == auto ]]; then auto_cap=1; fi
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    if (( cap == 0 )); then cap=$(recommended_scan_cap "$iface" "$nominal") || return 1; fi
    saturation_planning_rate="$cap"
    qdisc_guard "$iface" || return 1
    hardware_profile_values "$iface" "$nominal" || return 1
    new_measure_run sweep || return 1
    dir="$MEASURE_RUN_DIR"
    if (( nominal > 0 )); then preflight_capacity="$nominal"
    elif [[ "${HARDWARE_LINK_TRUST:-}" == trusted ]] && is_uint "${HARDWARE_LINK_MBIT:-}"; then preflight_capacity="$HARDWARE_LINK_MBIT"
    fi
    if declare -F measurement_environment_preflight >/dev/null; then
        if measurement_environment_preflight "$iface" "$preflight_capacity"; then :; else
            rc=$?
            measurement_finalize_run sweep "$peer" "$port" "$iface" "$rc" not-needed || true
            failure_summary_print "$dir/summary.tsv" || true
            measure_clear_peer_lock
            return "$rc"
        fi
    fi
    if measure_set_latency_baseline "$peer"; then :; else rc=$?; measurement_abort_before_begin sweep "$peer" "$port" "$iface" "$rc"; return $?; fi
    if path_profile_tuning_gate "$force_scan"; then :; else rc=$?; measurement_abort_before_begin sweep "$peer" "$port" "$iface" "$rc"; return $?; fi
    if measure_begin "$iface"; then :; else rc=$?; measurement_abort_before_begin sweep "$peer" "$port" "$iface" "$rc"; return $?; fi

    IFS=$'\t' read -r control_duration saturation_duration coarse_duration confirm_duration <<< "$(measurement_profile_stage_durations "$duration")"

    # Known-rate runs establish path quality before any saturation traffic.
    # Auto-rate runs do the same control after capacity discovery has supplied
    # a safe 40-50% receiver-derived target.
    if (( nominal > 0 )); then
        path_control_rate=$((nominal * 40 / 100)); ((path_control_rate < 1)) && path_control_rate=1
        log INFO "PATH_CONTROL: ${path_control_rate} Mbit/s（标称速率的 40%）"
        if ! apply_shaping "$iface" "$path_control_rate"; then
            rc=1
        elif path_control_row=$(sample_repeated "$peer" "$port" "$control_duration" 1 "$MEASURE_CONTROL_SAMPLES" path-control "$MEASURE_CONTROL_MAX_SAMPLES" 8 "$path_control_rate" shaped); then
            path_control_receiver=$(cut -f1 <<< "$path_control_row"); path_control_sender=$(cut -f15 <<< "$path_control_row")
            path_control_sender="${path_control_sender:-$path_control_receiver}"; path_control_loss=$(cut -f4 <<< "$path_control_row")
            if awk -v g="$path_control_receiver" -v r="$path_control_rate" 'BEGIN {exit !(g<r*0.70)}'; then
                path_control_quality=slow-peer; measurement_state=MEASUREMENT_UNSTABLE; reject_reason="path-control-peer-too-slow"; rc=2
                declare -F failure_set >/dev/null && failure_set PATH_CONTROL peer-too-slow "receiver ${path_control_receiver}Mbit below 70% of ${path_control_rate}Mbit" "" 2
            elif loss_spike "$path_control_loss" 0.5 0; then
                path_control_quality=dirty; legacy_baseline_quality=bad; measurement_state=PATH_DIRTY
                scan_decision="path-dirty"; reject_reason="path-control-dirty"; rc="$MEASURE_PATH_QUALITY_RC"
                declare -F failure_set >/dev/null && failure_set PATH_CONTROL path-dirty "retrans-est ${path_control_loss}%" "" "$rc"
            else
                path_control_quality=clean; legacy_baseline_quality=good
            fi
        else rc=$?; fi
    fi

    if (( rc == 0 )); then measurement_cooldown PRE_SCAN "${path_control_rate:-0}" "$control_duration" || rc=$?; fi
    if (( rc != 0 )); then
        :
    elif ! apply_fq "$iface"; then
        rc=1
    elif saturation_row=$(sample_repeated "$peer" "$port" "$saturation_duration" 1 "$MEASURE_SATURATION_SAMPLES" saturation "$MEASURE_SATURATION_MAX_SAMPLES" 6 "$saturation_planning_rate" unshaped); then
        saturation_receiver=$(cut -f1 <<< "$saturation_row"); saturation_loss=$(cut -f4 <<< "$saturation_row")
        saturation_sender=$(cut -f15 <<< "$saturation_row"); saturation_sender="${saturation_sender:-$saturation_receiver}"
        saturation_fallback=$(cut -f19 <<< "$saturation_row"); saturation_fallback="${saturation_fallback:-1}"
        if loss_spike "$saturation_loss" "$threshold" "${path_control_loss:-0}"; then
            saturation_state=lossy; policer_suspected=1
            log INFO "SATURATION: receiver ${saturation_receiver} Mbit/s, retrans-est ${saturation_loss}%（疑似 policer；不是脏路径判据）"
        else
            saturation_state=clean
            log INFO "SATURATION: receiver ${saturation_receiver} Mbit/s, retrans-est ${saturation_loss}%（未见 policer 跳变）"
        fi

        if (( nominal_was_auto && rc == 0 )); then
            path_control_rate=$(awk -v g="$saturation_receiver" 'BEGIN {v=int(g*0.45+0.5); if(v<1)v=1; print v}')
            log INFO "PATH_CONTROL: ${path_control_rate} Mbit/s（不限速 receiver 的 45%）"
            measurement_cooldown BETWEEN_LEVEL "$saturation_receiver" "$saturation_duration" || rc=$?
            if (( rc == 0 )) && ! apply_shaping "$iface" "$path_control_rate"; then
                rc=1
            elif (( rc == 0 )); then
                if path_control_row=$(sample_repeated "$peer" "$port" "$control_duration" 1 "$MEASURE_CONTROL_SAMPLES" path-control "$MEASURE_CONTROL_MAX_SAMPLES" 8 \
                    "$path_control_rate" shaped "$saturation_sender" "$saturation_loss" "$(cut -f8 <<< "$saturation_row")"); then
                    path_control_receiver=$(cut -f1 <<< "$path_control_row"); path_control_sender=$(cut -f15 <<< "$path_control_row")
                    path_control_sender="${path_control_sender:-$path_control_receiver}"; path_control_loss=$(cut -f4 <<< "$path_control_row")
                    if awk -v g="$path_control_receiver" -v r="$path_control_rate" 'BEGIN {exit !(g<r*0.70)}'; then
                        path_control_quality=slow-peer; measurement_state=MEASUREMENT_UNSTABLE; reject_reason="path-control-peer-too-slow"; rc=2
                        declare -F failure_set >/dev/null && failure_set PATH_CONTROL peer-too-slow "receiver ${path_control_receiver}Mbit below 70% of ${path_control_rate}Mbit" "" 2
                    elif loss_spike "$path_control_loss" 0.5 0; then
                        path_control_quality=dirty; legacy_baseline_quality=bad; measurement_state=PATH_DIRTY
                        scan_decision="path-dirty"; reject_reason="path-control-dirty"; rc="$MEASURE_PATH_QUALITY_RC"
                        declare -F failure_set >/dev/null && failure_set PATH_CONTROL path-dirty "retrans-est ${path_control_loss}%" "" "$rc"
                    else
                        path_control_quality=clean; legacy_baseline_quality=good
                    fi
                else rc=$?; fi
            fi
        fi

        if (( rc == 0 )) && [[ "$path_control_quality" == clean ]]; then
            if (( policer_suspected )); then measurement_state=CLEAN_POLICER_FOUND
            else
                measurement_state=CLEAN_NO_POLICER; no_knee=1; no_knee_reason="saturation-clean"; scan_decision=no-knee-clean
                (( force_scan )) && { no_knee=0; no_knee_reason=""; scan_decision=forced-scan; }
            fi
        fi
        capacity_receiver="$saturation_receiver"
        # Aggregate mode is capacity discovery only. It never replaces the
        # single-flow saturation tuple used for retransmission attribution.
        if (( rc == 0 )) && {
           { (( ! nominal_was_auto && nominal > 0 )) && awk -v g="$capacity_receiver" -v n="$nominal" 'BEGIN {exit !(g<n*0.70)}'; } ||
           { (( nominal_was_auto )) && [[ "$HARDWARE_LINK_TRUST" == trusted ]] && is_uint "$HARDWARE_LINK_MBIT" &&
              (( HARDWARE_LINK_MBIT >= 2500 )) && awk -v g="$capacity_receiver" -v n="$HARDWARE_LINK_MBIT" 'BEGIN {exit !(g<n*0.70)}'; }
        }; then
            local capacity_row capacity_parallel=8 aggregate_receiver
            log INFO "CAPACITY_DISCOVERY: 单流明显低于高带宽标称值，追加 ${capacity_parallel} 流容量探针"
            if ! apply_fq "$iface"; then
                rc=1
            elif capacity_row=$(sample_repeated "$peer" "$port" "$saturation_duration" "$capacity_parallel" "$MEASURE_SATURATION_SAMPLES" capacity-aggregate "$MEASURE_SATURATION_MAX_SAMPLES" 8 \
                "$saturation_planning_rate" unshaped "$saturation_sender" "$saturation_loss" "$(cut -f8 <<< "$saturation_row")"); then
                aggregate_receiver=$(cut -f1 <<< "$capacity_row")
                if awk -v a="$aggregate_receiver" -v b="$capacity_receiver" 'BEGIN {exit !(a>b)}'; then capacity_receiver="$aggregate_receiver"; fi
                capacity_mode=single+aggregate
            else rc=$?; fi
        fi
        if (( rc == 0 && auto_cap )); then
            if observed_cap=$(expanded_scan_cap "$cap" "$capacity_receiver"); then
                if (( observed_cap > cap )); then
                    log INFO "根据不限速基准将扫描上限从 ${cap} 调整为 ${observed_cap} Mbit/s"
                    cap="$observed_cap"
                fi
            else
                rc=$?
            fi
        fi
        # A clean, stable saturation result that remains far below a known
        # nominal rate proves neither a policer nor usable endpoint capacity.
        # The aggregate discovery above gets one bounded chance to rule out a
        # single-flow/window limitation; otherwise fail over instead of
        # declaring a trusted CLEAN_NO_POLICER result.
        if (( rc == 0 && ! nominal_was_auto && nominal > 0 && ! policer_suspected )) &&
           awk -v g="$capacity_receiver" -v n="$nominal" 'BEGIN {exit !(g<n*0.70)}'; then
            saturation_state=unstable; measurement_state=MEASUREMENT_UNSTABLE
            no_knee=0; no_knee_reason=""; scan_decision=inconclusive-peer-too-slow
            reject_reason="capacity-below-nominal-after-aggregate"; rc=2
            declare -F failure_set >/dev/null && failure_set CAPACITY_DISCOVERY peer-too-slow "aggregate receiver ${capacity_receiver}Mbit below nominal ${nominal}Mbit" "" 2
        fi
        if (( rc == 0 )); then
            if awk -v g="$capacity_receiver" -v c="$cap" 'BEGIN {exit !(g>c)}'; then
                above_cap=1; no_knee=1; no_knee_reason=above-scan-cap
                if (( policer_suspected )); then
                    scan_decision=inconclusive-above-cap; measurement_state=MEASUREMENT_UNSTABLE; reject_reason=policer-suspected-above-cap
                else scan_decision=no-knee-clean
                fi
                log WARN "容量探针 receiver 达到 ${capacity_receiver} Mbit/s，超过扫描上限 ${cap} Mbit/s"
            fi
            (( nominal > 0 )) || nominal=$(awk -v g="$capacity_receiver" 'BEGIN {printf "%d", g+0.5}')
            if (( nominal_was_auto )) && [[ "$result_mode" == auto ]]; then
                if duration=$(recommended_measure_duration "$iface" "$nominal"); then :; else rc=$?; fi
            fi
        fi
        if (( rc == 0 && ! no_knee )); then
            if (( low == 0 )); then
                if (( nominal_was_auto )); then low=$(awk -v g="$capacity_receiver" 'BEGIN {v=int(g*0.91+0.5); if(v<1)v=1; print v}')
                else low=$((nominal * 91 / 100)); ((low < 1)) && low=1
                fi
            fi
            if (( high == 0 )); then
                high=$(awk -v g="$capacity_receiver" -v n="$nominal" -v l="$saturation_loss" 'BEGIN {
                    v=g*(1.15+l/100*1.5); nmax=n*1.15; if(nmax>v)v=nmax; if(v<2)v=2; printf "%d",v+0.5
                }')
            fi
            if (( step == 0 )); then
                scan_width=$((high-low)); target_points=8
                step=$(( (scan_width + target_points - 2) / (target_points - 1) )); ((step < 1)) && step=1
            fi
            if (( ! above_cap && high > cap )); then
                log WARN "扫描上界 ${high} Mbit/s 超过硬上限 ${cap} Mbit/s，已收敛到硬上限"
                high="$cap"
            fi
            if (( low >= cap )); then
                die "扫描下界 ${low} Mbit/s 必须低于硬上限 ${cap} Mbit/s"
                rc=1
            elif (( high <= low )); then
                die "扫描上界必须大于下界"
                rc=1
            fi
        fi
    else
        rc=$?
    fi

    if (( rc == 0 && ! no_knee && (step <= 0 || high <= low) )); then
        die "无法根据基准样本生成有效扫描区间"
        rc=1
    fi

    if (( rc == 0 )); then
        if (( no_knee )); then
            tests=$((MEASURE_CONTROL_MAX_SAMPLES + MEASURE_SATURATION_MAX_SAMPLES)); [[ "$capacity_mode" == single+aggregate ]] && tests=$((tests + MEASURE_SATURATION_MAX_SAMPLES))
            estimated=$(estimate_control_saturation_bytes "$path_control_rate" "$control_duration" "$capacity_receiver" \
                "$saturation_duration" "$([[ "$capacity_mode" == single+aggregate ]] && echo 1 || echo 0)")
        else
            tests=$((MEASURE_CONTROL_MAX_SAMPLES + MEASURE_SATURATION_MAX_SAMPLES + MEASURE_CANDIDATE_MAX_SAMPLES + MEASURE_VERIFY_MAX_SAMPLES*2 + 20)); [[ "$capacity_mode" == single+aggregate ]] && tests=$((tests + MEASURE_SATURATION_MAX_SAMPLES))
            estimated=$(estimate_measurement_plan_bytes "$path_control_rate" "$control_duration" "$capacity_receiver" \
                "$saturation_duration" "$high" "$coarse_duration" "$confirm_duration" "$([[ "$capacity_mode" == single+aggregate ]] && echo 1 || echo 0)")
        fi
        log INFO "计划最多采集 $tests 个样本、产生约 $(human_bytes "$estimated") 出站流量（上界估算，不含失败重试）"

        if (( no_knee || above_cap )); then
            :
        else
            measurement_cooldown PRE_SCAN "$capacity_receiver" "$saturation_duration" || rc=$?
            if (( rc == 0 )); then apply_shaping "$iface" "$low" || rc=$?; fi
            if (( rc == 0 )); then
                measure_level_with_confirmation "$peer" "$port" "$coarse_duration" "$confirm_duration" "$parallel" \
                    "rate-${low}" "$threshold" "$path_control_loss" "$low" || rc=$?
                base_row="$MEASURE_LEVEL_ROW"
                base_gp=$(cut -f1 <<< "${base_row:-$'0\t0\t0\t0'}")
                base_loss=$(cut -f4 <<< "${base_row:-$'0\t0\t0\t0'}")
            fi
            if (( rc == 0 && MEASURE_LEVEL_SPIKE_CONFIRMED )); then
                local known_broke="$low" lower_rate="$low"
                first_scan_lossy=1
                while (( lower_attempts < 3 )); do
                    ((lower_attempts+=1)); lower_rate=$((lower_rate * 3 / 4)); ((lower_rate < 1)) && lower_rate=1
                    log WARN "首个扫描点 ${known_broke} Mbit/s 已确认重传跳变；向下检查控制点 ${lower_rate} Mbit/s（${lower_attempts}/3）"
                    measurement_cooldown BETWEEN_LEVEL "$lower_rate" "$coarse_duration" || { rc=$?; break; }
                    apply_shaping "$iface" "$lower_rate" || { rc=$?; break; }
                    measure_level_with_confirmation "$peer" "$port" "$coarse_duration" "$confirm_duration" "$parallel" \
                        "lower-control-${lower_rate}" "$threshold" "$path_control_loss" "$lower_rate" || { rc=$?; break; }
                    if (( ! MEASURE_LEVEL_SPIKE_CONFIRMED )); then
                        base_row="$MEASURE_LEVEL_ROW"; base_gp=$(cut -f1 <<< "$base_row"); base_loss=$(cut -f4 <<< "$base_row")
                        last_ok="$lower_rate"; last_ok_gp="$base_gp"; broke_at="$known_broke"
                        clean_reference_rate="$lower_rate"; clean_reference_receiver="$base_gp"; clean_reference_loss="$base_loss"
                        break
                    fi
                done
                if (( rc == 0 )) && [[ -z "$last_ok" ]]; then
                    measurement_state=MEASUREMENT_UNSTABLE; scan_decision=inconclusive-first-point-lossy
                    reject_reason="first-scan-point-lossy-after-controls"; rc=2
                fi
            fi
            if (( rc == 0 )); then
                local previous_gp previous_rate stall_count=0 stalled_rate=""
                if (( ! first_scan_lossy )); then
                    min_efficiency=$(minimum_efficiency_ratio "$base_gp" "$low")
                    clean_reference_rate="$low"; clean_reference_receiver="$base_gp"; clean_reference_loss="$base_loss"
                    last_ok="$low"; last_ok_gp="$base_gp"; previous_gp="$base_gp"; previous_rate="$low"
                else
                    min_efficiency=$(minimum_efficiency_ratio "$last_ok_gp" "$last_ok")
                    previous_gp="$last_ok_gp"; previous_rate="$last_ok"
                fi
                log INFO "低速干净参考: ${clean_reference_receiver}/${clean_reference_rate}，后续最低可接受效率比 ${min_efficiency}"
                for ((rate=low+step; first_scan_lossy==0 && rate<=high; rate+=step)); do
                    measurement_cooldown BETWEEN_LEVEL "$rate" "$coarse_duration" || { rc=$?; break; }
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    measure_level_with_confirmation "$peer" "$port" "$coarse_duration" "$confirm_duration" "$parallel" \
                        "rate-${rate}" "$threshold" "$clean_reference_loss" "$rate" || { rc=$?; break; }
                    row="$MEASURE_LEVEL_ROW"
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%%\n' "$rate" "$gp" "$loss"
                    if (( MEASURE_LEVEL_SPIKE_CONFIRMED )); then broke_at="$rate"; break; fi
                    if throughput_stalled "$gp" "$previous_gp" "$rate" "$previous_rate" "$min_efficiency"; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; last_ok_gp="$gp"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$broke_at" ]]; then
                fine_step=$(( (broke_at-last_ok+7) / 8 )); ((fine_step < 1)) && fine_step=1
                fine_start=$((last_ok + fine_step))
                previous_gp="$last_ok_gp"; previous_rate="$last_ok"; stall_count=0; stalled_rate=""
                for ((rate=fine_start; rate<broke_at; rate+=fine_step)); do
                    measurement_cooldown BETWEEN_LEVEL "$rate" "$coarse_duration" || { rc=$?; break; }
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    measure_level_with_confirmation "$peer" "$port" "$coarse_duration" "$confirm_duration" "$parallel" \
                        "refine-${rate}" "$threshold" "$clean_reference_loss" "$rate" || { rc=$?; break; }
                    row="$MEASURE_LEVEL_ROW"
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%% (refine)\n' "$rate" "$gp" "$loss"
                    if (( MEASURE_LEVEL_SPIKE_CONFIRMED )); then broke_at="$rate"; break; fi
                    if throughput_stalled "$gp" "$previous_gp" "$rate" "$previous_rate" "$min_efficiency"; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; last_ok_gp="$gp"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$last_ok" && -n "$broke_at" ]]; then
                candidate=$(( last_ok * (100-margin) / 100 )); ((candidate < 1)) && candidate=1
                measurement_cooldown BETWEEN_LEVEL "$candidate" "$confirm_duration" || rc=$?
                if (( rc == 0 )); then apply_shaping "$iface" "$candidate" || rc=$?; fi
                if (( rc == 0 )); then
                    confirm_row=$(sample_repeated "$peer" "$port" "$confirm_duration" "$parallel" "$MEASURE_CANDIDATE_SAMPLES" "confirm-${candidate}" "$MEASURE_CANDIDATE_MAX_SAMPLES" 6 "$candidate" shaped) || rc=$?
                    confirm_gp=$(cut -f1 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    confirm_loss=$(cut -f4 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    if (( rc == 0 )) && measurement_sample_acceptable "$confirm_gp" "$confirm_loss" "$candidate" "$min_efficiency" "$threshold" "$base_loss"; then
                        recommend="$candidate"; confirmed=1
                    elif (( rc == 0 )); then
                        reject_reason="confirmation-failed"
                        declare -F failure_set >/dev/null && failure_set CANDIDATE_CONFIRM candidate-confirm-failed "candidate ${candidate}Mbit did not meet throughput/retrans gates" "" 2
                        log WARN "候选档 ${candidate} Mbit 复测未通过吞吐/重传门槛，不生成推荐值"
                    fi
                fi
            elif (( rc == 0 )); then
                if (( policer_suspected )); then
                    measurement_state=MEASUREMENT_UNSTABLE; scan_decision=inconclusive-policer-out-of-range
                    reject_reason=policer-suspected-but-knee-not-located; rc=2
                    log WARN "饱和探针疑似 policer，但扫描到上界仍未定位拐点"
                else
                    no_knee=1; no_knee_reason=scan-complete-no-knee; measurement_state=CLEAN_NO_POLICER
                    scan_decision=no-knee-clean
                fi
            fi
        fi
    fi

    if (( rc == 0 )) && [[ -n "${recommend:-}" ]]; then scan_decision=recommend; measurement_state=CLEAN_POLICER_FOUND; fi
    if (( rc == 0 )) && [[ "$reject_reason" == confirmation-failed ]]; then scan_decision=inconclusive-confirmation; fi
    if (( rc == MEASURE_BUDGET_RC )); then
        measurement_state=MEASUREMENT_BUDGET_EXCEEDED; scan_decision=budget-exceeded
        reject_reason=budget-exceeded; recommend=""; confirmed=0; no_knee=0
    fi

    if (( rc == 0 || rc == MEASURE_PATH_QUALITY_RC || rc == MEASURE_BUDGET_RC || rc == MEASUREMENT_PREFLIGHT_RC || rc == 2 )); then
        printf 'TYPE\tsweep\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nHARDWARE_CLASS\t%s\nLINK_MBIT\t%s\nRX_QUEUES\t%s\nTX_QUEUES\t%s\nSCAN_CAP_MBIT\t%s\nSAMPLE_DURATION_SECONDS\t%s\nUNSHAPED_MBIT\t%s\nBASE_RETRANS_RATIO_EST_PERCENT\t%s\nCLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t%s\nBASELINE_QUALITY\t%s\nSCAN_DECISION\t%s\nLOW\t%s\nHIGH\t%s\nSTEP\t%s\nMIN_EFFICIENCY_RATIO\t%s\nLAST_OK\t%s\nBROKE_AT\t%s\nCANDIDATE\t%s\nCONFIRM_MBIT\t%s\nCONFIRM_RETRANS_RATIO_EST_PERCENT\t%s\nCONFIRMED\t%s\nREJECT_REASON\t%s\nRECOMMEND\t%s\nMARGIN_PERCENT\t%s\nNO_KNEE\t%s\nNO_KNEE_REASON\t%s\nABOVE_CAP\t%s\n' \
            "$peer" "$port" "$iface" "$HARDWARE_CLASS" "$HARDWARE_LINK_MBIT" "$HARDWARE_RX_QUEUES" "$HARDWARE_TX_QUEUES" "$cap" "$duration" \
            "${saturation_receiver:-}" "${saturation_loss:-}" "${clean_reference_loss:-${path_control_loss:-0}}" "$legacy_baseline_quality" "$scan_decision" "$low" "$high" "$step" "$min_efficiency" "${last_ok:-}" "${broke_at:-}" "${candidate:-}" "${confirm_gp:-}" "${confirm_loss:-}" "$confirmed" "${reject_reason:-}" "${recommend:-}" "$margin" "$no_knee" "$no_knee_reason" "$above_cap" > "$dir/summary.tsv"
        printf 'MEASUREMENT_STATE\t%s\nPATH_CONTROL_RATE_MBIT\t%s\nPATH_CONTROL_SENDER_MBIT\t%s\nPATH_CONTROL_RECEIVER_MBIT\t%s\nPATH_CONTROL_RETRANS_EST_PERCENT\t%s\nPATH_CONTROL_QUALITY\t%s\nSATURATION_SENDER_MBIT\t%s\nSATURATION_RECEIVER_MBIT\t%s\nSATURATION_RETRANS_EST_PERCENT\t%s\nSATURATION_STATE\t%s\nCAPACITY_DISCOVERY_MODE\t%s\nCAPACITY_RECEIVER_MBIT\t%s\nPOLICER_SUSPECTED\t%s\nSCAN_LOW_MBIT\t%s\nSCAN_HIGH_MBIT\t%s\nSCAN_STEP_MBIT\t%s\nCLEAN_REFERENCE_RATE_MBIT\t%s\nCLEAN_REFERENCE_RECEIVER_MBIT\t%s\nCLEAN_REFERENCE_RETRANS_EST_PERCENT\t%s\nKNEE_MBIT\t%s\nUNSHAPED_SEMANTICS\treceiver-delivered-saturation-probe\n' \
            "$measurement_state" "$path_control_rate" "${path_control_sender:-}" "${path_control_receiver:-}" "${path_control_loss:-}" "$path_control_quality" \
            "${saturation_sender:-}" "${saturation_receiver:-}" "${saturation_loss:-}" "$saturation_state" "$capacity_mode" "${capacity_receiver:-}" \
            "$policer_suspected" "$low" "$high" "$step" "${clean_reference_rate:-$path_control_rate}" \
            "${clean_reference_receiver:-$path_control_receiver}" "${clean_reference_loss:-$path_control_loss}" "${last_ok:-}" >> "$dir/summary.tsv"
        printf 'CONTROL_DURATION_SECONDS\t%s\nSATURATION_DURATION_SECONDS\t%s\nCOARSE_DURATION_SECONDS\t%s\nCONFIRM_DURATION_SECONDS\t%s\nPLANNED_SAMPLE_UPPER_BOUND\t%s\nESTIMATED_TRAFFIC_BYTES_UPPER_BOUND\t%s\nMEASUREMENT_PROFILE\t%s\n' \
            "$control_duration" "$saturation_duration" "$coarse_duration" "$confirm_duration" "${tests:-0}" "${estimated:-0}" "$MEASUREMENT_PROFILE" >> "$dir/summary.tsv"
        printf 'BASELINE_QUALITY_SEMANTICS\tpath-control-compatibility-alias\n' >> "$dir/summary.tsv"
        confidence_row="${confirm_row:-${saturation_row:-}}"
        if [[ -n "$confidence_row" ]]; then
            confidence=$(measurement_confidence "$(cut -f13 <<< "$confidence_row")" "$(cut -f12 <<< "$confidence_row")" "$(cut -f7 <<< "$confidence_row")" "$(cut -f11 <<< "$confidence_row")" 0 "$PATH_PROFILE_SCORE" "$(cut -f19 <<< "$confidence_row")")
            IFS=$'\t' read -r sample_confidence_score sample_confidence_grade sample_confidence_reasons <<< "$confidence"
        else
            sample_confidence_score=0; sample_confidence_grade=low; sample_confidence_reasons=no-usable-sample
        fi
        if [[ "$scan_decision" == inconclusive-* || "$path_control_quality" != clean ]]; then
            decision_confidence_score=0; decision_confidence_grade=low
            decision_confidence_reasons="${reject_reason:-measurement-unstable}"
            confidence_score="$decision_confidence_score"; confidence_grade="$decision_confidence_grade"; confidence_reasons="$decision_confidence_reasons"
        else
            decision_confidence_score="$sample_confidence_score"; decision_confidence_grade="$sample_confidence_grade"
            decision_confidence_reasons="$sample_confidence_reasons"
            confidence_score="$sample_confidence_score"; confidence_grade="$sample_confidence_grade"; confidence_reasons="$sample_confidence_reasons"
        fi
        printf 'IDLE_RTT_MS\t%s\nUNSHAPED_RETRANS_PER_GIB\t%s\nUNSHAPED_LOADED_RTT_P95_MS\t%s\nUNSHAPED_BUFFERBLOAT_P95_MS\t%s\nUNSHAPED_BACKGROUND_TX_PERCENT_MAX\t%s\nUNSHAPED_CPU_BUSY_PERCENT_MAX\t%s\nUNSHAPED_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_RETRANS_PER_GIB\t%s\nCONFIRM_LOADED_RTT_P95_MS\t%s\nCONFIRM_BUFFERBLOAT_P95_MS\t%s\nCONFIRM_BACKGROUND_TX_PERCENT_MAX\t%s\nCONFIRM_CPU_BUSY_PERCENT_MAX\t%s\nCONFIRM_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_GOODPUT_SPREAD_PERCENT\t%s\nCONFIRM_SAMPLE_COUNT\t%s\nSAMPLE_CONFIDENCE_SCORE\t%s\nSAMPLE_CONFIDENCE_GRADE\t%s\nSAMPLE_CONFIDENCE_REASONS\t%s\nDECISION_CONFIDENCE_SCORE\t%s\nDECISION_CONFIDENCE_GRADE\t%s\nDECISION_CONFIDENCE_REASONS\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f5 <<< "${saturation_row:-}")" "$(cut -f7 <<< "${saturation_row:-}")" "$(cut -f14 <<< "${saturation_row:-}")" \
            "$(cut -f8 <<< "${saturation_row:-}")" "$(cut -f9 <<< "${saturation_row:-}")" "$(cut -f10 <<< "${saturation_row:-}")" \
            "$(cut -f5 <<< "${confirm_row:-}")" "$(cut -f7 <<< "${confirm_row:-}")" "$(cut -f14 <<< "${confirm_row:-}")" \
            "$(cut -f8 <<< "${confirm_row:-}")" "$(cut -f9 <<< "${confirm_row:-}")" "$(cut -f10 <<< "${confirm_row:-}")" \
            "$(cut -f12 <<< "${confirm_row:-}")" "$(cut -f13 <<< "${confirm_row:-}")" \
            "$sample_confidence_score" "$sample_confidence_grade" "$sample_confidence_reasons" \
            "$decision_confidence_score" "$decision_confidence_grade" "$decision_confidence_reasons" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" >> "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if [[ -n "${recommend:-}" ]]; then
            log OK "扫描完成: last clean=${last_ok} Mbit, break=${broke_at:-above-range} Mbit, 推荐=${recommend} Mbit"
            if [[ "$result_mode" == auto ]]; then
                log INFO "候选档已通过扫描确认；最终单双流复验通过后才会持久化"
            else
                log INFO "确认业务表现后执行: ${0##*/} tc enable ${recommend} --knee ${broke_at:-0} --margin ${margin} --interface ${requested}"
            fi
        fi
        if [[ "$scan_decision" == inconclusive-* ]]; then
            log WARN "扫描结论: inconclusive（${decision_confidence_reasons}）；不会生成或持久化 measurement-derived 参数"
        else
            log INFO "扫描结论: ${scan_decision}；决策置信度 ${decision_confidence_grade} (${decision_confidence_score}/100, ${decision_confidence_reasons})"
        fi
        log INFO "完整结果: $dir"
    fi
    traffic_report "$iface"
    health_family="$MEASURE_PEER_FAMILY"; health_address="$MEASURE_PEER_ADDRESS"; health_rtt="${PATH_RTT_MEDIAN_MS:-na}"
    if measure_restore; then :; else restore_rc=$?; rc="$ROLLBACK_FAILURE_RC"; declare -F failure_set >/dev/null && failure_set ROLLBACK rollback-failed "temporary qdisc restore failed (restore rc=$restore_rc)" "" "$ROLLBACK_FAILURE_RC"; fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run sweep "$peer" "$port" "$iface" "$rc" "$([[ "$restore_rc" == 0 ]] && printf complete || printf failed)" || {
            log WARN "measurement history finalization failed; networking state remains authoritative"
        }
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    if (( rc == 2 )) && [[ "$path_control_quality" == clean || "$path_control_quality" == good ]]; then
        if [[ "$scan_decision" == inconclusive-policer-out-of-range ]]; then health_semantic="knee-not-located"
        else health_semantic=measurement-inconclusive
        fi
    fi
    measurement_peer_health_finalize "$peer" "$health_family" "$health_address" "$port" "$rc" "$health_rtt" \
        "${saturation_receiver:-na}" "$path_control_quality" "$health_semantic" || log WARN "peer health 写入失败；网络事务不受影响"
    return "$rc"
}

summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

measure_path_check() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" preferred_address="${5:-}" preferred_source="${6:-}"
    local iface dir row="" gp="" sender="" loss="" quality=unknown rc=0 accepted=0 restore_rc=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate > 0 )) || { die "路径检查速率无效"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    new_measure_run path-check || return 1; dir="$MEASURE_RUN_DIR"
    if declare -F measurement_environment_preflight >/dev/null; then
        if measurement_environment_preflight "$iface" "$rate"; then :; else
            rc=$?; measurement_finalize_run path-check "$peer" "$port" "$iface" "$rc" not-needed || true
            failure_summary_print "$dir/summary.tsv" || true; measure_clear_peer_lock; return "$rc"
        fi
    fi
    if measure_set_latency_baseline "$peer"; then :; else rc=$?; measurement_abort_before_begin path-check "$peer" "$port" "$iface" "$rc"; return $?; fi
    if path_profile_tuning_gate 0; then :; else rc=$?; measurement_abort_before_begin path-check "$peer" "$port" "$iface" "$rc"; return $?; fi
    if measure_begin "$iface"; then :; else rc=$?; measurement_abort_before_begin path-check "$peer" "$port" "$iface" "$rc"; return $?; fi
    log INFO "路径预检: 临时整形 ${rate} Mbit/s，检查对端是否足以承载测量"
    if ! apply_shaping "$iface" "$rate"; then
        rc=1
    elif row=$(sample_repeated "$peer" "$port" 5 1 3 path-check 3 8 "$rate" shaped); then
        gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
        sender=$(cut -f15 <<< "$row"); sender="${sender:-$gp}"
        if awk -v g="$gp" -v r="$rate" 'BEGIN {exit !(g < r*0.70)}'; then
            quality=slow-peer
            declare -F failure_set >/dev/null && failure_set PATH_CONTROL peer-too-slow "receiver ${gp}Mbit below 70% of ${rate}Mbit" "" 2
            log ERR "路径预检仅达到 ${gp} Mbit/s，明显低于 ${rate} Mbit/s；更换更近对端后重试"
            rc=2
        elif loss_spike "$loss" 0.5 0; then
            quality=dirty
            declare -F failure_set >/dev/null && failure_set PATH_CONTROL path-dirty "retrans-est ${loss}%" "" "$MEASURE_PATH_QUALITY_RC"
            log ERR "低速路径控制重传比例过高 (${loss}%)；PATH_DIRTY"
            rc="$MEASURE_PATH_QUALITY_RC"
        else
            quality=clean; accepted=1
            log OK "低速路径控制通过: receiver ${gp} Mbit/s，sender ${sender} Mbit/s，重传估算 ${loss}%"
        fi
    else
        rc=$?
    fi
    if [[ -n "$row" ]]; then
        printf 'TYPE\tpath-check\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nPATH_CONTROL_RATE_MBIT\t%s\nPATH_CONTROL_SENDER_MBIT\t%s\nPATH_CONTROL_RECEIVER_MBIT\t%s\nPATH_CONTROL_RETRANS_EST_PERCENT\t%s\nPATH_CONTROL_QUALITY\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nACCEPTED\t%s\n' \
            "$peer" "$port" "$iface" "$rate" "$rate" "$sender" "$gp" "$loss" "$quality" "$gp" "$loss" "$accepted" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log INFO "路径预检结果: $dir"
    fi
    traffic_report "$iface"
    if measure_restore; then :; else restore_rc=$?; rc="$ROLLBACK_FAILURE_RC"; declare -F failure_set >/dev/null && failure_set ROLLBACK rollback-failed "temporary qdisc restore failed (restore rc=$restore_rc)" "" "$ROLLBACK_FAILURE_RC"; fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run path-check "$peer" "$port" "$iface" "$rc" "$([[ "$restore_rc" == 0 ]] && printf complete || printf failed)" || log WARN "path-check history finalization failed"
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    return "$rc"
}

measure_verify() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="${4:-8}" expected_rate="${5:-0}" min_efficiency="${6:-0.90}"
    local clean_reference_loss="${7:-0}" threshold="${8:-0.1}" iface dir one multi one_gp one_loss multi_gp multi_loss rc=0 accepted=1 reject_reason=""
    local preferred_address="${9:-}" preferred_source="${10:-}"
    local multi_parallel
    local one_count multi_count combined_count one_spread multi_spread combined_spread combined_loaded combined_contaminated
    local confidence confidence_score confidence_grade confidence_reasons restore_rc=0 health_family health_address health_rtt preflight_capacity
    local verify_planning_rate verify_rate_semantics
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && (( duration >= 3 && duration <= 120 )) || { die "verify duration 超出安全范围"; return 1; }
    is_uint "$expected_rate" && (( expected_rate <= 1000000 )) || { die "verify 期望速率无效"; return 1; }
    is_decimal "$min_efficiency" && is_decimal "$clean_reference_loss" && is_decimal "$threshold" || { die "verify 验收参数无效"; return 1; }
    awk -v e="$min_efficiency" -v b="$clean_reference_loss" -v t="$threshold" 'BEGIN {exit !(e>0 && e<=1 && b>=0 && b<=100 && t>=0 && t<=100)}' || {
        die "verify 验收参数超出安全范围"
        return 1
    }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    multi_parallel=$(recommended_verify_flows "$iface" "$expected_rate") || return 1
    new_measure_run verify || return 1; dir="$MEASURE_RUN_DIR"
    preflight_capacity="$expected_rate"
    if (( preflight_capacity == 0 )); then preflight_capacity=$(detect_link_speed "$iface"); is_uint "$preflight_capacity" || preflight_capacity=0; fi
    if (( expected_rate > 0 )); then
        verify_planning_rate="$expected_rate"; verify_rate_semantics=shaped
    elif (( preflight_capacity > 0 )); then
        verify_planning_rate="$preflight_capacity"; verify_rate_semantics=unshaped
    else
        verify_planning_rate=$(recommended_scan_cap "$iface" 0) || return 1
        verify_rate_semantics=unshaped
    fi
    if declare -F measurement_environment_preflight >/dev/null; then
        if measurement_environment_preflight "$iface" "$preflight_capacity"; then :; else
            rc=$?; measurement_finalize_run verify "$peer" "$port" "$iface" "$rc" not-needed || true
            failure_summary_print "$dir/summary.tsv" || true; measure_clear_peer_lock; return "$rc"
        fi
    fi
    if measure_set_latency_baseline "$peer"; then :; else rc=$?; measurement_abort_before_begin verify "$peer" "$port" "$iface" "$rc"; return $?; fi
    if path_profile_tuning_gate 0; then :; else rc=$?; measurement_abort_before_begin verify "$peer" "$port" "$iface" "$rc"; return $?; fi
    if measure_begin "$iface"; then :; else rc=$?; measurement_abort_before_begin verify "$peer" "$port" "$iface" "$rc"; return $?; fi
    measurement_cooldown PRE_VERIFY "$expected_rate" "$duration" || rc=$?
    if (( rc == 0 )); then one=$(sample_repeated "$peer" "$port" "$duration" 1 "$MEASURE_VERIFY_SAMPLES" verify-single "$MEASURE_VERIFY_MAX_SAMPLES" 6 \
        "$verify_planning_rate" "$verify_rate_semantics") || rc=$?; fi
    if (( rc == 0 )); then multi=$(sample_repeated "$peer" "$port" "$duration" "$multi_parallel" "$MEASURE_VERIFY_SAMPLES" "verify-multi-${multi_parallel}" "$MEASURE_VERIFY_MAX_SAMPLES" 6 \
        "$verify_planning_rate" "$verify_rate_semantics" "$(cut -f15 <<< "${one:-}")" "$(cut -f4 <<< "${one:-}")" "$(cut -f8 <<< "${one:-}")") || rc=$?; fi
    if (( rc == 0 )); then
        one_gp=$(cut -f1 <<< "$one"); one_loss=$(cut -f4 <<< "$one")
        multi_gp=$(cut -f1 <<< "$multi"); multi_loss=$(cut -f4 <<< "$multi")
        if (( expected_rate > 0 )); then
            if ! measurement_sample_acceptable "$one_gp" "$one_loss" "$expected_rate" "$min_efficiency" "$threshold" "$clean_reference_loss"; then
                accepted=0; reject_reason="single-flow-below-threshold"
            elif ! measurement_sample_acceptable "$multi_gp" "$multi_loss" "$expected_rate" "$min_efficiency" "$threshold" "$clean_reference_loss"; then
                accepted=0; reject_reason="multi-flow-below-threshold"
            fi
        elif loss_spike "$one_loss" "$threshold" "$clean_reference_loss" || loss_spike "$multi_loss" "$threshold" "$clean_reference_loss"; then
            accepted=0; reject_reason="final-retrans-above-clean-reference"
        fi
        one_count=$(cut -f13 <<< "$one"); multi_count=$(cut -f13 <<< "$multi")
        is_uint "$one_count" || one_count=0; is_uint "$multi_count" || multi_count=0
        if (( one_count < multi_count )); then combined_count="$one_count"; else combined_count="$multi_count"; fi
        one_spread=$(cut -f12 <<< "$one"); multi_spread=$(cut -f12 <<< "$multi")
        if is_decimal "$one_spread" && is_decimal "$multi_spread"; then
            combined_spread=$(printf '%s\n%s\n' "$one_spread" "$multi_spread" | max_numbers)
        else
            combined_spread=na
        fi
        if is_decimal "$(cut -f7 <<< "$one")" && is_decimal "$(cut -f7 <<< "$multi")"; then
            combined_loaded=$(printf '%s\n%s\n' "$(cut -f7 <<< "$one")" "$(cut -f7 <<< "$multi")" | max_numbers)
        else
            combined_loaded=na
        fi
        combined_contaminated=$(printf '%s\n%s\n' "$(cut -f11 <<< "$one")" "$(cut -f11 <<< "$multi")" | max_numbers)
        local receiver_fallback=0
        if [[ "$(cut -f19 <<< "$one")" == 1 || "$(cut -f19 <<< "$multi")" == 1 ]]; then receiver_fallback=1; fi
        confidence=$(measurement_confidence "$combined_count" "$combined_spread" "$combined_loaded" "$combined_contaminated" 0 "$PATH_PROFILE_SCORE" "$receiver_fallback")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tverify\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nEXPECTED_RATE_MBIT\t%s\nMIN_EFFICIENCY_RATIO\t%s\nIDLE_RTT_MS\t%s\nSINGLE_SENDER_MBIT\t%s\nSINGLE_RECEIVER_MBIT\t%s\nSINGLE_MBIT\t%s\nSINGLE_RETRANS_EST_PERCENT\t%s\nSINGLE_RETRANS_PER_GIB\t%s\nSINGLE_LOADED_RTT_P95_MS\t%s\nSINGLE_BUFFERBLOAT_P95_MS\t%s\nSINGLE_GOODPUT_SPREAD_PERCENT\t%s\nSINGLE_SAMPLE_COUNT\t%s\nMULTI_FLOWS\t%s\nMULTI_SENDER_MBIT\t%s\nMULTI_RECEIVER_MBIT\t%s\nMULTI_MBIT\t%s\nMULTI_RETRANS_EST_PERCENT\t%s\nMULTI_RETRANS_PER_GIB\t%s\nMULTI_LOADED_RTT_P95_MS\t%s\nMULTI_BUFFERBLOAT_P95_MS\t%s\nMULTI_GOODPUT_SPREAD_PERCENT\t%s\nMULTI_SAMPLE_COUNT\t%s\nRECEIVER_FALLBACK\t%s\nCLEAN_REFERENCE_RETRANS_EST_PERCENT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nACCEPTED\t%s\nREJECT_REASON\t%s\n' \
            "$peer" "$port" "$iface" "$expected_rate" "$min_efficiency" "$MEASURE_IDLE_RTT_MS" \
            "$(cut -f15 <<< "$one")" "$(cut -f16 <<< "$one")" "$one_gp" "$one_loss" "$(cut -f5 <<< "$one")" "$(cut -f7 <<< "$one")" "$(cut -f14 <<< "$one")" "$one_spread" "$one_count" \
            "$multi_parallel" "$(cut -f15 <<< "$multi")" "$(cut -f16 <<< "$multi")" "$multi_gp" "$multi_loss" "$(cut -f5 <<< "$multi")" "$(cut -f7 <<< "$multi")" "$(cut -f14 <<< "$multi")" "$multi_spread" "$multi_count" \
            "$receiver_fallback" "$clean_reference_loss" "$confidence_score" "$confidence_grade" "$confidence_reasons" "$accepted" "$reject_reason" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if (( accepted )); then
            log OK "验证完成: 单流 ${one_gp} Mbit/s，多流(${multi_parallel}) ${multi_gp} Mbit/s"
            log INFO "负载 RTT p95: 单流 $(cut -f7 <<< "$one") ms，多流 $(cut -f7 <<< "$multi") ms；置信度 ${confidence_grade} (${confidence_score}/100)"
        else
            log ERR "最终复验未通过（$reject_reason）：单流 ${one_gp} Mbit/s，多流 ${multi_gp} Mbit/s"
            if [[ "$reject_reason" == *retrans* ]]; then
                declare -F failure_set >/dev/null && failure_set FINAL_VERIFY verify-retrans-failed "$reject_reason" "" 2
            else
                declare -F failure_set >/dev/null && failure_set FINAL_VERIFY verify-throughput-failed "$reject_reason" "" 2
            fi
            rc=2
        fi
        log INFO "验证结果: $dir"
    fi
    traffic_report "$iface"
    health_family="$MEASURE_PEER_FAMILY"; health_address="$MEASURE_PEER_ADDRESS"; health_rtt="${PATH_RTT_MEDIAN_MS:-na}"
    if measure_restore; then :; else restore_rc=$?; rc="$ROLLBACK_FAILURE_RC"; declare -F failure_set >/dev/null && failure_set ROLLBACK rollback-failed "temporary qdisc restore failed (restore rc=$restore_rc)" "" "$ROLLBACK_FAILURE_RC"; fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run verify "$peer" "$port" "$iface" "$rc" "$([[ "$restore_rc" == 0 ]] && printf complete || printf failed)" || log WARN "verify history finalization failed"
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    measurement_peer_health_finalize "$peer" "$health_family" "$health_address" "$port" "$rc" "$health_rtt" \
        "${multi_gp:-na}" "${PATH_CONTROL_QUALITY:-unknown}" || log WARN "peer health 写入失败"
    return "$rc"
}

measure_compare() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" duration="${5:-6}" rounds="${6:-2}"
    local preferred_address="${7:-}" preferred_source="${8:-}"
    local iface dir speed estimate_rate estimate rc=0 round mode row verdict confidence sample_plan sample_semantics
    local fq_gp shaped_gp fq_rpg shaped_rpg fq_bloat shaped_bloat fq_spread shaped_spread combined_spread combined_loaded
    local confidence_score confidence_grade confidence_reasons throughput_delta receiver_fallback=0 restore_rc=0 preflight_capacity
    local -a fq_goodputs=() shaped_goodputs=() fq_retrans_gib=() shaped_retrans_gib=() fq_bloats=() shaped_bloats=()
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "compare rate 必须是 1–1000000 的整数"; return 1; }
    is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "compare duration 必须是 3–30 秒"; return 1; }
    is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "compare rounds 必须是 2–5"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    new_measure_run compare || return 1; dir="$MEASURE_RUN_DIR"
    speed=$(detect_link_speed "$iface"); estimate_rate="$rate"
    if is_uint "$speed" && (( speed > estimate_rate )); then estimate_rate="$speed"; fi
    preflight_capacity="$estimate_rate"; is_uint "$preflight_capacity" || preflight_capacity="$rate"
    if declare -F measurement_environment_preflight >/dev/null; then
        if measurement_environment_preflight "$iface" "$preflight_capacity"; then :; else
            rc=$?; measurement_finalize_run compare "$peer" "$port" "$iface" "$rc" not-needed || true
            failure_summary_print "$dir/summary.tsv" || true; measure_clear_peer_lock; return "$rc"
        fi
    fi
    if measure_set_latency_baseline "$peer"; then :; else rc=$?; measurement_abort_before_begin compare "$peer" "$port" "$iface" "$rc"; return $?; fi
    estimate=$(estimate_sweep_bytes "$estimate_rate" "$duration" "$((rounds * 2))")
    log INFO "A/B 对照将交错执行 FQ 与 ${rate} Mbit HTB/FQ，各 ${rounds} 轮；最多约 $(human_bytes "$estimate") 出站流量"
    if measure_begin "$iface"; then :; else rc=$?; measurement_abort_before_begin compare "$peer" "$port" "$iface" "$rc"; return $?; fi
    for ((round=1; round<=rounds; round++)); do
        if (( round % 2 )); then local -a modes=(fq shaped); else local -a modes=(shaped fq); fi
        for mode in "${modes[@]}"; do
            if [[ "$mode" == fq ]]; then
                apply_fq "$iface" || { rc=$?; break 2; }
                sample_plan="$estimate_rate"; sample_semantics=unshaped
            else
                apply_shaping "$iface" "$rate" || { rc=$?; break 2; }
                sample_plan="$rate"; sample_semantics=shaped
            fi
            row=$(sample_repeated "$peer" "$port" "$duration" 1 1 "compare-${mode}-r${round}" 1 0 "$sample_plan" "$sample_semantics") || { rc=$?; break 2; }
            [[ "$(cut -f19 <<< "$row")" != 1 ]] || receiver_fallback=1
            if [[ "$mode" == fq ]]; then
                fq_goodputs+=("$(cut -f1 <<< "$row")"); fq_retrans_gib+=("$(cut -f5 <<< "$row")")
                is_decimal "$(cut -f14 <<< "$row")" && fq_bloats+=("$(cut -f14 <<< "$row")")
            else
                shaped_goodputs+=("$(cut -f1 <<< "$row")"); shaped_retrans_gib+=("$(cut -f5 <<< "$row")")
                is_decimal "$(cut -f14 <<< "$row")" && shaped_bloats+=("$(cut -f14 <<< "$row")")
            fi
            sleep 2
        done
    done
    if (( rc == 0 )); then
        fq_gp=$(median_numbers < <(printf '%s\n' "${fq_goodputs[@]}")); shaped_gp=$(median_numbers < <(printf '%s\n' "${shaped_goodputs[@]}"))
        fq_rpg=$(median_numbers < <(printf '%s\n' "${fq_retrans_gib[@]}")); shaped_rpg=$(median_numbers < <(printf '%s\n' "${shaped_retrans_gib[@]}"))
        fq_bloat=$(median_or_na "${fq_bloats[@]}"); shaped_bloat=$(median_or_na "${shaped_bloats[@]}")
        fq_spread=$(relative_spread_percent "${fq_goodputs[@]}"); shaped_spread=$(relative_spread_percent "${shaped_goodputs[@]}")
        combined_spread=$(printf '%s\n%s\n' "$fq_spread" "$shaped_spread" | max_numbers)
        if is_decimal "$fq_bloat" && is_decimal "$shaped_bloat"; then
            combined_loaded=$(printf '%s\n%s\n' "$fq_bloat" "$shaped_bloat" | max_numbers)
        else
            combined_loaded=na
        fi
        verdict=$(compare_verdict "$fq_gp" "$shaped_gp" "$fq_bloat" "$shaped_bloat" "$fq_rpg" "$shaped_rpg")
        confidence=$(measurement_confidence "$rounds" "$combined_spread" "$combined_loaded" 0 0 "$PATH_PROFILE_SCORE" "$receiver_fallback")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        throughput_delta=$(awk -v f="$fq_gp" -v s="$shaped_gp" 'BEGIN {if(f<=0) print "na"; else printf "%.2f", (s-f)*100/f}')
        printf 'TYPE\tcompare\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nDURATION_SECONDS\t%s\nROUNDS\t%s\nORDER\tinterleaved\nIDLE_RTT_MS\t%s\nFQ_RECEIVER_MBIT\t%s\nFQ_GOODPUT_MBIT\t%s\nFQ_RETRANS_PER_GIB\t%s\nFQ_BUFFERBLOAT_P95_MS\t%s\nFQ_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_RECEIVER_MBIT\t%s\nSHAPED_GOODPUT_MBIT\t%s\nSHAPED_RETRANS_PER_GIB\t%s\nSHAPED_BUFFERBLOAT_P95_MS\t%s\nSHAPED_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_THROUGHPUT_DELTA_PERCENT\t%s\nRECEIVER_FALLBACK\t%s\nVERDICT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nPERSISTED\t0\n' \
            "$peer" "$port" "$iface" "$rate" "$duration" "$rounds" "$MEASURE_IDLE_RTT_MS" \
            "$fq_gp" "$fq_gp" "$fq_rpg" "$fq_bloat" "$fq_spread" "$shaped_gp" "$shaped_gp" "$shaped_rpg" "$shaped_bloat" "$shaped_spread" \
            "$throughput_delta" "$receiver_fallback" "$verdict" "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "A/B 完成: FQ ${fq_gp} Mbit/s / ${fq_bloat} ms，整形 ${shaped_gp} Mbit/s / ${shaped_bloat} ms，结论 ${verdict}"
        log INFO "对照置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})；未写入配置或服务"
        log INFO "结果: $dir"
    fi
    traffic_report "$iface"
    if measure_restore; then :; else restore_rc=$?; rc="$ROLLBACK_FAILURE_RC"; declare -F failure_set >/dev/null && failure_set ROLLBACK rollback-failed "temporary qdisc restore failed (restore rc=$restore_rc)" "" "$ROLLBACK_FAILURE_RC"; fi
    if declare -F measurement_finalize_run >/dev/null; then
        measurement_finalize_run compare "$peer" "$port" "$iface" "$rc" "$([[ "$restore_rc" == 0 ]] && printf complete || printf failed)" || log WARN "compare history finalization failed"
        (( rc == 0 )) || failure_summary_print "$dir/summary.tsv" || true
    fi
    return "$rc"
}
