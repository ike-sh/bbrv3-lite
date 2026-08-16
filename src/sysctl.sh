# -----------------------------------------------------------------------------
# Sysctl: auditable balanced/adaptive profiles, BBR verification and route IW.
# -----------------------------------------------------------------------------

BALANCED_BUFFER_MAX=16777216
ADAPTIVE_BUFFER_FLOOR=16777216
BUFFER_ABSOLUTE_CAP=268435456

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
    local ram bdp max cap floor="$ADAPTIVE_BUFFER_FLOOR" absolute_cap="$BUFFER_ABSOLUTE_CAP" default_r=131072 default_w=65536
    ram=$(memory_mb)
    if [[ "$profile" == balanced ]]; then
        BUFFER_MAX="$BALANCED_BUFFER_MAX"
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
    BUFFER_REASON="2xBDP with 16 MiB floor, bounded by RAM/32 and 256 MiB"
}

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" || return 1
    cat <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# profile=${SYSCTL_PROFILE} role=${ROLE} bandwidth=${BANDWIDTH_MBIT}Mbps tuning_rtt=${RTT_MS}ms
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

normalize_sysctl_words() { awk '{$1=$1; print}'; }

verify_sysctl_profile_runtime() {
    local key expected actual rc=0
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" || return 1
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
        net.core.somaxconn 4096 \
        net.core.netdev_max_backlog 4096)
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
