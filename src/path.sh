# -----------------------------------------------------------------------------
# Network path awareness: stable route identity, RTT distribution and PMTU.
# This module is observational. It never changes routes, addresses or links.
# -----------------------------------------------------------------------------

PATH_PROFILE_SCHEMA="1"
PATH_ROUTE_FINGERPRINT=""
PATH_ENDPOINT_FINGERPRINT=""
PATH_GATEWAY="none"
PATH_TABLE="main"
PATH_INTERFACE_MTU="unknown"
PATH_ROUTE_MTU="unknown"
PATH_PMTU="unknown"
PATH_MSS="unknown"
PATH_PMTU_PROBE_CAPPED=0
PATH_PING_SENT=0
PATH_PING_RECEIVED=0
PATH_LOSS_PERCENT="na"
PATH_RTT_MIN_MS="na"
PATH_RTT_MEDIAN_MS="na"
PATH_RTT_P95_MS="na"
PATH_RTT_MAX_MS="na"
PATH_RTT_JITTER_P95_MS="na"
PATH_GATEWAY_RTT_MS="na"
PATH_LATENCY_CLASS="unknown"
PATH_STABILITY="unknown"
PATH_PROFILE_SCORE=0
PATH_PROFILE_GRADE="low"
PATH_DECISION="limited"
PATH_RISK_FLAGS="unavailable"
PATH_CAPTURED_AT=""

path_profile_reset_metrics() {
    PATH_PMTU="unknown"; PATH_MSS="unknown"; PATH_PMTU_PROBE_CAPPED=0
    PATH_PING_SENT=0; PATH_PING_RECEIVED=0; PATH_LOSS_PERCENT="na"
    PATH_RTT_MIN_MS="na"; PATH_RTT_MEDIAN_MS="na"; PATH_RTT_P95_MS="na"; PATH_RTT_MAX_MS="na"
    PATH_RTT_JITTER_P95_MS="na"; PATH_GATEWAY_RTT_MS="na"
    PATH_LATENCY_CLASS="unknown"; PATH_STABILITY="unknown"
    PATH_PROFILE_SCORE=0; PATH_PROFILE_GRADE="low"; PATH_DECISION="limited"
    PATH_RISK_FLAGS="unavailable"; PATH_CAPTURED_AT=""
}

path_state_reset() {
    PATH_ROUTE_FINGERPRINT=""; PATH_ENDPOINT_FINGERPRINT=""
    PATH_GATEWAY="none"; PATH_TABLE="main"
    PATH_INTERFACE_MTU="unknown"; PATH_ROUTE_MTU="unknown"
    path_profile_reset_metrics
}

path_token_after() {
    local token="$1"
    awk -v token="$token" '{for (i=1; i<NF; i++) if ($i==token) {print $(i+1); exit}}'
}

path_route_normalize() {
    local address="$1"
    awk -v address="$address" '
        {
            out=""
            for (i=1; i<=NF; i++) {
                # Everything after the cache marker is a mutable destination
                # exception (RTT/cwnd/expiry/etc.), not forwarding identity.
                # Route MTU is captured separately so a real PMTU change still
                # changes the fingerprint.
                if ($i=="cache") break
                if ($i=="uid" || $i=="expires") {i++; continue}
                value=$i
                if (value==address) value="<target>"
                out=(out=="" ? value : out " " value)
            }
            if (out!="") print out
        }
    '
}

path_hash_payload() {
    if command_exists sha256sum; then
        sha256sum | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        die "路径指纹需要 sha256sum 或 openssl"
        return 1
    fi
}

# Print one tab-separated identity record:
# route-fingerprint, endpoint-fingerprint, gateway, table, interface-mtu,
# route-mtu. The route fingerprint deliberately canonicalizes the target
# literal so a hostname moving between addresses on the same proven route does
# not look like an egress change. The endpoint fingerprint retains the literal.
path_capture_route_identity() {
    local family="$1" address="$2" source="$3" iface="$4"
    local route fib route_norm fib_norm gateway table iface_mtu route_mtu route_payload
    local route_fp endpoint_fp route_iface fib_iface
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    measure_source_address_is_valid "$family" "$source" || return 1
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1

    route=$(ip "-$family" route get "$address" from "$source" 2>/dev/null) || return 1
    fib=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || return 1
    [[ -n "$route" && -n "$fib" ]] || return 1
    route_iface=$(measure_unique_route_iface "$route" "路径指纹 route-get") || return 1
    fib_iface=$(measure_unique_route_iface "$fib" "路径指纹 fibmatch") || return 1
    [[ "$route_iface" == "$iface" && "$fib_iface" == "$iface" ]] || {
        die "路径指纹出口与冻结网卡不一致（route=$route_iface, fib=$fib_iface, expected=$iface）"
        return 1
    }

    route_norm=$(path_route_normalize "$address" <<< "$route") || return 1
    fib_norm=$(path_route_normalize "$address" <<< "$fib") || return 1
    [[ -n "$route_norm" && -n "$fib_norm" ]] || return 1
    gateway=$(path_token_after via <<< "$route"); gateway="${gateway:-none}"
    table=$(path_token_after table <<< "$fib"); table="${table:-main}"
    iface_mtu=$(detect_mtu "$iface"); is_uint "$iface_mtu" || iface_mtu=unknown
    route_mtu=$(path_token_after mtu <<< "$route")
    if ! is_uint "${route_mtu:-}"; then route_mtu="$iface_mtu"; fi

    route_payload=$(printf 'family=%s\nsource=%s\ninterface=%s\ngateway=%s\ntable=%s\ninterface_mtu=%s\nroute_mtu=%s\nroute=%s\nfib=%s\n' \
        "$family" "$source" "$iface" "$gateway" "$table" "$iface_mtu" "$route_mtu" "$route_norm" "$fib_norm") || return 1
    route_fp=$(path_hash_payload <<< "$route_payload") || return 1
    endpoint_fp=$(printf '%saddress=%s\n' "$route_payload" "$address" | path_hash_payload) || return 1
    [[ "$route_fp" =~ ^[0-9a-f]{64}$ && "$endpoint_fp" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$route_fp" "$endpoint_fp" "$gateway" "$table" "$iface_mtu" "$route_mtu"
}

path_lock_route_identity() {
    local state
    state=$(path_capture_route_identity "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" \
        "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE") || {
        die "无法建立测速路径指纹"
        return 1
    }
    IFS=$'\t' read -r PATH_ROUTE_FINGERPRINT PATH_ENDPOINT_FINGERPRINT PATH_GATEWAY PATH_TABLE \
        PATH_INTERFACE_MTU PATH_ROUTE_MTU <<< "$state"
    [[ -n "$PATH_ROUTE_FINGERPRINT" && -n "$PATH_ENDPOINT_FINGERPRINT" ]] || return 1
}

path_verify_route_identity() {
    local state route_fp endpoint_fp gateway table iface_mtu route_mtu
    [[ -n "$PATH_ROUTE_FINGERPRINT" && -n "$PATH_ENDPOINT_FINGERPRINT" ]] || {
        die "测速路径尚未建立指纹"
        return 1
    }
    state=$(path_capture_route_identity "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" \
        "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE") || return 1
    IFS=$'\t' read -r route_fp endpoint_fp gateway table iface_mtu route_mtu <<< "$state"
    [[ "$endpoint_fp" == "$PATH_ENDPOINT_FINGERPRINT" ]] || {
        die "测速端点路径指纹发生变化；拒绝使用本次样本"
        return 1
    }
    [[ "$route_fp" == "$PATH_ROUTE_FINGERPRINT" ]] || {
        die "测速出口路径指纹发生变化；拒绝使用本次样本"
        return 1
    }
}

path_ping_values() {
    awk '
        match($0,/time[=<][0-9.]+/) {
            value=substr($0,RSTART,RLENGTH)
            if (value ~ /^time</) {sub(/^time</,"",value); value=value/2}
            else sub(/^time=/,"",value)
            if (value ~ /^[0-9]+([.][0-9]+)?$/) print value
        }
    '
}

path_percentile_95() {
    sort -n | awk '{a[NR]=$1} END {if(NR){i=int((NR*95+99)/100); if(i<1)i=1; if(i>NR)i=NR; print a[i]}}'
}

path_ping_command() {
    local target="$1" count="$2"
    ping "-$MEASURE_PEER_FAMILY" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" \
        -n -i 0.2 -W 1 -c "$count" -- "$target"
}

path_probe_pmtu() {
    local enabled="$1" family="$MEASURE_PEER_FAMILY" interface_mtu="$PATH_INTERFACE_MTU"
    local icmp_overhead tcp_overhead minimum high low mid payload best=0 probe_cap="${BBRV3_PATH_PMTU_CAP:-9000}"
    (( enabled == 1 )) || { printf 'disabled\tunknown\t0\n'; return 0; }
    is_uint "$interface_mtu" && (( interface_mtu >= 576 )) || { printf 'unknown\tunknown\t0\n'; return 0; }
    is_uint "$probe_cap" && (( probe_cap >= 1280 && probe_cap <= 65535 )) || probe_cap=9000
    if [[ "$family" == 6 ]]; then
        icmp_overhead=48; tcp_overhead=60; minimum=1280
    else
        icmp_overhead=28; tcp_overhead=40; minimum=576
    fi
    high="$interface_mtu"; PATH_PMTU_PROBE_CAPPED=0
    if (( high > probe_cap )); then high="$probe_cap"; PATH_PMTU_PROBE_CAPPED=1; fi
    (( high >= minimum )) || { printf '%s\tunknown\t%s\n' "$high" "$PATH_PMTU_PROBE_CAPPED"; return 0; }
    payload=$((minimum - icmp_overhead)); (( payload >= 0 )) || return 1
    if ! ping "-$family" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" -M "do" \
            -n -W 1 -c 1 -s "$payload" -- "$MEASURE_PEER_ADDRESS" >/dev/null 2>&1; then
        printf 'unknown\tunknown\t%s\n' "$PATH_PMTU_PROBE_CAPPED"
        return 0
    fi
    low="$minimum"; best="$minimum"
    while (( low <= high )); do
        mid=$(((low + high) / 2)); payload=$((mid - icmp_overhead))
        if ping "-$family" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" -M "do" \
                -n -W 1 -c 1 -s "$payload" -- "$MEASURE_PEER_ADDRESS" >/dev/null 2>&1; then
            best="$mid"; low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done
    # PMTU probing uses ICMP payload size, but the reported MSS is a TCP
    # quantity: PMTU minus IP and TCP headers (40 bytes for IPv4, 60 for IPv6).
    printf '%s\t%s\t%s\n' "$best" "$((best-tcp_overhead))" "$PATH_PMTU_PROBE_CAPPED"
}

path_latency_class() {
    local median="$1"
    if ! is_decimal "$median"; then printf 'unknown\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=10)}'; then printf 'local\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=40)}'; then printf 'near\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=100)}'; then printf 'regional\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=200)}'; then printf 'long-haul\n'
    else printf 'extreme\n'; fi
}

path_profile_classify() {
    local score=100 decision=trusted stability=stable grade risk minimum_mtu jitter_limit variable_limit
    local -a risks=()
    if [[ "$MEASURE_PEER_FAMILY" == 6 ]]; then minimum_mtu=1280; else minimum_mtu=576; fi
    PATH_LATENCY_CLASS=$(path_latency_class "$PATH_RTT_MEDIAN_MS")
    if (( PATH_PING_RECEIVED == 0 )); then
        stability=unknown; decision=limited; score=$((score - 30)); risks+=(icmp-unavailable)
    else
        if awk -v l="$PATH_LOSS_PERCENT" 'BEGIN {exit !(l>=20)}'; then
            stability=unstable; decision=unsafe; score=$((score - 55)); risks+=(icmp-loss-high)
        elif awk -v l="$PATH_LOSS_PERCENT" 'BEGIN {exit !(l>0)}'; then
            stability=variable; score=$((score - 20)); risks+=(icmp-loss)
        fi
        if is_decimal "$PATH_RTT_JITTER_P95_MS" && is_decimal "$PATH_RTT_MEDIAN_MS"; then
            jitter_limit=$(awk -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {v=m*0.35; if(v<15)v=15; printf "%.2f",v}')
            variable_limit=$(awk -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {v=m*0.15; if(v<3)v=3; printf "%.2f",v}')
            if awk -v j="$PATH_RTT_JITTER_P95_MS" -v m="$jitter_limit" 'BEGIN {exit !(j>m)}'; then
                stability=unstable; decision=unsafe; score=$((score - 35)); risks+=(jitter-high)
            elif awk -v j="$PATH_RTT_JITTER_P95_MS" -v m="$variable_limit" 'BEGIN {exit !(j>m)}'; then
                [[ "$stability" == stable ]] && stability=variable
                score=$((score - 15)); risks+=(jitter-variable)
            fi
        fi
    fi
    if ! is_uint "$PATH_PMTU"; then
        score=$((score - 5)); risks+=(pmtu-unavailable)
    elif (( PATH_PMTU < minimum_mtu )); then
        decision=unsafe; score=$((score - 50)); risks+=(pmtu-below-family-minimum)
    elif is_uint "$PATH_INTERFACE_MTU" && (( PATH_PMTU < PATH_INTERFACE_MTU )) && (( PATH_PMTU_PROBE_CAPPED == 0 )); then
        score=$((score - 10)); risks+=(reduced-pmtu)
    fi
    case "$PATH_LATENCY_CLASS" in extreme) risks+=(extreme-rtt) ;; long-haul) risks+=(long-haul) ;; esac
    (( score < 0 )) && score=0
    if (( score >= 90 )); then grade=high
    elif (( score >= 65 )); then grade=medium
    else grade=low; fi
    if [[ "$decision" == trusted && "$grade" == low ]]; then decision=limited; fi
    PATH_STABILITY="$stability"; PATH_PROFILE_SCORE="$score"; PATH_PROFILE_GRADE="$grade"; PATH_DECISION="$decision"
    if ((${#risks[@]})); then local IFS=,; risk="${risks[*]}"; else risk=clean; fi
    PATH_RISK_FLAGS="$risk"
}

path_profile_capture() {
    local samples="${1:-7}" pmtu_enabled="${2:-1}" output_file values_file received pmtu_state gateway_output
    is_uint "$samples" && (( samples >= 3 && samples <= 20 )) || { die "路径画像样本数必须是 3–20"; return 1; }
    [[ "$pmtu_enabled" == 0 || "$pmtu_enabled" == 1 ]] || return 1
    [[ -n "$MEASURE_PEER_ADDRESS" && -n "$MEASURE_PEER_SOURCE" && -n "$MEASURE_PEER_IFACE" ]] || {
        die "路径画像需要已冻结的测速端点"
        return 1
    }
    path_verify_route_identity || return 1
    path_profile_reset_metrics
    PATH_CAPTURED_AT=$(utc_now)
    PATH_PING_SENT="$samples"
    output_file=$(mktemp) || return 1
    values_file=$(mktemp) || { rm -f -- "$output_file"; return 1; }
    path_ping_command "$MEASURE_PEER_ADDRESS" "$samples" > "$output_file" 2>/dev/null || true
    path_ping_values < "$output_file" > "$values_file"
    received=$(awk 'END {print NR+0}' "$values_file"); PATH_PING_RECEIVED="$received"
    PATH_LOSS_PERCENT=$(awk -v s="$samples" -v r="$received" 'BEGIN {printf "%.2f",(s-r)*100/s}')
    if (( received > 0 )); then
        PATH_RTT_MIN_MS=$(sort -n "$values_file" | head -n1)
        PATH_RTT_MEDIAN_MS=$(median_numbers < "$values_file")
        PATH_RTT_P95_MS=$(path_percentile_95 < "$values_file")
        PATH_RTT_MAX_MS=$(sort -n "$values_file" | tail -n1)
        PATH_RTT_JITTER_P95_MS=$(awk -v p="$PATH_RTT_P95_MS" -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {d=p-m; if(d<0)d=0; printf "%.2f",d}')
    fi
    if [[ "$PATH_GATEWAY" != none ]]; then
        gateway_output=$(path_ping_command "$PATH_GATEWAY" 3 2>/dev/null || true)
        PATH_GATEWAY_RTT_MS=$(path_ping_values <<< "$gateway_output" | median_numbers)
        [[ -n "$PATH_GATEWAY_RTT_MS" ]] || PATH_GATEWAY_RTT_MS=na
    fi
    pmtu_state=$(path_probe_pmtu "$pmtu_enabled") || { rm -f -- "$output_file" "$values_file"; return 1; }
    IFS=$'\t' read -r PATH_PMTU PATH_MSS PATH_PMTU_PROBE_CAPPED <<< "$pmtu_state"
    path_verify_route_identity || { rm -f -- "$output_file" "$values_file"; return 1; }
    path_profile_classify
    if [[ -n "${MEASURE_RUN_DIR:-}" && -d "$MEASURE_RUN_DIR" ]]; then
        {
            printf 'SAMPLE\tRTT_MS\n'
            awk '{print NR "\t" $1}' "$values_file"
        } > "$MEASURE_RUN_DIR/path-rtt.tsv"
        chmod 0600 "$MEASURE_RUN_DIR/path-rtt.tsv" 2>/dev/null || true
    fi
    rm -f -- "$output_file" "$values_file"
}

path_profile_tuning_gate() {
    local force="${1:-0}"
    [[ "$force" == 0 || "$force" == 1 ]] || return 1
    case "$PATH_DECISION" in
        trusted) return 0 ;;
        limited)
            log WARN "路径画像不完整或置信度有限（${PATH_RISK_FLAGS}）；测量可以继续，但结论会降级"
            return 0
            ;;
        unsafe)
            if (( force )); then
                log WARN "路径画像不稳定（${PATH_RISK_FLAGS}）；已按 --force-scan 继续，仅供人工判断"
                return 0
            fi
            die "路径画像不稳定（${PATH_RISK_FLAGS}）；拒绝自动生成或持久化整形建议"
            return 2
            ;;
        *) die "路径画像决策状态非法: ${PATH_DECISION:-missing}"; return 1 ;;
    esac
}

path_safe_summary_value() {
    local value="$1"
    value=${value//$'\t'/ }; value=${value//$'\n'/ }; value=${value//$'\r'/ }
    printf '%s' "$value"
}

path_profile_append_summary() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    printf 'PATH_PROFILE_SCHEMA\t%s\nPATH_CAPTURED_AT\t%s\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_GATEWAY\t%s\nPATH_TABLE\t%s\nPATH_INTERFACE_MTU\t%s\nPATH_ROUTE_MTU\t%s\nPATH_PMTU\t%s\nPATH_MSS\t%s\nPATH_PMTU_PROBE_CAPPED\t%s\nPATH_PING_SENT\t%s\nPATH_PING_RECEIVED\t%s\nPATH_LOSS_PERCENT\t%s\nPATH_RTT_MIN_MS\t%s\nPATH_RTT_MEDIAN_MS\t%s\nPATH_RTT_P95_MS\t%s\nPATH_RTT_MAX_MS\t%s\nPATH_RTT_JITTER_P95_MS\t%s\nPATH_GATEWAY_RTT_MS\t%s\nPATH_LATENCY_CLASS\t%s\nPATH_STABILITY\t%s\nPATH_PROFILE_SCORE\t%s\nPATH_PROFILE_GRADE\t%s\nPATH_DECISION\t%s\nPATH_RISK_FLAGS\t%s\n' \
        "$PATH_PROFILE_SCHEMA" "$PATH_CAPTURED_AT" "$PATH_ROUTE_FINGERPRINT" "$PATH_ENDPOINT_FINGERPRINT" \
        "$(path_safe_summary_value "$PATH_GATEWAY")" "$(path_safe_summary_value "$PATH_TABLE")" \
        "$PATH_INTERFACE_MTU" "$PATH_ROUTE_MTU" "$PATH_PMTU" "$PATH_MSS" "$PATH_PMTU_PROBE_CAPPED" \
        "$PATH_PING_SENT" "$PATH_PING_RECEIVED" "$PATH_LOSS_PERCENT" "$PATH_RTT_MIN_MS" "$PATH_RTT_MEDIAN_MS" \
        "$PATH_RTT_P95_MS" "$PATH_RTT_MAX_MS" "$PATH_RTT_JITTER_P95_MS" "$PATH_GATEWAY_RTT_MS" \
        "$PATH_LATENCY_CLASS" "$PATH_STABILITY" "$PATH_PROFILE_SCORE" "$PATH_PROFILE_GRADE" "$PATH_DECISION" \
        "$(path_safe_summary_value "$PATH_RISK_FLAGS")" >> "$file"
}

path_profile_report() {
    printf '%-22s %s\n' 'Target' "$MEASURE_PEER_HOST -> $MEASURE_PEER_ADDRESS"
    printf '%-22s %s\n' 'Route' "IPv${MEASURE_PEER_FAMILY} / src $MEASURE_PEER_SOURCE / dev $MEASURE_PEER_IFACE"
    printf '%-22s %s\n' 'Gateway / table' "$PATH_GATEWAY / $PATH_TABLE"
    printf '%-22s %s\n' 'Route fingerprint' "$PATH_ROUTE_FINGERPRINT"
    printf '%-22s %s\n' 'RTT distribution' "min $PATH_RTT_MIN_MS / median $PATH_RTT_MEDIAN_MS / p95 $PATH_RTT_P95_MS / max $PATH_RTT_MAX_MS ms"
    printf '%-22s %s\n' 'Jitter / ICMP loss' "$PATH_RTT_JITTER_P95_MS ms / $PATH_LOSS_PERCENT% ($PATH_PING_RECEIVED/$PATH_PING_SENT)"
    printf '%-22s %s\n' 'Gateway RTT' "$PATH_GATEWAY_RTT_MS ms"
    printf '%-22s %s\n' 'MTU / PMTU / MSS' "$PATH_INTERFACE_MTU / $PATH_PMTU / $PATH_MSS"
    printf '%-22s %s\n' 'Path class' "$PATH_LATENCY_CLASS / $PATH_STABILITY"
    printf '%-22s %s\n' 'Path confidence' "$PATH_PROFILE_GRADE ($PATH_PROFILE_SCORE/100)"
    printf '%-22s %s\n' 'Tuning decision' "$PATH_DECISION ($PATH_RISK_FLAGS)"
}

path_summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

latest_path_summary() {
    local file
    [[ -d "$HISTORY_DIR" && ! -L "$HISTORY_DIR" ]] || return 1
    while IFS= read -r file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        [[ "$(path_summary_value "$file" PATH_PROFILE_SCHEMA)" == "$PATH_PROFILE_SCHEMA" ]] || continue
        printf '%s\n' "$file"
        return 0
    done < <(find "$HISTORY_DIR" -mindepth 2 -maxdepth 2 -type f -name summary.tsv -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    return 1
}

latest_path_brief() {
    local file peer iface family latency stability pmtu score
    file=$(latest_path_summary 2>/dev/null) || { printf 'none\n'; return 0; }
    peer=$(path_summary_value "$file" PEER); iface=$(path_summary_value "$file" LOCKED_INTERFACE)
    family=$(path_summary_value "$file" LOCKED_FAMILY); latency=$(path_summary_value "$file" PATH_LATENCY_CLASS)
    stability=$(path_summary_value "$file" PATH_STABILITY); pmtu=$(path_summary_value "$file" PATH_PMTU)
    score=$(path_summary_value "$file" PATH_PROFILE_SCORE)
    printf '%s / %s / IPv%s / %s / %s / PMTU %s / %s/100\n' \
        "${peer:-unknown}" "${iface:-unknown}" "${family:-?}" "${latency:-unknown}" "${stability:-unknown}" "${pmtu:-unknown}" "${score:-0}"
}
