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
PATH_PMTU_EVIDENCE="unavailable"
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
    PATH_PMTU="unknown"; PATH_MSS="unknown"; PATH_PMTU_PROBE_CAPPED=0; PATH_PMTU_EVIDENCE="unavailable"
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
                # A nexthop object numeric ID is allocation metadata.  Its
                # resolved leaf is validated separately and is the topology
                # identity, so RA-driven ID churn must not look like drift.
                if ($i=="uid" || $i=="expires" || $i=="nhid" || $i=="metric" || $i=="proto") {i++; continue}
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
    local route fib gateway table iface_mtu route_mtu route_payload
    local route_fp endpoint_fp route_state fib_state route_iface fib_iface
    local route_gateway route_gateway_family fib_gateway fib_gateway_family
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    measure_source_address_is_valid "$family" "$source" || return 1
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1

    route=$(ip "-$family" route get "$address" from "$source" 2>/dev/null) || return 1
    fib=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || return 1
    [[ -n "$route" && -n "$fib" ]] || return 1
    route_state=$(route_unique_path_record "$route" "路径指纹 route-get" "$family") || return 1
    fib_state=$(route_unique_path_record "$fib" "路径指纹 fibmatch" "$family") || return 1
    route_iface=$(cut -f1 <<< "$route_state")
    fib_iface=$(cut -f1 <<< "$fib_state")
    [[ "$route_iface" == "$iface" && "$fib_iface" == "$iface" ]] || {
        die "路径指纹出口与冻结网卡不一致（route=$route_iface, fib=$fib_iface, expected=$iface）"
        return 1
    }

    IFS=$'\t' read -r route_iface route_gateway route_gateway_family _ <<< "$route_state"
    IFS=$'\t' read -r fib_iface fib_gateway fib_gateway_family _ <<< "$fib_state"
    gateway="$route_gateway"; [[ "$gateway" != none ]] || gateway="$fib_gateway"
    # route-get reports the table actually selected after policy lookup.  Some
    # iproute2/kernel combinations intermittently omit the table token from
    # fibmatch once a destination exception/cache entry exists, so use the
    # selected route first and fibmatch only as a fallback.  Both records are
    # still resolved and fail-closed above.
    table=$(path_token_after table <<< "$route")
    [[ -n "$table" ]] || table=$(path_token_after table <<< "$fib")
    table="${table:-main}"
    iface_mtu=$(detect_mtu "$iface"); is_uint "$iface_mtu" || iface_mtu=unknown
    route_mtu=$(path_token_after mtu <<< "$route")
    if ! is_uint "${route_mtu:-}"; then route_mtu="$iface_mtu"; fi

    # Only forwarding semantics are fingerprinted.  In particular, nhid,
    # expires/cache, protocol and metric presentation are intentionally absent.
    # route_unique_path_record above still resolves every nhid and rejects
    # groups/ECMP/invalid leaves on every capture.
    route_payload=$(printf 'family=%s\nsource=%s\ninterface=%s\ngateway=%s\ngateway_family=%s\ntable=%s\ninterface_mtu=%s\nroute_mtu=%s\nroute_leaf=%s|%s|%s\nfib_leaf=%s|%s|%s\n' \
        "$family" "$source" "$iface" "$gateway" "$route_gateway_family" "$table" "$iface_mtu" "$route_mtu" \
        "$route_iface" "$route_gateway" "$route_gateway_family" "$fib_iface" "$fib_gateway" "$fib_gateway_family") || return 1
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

# Classify one DF/IPv6-do-not-fragment probe.  A successful echo proves that
# the candidate fits.  Only errors with explicit MTU semantics prove that it
# does not; loss, timeout and generic unreachable results remain ambiguous.
path_pmtu_probe_once() {
    local family="$1" payload="$2" output rc lower
    output=$(LC_ALL=C ping "-$family" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" -M "do" \
        -n -W 1 -c 1 -s "$payload" -- "$MEASURE_PEER_ADDRESS" 2>&1) && rc=0 || rc=$?
    if (( rc == 0 )); then
        printf 'fits\n'
        return 0
    fi
    lower=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<< "$output")
    case "$lower" in
        *'emsgsize'*|*'message too long'*|*'frag needed'*|*'packet too big'*|*'packet needs to be fragmented'*|*'fragmentation needed'*)
            printf 'too-large\n'
            ;;
        *)  printf 'ambiguous\n' ;;
    esac
}

# Two matching observations out of at most three are the smallest quorum that
# survives one dropped echo or one anomalous diagnostic without high traffic.
path_pmtu_probe_candidate() {
    local family="$1" payload="$2" result fits=0 too_large=0
    for _ in 1 2 3; do
        result=$(path_pmtu_probe_once "$family" "$payload") || result=ambiguous
        case "$result" in
            fits) ((fits+=1)) ;;
            too-large) ((too_large+=1)) ;;
            *) ;;
        esac
        if (( fits >= 2 )); then printf 'fits\n'; return 0; fi
        if (( too_large >= 2 )); then printf 'too-large\n'; return 0; fi
    done
    printf 'ambiguous\n'
}

path_probe_pmtu() {
    local enabled="$1" family="$MEASURE_PEER_FAMILY" interface_mtu="$PATH_INTERFACE_MTU" route_mtu="$PATH_ROUTE_MTU"
    local icmp_overhead tcp_overhead minimum high low mid payload best=0 result capped=0
    local probe_cap="${BBRV3_PATH_PMTU_CAP:-9000}"
    (( enabled == 1 )) || { printf 'disabled\tunknown\t0\tdisabled\n'; return 0; }
    is_uint "$interface_mtu" && (( interface_mtu >= 576 )) || { printf 'unknown\tunknown\t0\tunavailable\n'; return 0; }
    is_uint "$probe_cap" && (( probe_cap >= 1280 && probe_cap <= 65535 )) || probe_cap=9000
    if [[ "$family" == 6 ]]; then
        icmp_overhead=48; tcp_overhead=60; minimum=1280
    else
        icmp_overhead=28; tcp_overhead=40; minimum=576
    fi
    high="$interface_mtu"
    if is_uint "$route_mtu" && (( route_mtu < high )); then high="$route_mtu"; fi
    if (( high > probe_cap )); then high="$probe_cap"; capped=1; fi
    (( high >= minimum )) || { printf 'unknown\tunknown\t%s\tbelow-family-minimum\n' "$capped"; return 0; }

    # Fast path: the route/interface ceiling is the most useful candidate and
    # a confirmed success proves the full PMTU without binary search.
    payload=$((high - icmp_overhead)); (( payload >= 0 )) || return 1
    result=$(path_pmtu_probe_candidate "$family" "$payload") || result=ambiguous
    case "$result" in
        fits)
            if (( capped )); then
                printf '%s\t%s\t%s\tcapped-lower-bound\n' "$high" "$((high-tcp_overhead))" "$capped"
            else
                printf '%s\t%s\t%s\tfull-mtu-confirmed\n' "$high" "$((high-tcp_overhead))" "$capped"
            fi
            return 0
            ;;
        ambiguous)
            printf 'unknown\tunknown\t%s\tinconclusive\n' "$capped"
            return 0
            ;;
        too-large) ;;
        *) return 1 ;;
    esac

    # A lower bound is useful only when confirmed.  Every subsequent upper
    # bound reduction likewise requires a confirmed MTU-specific failure.
    payload=$((minimum - icmp_overhead))
    result=$(path_pmtu_probe_candidate "$family" "$payload") || result=ambiguous
    case "$result" in
        fits) low=$((minimum + 1)); best="$minimum" ;;
        *) printf 'unknown\tunknown\t%s\tinconclusive\n' "$capped"; return 0 ;;
    esac
    high=$((high - 1))
    while (( low <= high )); do
        mid=$(((low + high) / 2)); payload=$((mid - icmp_overhead))
        result=$(path_pmtu_probe_candidate "$family" "$payload") || result=ambiguous
        case "$result" in
            fits) best="$mid"; low=$((mid + 1)) ;;
            too-large) high=$((mid - 1)) ;;
            ambiguous)
                printf 'unknown\tunknown\t%s\tinconclusive\n' "$capped"
                return 0
                ;;
            *) return 1 ;;
        esac
    done
    # PMTU probing uses ICMP payload size, but the reported MSS is a TCP
    # quantity: PMTU minus IP and TCP headers (40 bytes for IPv4, 60 for IPv6).
    printf '%s\t%s\t%s\treduced-mtu-confirmed\n' "$best" "$((best-tcp_overhead))" "$capped"
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
        score=$((score - 5))
        if [[ "$PATH_PMTU_EVIDENCE" == inconclusive ]]; then risks+=(pmtu-probe-inconclusive)
        else risks+=(pmtu-unavailable)
        fi
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
        PATH_RTT_MIN_MS=$(sort -n "$values_file" | sed -n '1p')
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
    IFS=$'\t' read -r PATH_PMTU PATH_MSS PATH_PMTU_PROBE_CAPPED PATH_PMTU_EVIDENCE <<< "$pmtu_state"
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
    printf 'PATH_PROFILE_SCHEMA\t%s\nPATH_CAPTURED_AT\t%s\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_GATEWAY\t%s\nPATH_TABLE\t%s\nPATH_INTERFACE_MTU\t%s\nPATH_ROUTE_MTU\t%s\nPATH_PMTU\t%s\nPATH_MSS\t%s\nPATH_PMTU_PROBE_CAPPED\t%s\nPATH_PMTU_EVIDENCE\t%s\nPATH_PING_SENT\t%s\nPATH_PING_RECEIVED\t%s\nPATH_LOSS_PERCENT\t%s\nPATH_RTT_MIN_MS\t%s\nPATH_RTT_MEDIAN_MS\t%s\nPATH_RTT_P95_MS\t%s\nPATH_RTT_MAX_MS\t%s\nPATH_RTT_JITTER_P95_MS\t%s\nPATH_GATEWAY_RTT_MS\t%s\nPATH_LATENCY_CLASS\t%s\nPATH_STABILITY\t%s\nPATH_PROFILE_SCORE\t%s\nPATH_PROFILE_GRADE\t%s\nPATH_DECISION\t%s\nPATH_RISK_FLAGS\t%s\n' \
        "$PATH_PROFILE_SCHEMA" "$PATH_CAPTURED_AT" "$PATH_ROUTE_FINGERPRINT" "$PATH_ENDPOINT_FINGERPRINT" \
        "$(path_safe_summary_value "$PATH_GATEWAY")" "$(path_safe_summary_value "$PATH_TABLE")" \
        "$PATH_INTERFACE_MTU" "$PATH_ROUTE_MTU" "$PATH_PMTU" "$PATH_MSS" "$PATH_PMTU_PROBE_CAPPED" "$PATH_PMTU_EVIDENCE" \
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
    printf '%-22s %s\n' 'PMTU evidence' "$PATH_PMTU_EVIDENCE"
    printf '%-22s %s\n' 'Path class' "$PATH_LATENCY_CLASS / $PATH_STABILITY"
    printf '%-22s %s\n' 'Path confidence' "$PATH_PROFILE_GRADE ($PATH_PROFILE_SCORE/100)"
    printf '%-22s %s\n' 'Tuning decision' "$PATH_DECISION ($PATH_RISK_FLAGS)"
}

path_summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

path_profile_required_keys() {
    printf '%s\n' \
        PATH_PROFILE_SCHEMA PATH_CAPTURED_AT PATH_ROUTE_FINGERPRINT PATH_ENDPOINT_FINGERPRINT \
        PATH_GATEWAY PATH_TABLE PATH_INTERFACE_MTU PATH_ROUTE_MTU PATH_PMTU PATH_MSS \
        PATH_PMTU_PROBE_CAPPED PATH_PMTU_EVIDENCE PATH_PING_SENT PATH_PING_RECEIVED \
        PATH_LOSS_PERCENT PATH_RTT_MIN_MS PATH_RTT_MEDIAN_MS PATH_RTT_P95_MS PATH_RTT_MAX_MS \
        PATH_RTT_JITTER_P95_MS PATH_GATEWAY_RTT_MS PATH_LATENCY_CLASS PATH_STABILITY \
        PATH_PROFILE_SCORE PATH_PROFILE_GRADE PATH_DECISION PATH_RISK_FLAGS
}

path_profile_summary_complete() {
    local file="$1" key value count family pmtu mss evidence score sent received
    [[ -f "$file" && ! -L "$file" ]] || return 1
    for key in PEER PORT LOCKED_ADDRESS LOCKED_SOURCE LOCKED_INTERFACE LOCKED_FAMILY; do
        count=$(awk -F'\t' -v key="$key" '$1==key {n++} END {print n+0}' "$file" 2>/dev/null)
        (( count == 1 )) || return 1
    done
    while IFS= read -r key; do
        count=$(awk -F'\t' -v key="$key" '$1==key {n++} END {print n+0}' "$file" 2>/dev/null)
        (( count == 1 )) || return 1
        value=$(path_summary_value "$file" "$key")
        [[ -n "$value" ]] || return 1
    done < <(path_profile_required_keys)
    [[ "$(path_summary_value "$file" PATH_PROFILE_SCHEMA)" == "$PATH_PROFILE_SCHEMA" ]] || return 1
    [[ "$(path_summary_value "$file" PATH_ROUTE_FINGERPRINT)" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(path_summary_value "$file" PATH_ENDPOINT_FINGERPRINT)" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(path_summary_value "$file" PATH_CAPTURED_AT)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    family=$(path_summary_value "$file" LOCKED_FAMILY); [[ "$family" == 4 || "$family" == 6 ]] || return 1
    is_uint "$(path_summary_value "$file" PATH_INTERFACE_MTU)" || return 1
    is_uint "$(path_summary_value "$file" PATH_ROUTE_MTU)" || return 1
    sent=$(path_summary_value "$file" PATH_PING_SENT); received=$(path_summary_value "$file" PATH_PING_RECEIVED)
    is_uint "$sent" && is_uint "$received" && (( received <= sent )) || return 1
    score=$(path_summary_value "$file" PATH_PROFILE_SCORE); is_uint "$score" && (( score <= 100 )) || return 1
    [[ "$(path_summary_value "$file" PATH_PMTU_PROBE_CAPPED)" == 0 || "$(path_summary_value "$file" PATH_PMTU_PROBE_CAPPED)" == 1 ]] || return 1
    evidence=$(path_summary_value "$file" PATH_PMTU_EVIDENCE)
    case "$evidence" in
        full-mtu-confirmed|reduced-mtu-confirmed|capped-lower-bound)
            pmtu=$(path_summary_value "$file" PATH_PMTU); mss=$(path_summary_value "$file" PATH_MSS)
            is_uint "$pmtu" && is_uint "$mss" || return 1
            ;;
        inconclusive|unavailable|below-family-minimum)
            [[ "$(path_summary_value "$file" PATH_PMTU)" == unknown && "$(path_summary_value "$file" PATH_MSS)" == unknown ]] || return 1
            ;;
        disabled)
            [[ "$(path_summary_value "$file" PATH_PMTU)" == disabled && "$(path_summary_value "$file" PATH_MSS)" == unknown ]] || return 1
            ;;
        *) return 1 ;;
    esac
    case "$(path_summary_value "$file" PATH_DECISION)" in trusted|limited|unsafe) ;; *) return 1 ;; esac
}

# Read legacy and standalone path captures without weakening final-profile
# promotion.  v8.0.6 summaries have no PATH_PMTU_EVIDENCE, and standalone
# `measure path` history did not require a transport PORT field.
path_profile_summary_readable() {
    local file="$1" key value count
    [[ -f "$file" && ! -L "$file" ]] || return 1
    for key in PEER LOCKED_ADDRESS LOCKED_SOURCE LOCKED_INTERFACE LOCKED_FAMILY; do
        [[ -n "$(path_summary_value "$file" "$key")" ]] || return 1
    done
    while IFS= read -r key; do
        [[ "$key" != PATH_PMTU_EVIDENCE ]] || continue
        count=$(awk -F'\t' -v key="$key" '$1==key {n++} END {print n+0}' "$file" 2>/dev/null)
        (( count == 1 )) || return 1
        value=$(path_summary_value "$file" "$key"); [[ -n "$value" ]] || return 1
    done < <(path_profile_required_keys)
    [[ "$(path_summary_value "$file" PATH_PROFILE_SCHEMA)" == "$PATH_PROFILE_SCHEMA" ]] || return 1
    [[ "$(path_summary_value "$file" PATH_ROUTE_FINGERPRINT)" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(path_summary_value "$file" PATH_ENDPOINT_FINGERPRINT)" =~ ^[0-9a-f]{64}$ ]] || return 1
}

path_profile_history_id() {
    local file="$1" id
    [[ "$file" == "$HISTORY_DIR/"*/summary.tsv ]] || return 1
    id="${file%/summary.tsv}"; id="${id##*/}"
    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-(path|path-check|probe|sweep|verify|compare)(-[0-9]+)?$ ]] || return 1
    printf '%s\n' "$id"
}

path_profiles_same_identity() {
    local sweep="$1" candidate="$2" key
    for key in PEER LOCKED_ADDRESS LOCKED_SOURCE LOCKED_INTERFACE LOCKED_FAMILY \
        PATH_ROUTE_FINGERPRINT PATH_ENDPOINT_FINGERPRINT PATH_GATEWAY PATH_TABLE \
        PATH_INTERFACE_MTU PATH_ROUTE_MTU; do
        [[ "$(path_summary_value "$sweep" "$key")" == "$(path_summary_value "$candidate" "$key")" ]] || return 1
    done
}

# Persist one complete, real capture as the authority for status.  The source
# history files are read-only here: the final profile is a separate atomic
# artifact with explicit sweep/verify provenance.
path_profile_persist_final() {
    local sweep="$1" candidate="$2" source="$3" sweep_id source_id temp key value
    path_profile_summary_complete "$sweep" || { die "sweep path profile 不完整；不会持久化最终画像"; return 1; }
    path_profile_summary_complete "$candidate" || { die "final path profile 不完整；不会持久化"; return 1; }
    sweep_id=$(path_profile_history_id "$sweep") || return 1
    source_id=$(path_profile_history_id "$candidate") || return 1
    [[ "$(path_summary_value "$sweep" TYPE)" == sweep && "$(path_summary_value "$sweep" RESULT)" == SUCCESS ]] || return 1
    path_profiles_same_identity "$sweep" "$candidate" || {
        die "sweep 与 final path profile 身份不一致；不会持久化"
        return 1
    }
    case "$source" in
        verify)
            [[ "$(path_summary_value "$candidate" TYPE)" == verify && \
               "$(path_summary_value "$candidate" RESULT)" == SUCCESS && \
               "$(path_summary_value "$candidate" ACCEPTED)" == 1 && \
               "$(path_summary_value "$candidate" PATH_DECISION)" == trusted ]] || {
                die "最终 verify path profile 未同时满足 success/accepted/trusted；不会持久化"
                return 1
            }
            ;;
        sweep-local-fallback|sweep-untrusted-verify)
            [[ "$candidate" == "$sweep" && "$(path_summary_value "$candidate" PATH_DECISION)" != unsafe ]] || return 1
            ;;
        *) return 1 ;;
    esac

    ensure_state_layout || return 1
    temp=$(mktemp "${STATE_DIR}/.final-path-profile.XXXXXX") || return 1
    if ! printf 'FINAL_PATH_PROFILE_SCHEMA\t1\nFINAL_PATH_PROFILE_SOURCE\t%s\nFINAL_PATH_SWEEP_HISTORY_ID\t%s\nFINAL_PATH_SOURCE_HISTORY_ID\t%s\nFINAL_PATH_PERSISTED_AT\t%s\n' \
        "$source" "$sweep_id" "$source_id" "$(utc_now)" > "$temp"; then
        rm -f -- "$temp"; return 1
    fi
    for key in PEER PORT INTERFACE LOCKED_ADDRESS LOCKED_SOURCE LOCKED_INTERFACE LOCKED_FAMILY LOCKED_PORT; do
        value=$(path_summary_value "$candidate" "$key")
        printf '%s\t%s\n' "$key" "$(path_safe_summary_value "$value")" >> "$temp" || { rm -f -- "$temp"; return 1; }
    done
    while IFS= read -r key; do
        value=$(path_summary_value "$candidate" "$key")
        printf '%s\t%s\n' "$key" "$(path_safe_summary_value "$value")" >> "$temp" || { rm -f -- "$temp"; return 1; }
    done < <(path_profile_required_keys)
    atomic_install "$temp" "$FINAL_PATH_PROFILE_FILE" 0600 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

path_final_profile_valid() {
    local file="${1:-$FINAL_PATH_PROFILE_FILE}" source
    [[ "$(path_summary_value "$file" FINAL_PATH_PROFILE_SCHEMA)" == 1 ]] || return 1
    source=$(path_summary_value "$file" FINAL_PATH_PROFILE_SOURCE)
    [[ "$source" == verify || "$source" == sweep-local-fallback || "$source" == sweep-untrusted-verify ]] || return 1
    [[ "$(path_summary_value "$file" FINAL_PATH_SWEEP_HISTORY_ID)" =~ ^[0-9]{8}T[0-9]{6}Z-sweep(-[0-9]+)?$ ]] || return 1
    [[ "$(path_summary_value "$file" FINAL_PATH_SOURCE_HISTORY_ID)" =~ ^[0-9]{8}T[0-9]{6}Z-(sweep|verify)(-[0-9]+)?$ ]] || return 1
    path_profile_summary_complete "$file"
}

path_profile_for_sweep() {
    local sweep="$1" sweep_id
    sweep_id=$(path_profile_history_id "$sweep") || { printf '%s\n' "$sweep"; return 0; }
    if path_final_profile_valid "$FINAL_PATH_PROFILE_FILE" &&
       [[ "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" FINAL_PATH_SWEEP_HISTORY_ID)" == "$sweep_id" ]]; then
        printf '%s\n' "$FINAL_PATH_PROFILE_FILE"
    else
        printf '%s\n' "$sweep"
    fi
}

latest_path_summary() {
    local file
    if path_final_profile_valid "$FINAL_PATH_PROFILE_FILE"; then
        printf '%s\n' "$FINAL_PATH_PROFILE_FILE"
        return 0
    fi
    [[ -d "$HISTORY_DIR" && ! -L "$HISTORY_DIR" ]] || return 1
    # A failed or unrelated verify must never displace the last successful
    # sweep.  The separate final profile above is the only promoted authority.
    while IFS= read -r file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        [[ "$(path_summary_value "$file" TYPE)" == sweep && "$(path_summary_value "$file" RESULT)" == SUCCESS ]] || continue
        path_profile_summary_readable "$file" || continue
        printf '%s\n' "$file"
        return 0
    done < <(find "$HISTORY_DIR" -mindepth 2 -maxdepth 2 -type f -name summary.tsv -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    while IFS= read -r file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        path_profile_summary_readable "$file" || continue
        printf '%s\n' "$file"
        return 0
    done < <(find "$HISTORY_DIR" -mindepth 2 -maxdepth 2 -type f -name summary.tsv -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    return 1
}

latest_path_brief() {
    local file peer iface family latency stability pmtu score source
    file=$(latest_path_summary 2>/dev/null) || { printf 'none\n'; return 0; }
    peer=$(path_summary_value "$file" PEER); iface=$(path_summary_value "$file" LOCKED_INTERFACE)
    family=$(path_summary_value "$file" LOCKED_FAMILY); latency=$(path_summary_value "$file" PATH_LATENCY_CLASS)
    stability=$(path_summary_value "$file" PATH_STABILITY); pmtu=$(path_summary_value "$file" PATH_PMTU)
    score=$(path_summary_value "$file" PATH_PROFILE_SCORE)
    source=$(path_summary_value "$file" FINAL_PATH_PROFILE_SOURCE)
    [[ -n "$source" ]] || source=$(path_summary_value "$file" TYPE)
    printf '%s / %s / IPv%s / %s / %s / PMTU %s / %s/100 / source %s\n' \
        "${peer:-unknown}" "${iface:-unknown}" "${family:-?}" "${latency:-unknown}" "${stability:-unknown}" "${pmtu:-unknown}" "${score:-0}" "${source:-capture}"
}
