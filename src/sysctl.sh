# -----------------------------------------------------------------------------
# Sysctl: auditable balanced/adaptive profiles, BBR verification and route IW.
# -----------------------------------------------------------------------------

ensure_bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<< "$available"; then
        die "当前内核不提供 BBR；不会静默回退到 cubic"
        return 1
    fi
}

buffer_profile_values() {
    local profile="$1" role="$2" bandwidth="$3" rtt="$4"
    local ram bdp max cap floor=4194304 absolute_cap=268435456 default_r=131072 default_w=65536
    ram=$(memory_mb)
    if [[ "$profile" == balanced ]]; then
        BUFFER_MAX=16777216
        BUFFER_R_DEFAULT=$default_r
        BUFFER_W_DEFAULT=$default_w
        BUFFER_REASON="balanced fixed 16 MiB ceiling"
        return 0
    fi
    (( bandwidth > 0 && rtt > 0 )) || { die "adaptive profile 需要 --bandwidth 和 --rtt"; return 1; }
    # bytes = Mbps * ms * 125; keep two BDPs, bounded by RAM/32 and 256 MiB.
    bdp=$(( bandwidth * rtt * 125 ))
    max=$(( bdp * 2 ))
    cap=$(( ram * 1024 * 1024 / 32 ))
    (( cap > absolute_cap )) && cap=$absolute_cap
    (( cap < floor )) && cap=$floor
    (( max < floor )) && max=$floor
    (( max > cap )) && max=$cap
    case "$role" in
        proxy) default_r=131072; default_w=65536 ;;
        mixed) default_r=262144; default_w=131072 ;;
        bulk)  default_r=1048576; default_w=1048576 ;;
    esac
    (( default_r > max )) && default_r=$max
    (( default_w > max )) && default_w=$max
    BUFFER_MAX=$max
    BUFFER_R_DEFAULT=$default_r
    BUFFER_W_DEFAULT=$default_w
    BUFFER_REASON="2xBDP bounded by RAM/32 and 256 MiB"
}

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" || return 1
    cat <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# profile=${SYSCTL_PROFILE} role=${ROLE} bandwidth=${BANDWIDTH_MBIT}Mbps rtt=${RTT_MS}ms
# buffer_max=${BUFFER_MAX} (${BUFFER_REASON})
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUFFER_MAX}
net.core.wmem_max = ${BUFFER_MAX}
net.ipv4.tcp_rmem = 4096 ${BUFFER_R_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 ${BUFFER_W_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
EOF
}

explain_sysctl_profile() {
    render_sysctl_profile
    printf '\n# Deliberately untouched: tcp_mem, tcp_adv_win_scale, TIME_WAIT, VM, file limits, RPS/RFS.\n'
}

write_sysctl_profile() {
    local temp
    temp=$(mktemp) || return 1
    render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
    atomic_install "$temp" "$SYSCTL_FILE" 0644
    rm -f -- "$temp"
}

apply_sysctl_profile() {
    require_commands sysctl modprobe
    ensure_bbr_available || return 1
    write_sysctl_profile || return 1
    sysctl -q -p "$SYSCTL_FILE" || { die "sysctl 应用失败"; return 1; }
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] || { die "BBR 验证失败"; return 1; }
    [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == fq ]] || { die "default_qdisc 验证失败"; return 1; }
    log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效"
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
