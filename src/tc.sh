# -----------------------------------------------------------------------------
# Traffic control: HTB aggregate shaper + FQ leaf, full verification and rollback.
# -----------------------------------------------------------------------------

TC_SESSION_HTB_IFACE=""
TC_TRIAL_IFACE=""
TC_TRIAL_SNAPSHOT=""
# Enough for 1 Tbit/s even at CONFIG_HZ=100. The actual value remains rate/HZ,
# so ordinary VPS rates do not inherit a large bucket merely because the cap
# supports modern 25/100/400G NICs.
HTB_BURST_CAP=2147483647

tc_dependencies() { require_commands ip tc awk; }

qdisc_module_hint() {
    local kind="$1" module="sch_$1"
    command_exists modprobe || return 0
    modprobe -q "$module" 2>/dev/null || true
    # A qdisc can be built into the kernel and therefore have no module entry.
    # The real replace operation below remains the authoritative capability
    # check and is always followed by structural verification.
    return 0
}

network_tuning_preflight() {
    local iface="$1" need_shaping="${2:-0}" key
    tc_dependencies || return 1
    [[ -e "${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}/$iface" ]] || { die "网卡不存在: $iface"; return 1; }
    tc qdisc show dev "$iface" >/dev/null 2>&1 || { die "无法读取 $iface 的 qdisc；缺少 NET_ADMIN 或驱动不支持"; return 1; }
    for key in default_qdisc rmem_max wmem_max somaxconn netdev_max_backlog; do
        [[ -e "/proc/sys/net/core/$key" ]] || { die "内核缺少受管 sysctl: net.core.$key"; return 1; }
    done
    [[ -e /proc/sys/net/ipv4/tcp_congestion_control ]] || { die "内核缺少 TCP 拥塞控制 sysctl"; return 1; }
    [[ -e /proc/sys/net/ipv4/tcp_max_syn_backlog ]] || { die "内核缺少 TCP SYN backlog sysctl"; return 1; }
    qdisc_module_hint fq
    (( need_shaping == 0 )) || qdisc_module_hint htb
    hardware_profile_values "$iface" "${BANDWIDTH_MBIT:-0}" || return 1
    log INFO "硬件预检: ${HARDWARE_CLASS}, ${HARDWARE_CPU_COUNT} CPU, ${HARDWARE_MEMORY_MB} MiB RAM, ${HARDWARE_RX_QUEUES}/${HARDWARE_TX_QUEUES} RX/TX queues, link ${HARDWARE_LINK_MBIT} Mbit"
    log INFO "硬件建议: $(hardware_scaling_note)"
}

root_qdisc_kind() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    awk '$1=="qdisc" && $0 ~ / root([[:space:]]|$)/ {print $2; exit}' <<< "$text"
}

qdisc_replay_args_from_stream() {
    awk '
        $1=="qdisc" && $0~/ root([[:space:]]|$)/ {
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

mq_child_replay_rows_from_stream() {
    awk '
        $1=="qdisc" && $0!~/ root([[:space:]]|$)/ {
            parent=""; start=0; bands=3
            for(i=1;i<=NF;i++) if($i=="parent" && $(i+1) ~ /^:[[:xdigit:]]+$/) {
                parent=$(i+1); start=i+2; break
            }
            if(parent=="") next
            kind=$2; out=""
            for(i=start;i<=NF;i++) {
                if($i=="refcnt") {i++; continue}
                if($i=="bands") {bands=$(i+1); i++; continue}
                if($i=="priomap") {i+=16; continue}
                if($i=="weights") {i+=bands; continue}
                token=$i; if(token ~ /^[0-9]+p$/) sub(/p$/, "", token)
                out=out (out?" ":"") token
            }
            printf "%s\t%s\t%s\n", parent, kind, out
        }'
}

mq_unsupported_child_qdiscs() {
    local iface="$1"
    tc qdisc show dev "$iface" 2>/dev/null | mq_child_replay_rows_from_stream |
        awk -F'\t' '$2!="fq" && $2!="fq_codel" && $2!="pfifo_fast" && $2!="pfifo" && $2!="bfifo" && $2!="noqueue" {print $2 "@" $1}'
}

restore_mq_qdisc_snapshot() {
    local iface="$1" file="$2" parent kind args_string
    local -a args=()
    tc qdisc replace dev "$iface" root mq >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r parent kind args_string; do
        [[ -n "$parent" && -n "$kind" ]] || continue
        case "$kind" in
            fq|fq_codel|pfifo_fast|pfifo|bfifo)
                args=(); [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
                tc qdisc replace dev "$iface" parent "$parent" "$kind" "${args[@]}" >/dev/null 2>&1 || return 1
                ;;
            noqueue) ;;
            *) return 2 ;;
        esac
    done < <(mq_child_replay_rows_from_stream < "$file")
}

managed_htb() {
    local iface="$1" qdisc_text class_text
    qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    class_text=$(tc class show dev "$iface" 2>/dev/null) || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" &&
        grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" &&
        grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text"
}

managed_htb_interfaces() {
    local net_root="${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}" path iface
    [[ -d "$net_root" ]] || return 0
    for path in "$net_root"/*; do
        [[ -e "$path" ]] || continue
        iface="${path##*/}"
        validate_interface_name "$iface" || continue
        managed_htb "$iface" && printf '%s\n' "$iface"
    done
    return 0
}

# Mutation gates must distinguish "not managed" from "could not be
# inspected". Read every visible interface once and reject the whole operation
# if any qdisc/class query is unavailable.
managed_htb_interfaces_strict() {
    local net_root="${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}" path iface qdisc_text class_text
    [[ -d "$net_root" && ! -L "$net_root" ]] || { die "无法枚举宿主机网卡: $net_root"; return 1; }
    for path in "$net_root"/*; do
        [[ -e "$path" || -L "$path" ]] || continue
        iface="${path##*/}"
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || {
            die "网卡目录包含非法名称，不能完成全接口 qdisc 审计: $iface"
            return 1
        }
        qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null) || {
            die "无法读取 $iface 的 qdisc；不能证明不存在遗留 HTB"
            return 1
        }
        class_text=$(tc class show dev "$iface" 2>/dev/null) || {
            die "无法读取 $iface 的 class；不能证明不存在遗留 HTB"
            return 1
        }
        if grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" &&
           grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" &&
           grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text"; then
            printf '%s\n' "$iface"
        fi
    done
}

shaping_interface_list_text() {
    local interfaces="$1"
    [[ -n "$interfaces" ]] && tr '\n' ' ' <<< "$interfaces" | sed -E 's/[[:space:]]+$//' || printf 'none\n'
}

load_config_for_shaping_preflight() {
    local file="${1:-$CONFIG_FILE}" line key value lineno=0
    local -A seen=()
    # Current configurations use the full strict parser. A legacy configuration
    # still has to be inspected before capture_baseline/migrate_legacy_config,
    # but this preflight must remain read-only. Parse only the three shaping
    # fields needed to prevent a cross-NIC migration; never rewrite the file here.
    if load_config "$file" 2>/dev/null; then return 0; fi
    [[ -f "$file" ]] || return 0
    if grep -Fxq 'SCHEMA_VERSION=1' "$file" && ! grep -Fxq 'SYSCTL_PROFILE=balanced-minimal' "$file"; then
        die "当前 schema 配置未通过严格校验，拒绝把损坏配置当作旧版迁移: $file"
        return 1
    fi
    check_config_permissions "$file" || return 1
    reset_config
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno+=1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]]; then
            die "旧配置含非法格式，无法执行只读整形预检: ${file}:${lineno}"
            return 1
        fi
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]+x}" ]] || { die "旧配置字段重复，无法安全预检: ${file}:${lineno}: $key"; return 1; }
        seen[$key]=1
        case "$key" in
            TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT)
                validate_config_value "$key" "$value" || {
                    die "旧配置含非法整形字段: ${file}:${lineno}: $key"
                    return 1
                }
                printf -v "$key" '%s' "$value"
                ;;
            # These are known current/legacy data fields. They are deliberately
            # ignored here and will be handled by migrate_legacy_config inside
            # the surrounding action transaction.
            SCHEMA_VERSION|BBR_ENABLED|SYSCTL_PROFILE|ROLE|BANDWIDTH_MBIT|RTT_MS|TC_KNEE_MBIT|TC_MARGIN_PERCENT|INITCWND|INITRWND|MULTI_NIC_ENABLED|TC_BASELINE_MBIT|TC_PERCENT) ;;
            *)
                die "旧配置含未知字段，拒绝在迁移前猜测整形归属: ${file}:${lineno}: $key"
                return 1
                ;;
        esac
    done < "$file"
}

# The configuration schema owns one shaping interface. Refuse an implicit
# migration while another managed HTB remains active: otherwise a default-route
# change can leave an orphan shaper on the old NIC and commit a second one on the
# new NIC. Disabling is deliberately explicit so recovery remains deterministic.
shaping_target_preflight() {
    local target="$1" action="$2" requested="${3:-$1}" interfaces other configured
    validate_interface_name "$target" || { die "整形目标网卡非法: $target"; return 1; }
    [[ "$action" == enable || "$action" == trial || "$action" == install || "$action" == auto || "$action" == disable ]] || {
        die "未知整形操作: $action"
        return 1
    }
    load_config_for_shaping_preflight || return 1
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then
        declare -F nic_policy_ownership_preflight >/dev/null || { die "多网卡策略模块未加载"; return 1; }
        nic_policy_ownership_preflight "$target" || return 1
        if [[ "$action" == disable ]] && ! nic_policy_exists "$target"; then
            die "网卡没有受管策略: $target"
            return 1
        fi
        return 0
    fi
    configured="$TC_INTERFACE"
    interfaces=$(managed_htb_interfaces_strict) || return 1

    if [[ "$action" == disable ]]; then
        if (( TC_ENABLED == 1 )) && [[ "$configured" == auto && "$requested" == auto ]]; then
            die "检测到旧版 TC_INTERFACE=auto；不能猜测应关闭哪张网卡。受管 HTB: $(shaping_interface_list_text "$interfaces")。请显式执行 ${0##*/} tc disable --interface DEV"
            return 1
        fi
        if (( TC_ENABLED == 1 )) && [[ "$configured" != auto && "$target" != "$configured" ]]; then
            die "配置中的整形绑定 $configured，拒绝改为关闭 $target；请先对 $configured 执行 tc disable"
            return 1
        fi
        if (( TC_ENABLED == 1 )) && [[ "$configured" == auto ]] && ! grep -Fqx -- "$target" <<< "$interfaces"; then
            die "旧版 auto 配置无法证明 $target 是原受管接口；当前受管 HTB: $(shaping_interface_list_text "$interfaces")"
            return 1
        fi
        if [[ -n "$interfaces" ]] && ! grep -Fqx -- "$target" <<< "$interfaces"; then
            die "发现的受管 HTB 位于 $(shaping_interface_list_text "$interfaces")，拒绝把关闭操作应用到 $target"
            return 1
        fi
        return 0
    fi

    while IFS= read -r other; do
        [[ -n "$other" ]] || continue
        if [[ "$other" != "$target" ]]; then
            die "检测到另一张网卡 $other 上仍有受管 HTB；当前版本只允许一个持久化整形接口。请先执行 ${0##*/} tc disable --interface $other"
            return 1
        fi
    done <<< "$interfaces"

    if (( TC_ENABLED == 1 )); then
        if [[ "$configured" == auto ]]; then
            die "检测到旧版 TC_INTERFACE=auto，拒绝把旧速率隐式迁移到 $target。受管 HTB: $(shaping_interface_list_text "$interfaces")；请先显式关闭旧接口整形"
            return 1
        fi
        if [[ "$configured" != "$target" ]]; then
            die "现有整形绑定 $configured，当前目标为 $target；请先执行 ${0##*/} tc disable --interface $configured"
            return 1
        fi
    fi
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
        if (r ~ /Tbit$/) {sub(/Tbit$/, "", r); printf "%.0f\n", r*1000000}
        else if (r ~ /Gbit$/) {sub(/Gbit$/, "", r); printf "%.0f\n", r*1000}
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
    local iface="$1" kind detail unsupported
    kind=$(root_qdisc_kind "$iface") || { die "无法读取 $iface 的 root qdisc"; return 1; }
    if managed_htb "$iface" || session_owned_htb "$iface"; then return 0; fi
    case "$kind" in
        ""|fq|fq_codel|noqueue|pfifo_fast) return 0 ;;
        mq)
            unsupported=$(mq_unsupported_child_qdiscs "$iface")
            if [[ -n "$unsupported" ]]; then
                die "拒绝覆盖含不可安全重放子队列的 mq（$iface；$unsupported）"
                return 1
            fi
            return 0
            ;;
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
        kind="managed-htb"
        rate=$(managed_rate_mbit "$iface") || return 1
    fi
    [[ "$kind" == fq || "$kind" == fq_codel ]] && replay_args_string=$(root_qdisc_replay_args "$iface")
    printf 'KIND\t%s\nRATE\t%s\nARGS\t%s\n' "$kind" "$rate" "$replay_args_string" > "$file" || return 1
    tc qdisc show dev "$iface" >> "$file" 2>/dev/null || true
    tc class show dev "$iface" >> "$file" 2>/dev/null || true
}

snapshot_field() { awk -F'\t' -v key="$2" '$1==key {print $2; exit}' "$1"; }

action_qdisc_snapshot_validate() {
    local file="$1" kind rate args extra
    local -a snapshot_header=()
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mapfile -t snapshot_header < <(head -n 3 "$file") || return 1
    (( ${#snapshot_header[@]} == 3 )) || return 1
    [[ "${snapshot_header[0]}" == KIND$'\t'* && "${snapshot_header[0]#*$'\t'}" != *$'\t'* ]] || return 1
    [[ "${snapshot_header[1]}" == RATE$'\t'* && "${snapshot_header[1]#*$'\t'}" != *$'\t'* ]] || return 1
    [[ "${snapshot_header[2]}" == ARGS$'\t'* && "${snapshot_header[2]#*$'\t'}" != *$'\t'* ]] || return 1
    kind="${snapshot_header[0]#*$'\t'}"; rate="${snapshot_header[1]#*$'\t'}"; args="${snapshot_header[2]#*$'\t'}"
    case "$kind" in
        managed-htb)
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) && [[ -z "$args" ]] || return 1
            ;;
        fq|fq_codel) [[ -z "$rate" ]] || return 1 ;;
        ""|mq|noqueue|pfifo_fast) [[ -z "$rate" && -z "$args" ]] || return 1 ;;
        *) return 1 ;;
    esac
    extra=$(awk -F'\t' '$1=="KIND" || $1=="RATE" || $1=="ARGS" {count++} END {print count+0}' "$file") || return 1
    (( extra == 3 ))
}

restore_action_qdisc() {
    local iface="$1" file="$2" kind rate args_string
    local -a args=()
    action_qdisc_snapshot_validate "$file" || { die "qdisc 操作快照格式非法: $file"; return 1; }
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
        mq)
            restore_mq_qdisc_snapshot "$iface" "$file" || return 1
            if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            ;;
        ""|noqueue|pfifo_fast)
            tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
            if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            ;;
        *) die "无法安全恢复 qdisc 类型: $kind" ;;
    esac
}

restore_qdisc_text_snapshot() {
    local iface="$1" file="$2" kind args_string
    local -a args=()
    kind=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {print $2; exit}' "$file" 2>/dev/null)
    args_string=$(qdisc_replay_args_from_stream < "$file")
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        fq|fq_codel) tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null 2>&1 || tc qdisc replace dev "$iface" root "$kind" ;;
        mq) restore_mq_qdisc_snapshot "$iface" "$file" ;;
        ""|noqueue|pfifo_fast) tc qdisc del dev "$iface" root 2>/dev/null || true ;;
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
    qdisc_module_hint htb; qdisc_module_hint fq
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
    tc_dependencies || return 1; qdisc_guard "$iface" || return 1; qdisc_module_hint fq
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

tc_trial_transaction_begin() {
    local iface="$1" snapshot
    [[ -z "$TC_TRIAL_IFACE" && -z "$TC_TRIAL_SNAPSHOT" ]] || {
        die "已有未提交的临时 TC 操作"
        return 1
    }
    snapshot=$(mktemp) || return 1
    if ! action_qdisc_snapshot "$iface" "$snapshot"; then
        rm -f -- "$snapshot"
        return 1
    fi
    chmod 0600 "$snapshot" 2>/dev/null || true
    TC_TRIAL_IFACE="$iface"
    TC_TRIAL_SNAPSHOT="$snapshot"
}

tc_trial_transaction_commit() {
    local snapshot="$TC_TRIAL_SNAPSHOT"
    TC_TRIAL_IFACE=""
    TC_TRIAL_SNAPSHOT=""
    [[ -z "$snapshot" ]] || rm -f -- "$snapshot"
}

tc_trial_transaction_rollback() {
    local iface="$TC_TRIAL_IFACE" snapshot="$TC_TRIAL_SNAPSHOT" rc=0
    [[ -n "$iface" && -n "$snapshot" && -f "$snapshot" ]] || {
        TC_TRIAL_IFACE=""; TC_TRIAL_SNAPSHOT=""
        return 0
    }
    restore_action_qdisc "$iface" "$snapshot" || rc=1
    if (( rc == 0 )); then
        rm -f -- "$snapshot"
        TC_TRIAL_IFACE=""
        TC_TRIAL_SNAPSHOT=""
    else
        log ERR "临时 TC 回滚失败；qdisc 快照保留在 $snapshot"
    fi
    return "$rc"
}

tc_trial() {
    require_root || return 1; require_host_network_control || return 1; acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" iface rc=0 rollback_rc=0
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    [[ "$requested" != auto ]] || auto_tune_route_guard "$iface" "" || return 1
    shaping_target_preflight "$iface" trial "$requested" || return 1
    BANDWIDTH_MBIT="$rate"; network_tuning_preflight "$iface" 1 || return 1
    capture_baseline "$iface" || return 1
    tc_trial_transaction_begin "$iface" || return 1
    if apply_shaping "$iface" "$rate"; then
        tc_trial_transaction_commit || return 1
    else
        rc=$?
        tc_trial_transaction_rollback || rollback_rc=$?
        (( rollback_rc == 0 )) || return "$rollback_rc"
        return "$rc"
    fi
    log OK "临时整形已生效: $iface ${rate} Mbit（未写配置，重启后失效）"
}

tc_enable() {
    local rate="$1" requested="${2:-auto}" knee="${3:-0}" margin="${4:-3}" iface profile role bandwidth rtt
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    is_uint "$knee" && (( knee <= 1000000 )) || { die "非法拐点速率: $knee"; return 1; }
    is_uint "$margin" && (( margin <= 25 )) || { die "非法退让比例: $margin"; return 1; }
    (( knee == 0 || knee >= rate )) || { die "拐点速率不能低于最终整形速率"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    [[ "$requested" != auto ]] || auto_tune_route_guard "$iface" "" || return 1
    load_config || return 1
    profile="$SYSCTL_PROFILE"; role="$ROLE"; bandwidth="$BANDWIDTH_MBIT"; rtt="$RTT_MS"
    if (( MULTI_NIC_ENABLED == 1 )); then
        # The global model may belong to a completely different, higher-BDP
        # interface.  A qdisc-only compatibility command must never copy that
        # aggregate metadata into a newly managed NIC.
        profile=balanced; role=mixed; bandwidth=0; rtt=0
        if nic_policy_exists "$iface"; then
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            profile="$NIC_POLICY_PROFILE"; role="$NIC_POLICY_ROLE"; bandwidth="$NIC_POLICY_BANDWIDTH_MBIT"; rtt="$NIC_POLICY_RTT_MS"
        fi
    fi
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; fi
    nic_manage "$iface" shape "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
}

tc_disable() {
    local requested="${1:-auto}" iface interfaces count profile role bandwidth rtt margin=3
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )) && [[ "$requested" == auto ]]; then
        interfaces=""
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            [[ "$NIC_POLICY_MODE" == shape ]] && interfaces+="${interfaces:+$'\n'}$iface"
        done < <(nic_policy_interface_list)
        count=$(grep -c . <<< "$interfaces" || true)
        (( count == 1 )) || { die "多网卡模式下 tc disable 必须显式指定 --interface（当前整形接口: $(shaping_interface_list_text "$interfaces")）"; return 1; }
        requested="$interfaces"
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto && "$requested" == auto ]]; then
        interfaces=$(managed_htb_interfaces)
        count=$(grep -c . <<< "$interfaces" || true)
        die "检测到旧版 TC_INTERFACE=auto；拒绝根据当前默认路由猜测旧整形接口。发现 ${count} 个受管 HTB: $(shaping_interface_list_text "$interfaces")。请显式指定 --interface DEV"
        return 1
    fi
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    profile="$SYSCTL_PROFILE"; role="$ROLE"; bandwidth="$BANDWIDTH_MBIT"; rtt="$RTT_MS"
    if (( MULTI_NIC_ENABLED == 1 )); then
        nic_policy_exists "$iface" || { die "网卡没有受管策略: $iface"; return 1; }
        nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
        profile="$NIC_POLICY_PROFILE"; role="$NIC_POLICY_ROLE"; bandwidth="$NIC_POLICY_BANDWIDTH_MBIT"; rtt="$NIC_POLICY_RTT_MS"; margin="$NIC_POLICY_MARGIN_PERCENT"
    fi
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; fi
    nic_manage "$iface" fq 0 0 "$margin" "$profile" "$role" "$bandwidth" "$rtt"
}

tc_status() {
    local requested="${1:-auto}" iface interfaces count
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )) && [[ "$requested" == auto ]]; then
        nic_inventory
        return
    fi
    if (( MULTI_NIC_ENABLED == 1 )); then
        iface=$(detect_interface "$requested") || return 1
        printf 'Interface: %s\n' "$iface"
        if nic_policy_exists "$iface"; then
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            printf 'Configured: mode=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$NIC_POLICY_MODE" "$NIC_POLICY_RATE_MBIT" "$NIC_POLICY_KNEE_MBIT" "$NIC_POLICY_MARGIN_PERCENT"
        else printf 'Configured: unmanaged\n'; fi
        tc -s -d qdisc show dev "$iface"
        tc -s -d class show dev "$iface"
        return
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto && "$requested" == auto ]]; then
        interfaces=$(managed_htb_interfaces)
        count=$(grep -c . <<< "$interfaces" || true)
        if (( count == 1 )); then
            requested="$interfaces"
            log WARN "旧版 auto 配置未固化接口；只读状态暂按唯一受管 HTB $requested 展示"
        elif (( count > 1 )); then
            die "旧版 auto 配置对应多个受管 HTB ($(shaping_interface_list_text "$interfaces"))；请显式指定 --interface"
            return 1
        fi
    fi
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    printf 'Interface: %s\n' "$iface"
    printf 'Configured: enabled=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$TC_ENABLED" "$TC_RATE_MBIT" "$TC_KNEE_MBIT" "$TC_MARGIN_PERCENT"
    tc -s -d qdisc show dev "$iface"
    tc -s -d class show dev "$iface"
}
