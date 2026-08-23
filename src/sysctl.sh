# -----------------------------------------------------------------------------
# Sysctl: auditable balanced/adaptive profiles, BBR verification and route IW.
# -----------------------------------------------------------------------------

BALANCED_BUFFER_MAX=16777216
BUFFER_ABSOLUTE_CAP=2147483647

hardware_tuning_values() {
    local role="$1" bandwidth="$2" requested="${3:-${TC_INTERFACE:-auto}}"
    local desired_floor memory_cap platform_cap backlog_limit
    hardware_profile_values "$requested" "$bandwidth" || return 1

    # Keep the per-socket ceiling proportional to available RAM. Low-memory
    # VPSes no longer inherit a forced 16 MiB floor, while large-memory systems
    # can reach the signed sysctl ceiling (about 2 GiB) when BDP actually needs it.
    if (( HARDWARE_MEMORY_MB < 512 )); then desired_floor=4194304; platform_cap=8388608
    elif (( HARDWARE_MEMORY_MB < 1024 )); then desired_floor=8388608; platform_cap=16777216
    elif (( HARDWARE_MEMORY_MB < 2048 )); then desired_floor=16777216; platform_cap=33554432
    elif (( HARDWARE_MEMORY_MB < 4096 )); then desired_floor=16777216; platform_cap=67108864
    elif (( HARDWARE_MEMORY_MB < 8192 )); then desired_floor=16777216; platform_cap=134217728
    elif (( HARDWARE_MEMORY_MB < 12288 )); then desired_floor=16777216; platform_cap=268435456
    elif (( HARDWARE_MEMORY_MB < 24576 )); then desired_floor=16777216; platform_cap=536870912
    elif (( HARDWARE_MEMORY_MB < 49152 )); then desired_floor=16777216; platform_cap=1073741824
    else desired_floor=16777216; platform_cap=$BUFFER_ABSOLUTE_CAP
    fi
    memory_cap=$((HARDWARE_MEMORY_MB * 1024 * 1024 / 32))
    (( memory_cap < 1048576 )) && memory_cap=1048576
    (( platform_cap > BUFFER_ABSOLUTE_CAP )) && platform_cap=$BUFFER_ABSOLUTE_CAP
    BUFFER_CAP="$memory_cap"; (( BUFFER_CAP > platform_cap )) && BUFFER_CAP="$platform_cap"
    BUFFER_FLOOR="$desired_floor"; (( BUFFER_FLOOR > BUFFER_CAP )) && BUFFER_FLOOR="$BUFFER_CAP"
    BUFFER_MEMORY_CAP="$memory_cap"
    BUFFER_PLATFORM_CAP="$platform_cap"

    SOMAXCONN=4096
    if [[ "$role" == proxy ]] && (( HARDWARE_CPU_COUNT >= 4 && HARDWARE_MEMORY_MB >= 2048 )); then SOMAXCONN=8192; fi
    if [[ "$role" == proxy ]] && (( HARDWARE_CPU_COUNT >= 16 && HARDWARE_MEMORY_MB >= 8192 )); then SOMAXCONN=16384; fi
    if [[ "$role" == mixed ]] && (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 && HARDWARE_CPU_COUNT >= 8 )); then SOMAXCONN=8192; fi
    TCP_MAX_SYN_BACKLOG="$SOMAXCONN"

    if (( EFFECTIVE_BANDWIDTH_MBIT <= 1000 )); then NETDEV_BACKLOG=4096
    elif (( EFFECTIVE_BANDWIDTH_MBIT <= 10000 )); then NETDEV_BACKLOG=8192
    elif (( EFFECTIVE_BANDWIDTH_MBIT <= 40000 )); then NETDEV_BACKLOG=16384
    else NETDEV_BACKLOG=32768
    fi
    if (( HARDWARE_CPU_COUNT <= 1 || HARDWARE_MEMORY_MB < 1024 )); then backlog_limit=4096
    elif (( HARDWARE_CPU_COUNT <= 2 || HARDWARE_MEMORY_MB < 2048 )); then backlog_limit=8192
    elif (( HARDWARE_CPU_COUNT <= 4 )); then backlog_limit=16384
    else backlog_limit=32768
    fi
    (( NETDEV_BACKLOG > backlog_limit )) && NETDEV_BACKLOG="$backlog_limit"
    return 0
}

role_tuning_rtt_floor() {
    case "$1" in
        proxy) printf '150\n' ;;
        mixed|bulk) printf '100\n' ;;
        *) die "未知业务用途: $1"; return 1 ;;
    esac
}

recommended_tuning_rtt() {
    local role="$1" observed="${2:-0}" floor
    is_uint "$observed" && (( observed <= 60000 )) || { die "观测 RTT 无效: $observed"; return 1; }
    floor=$(role_tuning_rtt_floor "$role") || return 1
    if (( observed > floor )); then printf '%s\n' "$observed"; else printf '%s\n' "$floor"; fi
}

ensure_bbr_available() {
    local available current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ "$current" == bbr* && "$current" != bbr ]]; then
        die "检测到当前拥塞控制为第三方 BBR 变体 '$current'；为避免静默替换或与其 sysctl 冲突，已中止。请先人工切换到 cubic/标准 bbr 并确认迁移意图"
        return 1
    fi
    modprobe tcp_bbr 2>/dev/null || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<< "$available"; then
        die "当前内核不提供 BBR；不会静默回退到 cubic"
        return 1
    fi
}

bbr_compatibility_status() {
    local current="${1:-}" available="${2:-}"
    [[ -n "$current" ]] || current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    [[ -n "$available" ]] || available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ "$current" == bbr* && "$current" != bbr ]]; then
        printf 'conflict: third-party variant %s would be replaced\n' "$current"
    elif [[ "$current" == bbr ]]; then
        printf 'compatible: standard bbr runtime API\n'
    elif grep -qw bbr <<< "$available"; then
        printf 'ready: standard bbr is available\n'
    else
        printf 'unavailable\n'
    fi
}

bbr_kernel_support_status() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available"; then
        printf 'available (built-in or loaded)\n'
    elif modinfo tcp_bbr >/dev/null 2>&1; then
        printf 'module present, not loaded\n'
    else
        printf 'unavailable\n'
    fi
}

buffer_profile_values() {
    local profile="$1" role="$2" bandwidth="$3" rtt="$4" requested="${5:-${TC_INTERFACE:-auto}}"
    local bdp max default_r=131072 default_w=65536
    hardware_tuning_values "$role" "$bandwidth" "$requested" || return 1
    if [[ "$profile" == balanced ]]; then
        BUFFER_MAX="$BALANCED_BUFFER_MAX"; (( BUFFER_MAX > BUFFER_CAP )) && BUFFER_MAX="$BUFFER_CAP"
        BUFFER_R_DEFAULT=$default_r
        BUFFER_W_DEFAULT=$default_w
        (( BUFFER_R_DEFAULT > BUFFER_MAX )) && BUFFER_R_DEFAULT="$BUFFER_MAX"
        (( BUFFER_W_DEFAULT > BUFFER_MAX )) && BUFFER_W_DEFAULT="$BUFFER_MAX"
        BUFFER_REASON="balanced ceiling, hardware-bounded by RAM/32"
        return 0
    fi
    (( bandwidth > 0 && rtt > 0 )) || { die "adaptive profile 需要 --bandwidth 和 --rtt"; return 1; }
    # bytes = Mbps * ms * 125; keep two BDPs and apply the hardware budget.
    bdp=$(( bandwidth * rtt * 125 ))
    max=$(( bdp * 2 ))
    (( max < BUFFER_FLOOR )) && max=$BUFFER_FLOOR
    (( max > BUFFER_CAP )) && max=$BUFFER_CAP
    case "$role" in
        proxy) default_r=131072; default_w=65536 ;;
        mixed) default_r=262144; default_w=131072 ;;
        bulk)
            default_r=1048576; default_w=1048576
            (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )) && default_r=2097152 && default_w=2097152
            ;;
    esac
    (( default_r > max )) && default_r=$max
    (( default_w > max )) && default_w=$max
    BUFFER_MAX=$max
    BUFFER_R_DEFAULT=$default_r
    BUFFER_W_DEFAULT=$default_w
    BUFFER_REASON="2xBDP with hardware floor, bounded by RAM/32 and platform cap"
}

sysctl_model_interface() {
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then printf '%s\n' "${NIC_MODEL_INTERFACE:-auto}"
    else printf '%s\n' "${TC_INTERFACE:-auto}"
    fi
}

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(sysctl_model_interface)" || return 1
    cat <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# profile=${SYSCTL_PROFILE} role=${ROLE} bandwidth=${BANDWIDTH_MBIT}Mbps tuning_rtt=${RTT_MS}ms
# buffer_max=${BUFFER_MAX} (${BUFFER_REASON})
# hardware=${HARDWARE_CLASS} cpu=${HARDWARE_CPU_COUNT} ram=${HARDWARE_MEMORY_MB}MiB link=${HARDWARE_LINK_MBIT}Mbit(${HARDWARE_LINK_TRUST}) queues=${HARDWARE_RX_QUEUES}/${HARDWARE_TX_QUEUES}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUFFER_MAX}
net.core.wmem_max = ${BUFFER_MAX}
net.ipv4.tcp_rmem = 4096 ${BUFFER_R_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 ${BUFFER_W_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
EOF
}

explain_sysctl_profile() {
    render_sysctl_profile
    printf '\n# Hardware model: class=%s, effective_bandwidth=%sMbit (%s), buffer_floor=%s, buffer_cap=%s.\n' \
        "$HARDWARE_CLASS" "$EFFECTIVE_BANDWIDTH_MBIT" "$EFFECTIVE_BANDWIDTH_SOURCE" "$(human_bytes "$BUFFER_FLOOR")" "$(human_bytes "$BUFFER_CAP")"
    printf '# Buffer bounds: memory_cap=%s, platform_cap=%s.\n' "$(human_bytes "$BUFFER_MEMORY_CAP")" "$(human_bytes "$BUFFER_PLATFORM_CAP")"
    printf '# Scaling note: %s.\n' "$(hardware_scaling_note)"
    printf '# Deliberately untouched: tcp_mem, tcp_adv_win_scale, TIME_WAIT, VM, file limits, IRQ affinity, NIC offloads and RPS/RFS.\n'
}

normalize_sysctl_words() { awk '{$1=$1; print}'; }

verify_sysctl_profile_runtime() {
    local key expected actual rc=0
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(sysctl_model_interface)" || return 1
    while IFS=$'\t' read -r key expected; do
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_sysctl_words || true)
        expected=$(normalize_sysctl_words <<< "$expected")
        if [[ "$actual" != "$expected" ]]; then
            log ERR "sysctl 不一致: $key=${actual:-unavailable}（期望 $expected）"
            rc=1
        fi
    done < <(printf '%s\t%s\n' \
        net.core.default_qdisc fq \
        net.ipv4.tcp_congestion_control bbr \
        net.core.rmem_max "$BUFFER_MAX" \
        net.core.wmem_max "$BUFFER_MAX" \
        net.ipv4.tcp_rmem "4096 $BUFFER_R_DEFAULT $BUFFER_MAX" \
        net.ipv4.tcp_wmem "4096 $BUFFER_W_DEFAULT $BUFFER_MAX" \
        net.ipv4.tcp_mtu_probing 1 \
        net.ipv4.tcp_fastopen 3 \
        net.core.somaxconn "$SOMAXCONN" \
        net.ipv4.tcp_max_syn_backlog "$TCP_MAX_SYN_BACKLOG" \
        net.core.netdev_max_backlog "$NETDEV_BACKLOG")
    return "$rc"
}

verify_sysctl_profile_file() {
    local expected
    [[ -f "$SYSCTL_FILE" ]] || { log ERR "sysctl 持久化文件缺失: $SYSCTL_FILE"; return 1; }
    command_exists cmp || { die "缺少命令: cmp"; return 1; }
    expected=$(mktemp) || return 1
    if ! render_sysctl_profile > "$expected"; then rm -f -- "$expected"; return 1; fi
    if ! cmp -s "$expected" "$SYSCTL_FILE"; then
        rm -f -- "$expected"
        log ERR "sysctl 持久化文件与当前配置不一致: $SYSCTL_FILE"
        return 1
    fi
    rm -f -- "$expected"
}

write_sysctl_profile() {
    local temp
    temp=$(mktemp) || return 1
    render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
    atomic_install "$temp" "$SYSCTL_FILE" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

apply_sysctl_profile() {
    local mode="${1:-persistent}" temp=""
    [[ "$mode" == persistent || "$mode" == runtime ]] || { die "sysctl 应用模式只支持 persistent/runtime"; return 1; }
    require_commands sysctl modprobe || return 1
    ensure_bbr_available || return 1
    if [[ "$mode" == runtime ]]; then
        temp=$(mktemp) || return 1
        render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
        sysctl -q -p "$temp" || { rm -f -- "$temp"; die "sysctl 应用失败"; return 1; }
        rm -f -- "$temp"
    else
        write_sysctl_profile || return 1
        sysctl -q -p "$SYSCTL_FILE" || { die "sysctl 应用失败"; return 1; }
    fi
    verify_sysctl_profile_runtime || { die "受管 sysctl 运行时验证失败"; return 1; }
    if [[ "$mode" == runtime ]]; then
        log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效（临时）"
    else
        log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效"
    fi
}

apply_initial_windows() {
    (( INITCWND > 0 || INITRWND > 0 )) || return 0
    local family line token i changed=0
    local -a args=() clean=()
    for family in -4 -6; do
        line=$(ip "$family" route show default 2>/dev/null | head -n1 || true)
        [[ -n "$line" ]] || continue
        read -r -a args <<< "$line"
        clean=()
        for ((i=0; i<${#args[@]}; i++)); do
            token="${args[$i]}"
            if [[ "$token" == initcwnd || "$token" == initrwnd ]]; then ((i+=1)); continue; fi
            clean+=("$token")
        done
        (( INITCWND > 0 )) && clean+=(initcwnd "$INITCWND")
        (( INITRWND > 0 )) && clean+=(initrwnd "$INITRWND")
        if ip "$family" route change "${clean[@]}"; then ((changed+=1)); fi
    done
    (( changed > 0 )) || { die "没有可设置 initcwnd/initrwnd 的默认路由"; return 1; }
}

restore_default_route_windows_snapshot() {
    local directory="$1" family file baseline current token i rc=0
    local -a route=() clean=()
    for family in -4 -6; do
        file="$directory/default-route-v${family#-}.txt"
        [[ -s "$file" ]] || continue
        baseline=$(head -n1 "$file")
        current=$(ip "$family" route show default 2>/dev/null | head -n1 || true)
        [[ "$baseline$current" == *initcwnd* || "$baseline$current" == *initrwnd* ]] || continue
        [[ -n "$current" ]] || { rc=1; continue; }
        read -r -a route <<< "$current"; clean=()
        for ((i=0; i<${#route[@]}; i++)); do
            token="${route[$i]}"
            if [[ "$token" == initcwnd || "$token" == initrwnd ]]; then ((i+=1)); continue; fi
            clean+=("$token")
        done
        if [[ "$baseline" =~ (^|[[:space:]])initcwnd[[:space:]]+([0-9]+) ]]; then clean+=(initcwnd "${BASH_REMATCH[2]}"); fi
        if [[ "$baseline" =~ (^|[[:space:]])initrwnd[[:space:]]+([0-9]+) ]]; then clean+=(initrwnd "${BASH_REMATCH[2]}"); fi
        ip "$family" route replace "${clean[@]}" || rc=1
    done
    return "$rc"
}
