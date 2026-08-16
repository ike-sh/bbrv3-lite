# -----------------------------------------------------------------------------
# Traffic control: HTB aggregate shaper + FQ leaf, full verification and rollback.
# -----------------------------------------------------------------------------

TC_SESSION_HTB_IFACE=""
HTB_BURST_CAP=8388608

tc_dependencies() { require_commands ip tc awk; }
has_net_admin() { tc qdisc show >/dev/null 2>&1; }

root_qdisc_kind() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    awk '$1=="qdisc" && $0 ~ / root / {print $2; exit}' <<< "$text"
}

qdisc_replay_args_from_stream() {
    awk '
        $1=="qdisc" && $0~/ root / {
            seen=0; bands=3;
            for(i=1;i<=NF;i++) {
                if(seen) {
                    if($i=="refcnt") {i++; continue}
                    if($i=="bands") {bands=$(i+1); i++; continue}
                    if($i=="priomap") {i+=16; continue}
                    if($i=="weights") {i+=bands; continue}
                    token=$i; if(token ~ /^[0-9]+p$/) sub(/p$/, "", token)
                    printf "%s%s", (out?" ":""), token; out=1
                }
                if($i=="root") seen=1
            }
            print ""; exit
        }'
}

root_qdisc_replay_args() {
    tc qdisc show dev "$1" 2>/dev/null | qdisc_replay_args_from_stream
}

managed_htb() {
    local iface="$1" qdisc_text class_text
    qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    class_text=$(tc class show dev "$iface" 2>/dev/null) || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" &&
        grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" &&
        grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text"
}

managed_htb_root() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$text"
}

managed_fq_leaf() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$text"
}

managed_rate_mbit() {
    local iface="$1" text token
    text=$(tc class show dev "$iface" 2>/dev/null) || return 1
    token=$(awk '$1=="class" && $2=="htb" && $3=="1:10" {for(i=1;i<=NF;i++) if($i=="rate") {print $(i+1); exit}}' <<< "$text")
    awk -v r="$token" 'BEGIN {
        if (r ~ /Gbit$/) {sub(/Gbit$/, "", r); printf "%.0f\n", r*1000}
        else if (r ~ /Mbit$/) {sub(/Mbit$/, "", r); printf "%.0f\n", r}
        else if (r ~ /Kbit$/) {sub(/Kbit$/, "", r); printf "%.0f\n", r/1000}
    }'
}

session_owned_htb() {
    local iface="$1" rate
    [[ -n "$TC_SESSION_HTB_IFACE" && "$TC_SESSION_HTB_IFACE" == "$iface" ]] || return 1
    managed_htb_root "$iface" || return 1
    rate=$(managed_rate_mbit "$iface") || return 1
    is_uint "$rate" && (( rate > 0 ))
}

managed_htb_diagnostic() {
    local iface="$1" qdisc_text class_text root=no class=no leaf=no rate
    qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    class_text=$(tc class show dev "$iface" 2>/dev/null || true)
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" && root=yes
    grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" && class=yes
    grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text" && leaf=yes
    rate=$(managed_rate_mbit "$iface") || rate=""
    rate="${rate:--}"
    printf 'root-1=%s class-1:10=%s fq-10=%s rate=%sMbit' "$root" "$class" "$leaf" "$rate"
}

qdisc_guard() {
    local iface="$1" kind detail
    kind=$(root_qdisc_kind "$iface") || { die "无法读取 $iface 的 root qdisc"; return 1; }
    if managed_htb "$iface" || session_owned_htb "$iface"; then return 0; fi
    case "$kind" in
        ""|fq|fq_codel|noqueue|mq|pfifo_fast) return 0 ;;
        htb)
            detail=$(managed_htb_diagnostic "$iface")
            die "拒绝覆盖未管理的 root qdisc 'htb'（$iface；$detail）"
            return 1
            ;;
        *)
            die "拒绝覆盖未管理的 root qdisc '$kind'（$iface）；请先自行恢复或删除"
            return 1
            ;;
    esac
}

action_qdisc_snapshot() {
    local iface="$1" file="$2" kind rate="" replay_args_string=""
    kind=$(root_qdisc_kind "$iface") || return 1
    if managed_htb "$iface" || session_owned_htb "$iface"; then
        kind=managed-htb
        rate=$(managed_rate_mbit "$iface") || return 1
    fi
    [[ "$kind" == fq || "$kind" == fq_codel ]] && replay_args_string=$(root_qdisc_replay_args "$iface")
    printf 'KIND\t%s\nRATE\t%s\nARGS\t%s\n' "$kind" "$rate" "$replay_args_string" > "$file" || return 1
    tc qdisc show dev "$iface" >> "$file" 2>/dev/null || true
    tc class show dev "$iface" >> "$file" 2>/dev/null || true
}

snapshot_field() { awk -F'\t' -v key="$2" '$1==key {print $2; exit}' "$1"; }

restore_action_qdisc() {
    local iface="$1" file="$2" kind rate args_string
    local -a args=()
    [[ -f "$file" ]] || return 1
    kind=$(snapshot_field "$file" KIND)
    rate=$(snapshot_field "$file" RATE)
    args_string=$(snapshot_field "$file" ARGS)
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        managed-htb) _apply_shaping_raw "$iface" "$rate" ;;
        fq|fq_codel)
            if tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null 2>&1 || tc qdisc replace dev "$iface" root "$kind" >/dev/null; then
                if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            else return 1
            fi
            ;;
        ""|noqueue|mq|pfifo_fast)
            tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
            if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            ;;
        *) die "无法安全恢复 qdisc 类型: $kind" ;;
    esac
}

restore_qdisc_text_snapshot() {
    local iface="$1" file="$2" kind args_string
    local -a args=()
    kind=$(awk '$1=="qdisc" && $0~/ root / {print $2; exit}' "$file" 2>/dev/null)
    args_string=$(qdisc_replay_args_from_stream < "$file")
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        fq|fq_codel) tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null 2>&1 || tc qdisc replace dev "$iface" root "$kind" ;;
        ""|noqueue|mq|pfifo_fast) tc qdisc del dev "$iface" root 2>/dev/null || true ;;
        *) return 2 ;;
    esac
}

detect_kernel_hz() {
    local file value
    for file in "/boot/config-$(uname -r)" /proc/config; do
        [[ -r "$file" ]] || continue
        value=$(awk -F= '$1=="CONFIG_HZ" {print $2; exit}' "$file" 2>/dev/null || true)
        if is_uint "${value:-}" && (( value >= 100 && value <= 2000 )); then printf '%s\n' "$value"; return 0; fi
    done
    if [[ -r /proc/config.gz ]] && command_exists zcat; then
        value=$(zcat /proc/config.gz 2>/dev/null | awk -F= '$1=="CONFIG_HZ" {print $2; exit}' || true)
        if is_uint "${value:-}" && (( value >= 100 && value <= 2000 )); then printf '%s\n' "$value"; return 0; fi
    fi
    # Debian/Ubuntu generic cloud kernels commonly use 250 Hz. USER_HZ from
    # getconf CLK_TCK is deliberately not used because it is a different clock.
    printf '250\n'
}

calc_htb_burst() {
    local rate="$1" hz mtu="$2" bytes
    hz=$(detect_kernel_hz)
    bytes=$(( (rate * 1000000 + 8 * hz - 1) / (8 * hz) ))
    (( bytes < 32768 )) && bytes=32768
    (( bytes < mtu * 10 )) && bytes=$((mtu * 10))
    (( bytes > HTB_BURST_CAP )) && bytes=$HTB_BURST_CAP
    printf '%s\n' "$bytes"
}

calc_htb_quantum() {
    local mtu="$1" quantum
    quantum=$((mtu * 10))
    (( quantum > 60000 )) && quantum=60000
    printf '%s\n' "$quantum"
}

verify_shaping() {
    local iface="$1"
    managed_htb "$iface" || { die "HTB -> FQ 层级验证失败: $iface"; return 1; }
}

_apply_shaping_raw() {
    local iface="$1" rate="$2" mtu burst quantum cburst hierarchy_exists=0 kind
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    mtu=$(detect_mtu "$iface"); is_uint "$mtu" || mtu=1500
    burst=$(calc_htb_burst "$rate" "$mtu")
    quantum=$(calc_htb_quantum "$mtu")
    cburst=$((mtu * 2))
    if managed_htb "$iface" || session_owned_htb "$iface"; then
        hierarchy_exists=1
    else
        kind=$(root_qdisc_kind "$iface")
        [[ "$kind" != htb ]] || { die "拒绝修改来源不明的 HTB root（$iface）"; return 1; }
    fi
    if (( ! hierarchy_exists )); then
        tc qdisc replace dev "$iface" root handle 1: htb default 10 || return 1
    fi
    tc class replace dev "$iface" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$cburst" quantum "$quantum" || return 1
    if ! managed_fq_leaf "$iface"; then
        tc qdisc replace dev "$iface" parent 1:10 handle 10: fq || return 1
    fi
    verify_shaping "$iface" || return 1
    TC_SESSION_HTB_IFACE="$iface"
}

apply_shaping() {
    local iface="$1" rate="$2" snapshot
    tc_dependencies || return 1; qdisc_guard "$iface" || return 1
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || { rm -f -- "$snapshot"; return 1; }
    if ! _apply_shaping_raw "$iface" "$rate"; then
        log ERR "应用 ${rate} Mbit 整形失败，正在恢复操作前 qdisc"
        restore_action_qdisc "$iface" "$snapshot" || true
        rm -f -- "$snapshot"
        return 1
    fi
    rm -f -- "$snapshot"
}

apply_fq() {
    local iface="$1" snapshot
    tc_dependencies || return 1; qdisc_guard "$iface" || return 1
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || { rm -f -- "$snapshot"; return 1; }
    if ! tc qdisc replace dev "$iface" root fq || [[ "$(root_qdisc_kind "$iface")" != fq ]]; then
        restore_action_qdisc "$iface" "$snapshot" || true
        rm -f -- "$snapshot"
        die "root FQ 应用失败"
        return 1
    fi
    [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]] && TC_SESSION_HTB_IFACE=""
    rm -f -- "$snapshot"
}

tc_trial() {
    require_root || return 1; require_host_network_control || return 1; acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" iface
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    capture_baseline "$iface" || return 1
    apply_shaping "$iface" "$rate" || return 1
    log OK "临时整形已生效: $iface ${rate} Mbit（未写配置，重启后失效）"
}

tc_enable_steps() {
    local iface="$1" rate="$2" requested="$3" knee="$4" margin="$5"
    capture_baseline "$iface" || return 1
    load_config || return 1
    TC_ENABLED=1; TC_INTERFACE="$requested"; TC_RATE_MBIT="$rate"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT="$margin"
    apply_sysctl_profile || return 1
    apply_shaping "$iface" "$rate" || return 1
    save_config || { die "整形已在运行时生效，但配置保存失败"; return 1; }
    install_persistence || { die "整形已在运行时生效，但持久化安装失败"; return 1; }
    restart_and_verify_persistence || return 1
    log OK "整形已持久化: $iface ${rate} Mbit"
}

tc_enable() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" knee="${3:-0}" margin="${4:-3}" iface
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    is_uint "$knee" && (( knee <= 1000000 )) || { die "非法拐点速率: $knee"; return 1; }
    is_uint "$margin" && (( margin <= 25 )) || { die "非法退让比例: $margin"; return 1; }
    (( knee == 0 || knee >= rate )) || { die "拐点速率不能低于最终整形速率"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    run_action_transaction "$iface" tc_enable_steps "$iface" "$rate" "$requested" "$knee" "$margin"
}

tc_disable_steps() {
    local iface="$1"
    if managed_htb "$iface"; then apply_fq "$iface" || return 1
    elif [[ "$(root_qdisc_kind "$iface")" != fq ]]; then qdisc_guard "$iface" || return 1; apply_fq "$iface" || return 1; fi
    TC_ENABLED=0; TC_RATE_MBIT=0
    save_config || return 1
    install_persistence || return 1
    restart_and_verify_persistence || return 1
    log OK "HTB 整形已关闭，BBR + FQ 保持启用"
}

tc_disable() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; tc_dependencies || return 1
    local requested="${1:-auto}" iface
    load_config || return 1
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    run_action_transaction "$iface" tc_disable_steps "$iface"
}

tc_status() {
    local requested="${1:-auto}" iface
    load_config || return 1
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    printf 'Interface: %s\n' "$iface"
    printf 'Configured: enabled=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$TC_ENABLED" "$TC_RATE_MBIT" "$TC_KNEE_MBIT" "$TC_MARGIN_PERCENT"
    tc -s -d qdisc show dev "$iface"
    tc -s -d class show dev "$iface"
}
