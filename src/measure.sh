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
IPERF_DATA_RC=65
IPERF_CONTAMINATED_RC=66
IPERF_UNSTABLE_RC=67
IPERF_UNAVAILABLE_RC=75
PUBLIC_PEER_CANDIDATES=()

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
        if (( ${#PUBLIC_PEER_CANDIDATES[@]} == 1 )); then
            log OK "公共对端已通过 IPv${family} iperf3 预检: $host:$port -> $address ($region/$provider, RTT ${rtt}ms)"
        else
            log INFO "已保留备用公共对端: $host:$port -> $address (IPv${family}, $region/$provider, RTT ${rtt}ms)"
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
    log INFO "本轮接口流量: TX $(human_bytes "$tx"), RX $(human_bytes "$rx")"
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
    local output="$1" context="$2" iface count
    if route_output_has_unresolved_nhid "$output"; then
        die "$context 包含未解析的 nexthop object (nhid)；测速路径不再唯一"
        return 1
    fi
    if route_output_has_multipath "$output"; then
        die "$context 包含 ECMP/nexthop；测速路径不再唯一"
        return 1
    fi
    count=$(route_output_interfaces <<< "$output" | awk 'END {print NR+0}')
    if ! is_uint "${count:-}" || (( count != 1 )); then
        die "$context 无法确定唯一出口网卡"
        return 1
    fi
    iface=$(route_output_interfaces <<< "$output" | sed -n '1p')
    validate_interface_name "$iface" || { die "$context 返回非法出口网卡: $iface"; return 1; }
    printf '%s\n' "$iface"
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
    iface=$(measure_unique_route_iface "$output" "测速地址 $address 的 route-get") || return 1
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
    bound_iface=$(measure_unique_route_iface "$bound_output" "测速地址 $address 的来源绑定 route-get") || return 1
    [[ "$bound_iface" == "$expected_iface" ]] || {
        die "绑定来源地址 $source 后，测速出口从 $expected_iface 变为 $bound_iface"
        return 1
    }
    if ! bound_fibmatch=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || [[ -z "$bound_fibmatch" ]]; then
        die "无法用 fibmatch 核验测速地址 $address 的来源绑定路径"
        return 1
    fi
    bound_fib_iface=$(measure_unique_route_iface "$bound_fibmatch" "测速地址 $address 的来源绑定 fibmatch") || return 1
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
            if ! peer_port_open "$address" "$port" || ! iperf_peer_usable "$address" "$port" "$family" "$source"; then
                (( quiet )) || log WARN "跳过 $address:$port（IPv${family}）：TCP/iperf3 预检不可用"
                if (( is_literal || exact_candidate )); then
                    measure_clear_peer_lock
                    return "$IPERF_UNAVAILABLE_RC"
                fi
                continue
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
    local expected_iface="$requested"
    # The wrapper may fail before measure_lock_peer is reached (for example an
    # invalid explicit interface); stale state must not survive that failure.
    measure_clear_peer_lock
    if [[ "$requested" != auto ]]; then
        expected_iface=$(detect_interface "$requested") || return 1
    fi
    measure_lock_peer "$peer" "$expected_iface" "$port" "$preferred_address" "$preferred_source"
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
        return 1
    fi
    state=$(measure_capture_route_state "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_IFACE" "$MEASURE_PEER_SOURCE") || {
        die "测速路径已漂移；拒绝继续并恢复操作前 qdisc"
        return 1
    }
    IFS=$'\t' read -r iface source <<< "$state"
    [[ "$iface" == "$MEASURE_PEER_IFACE" && "$source" == "$MEASURE_PEER_SOURCE" ]] || {
        die "测速路径已漂移；拒绝使用本次样本"
        return 1
    }
    path_verify_route_identity || {
        die "测速路由、网关、路由表、MTU 或 FIB 指纹已经漂移"
        return 1
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
    measure_peer_route_guard || return 1
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
    local rc=0 reason="" bps bytes retrans goodput ratio retrans_per_gib loaded_median="na" loaded_p95="na"
    local tx_before=0 tx_after=0 background="na" cpu_before cpu_after cpu_busy="na" cpu_steal="na" contaminated=0
    local core_before core_after core_busy="na" core_steal="na" reason_parse_rc=0 cpu_metrics core_metrics latency_metrics
    local route_guard_rc=0
    local -a family_arg=()
    validate_peer "$peer" "$port" || return 1
    measure_require_sample_lock "$peer" "$port" || return $?
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
        return 1
    fi
    rm -f -- "$error_file"
    if (( rc != 0 )); then
        reason=${reason//$'\n'/ }
        reason=${reason//$'\r'/}
        reason=${reason:0:240}
        log WARN "iperf3 $peer:$port（$MEASURE_PEER_ADDRESS）测试失败: $reason"
        rm -f -- "$json" "$latency_file"
        if (( rc == 124 )) || iperf_failure_is_unavailable "$reason"; then return "$IPERF_UNAVAILABLE_RC"; fi
        return 1
    fi
    if (( reason_parse_rc != 0 )); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    if ! bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json") ||
       ! bytes=$(jq -r '.end.sum_sent.bytes // .end.sum.bytes // 0' "$json") ||
       ! retrans=$(jq -r '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0' "$json"); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    rm -f -- "$json"
    if ! is_decimal "$bps" || ! is_uint "$bytes" || ! is_uint "$retrans" || (( bytes == 0 )) || ! awk -v b="$bps" 'BEGIN {exit !(b>0)}'; then
        log WARN "iperf3 $peer:$port 返回的 JSON 结果不完整"
        rm -f -- "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    goodput=$(awk -v b="$bps" 'BEGIN {printf "%.2f", b/1000000}')
    # An estimate, not packet loss: iperf retransmits / estimated MSS-sized segments.
    ratio=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {n=b/1448; if(n<1)n=1; printf "%.5f", r*100/n}')
    retrans_per_gib=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {printf "%.3f", r*1073741824/b}')
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
    if [[ -n "$MEASURE_IFACE" ]]; then background=$(background_tx_percent "$tx_before" "$tx_after" "$bytes"); fi
    sample_is_contaminated "$background" "$cpu_steal" "$cpu_busy" && contaminated=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$goodput" "$retrans" "$bytes" "$ratio" "$retrans_per_gib" "$loaded_median" "$loaded_p95" \
        "$background" "$cpu_busy" "$cpu_steal" "$contaminated"
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
    local -a goodputs=() retrans=() bytes=() ratios=() retrans_gib=() loaded_medians=() loaded_p95s=()
    local -a backgrounds=() cpu_busies=() cpu_steals=() contaminations=()
    local row i attempt sample_rc=0 attempts="${BBRV3_IPERF_ATTEMPTS:-3}" target_count="$count" contamination_retry
    local contamination_retries="${BBRV3_CONTAMINATION_RETRIES:-1}"
    local g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated spread="0.00" bloat
    is_uint "$attempts" && (( attempts >= 1 && attempts <= 5 )) || attempts=3
    is_uint "$contamination_retries" && (( contamination_retries <= 3 )) || contamination_retries=1
    is_uint "$max_count" && (( max_count >= count && max_count <= 5 )) || max_count="$count"
    is_decimal "$stability_threshold" || stability_threshold=0
    for ((i=1; i<=target_count; i++)); do
        log INFO "$label: ${duration}s × ${parallel} flow(s), sample ${i}/${target_count}"
        contamination_retry=0
        while true; do
            row=""
            for ((attempt=1; attempt<=attempts; attempt++)); do
                if row=$(iperf_sample "$peer" "$port" "$duration" "$parallel"); then
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
            IFS=$'\t' read -r g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated <<< "$row"
            rpg="${rpg:-$(awk -v rv="$r" -v bv="$b" 'BEGIN {if(bv>0) printf "%.3f", rv*1073741824/bv; else print "0.000"}')}"
            loaded_med="${loaded_med:-na}"; loaded_tail="${loaded_tail:-na}"; background="${background:-na}"
            cpu_busy="${cpu_busy:-na}"; cpu_steal="${cpu_steal:-na}"; contaminated="${contaminated:-0}"
            bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$loaded_tail")
            [[ -n "$MEASURE_RESULT_FILE" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(utc_now)" "$label" "$g" "$r" "$b" "$l" "$rpg" "$MEASURE_IDLE_RTT_MS" "$loaded_med" "$loaded_tail" \
                "$bloat" "$background" "$cpu_busy" "$cpu_steal" "$contaminated" >> "$MEASURE_RESULT_FILE"
            if [[ "$contaminated" == 1 && "$contamination_retry" -lt "$contamination_retries" ]]; then
                ((contamination_retry+=1))
                log WARN "样本受到后台流量、CPU 饱和或 steal 污染，2 秒后重采（${contamination_retry}/${contamination_retries}）"
                sleep 2
                continue
            fi
            break
        done
        if [[ "$contaminated" == 1 ]]; then
            die "连续样本受到后台流量、CPU 饱和或 steal 污染；停止测量以避免误判拐点"
            return "$IPERF_CONTAMINATED_RC"
        fi
        goodputs+=("$g"); retrans+=("$r"); bytes+=("$b"); ratios+=("$l"); retrans_gib+=("$rpg")
        is_decimal "$loaded_med" && loaded_medians+=("$loaded_med")
        is_decimal "$loaded_tail" && loaded_p95s+=("$loaded_tail")
        is_decimal "$background" && backgrounds+=("$background")
        is_decimal "$cpu_busy" && cpu_busies+=("$cpu_busy")
        is_decimal "$cpu_steal" && cpu_steals+=("$cpu_steal")
        contaminations+=("$contaminated")
        spread=$(relative_spread_percent "${goodputs[@]}")
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
    bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$(median_or_na "${loaded_p95s[@]}")")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(printf '%s\n' "${goodputs[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans[@]}" | median_numbers)" \
        "$(printf '%s\n' "${bytes[@]}" | median_numbers)" \
        "$(printf '%s\n' "${ratios[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans_gib[@]}" | median_numbers)" \
        "$(median_or_na "${loaded_medians[@]}")" "$(median_or_na "${loaded_p95s[@]}")" \
        "$(max_or_na "${backgrounds[@]}")" "$(max_or_na "${cpu_busies[@]}")" "$(max_or_na "${cpu_steals[@]}")" \
        "$(printf '%s\n' "${contaminations[@]}" | max_numbers)" "$spread" "$target_count" "$bloat"
}

loss_spike() {
    local value="$1" threshold="$2" base="$3"
    awk -v v="$value" -v t="$threshold" -v b="$base" 'BEGIN {
        if (v <= t) exit 1;
        if (b > 0 && v < b*5) exit 1;
        exit 0
    }'
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
    local goodput="$1" loss="$2" rate="$3" min_efficiency="$4" threshold="$5" baseline_loss="$6"
    loss_spike "$loss" "$threshold" "$baseline_loss" && return 1
    awk -v g="$goodput" -v r="$rate" -v e="$min_efficiency" 'BEGIN {exit !(r<=0 || g>=r*e)}'
}

estimate_sweep_bytes() {
    local high="$1" duration="$2" tests="$3"
    awk -v r="$high" -v d="$duration" -v n="$tests" 'BEGIN {printf "%.0f", r*1000000/8*d*n*1.08}'
}

new_measure_run() {
    local kind="$1" dir base suffix=0
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
    printf 'TIME\tLABEL\tGOODPUT_MBIT\tRETRANSMITS\tBYTES\tRETRANS_RATIO_EST_PERCENT\tRETRANS_PER_GIB\tIDLE_RTT_MS\tLOADED_RTT_MEDIAN_MS\tLOADED_RTT_P95_MS\tBUFFERBLOAT_P95_MS\tBACKGROUND_TX_PERCENT\tCPU_BUSY_PERCENT\tCPU_STEAL_PERCENT\tCONTAMINATED\n' > "$MEASURE_RESULT_FILE"
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
    measure_clear_peer_lock
    return "$rc"
}

measure_probe() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" preferred_address="${6:-}" preferred_source="${7:-}"
    local iface dir row rc=0 speed estimate
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    fi
    new_measure_run probe || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    measure_begin "$iface" || return 1
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 unshaped 3 6); then
        confidence=$(measurement_confidence "$(cut -f13 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f7 <<< "$row")" "$(cut -f11 <<< "$row")" 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nRETRANS_PER_GIB\t%s\nIDLE_RTT_MS\t%s\nLOADED_RTT_P95_MS\t%s\nBUFFERBLOAT_P95_MS\t%s\nGOODPUT_SPREAD_PERCENT\t%s\nSAMPLE_COUNT\t%s\nBACKGROUND_TX_PERCENT_MAX\t%s\nCPU_BUSY_PERCENT_MAX\t%s\nCPU_STEAL_PERCENT_MAX\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" "$(cut -f5 <<< "$row")" \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f7 <<< "$row")" "$(cut -f14 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f13 <<< "$row")" \
            "$(cut -f8 <<< "$row")" "$(cut -f9 <<< "$row")" "$(cut -f10 <<< "$row")" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "可用带宽中位数: $(cut -f1 <<< "$row") Mbit/s，重传 $(cut -f5 <<< "$row") 次/GiB，负载 RTT p95 $(cut -f7 <<< "$row") ms"
        log INFO "测量置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})"
        log INFO "结果: $dir"
    else rc=$?; fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_sweep() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" nominal="$4" low="$5" high="$6" step="$7"
    local duration="$8" parallel="$9" margin="${10}" threshold="${11}" force_scan="${12}" cap="${13}"
    local result_mode="${14:-manual}"
    local preferred_address="${15:-}" preferred_source="${16:-}"
    local iface dir baseline_row baseline_gp baseline_loss base_row base_gp base_loss rate row gp loss
    local last_ok="" last_ok_gp="" broke_at="" fine_start fine_step recommend="" candidate="" confirm_row confirm_gp="" confirm_loss=""
    local min_efficiency="0.90" confirmed=0 reject_reason="" estimated tests rc=0 no_knee=0 above_cap=0 baseline_duration
    local auto_cap=0 nominal_was_auto=0 observed_cap
    local confidence_row confidence confidence_score confidence_grade confidence_reasons
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
    qdisc_guard "$iface" || return 1
    hardware_profile_values "$iface" "$nominal" || return 1
    new_measure_run sweep || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate "$force_scan" || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1

    baseline_duration="$duration"; ((baseline_duration>5)) && baseline_duration=5
    if ! apply_fq "$iface"; then
        rc=1
    elif baseline_row=$(sample_repeated "$peer" "$port" "$baseline_duration" 1 2 unshaped 3 6); then
        baseline_gp=$(cut -f1 <<< "$baseline_row"); baseline_loss=$(cut -f4 <<< "$baseline_row")
        if (( auto_cap )); then
            if observed_cap=$(expanded_scan_cap "$cap" "$baseline_gp"); then
                if (( observed_cap > cap )); then
                    log INFO "根据不限速基准将扫描上限从 ${cap} 调整为 ${observed_cap} Mbit/s"
                    cap="$observed_cap"
                fi
            else
                rc=$?
            fi
        fi
        if (( rc == 0 )); then
            if awk -v g="$baseline_gp" -v c="$cap" 'BEGIN {exit !(g>c)}'; then
                above_cap=1; no_knee=1
                log WARN "不限速单流达到 ${baseline_gp} Mbit/s，超过扫描上限 ${cap} Mbit/s；跳过整形扫描"
            fi
            (( nominal > 0 )) || nominal=$(awk -v g="$baseline_gp" 'BEGIN {printf "%d", g+0.5}')
            if (( nominal_was_auto )) && [[ "$result_mode" == auto ]]; then
                if duration=$(recommended_measure_duration "$iface" "$nominal"); then :; else rc=$?; fi
            fi
        fi
        if (( rc == 0 )); then
            (( low > 0 )) || low=$(awk -v g="$baseline_gp" 'BEGIN {v=g*0.80; if(v<1)v=1; printf "%d", v}')
            (( high > 0 )) || high=$(awk -v g="$baseline_gp" 'BEGIN {v=g*1.30; if(v<2)v=2; printf "%d", v}')
            (( step > 0 )) || { step=$((nominal / 20)); ((step < 5)) && step=5; }
            if (( ! above_cap && high > cap )); then
                log WARN "扫描上界 ${high} Mbit/s 超过硬上限 ${cap} Mbit/s，已收敛到硬上限"
                high="$cap"
            fi
            if (( ! above_cap && low >= cap )); then
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

    if (( rc == 0 && (step <= 0 || high <= low) )); then
        die "无法根据基准样本生成有效扫描区间"
        rc=1
    fi

    if (( rc == 0 )); then
        # Baseline, low-rate reference and confirmation may each add a third
        # sample when the first pair is unstable.
        tests=$((3 + 3 + (high-low)/step + 4 + 3))
        estimated=$(estimate_sweep_bytes "$high" "$duration" "$tests")
        log INFO "计划最多采集 $tests 个样本、产生约 $(human_bytes "$estimated") 出站流量（不含失败重试）"

        if (( above_cap )); then
            :
        elif (( ! force_scan )) && awk -v v="$baseline_loss" -v t="$threshold" 'BEGIN {limit=t*10; if(limit<1)limit=1; exit !(v>limit)}'; then
            no_knee=1
            log WARN "不限速路径重传估算 ${baseline_loss}% 过高，无法可靠定位 policer；更换对端或使用 --force-scan"
        else
            apply_shaping "$iface" "$low" || rc=$?
            if (( rc == 0 )); then
                base_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "rate-${low}" 3 6) || rc=$?
                base_gp=$(cut -f1 <<< "${base_row:-$'0\t0\t0\t0'}")
                base_loss=$(cut -f4 <<< "${base_row:-$'0\t0\t0\t0'}")
                min_efficiency=$(minimum_efficiency_ratio "$base_gp" "$low")
                log INFO "低速档效率基准: ${base_gp}/${low}，后续最低可接受效率比 ${min_efficiency}"
            fi
            if (( rc == 0 )) && loss_spike "$base_loss" "$threshold" 0; then
                die "扫描下界 ${low} Mbit 已有明显重传，无法建立干净本底；请降低 --low 或更换 peer"
                rc=2
            fi
            if (( rc == 0 )); then
                local previous_gp previous_rate stall_count=0 stalled_rate=""
                last_ok="$low"
                last_ok_gp="$base_gp"; previous_gp="$base_gp"; previous_rate="$low"
                for ((rate=low+step; rate<=high; rate+=step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "rate-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%%\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    if throughput_stalled "$gp" "$previous_gp" "$rate" "$previous_rate" "$min_efficiency"; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; last_ok_gp="$gp"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$broke_at" ]]; then
                fine_step=$((step / 5)); ((fine_step < 1)) && fine_step=1
                fine_start=$((last_ok + fine_step))
                previous_gp="$last_ok_gp"; previous_rate="$last_ok"; stall_count=0; stalled_rate=""
                for ((rate=fine_start; rate<broke_at; rate+=fine_step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "refine-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%% (refine)\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
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
                apply_shaping "$iface" "$candidate" || rc=$?
                if (( rc == 0 )); then
                    confirm_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "confirm-${candidate}" 3 6) || rc=$?
                    confirm_gp=$(cut -f1 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    confirm_loss=$(cut -f4 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    if (( rc == 0 )) && measurement_sample_acceptable "$confirm_gp" "$confirm_loss" "$candidate" "$min_efficiency" "$threshold" "$base_loss"; then
                        recommend="$candidate"; confirmed=1
                    elif (( rc == 0 )); then
                        reject_reason="confirmation-failed"
                        log WARN "候选档 ${candidate} Mbit 复测未通过吞吐/重传门槛，不生成推荐值"
                    fi
                fi
            elif (( rc == 0 )); then
                no_knee=1
                log WARN "扫描到上界仍未发现拐点，不建议基于本次结果启用整形"
            fi
        fi
    fi

    if (( rc == 0 )); then
        printf 'TYPE\tsweep\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nHARDWARE_CLASS\t%s\nLINK_MBIT\t%s\nRX_QUEUES\t%s\nTX_QUEUES\t%s\nSCAN_CAP_MBIT\t%s\nSAMPLE_DURATION_SECONDS\t%s\nUNSHAPED_MBIT\t%s\nBASE_RETRANS_RATIO_EST_PERCENT\t%s\nCLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t%s\nLOW\t%s\nHIGH\t%s\nSTEP\t%s\nMIN_EFFICIENCY_RATIO\t%s\nLAST_OK\t%s\nBROKE_AT\t%s\nCANDIDATE\t%s\nCONFIRM_MBIT\t%s\nCONFIRM_RETRANS_RATIO_EST_PERCENT\t%s\nCONFIRMED\t%s\nREJECT_REASON\t%s\nRECOMMEND\t%s\nMARGIN_PERCENT\t%s\nNO_KNEE\t%s\nABOVE_CAP\t%s\n' \
            "$peer" "$port" "$iface" "$HARDWARE_CLASS" "$HARDWARE_LINK_MBIT" "$HARDWARE_RX_QUEUES" "$HARDWARE_TX_QUEUES" "$cap" "$duration" \
            "${baseline_gp:-}" "${baseline_loss:-}" "${base_loss:-0}" "$low" "$high" "$step" "$min_efficiency" "${last_ok:-}" "${broke_at:-}" "${candidate:-}" "${confirm_gp:-}" "${confirm_loss:-}" "$confirmed" "${reject_reason:-}" "${recommend:-}" "$margin" "$no_knee" "$above_cap" > "$dir/summary.tsv"
        confidence_row="${confirm_row:-${baseline_row:-}}"
        if [[ -n "$confidence_row" ]]; then
            confidence=$(measurement_confidence "$(cut -f13 <<< "$confidence_row")" "$(cut -f12 <<< "$confidence_row")" "$(cut -f7 <<< "$confidence_row")" "$(cut -f11 <<< "$confidence_row")" 0 "$PATH_PROFILE_SCORE")
            IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        else
            confidence_score=0; confidence_grade=low; confidence_reasons=no-usable-sample
        fi
        printf 'IDLE_RTT_MS\t%s\nUNSHAPED_RETRANS_PER_GIB\t%s\nUNSHAPED_LOADED_RTT_P95_MS\t%s\nUNSHAPED_BUFFERBLOAT_P95_MS\t%s\nUNSHAPED_BACKGROUND_TX_PERCENT_MAX\t%s\nUNSHAPED_CPU_BUSY_PERCENT_MAX\t%s\nUNSHAPED_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_RETRANS_PER_GIB\t%s\nCONFIRM_LOADED_RTT_P95_MS\t%s\nCONFIRM_BUFFERBLOAT_P95_MS\t%s\nCONFIRM_BACKGROUND_TX_PERCENT_MAX\t%s\nCONFIRM_CPU_BUSY_PERCENT_MAX\t%s\nCONFIRM_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_GOODPUT_SPREAD_PERCENT\t%s\nCONFIRM_SAMPLE_COUNT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f5 <<< "${baseline_row:-}")" "$(cut -f7 <<< "${baseline_row:-}")" "$(cut -f14 <<< "${baseline_row:-}")" \
            "$(cut -f8 <<< "${baseline_row:-}")" "$(cut -f9 <<< "${baseline_row:-}")" "$(cut -f10 <<< "${baseline_row:-}")" \
            "$(cut -f5 <<< "${confirm_row:-}")" "$(cut -f7 <<< "${confirm_row:-}")" "$(cut -f14 <<< "${confirm_row:-}")" \
            "$(cut -f8 <<< "${confirm_row:-}")" "$(cut -f9 <<< "${confirm_row:-}")" "$(cut -f10 <<< "${confirm_row:-}")" \
            "$(cut -f12 <<< "${confirm_row:-}")" "$(cut -f13 <<< "${confirm_row:-}")" \
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
        log INFO "扫描置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})"
        log INFO "完整结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
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
    local iface dir row="" gp="" loss="" rc=0 accepted=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate > 0 )) || { die "路径检查速率无效"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    new_measure_run path-check || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate 0 || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1
    log INFO "路径预检: 临时整形 ${rate} Mbit/s，检查对端是否足以承载测量"
    if ! apply_shaping "$iface" "$rate"; then
        rc=1
    elif row=$(sample_repeated "$peer" "$port" 5 1 1 path-check); then
        gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
        if awk -v g="$gp" -v r="$rate" 'BEGIN {exit !(g < r*0.60)}'; then
            log ERR "路径预检仅达到 ${gp} Mbit/s，明显低于 ${rate} Mbit/s；更换更近对端后重试"
            rc=2
        elif loss_spike "$loss" 0.5 0; then
            log ERR "路径预检重传比例过高 (${loss}%)；本次对端不适合寻找 policer 拐点"
            rc=2
        else
            accepted=1
            log OK "路径预检通过: ${gp} Mbit/s，重传估算 ${loss}%"
        fi
    else
        rc=$?
    fi
    if [[ -n "$row" ]]; then
        printf 'TYPE\tpath-check\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nACCEPTED\t%s\n' \
            "$peer" "$port" "$iface" "$rate" "$gp" "$loss" "$accepted" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log INFO "路径预检结果: $dir"
    fi
    measure_restore || rc=$?
    return "$rc"
}

measure_verify() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="${4:-8}" expected_rate="${5:-0}" min_efficiency="${6:-0.90}"
    local baseline_loss="${7:-0}" threshold="${8:-0.1}" iface dir one multi one_gp one_loss multi_gp multi_loss rc=0 accepted=1 reject_reason=""
    local preferred_address="${9:-}" preferred_source="${10:-}"
    local multi_parallel
    local one_count multi_count combined_count one_spread multi_spread combined_spread combined_loaded combined_contaminated
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && (( duration >= 3 && duration <= 120 )) || { die "verify duration 超出安全范围"; return 1; }
    is_uint "$expected_rate" && (( expected_rate <= 1000000 )) || { die "verify 期望速率无效"; return 1; }
    is_decimal "$min_efficiency" && is_decimal "$baseline_loss" && is_decimal "$threshold" || { die "verify 验收参数无效"; return 1; }
    awk -v e="$min_efficiency" -v b="$baseline_loss" -v t="$threshold" 'BEGIN {exit !(e>0 && e<=1 && b>=0 && b<=100 && t>=0 && t<=100)}' || {
        die "verify 验收参数超出安全范围"
        return 1
    }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    multi_parallel=$(recommended_verify_flows "$iface" "$expected_rate") || return 1
    new_measure_run verify || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate 0 || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1
    one=$(sample_repeated "$peer" "$port" "$duration" 1 2 verify-single 3 6) || rc=$?
    if (( rc == 0 )); then multi=$(sample_repeated "$peer" "$port" "$duration" "$multi_parallel" 2 "verify-multi-${multi_parallel}" 3 6) || rc=$?; fi
    if (( rc == 0 )); then
        one_gp=$(cut -f1 <<< "$one"); one_loss=$(cut -f4 <<< "$one")
        multi_gp=$(cut -f1 <<< "$multi"); multi_loss=$(cut -f4 <<< "$multi")
        if (( expected_rate > 0 )); then
            if ! measurement_sample_acceptable "$one_gp" "$one_loss" "$expected_rate" "$min_efficiency" "$threshold" "$baseline_loss"; then
                accepted=0; reject_reason="single-flow-below-threshold"
            elif ! measurement_sample_acceptable "$multi_gp" "$multi_loss" "$expected_rate" "$min_efficiency" "$threshold" "$baseline_loss"; then
                accepted=0; reject_reason="multi-flow-below-threshold"
            fi
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
        confidence=$(measurement_confidence "$combined_count" "$combined_spread" "$combined_loaded" "$combined_contaminated" 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tverify\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nEXPECTED_RATE_MBIT\t%s\nMIN_EFFICIENCY_RATIO\t%s\nIDLE_RTT_MS\t%s\nSINGLE_MBIT\t%s\nSINGLE_RETRANS_EST_PERCENT\t%s\nSINGLE_RETRANS_PER_GIB\t%s\nSINGLE_LOADED_RTT_P95_MS\t%s\nSINGLE_BUFFERBLOAT_P95_MS\t%s\nSINGLE_GOODPUT_SPREAD_PERCENT\t%s\nSINGLE_SAMPLE_COUNT\t%s\nMULTI_FLOWS\t%s\nMULTI_MBIT\t%s\nMULTI_RETRANS_EST_PERCENT\t%s\nMULTI_RETRANS_PER_GIB\t%s\nMULTI_LOADED_RTT_P95_MS\t%s\nMULTI_BUFFERBLOAT_P95_MS\t%s\nMULTI_GOODPUT_SPREAD_PERCENT\t%s\nMULTI_SAMPLE_COUNT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nACCEPTED\t%s\nREJECT_REASON\t%s\n' \
            "$peer" "$port" "$iface" "$expected_rate" "$min_efficiency" "$MEASURE_IDLE_RTT_MS" \
            "$one_gp" "$one_loss" "$(cut -f5 <<< "$one")" "$(cut -f7 <<< "$one")" "$(cut -f14 <<< "$one")" "$one_spread" "$one_count" \
            "$multi_parallel" "$multi_gp" "$multi_loss" "$(cut -f5 <<< "$multi")" "$(cut -f7 <<< "$multi")" "$(cut -f14 <<< "$multi")" "$multi_spread" "$multi_count" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" "$accepted" "$reject_reason" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if (( accepted )); then
            log OK "验证完成: 单流 ${one_gp} Mbit/s，多流(${multi_parallel}) ${multi_gp} Mbit/s"
            log INFO "负载 RTT p95: 单流 $(cut -f7 <<< "$one") ms，多流 $(cut -f7 <<< "$multi") ms；置信度 ${confidence_grade} (${confidence_score}/100)"
        else
            log ERR "最终复验未通过（$reject_reason）：单流 ${one_gp} Mbit/s，多流 ${multi_gp} Mbit/s"
            rc=2
        fi
        log INFO "验证结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_compare() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" duration="${5:-6}" rounds="${6:-2}"
    local preferred_address="${7:-}" preferred_source="${8:-}"
    local iface dir speed estimate_rate estimate rc=0 round mode row verdict confidence
    local fq_gp shaped_gp fq_rpg shaped_rpg fq_bloat shaped_bloat fq_spread shaped_spread combined_spread combined_loaded
    local confidence_score confidence_grade confidence_reasons throughput_delta
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
    measure_set_latency_baseline "$peer" || return 1
    speed=$(detect_link_speed "$iface"); estimate_rate="$rate"
    if is_uint "$speed" && (( speed > estimate_rate )); then estimate_rate="$speed"; fi
    estimate=$(estimate_sweep_bytes "$estimate_rate" "$duration" "$((rounds * 2))")
    log INFO "A/B 对照将交错执行 FQ 与 ${rate} Mbit HTB/FQ，各 ${rounds} 轮；最多约 $(human_bytes "$estimate") 出站流量"
    measure_begin "$iface" || return 1
    for ((round=1; round<=rounds; round++)); do
        if (( round % 2 )); then local -a modes=(fq shaped); else local -a modes=(shaped fq); fi
        for mode in "${modes[@]}"; do
            if [[ "$mode" == fq ]]; then
                apply_fq "$iface" || { rc=$?; break 2; }
            else
                apply_shaping "$iface" "$rate" || { rc=$?; break 2; }
            fi
            row=$(sample_repeated "$peer" "$port" "$duration" 1 1 "compare-${mode}-r${round}") || { rc=$?; break 2; }
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
        confidence=$(measurement_confidence "$rounds" "$combined_spread" "$combined_loaded" 0 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        throughput_delta=$(awk -v f="$fq_gp" -v s="$shaped_gp" 'BEGIN {if(f<=0) print "na"; else printf "%.2f", (s-f)*100/f}')
        printf 'TYPE\tcompare\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nDURATION_SECONDS\t%s\nROUNDS\t%s\nORDER\tinterleaved\nIDLE_RTT_MS\t%s\nFQ_GOODPUT_MBIT\t%s\nFQ_RETRANS_PER_GIB\t%s\nFQ_BUFFERBLOAT_P95_MS\t%s\nFQ_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_GOODPUT_MBIT\t%s\nSHAPED_RETRANS_PER_GIB\t%s\nSHAPED_BUFFERBLOAT_P95_MS\t%s\nSHAPED_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_THROUGHPUT_DELTA_PERCENT\t%s\nVERDICT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nPERSISTED\t0\n' \
            "$peer" "$port" "$iface" "$rate" "$duration" "$rounds" "$MEASURE_IDLE_RTT_MS" \
            "$fq_gp" "$fq_rpg" "$fq_bloat" "$fq_spread" "$shaped_gp" "$shaped_rpg" "$shaped_bloat" "$shaped_spread" \
            "$throughput_delta" "$verdict" "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "A/B 完成: FQ ${fq_gp} Mbit/s / ${fq_bloat} ms，整形 ${shaped_gp} Mbit/s / ${shaped_bloat} ms，结论 ${verdict}"
        log INFO "对照置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})；未写入配置或服务"
        log INFO "结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}
