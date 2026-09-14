# -----------------------------------------------------------------------------
# Platform detection: OS, interface, machine facts and dependency installation.
# -----------------------------------------------------------------------------

os_id() { awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null; }
os_codename() {
    awk -F= '$1=="VERSION_CODENAME" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
}

virtualization_type() {
    if command_exists systemd-detect-virt; then systemd-detect-virt 2>/dev/null || printf 'none\n';
    elif [[ -f /.dockerenv ]]; then printf 'docker\n';
    else printf 'unknown\n'; fi
}

is_container() {
    if command_exists systemd-detect-virt && systemd-detect-virt --quiet --container 2>/dev/null; then return 0; fi
    case "$(virtualization_type)" in docker|lxc|openvz|podman|container-other|systemd-nspawn|wsl) return 0 ;; *) return 1 ;; esac
}

require_host_network_control() {
    if is_container; then
        die "容器环境不能安全修改宿主机内核、sysctl 或 qdisc；请在 VPS 宿主系统执行"
        return 1
    fi
    return 0
}

require_systemd_runtime() {
    require_commands systemctl || return 1
    [[ -d /run/systemd/system ]] || { die "当前系统没有运行 systemd，不能安装持久化服务"; return 1; }
    systemctl show-environment >/dev/null 2>&1 || { die "无法连接 systemd，不能安全提交持久化配置"; return 1; }
}

route_output_interfaces() {
    # "dev" is not at a fixed column (for example, "default dev ppp0"), and
    # multipath output can contain more than one dev token on the same line.
    awk '{for (i=1; i<NF; i++) if ($i=="dev") print $(i+1)}' | awk '!seen[$0]++'
}

default_route_output() {
    local family="$1"
    [[ "$family" == -4 || "$family" == -6 ]] || return 1
    ip "$family" route show default 2>/dev/null || true
}

default_route_interface_for_family() {
    local family="$1" output route
    output=$(default_route_output "$family") || return 1
    route=$(awk '$1=="default" {print; exit}' <<< "$output")
    [[ -n "$route" ]] || return 0
    route_unique_path_iface "$route" "IPv${family#-} 默认路由" "${family#-}"
}

default_route_interface() {
    local iface
    iface=$(default_route_interface_for_family -4)
    [[ -n "$iface" ]] || iface=$(default_route_interface_for_family -6)
    printf '%s\n' "$iface"
}

default_route_count() {
    local family="$1" output
    output=$(default_route_output "$family") || return 1
    awk '$1=="default" {count++} END {print count+0}' <<< "$output"
}

route_output_has_multipath() {
    local output="$1"
    [[ "$output" =~ (^|[[:space:]])nexthop([[:space:]]|$) ]] && return 0
    awk '
        {
            devs=0
            for (i=1; i<NF; i++) if ($i=="dev") devs++
            if (devs>1) found=1
        }
        END {exit !found}
    ' <<< "$output"
}

route_output_token_values() {
    local token="$1"
    awk -v token="$token" '{for (i=1; i<NF; i++) if ($i==token) print $(i+1)}'
}

route_output_token_count() {
    local output="$1" token="$2"
    awk -v token="$token" '{for (i=1; i<=NF; i++) if ($i==token) count++} END {print count+0}' <<< "$output"
}

route_output_nhids() {
    route_output_token_values nhid | awk '/^[0-9]+$/ && $0 != "0" && !seen[$0]++'
}

route_output_via_records() {
    awk '
        function family_of(value) {return index(value, ":") ? 6 : 4}
        {
            for (i=1; i<NF; i++) {
                if ($i != "via") continue
                family=""; value=$(i+1)
                if (value=="inet" || value=="inet6") {
                    family=(value=="inet" ? 4 : 6)
                    if (i+2>NF) continue
                    value=$(i+2)
                } else {
                    family=family_of(value)
                }
                print family "\t" value
            }
        }
    ' | awk -F'\t' '!seen[$0]++'
}

nexthop_object_output() {
    local id="$1" family="${2:-}" output
    # iproute2 6.15 can return "Unknown attribute type" for RTM_GETNEXTHOP
    # against kernels that still provide a usable RTM_GETNEXTHOP dump.  Prefer
    # the exact lookup, then conservatively select the exact ID from a dump;
    # the caller still requires exactly one structurally valid record.
    output=$(ip nexthop get id "$id" 2>/dev/null) || output=""
    if [[ -z "$output" && ( "$family" == 4 || "$family" == 6 ) ]]; then
        output=$(ip "-$family" nexthop get id "$id" 2>/dev/null) || output=""
    fi
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
        return 0
    fi
    ip nexthop show 2>/dev/null | awk -v id="$id" '$1=="id" && ($2 "")== (id "") {print}'
}

# Resolve a route-referenced nexthop object into one ordinary leaf.  Groups are
# deliberately rejected as a class: even members on the same interface can
# represent different gateways/hash paths, and accepting a singleton-looking
# group would require proving concurrent group membership did not change.
# Output: interface, gateway-or-none, gateway-family-or-none, nhid.
nexthop_object_leaf_record() {
    local id="$1" context="$2" expected_family="${3:-}" output line_count object_id
    local interfaces iface interface_count gateways gateway_count gateway_family gateway
    is_uint "$id" && (( id > 0 && id <= 4294967295 )) || {
        die "$context 引用了非法 nexthop object ID: ${id:-missing}"
        return 1
    }
    if ! output=$(nexthop_object_output "$id" "$expected_family") || [[ -z "$output" ]]; then
        die "$context 引用 nhid $id，但无法解析该 nexthop object；为避免错误选择出口，已停止"
        return 1
    fi
    line_count=$(awk 'NF {count++} END {print count+0}' <<< "$output")
    if ! is_uint "$line_count" || (( line_count != 1 )); then
        die "$context 引用 nhid $id，但查询返回了异常的 nexthop object 记录数；已停止"
        return 1
    fi
    object_id=$(awk '$1=="id" {print $2; exit}' <<< "$output")
    if [[ "$object_id" != "$id" ]] || (( $(route_output_token_count "$output" id) != 1 )); then
        die "$context 引用 nhid $id，但 nexthop object 身份不一致或结构异常；已停止"
        return 1
    fi
    if [[ "$output" =~ (^|[[:space:]])group([[:space:]]|$) ]]; then
        die "$context 引用的 nhid $id 是 nexthop group；无法证明唯一 leaf 路径，已停止"
        return 1
    fi
    if [[ "$output" =~ (^|[[:space:]])blackhole([[:space:]]|$) ]]; then
        die "$context 引用的 nhid $id 是 blackhole；拒绝将其作为网络出口"
        return 1
    fi
    if [[ "$output" =~ (^|[[:space:]])(unresolved|dead|linkdown|trap)([[:space:]]|$) ]] ||
       [[ "$output" =~ (^|[[:space:]])encap([[:space:]]|$) ]]; then
        die "$context 引用的 nhid $id 带有无法安全自动处理的状态或封装；已停止"
        return 1
    fi
    interfaces=$(route_output_interfaces <<< "$output")
    interface_count=$(awk 'NF {count++} END {print count+0}' <<< "$interfaces")
    if ! is_uint "$interface_count" || (( interface_count != 1 )); then
        die "$context 引用的 nhid $id 无法解析为唯一出口网卡"
        return 1
    fi
    iface=$(sed -n '1p' <<< "$interfaces")
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || {
        die "$context 引用的 nhid $id 返回非法出口网卡: ${iface:-missing}"
        return 1
    }
    gateways=$(route_output_via_records <<< "$output")
    gateway_count=$(awk 'NF {count++} END {print count+0}' <<< "$gateways")
    if ! is_uint "$gateway_count" || (( gateway_count > 1 )); then
        die "$context 引用的 nhid $id 返回多个或异常 gateway；已停止"
        return 1
    fi
    gateway=none; gateway_family=none
    if (( gateway_count == 1 )); then
        IFS=$'\t' read -r gateway_family gateway <<< "$gateways"
        [[ -n "$gateway" && "$gateway" != -* && "$gateway" != *[[:space:]]* ]] || {
            die "$context 引用的 nhid $id 返回非法 gateway；已停止"
            return 1
        }
        if [[ -n "$expected_family" && "$gateway_family" != "$expected_family" ]]; then
            die "$context 引用的 nhid $id gateway 地址族为 IPv$gateway_family，与路由 IPv$expected_family 不一致；已停止"
            return 1
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$iface" "$gateway" "$gateway_family" "$id"
}

# Validate either a traditional route or a route backed by one nexthop object.
# This is the single route-uniqueness gate used by default-route selection,
# route-get/fibmatch, source-bound measurement and path fingerprints.
# Output: interface, gateway-or-none, gateway-family-or-none, nhid-or-none.
route_unique_path_record() {
    local output="$1" context="$2" expected_family="${3:-}" nhid_tokens nhids nhid_count nhid
    local route_interfaces route_iface_count route_iface route_gateways route_gateway_count
    local route_gateway_family=none route_gateway=none leaf leaf_iface leaf_gateway leaf_family leaf_id
    [[ "$expected_family" == "" || "$expected_family" == 4 || "$expected_family" == 6 ]] || return 1
    [[ -n "$output" ]] || { die "$context 没有返回路由记录"; return 1; }
    if route_output_has_multipath "$output"; then
        die "$context 包含 inline ECMP/nexthop；无法证明出口唯一，已停止"
        return 1
    fi

    nhid_tokens=$(route_output_token_count "$output" nhid)
    nhids=$(route_output_nhids <<< "$output")
    nhid_count=$(awk 'NF {count++} END {print count+0}' <<< "$nhids")
    if ! is_uint "$nhid_tokens" || ! is_uint "$nhid_count" || (( nhid_tokens != nhid_count || nhid_count > 1 )); then
        die "$context 包含缺失、重复或非法的 nhid；无法证明出口唯一，已停止"
        return 1
    fi

    route_interfaces=$(route_output_interfaces <<< "$output")
    route_iface_count=$(awk 'NF {count++} END {print count+0}' <<< "$route_interfaces")
    if ! is_uint "$route_iface_count" || (( route_iface_count > 1 )); then
        die "$context 无法确定唯一出口网卡"
        return 1
    fi
    [[ "$route_iface_count" == 0 ]] || route_iface=$(sed -n '1p' <<< "$route_interfaces")
    if [[ -n "${route_iface:-}" ]]; then
        validate_interface_name "$route_iface" && [[ "$route_iface" != auto ]] || {
            die "$context 返回非法出口网卡: $route_iface"
            return 1
        }
    fi

    route_gateways=$(route_output_via_records <<< "$output")
    route_gateway_count=$(awk 'NF {count++} END {print count+0}' <<< "$route_gateways")
    if ! is_uint "$route_gateway_count" || (( route_gateway_count > 1 )); then
        die "$context 返回多个或异常 gateway；无法证明路径唯一"
        return 1
    fi
    if (( route_gateway_count == 1 )); then
        IFS=$'\t' read -r route_gateway_family route_gateway <<< "$route_gateways"
        if [[ -n "$expected_family" && "$route_gateway_family" != "$expected_family" ]]; then
            die "$context gateway 地址族为 IPv$route_gateway_family，与路由 IPv$expected_family 不一致；已停止"
            return 1
        fi
    fi

    if (( nhid_count == 0 )); then
        (( route_iface_count == 1 )) || { die "$context 无法确定唯一出口网卡"; return 1; }
        printf '%s\t%s\t%s\tnone\n' "$route_iface" "$route_gateway" "$route_gateway_family"
        return 0
    fi

    nhid=$(sed -n '1p' <<< "$nhids")
    leaf=$(nexthop_object_leaf_record "$nhid" "$context" "$expected_family") || return 1
    IFS=$'\t' read -r leaf_iface leaf_gateway leaf_family leaf_id <<< "$leaf"
    if [[ -n "${route_iface:-}" && "$route_iface" != "$leaf_iface" ]]; then
        die "$context 的 route dev $route_iface 与 nhid $nhid leaf dev $leaf_iface 不一致；已停止"
        return 1
    fi
    if [[ "$route_gateway" != none && "$leaf_gateway" == none ]]; then
        die "$context 显示 gateway $route_gateway，但 nhid $nhid leaf 没有 gateway；已停止"
        return 1
    fi
    if [[ "$route_gateway" != none && "$route_gateway" != "$leaf_gateway" ]]; then
        die "$context 的 route gateway $route_gateway 与 nhid $nhid leaf gateway $leaf_gateway 不一致；已停止"
        return 1
    fi
    if [[ "$route_gateway_family" != none && "$leaf_family" != none && "$route_gateway_family" != "$leaf_family" ]]; then
        die "$context 的 route/nhid gateway 地址族不一致；已停止"
        return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$leaf_iface" "$leaf_gateway" "$leaf_family" "$leaf_id"
}

route_unique_path_iface() {
    local record
    record=$(route_unique_path_record "$@") || return 1
    cut -f1 <<< "$record"
}

default_route_has_multipath() {
    local family="$1" output
    output=$(default_route_output "$family") || return 1
    route_output_has_multipath "$output"
}

resolve_route_target_addresses() {
    local target="$1" address
    if [[ "$target" == *:* ]]; then
        printf '6\t%s\n' "$target"
        return 0
    fi
    if [[ "$target" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        printf '4\t%s\n' "$target"
        return 0
    fi
    command_exists getent || { die "无法解析测速目标路由：缺少 getent"; return 1; }
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        if [[ "$address" == *:* ]]; then printf '6\t%s\n' "$address"
        elif [[ "$address" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then printf '4\t%s\n' "$address"
        fi
    done < <(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++')
}

target_route_records() {
    local target="$1" family address output fibmatch iface fib_iface addresses
    local resolved_count=0 verified_count=0
    addresses=$(resolve_route_target_addresses "$target") || return 1
    [[ -n "$addresses" ]] || { die "无法解析测速目标 $target 的任何路由候选地址"; return 1; }
    while IFS=$'\t' read -r family address; do
        [[ -n "$family" && -n "$address" ]] || continue
        ((resolved_count+=1))
        if ! output=$(ip "-$family" route get "$address" 2>/dev/null) || [[ -z "$output" ]]; then
            die "测速目标 $address 无法完成 route-get；所有解析候选都必须可核验，已停止"
            return 1
        fi
        iface=$(route_unique_path_iface "$output" "测速目标 $address 的 route-get" "$family") || return 1

        # `route get` can hash an ECMP route and expose only one selected dev.
        # fibmatch returns the underlying FIB entry (including its nexthops).
        if ! fibmatch=$(ip "-$family" route get fibmatch "$address" 2>/dev/null) || [[ -z "$fibmatch" ]]; then
            die "当前 iproute2 无法用 fibmatch 核验测速目标 $address；不完整的 route-show fallback 不能证明策略路由出口，已停止"
            return 1
        fi
        fib_iface=$(route_unique_path_iface "$fibmatch" "测速目标 $address 的 fibmatch" "$family") || return 1
        [[ "$fib_iface" == "$iface" ]] || {
            die "测速目标 $address 的 route-get/fibmatch 出口不一致（$iface/$fib_iface）；无法证明路径稳定，已停止"
            return 1
        }
        printf '%s\t%s\t%s\n' "$family" "$address" "$iface"
        ((verified_count+=1))
    done <<< "$addresses"
    (( resolved_count > 0 )) || { die "无法取得测速目标 $target 的路由候选地址"; return 1; }
    (( verified_count == resolved_count )) || {
        die "测速目标 $target 仅核验了 ${verified_count}/${resolved_count} 个解析候选；已停止"
        return 1
    }
}

# Path-safety gate: inspect every resolved candidate before the formal
# measurement freezes one literal/source/interface tuple. Ambiguous paths fail
# closed and no route is altered.
auto_tune_route_guard() {
    local expected_iface="$1" target="${2:-}" family output count v4_iface v6_iface records route route_iface
    local route_family address iface first_iface=""
    validate_interface_name "$expected_iface" || { die "自动调优选中了非法网卡: $expected_iface"; return 1; }

    # Once endpoint discovery has frozen a literal address, only that address
    # and family can influence the formal measurement. An unrelated broken
    # AAAA/default IPv6 path must not veto a proven IPv4 endpoint (and vice
    # versa). The literal still goes through the full route-get/fibmatch gate.
    if [[ -n "$target" ]] && { [[ "$target" == *:* ]] || [[ "$target" =~ ^[0-9]+([.][0-9]+){3}$ ]]; }; then
        records=$(target_route_records "$target") || return 1
        IFS=$'\t' read -r route_family address iface <<< "$records"
        [[ -n "$route_family" && -n "$address" && -n "$iface" ]] || {
            die "测速地址 $target 没有返回完整路由记录"
            return 1
        }
        [[ "$iface" == "$expected_iface" ]] || {
            die "测速地址 $address 实际通过 $iface，但自动调优选中 $expected_iface；拒绝在错误网卡上应用 TC"
            return 1
        }
        log INFO "测速目标路由检查通过: $address (IPv${route_family}) -> $expected_iface"
        return 0
    fi

    for family in -4 -6; do
        output=$(default_route_output "$family") || return 1
        count=$(awk '$1=="default" {count++} END {print count+0}' <<< "$output")
        if default_route_has_multipath "$family"; then
            die "IPv${family#-} 默认路由包含 ECMP/nexthop；v${SCRIPT_VERSION} 不会自动选择其中一条路径"
            return 1
        fi
        while IFS= read -r route; do
            [[ -n "$route" && "$route" =~ (^|[[:space:]])nhid([[:space:]]|$) ]] || continue
            route_iface=$(route_unique_path_iface "$route" "IPv${family#-} 默认路由" "${family#-}") || return 1
            [[ -n "$route_iface" ]] || return 1
        done <<< "$output"
        if (( count > 1 )); then
            log WARN "检测到 ${count} 条 IPv${family#-} 默认路由；将以具体测速目标的 route-get 结果决定是否可安全继续"
        fi
    done

    v4_iface=$(default_route_interface_for_family -4)
    v6_iface=$(default_route_interface_for_family -6)
    if [[ -z "$target" ]]; then
        # There is no peer whose route can disambiguate this BBR+FQ-only run.
        if [[ -n "$v4_iface" && -n "$v6_iface" && "$v4_iface" != "$v6_iface" ]]; then
            die "IPv4/IPv6 默认出口分别为 $v4_iface/$v6_iface；未测速时无法证明应调优哪张网卡"
            return 1
        fi
        for family in -4 -6; do
            count=$(default_route_count "$family") || return 1
            output=$(default_route_output "$family") || return 1
            if (( count > 1 )) && (( $(route_output_interfaces <<< "$output" | wc -l) > 1 )); then
                die "IPv${family#-} 存在跨网卡的多条默认路由；未提供测速目标，拒绝自动选择"
                return 1
            fi
        done
        [[ "$expected_iface" == "${v4_iface:-$v6_iface}" ]] || {
            die "自动选择网卡 $expected_iface 与当前默认出口 ${v4_iface:-$v6_iface} 不一致"
            return 1
        }
        log INFO "自动调优出口检查通过: $expected_iface（未运行测速）"
        return 0
    fi

    records=$(target_route_records "$target") || return 1
    while IFS=$'\t' read -r route_family address iface; do
        [[ -n "$route_family" && -n "$iface" ]] || continue
        if [[ -z "$first_iface" ]]; then first_iface="$iface"; fi
        if [[ "$iface" != "$first_iface" ]]; then
            die "测速目标 $target 的候选地址出口不一致（$first_iface/$iface）；未固定地址族时拒绝自动调优"
            return 1
        fi
        if [[ "$iface" != "$expected_iface" ]]; then
            die "测速目标 $address 实际通过 $iface，但自动调优选中 $expected_iface；拒绝在错误网卡上应用 TC"
            return 1
        fi
    done <<< "$records"
    log INFO "测速目标路由检查通过: $target -> $expected_iface"
}

interface_is_excluded() {
    case "$1" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*) return 0 ;; *) return 1 ;; esac
}

detect_interface() {
    local requested="${1:-auto}" iface
    if [[ "$requested" != auto ]]; then
        validate_interface_name "$requested" || { die "非法网卡名: $requested"; return 1; }
        [[ -e "/sys/class/net/$requested" ]] || { die "网卡不存在: $requested"; return 1; }
        printf '%s\n' "$requested"
        return 0
    fi
    iface=$(default_route_interface)
    [[ -n "$iface" ]] || { die "没有检测到 IPv4/IPv6 默认路由出口"; return 1; }
    interface_is_excluded "$iface" && { die "默认出口是受保护的虚拟接口: $iface，请显式指定 --interface"; return 1; }
    validate_interface_name "$iface" || { die "检测到非法网卡名: $iface"; return 1; }
    printf '%s\n' "$iface"
}

detect_mtu() { cat "/sys/class/net/$1/mtu" 2>/dev/null || printf '1500\n'; }
detect_link_speed() {
    local value
    value=$(cat "/sys/class/net/$1/speed" 2>/dev/null || true)
    # Some virtual drivers expose UINT32_MAX or another sentinel instead of a
    # usable line rate. Treat anything beyond the CLI's supported 1 Tbit/s
    # range as unknown rather than feeding it into buffer/traffic estimates.
    if is_uint "${value:-}" && (( value > 0 && value <= 1000000 )); then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
detect_rx_queues() {
    local count
    count=$(find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | awk '{print $1}')
    is_uint "${count:-}" && (( count > 0 )) && printf '%s\n' "$count" || printf '1\n'
}
detect_tx_queues() {
    local count
    count=$(find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l | awk '{print $1}')
    is_uint "${count:-}" && (( count > 0 )) && printf '%s\n' "$count" || printf '1\n'
}
detect_driver() {
    local path
    path=$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null || true)
    [[ -n "$path" ]] && basename "$path" || printf 'virtual\n'
}
detect_offload_summary() {
    local iface="$1" output feature value summary="" key
    command_exists ethtool || { printf 'unavailable (ethtool not installed)\n'; return 0; }
    output=$(ethtool -k "$iface" 2>/dev/null || true)
    [[ -n "$output" ]] || { printf 'unavailable\n'; return 0; }
    for key in tcp-segmentation-offload generic-segmentation-offload generic-receive-offload; do
        value=$(awk -F': ' -v key="$key" '$1==key {print $2; exit}' <<< "$output")
        value="${value%% *}"
        case "$key" in tcp-segmentation-offload) feature=tso ;; generic-segmentation-offload) feature=gso ;; *) feature=gro ;; esac
        [[ -n "$value" ]] && summary+="${summary:+ }${feature}=${value}"
    done
    printf '%s\n' "${summary:-unavailable}"
}
memory_mb() {
    local value
    value=$(awk '/MemTotal:/ {printf "%d\n", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)
    is_uint "${value:-}" && (( value > 0 )) && printf '%s\n' "$value" || printf '1024\n'
}
cpu_count() {
    local value
    value=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)
    is_uint "${value:-}" && (( value > 0 )) && printf '%s\n' "$value" || printf '1\n'
}

hardware_class_for() {
    local cpu="$1" ram="$2"
    if (( ram < 768 || cpu <= 1 )); then printf 'micro\n'
    elif (( ram < 2048 || cpu <= 2 )); then printf 'small\n'
    elif (( ram < 8192 || cpu <= 8 )); then printf 'standard\n'
    elif (( ram < 32768 || cpu <= 32 )); then printf 'high\n'
    else printf 'extreme\n'
    fi
}

# Populate a single, auditable hardware model used by sysctl sizing, scan
# bounds and status output. The configured/observed bandwidth always wins over
# a NIC-reported line rate because virtual NIC speeds are often synthetic.
hardware_profile_values() {
    local requested="${1:-auto}" configured_bandwidth="${2:-0}" iface="" link="unknown"
    is_uint "$configured_bandwidth" && (( configured_bandwidth <= 1000000 )) || {
        die "硬件模型带宽无效: $configured_bandwidth"
        return 1
    }
    HARDWARE_CPU_COUNT=$(cpu_count)
    HARDWARE_MEMORY_MB=$(memory_mb)
    iface=$(detect_interface "$requested" 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
        link=$(detect_link_speed "$iface")
        HARDWARE_RX_QUEUES=$(detect_rx_queues "$iface")
        HARDWARE_TX_QUEUES=$(detect_tx_queues "$iface")
        HARDWARE_MTU=$(detect_mtu "$iface")
        HARDWARE_DRIVER=$(detect_driver "$iface")
    else
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1; HARDWARE_MTU=1500; HARDWARE_DRIVER=unknown
    fi
    HARDWARE_LINK_MBIT="$link"
    HARDWARE_CLASS=$(hardware_class_for "$HARDWARE_CPU_COUNT" "$HARDWARE_MEMORY_MB")
    HARDWARE_VIRTUALIZATION=$(virtualization_type)
    HARDWARE_LINK_TRUST=trusted
    if [[ "$link" == unknown ]]; then
        HARDWARE_LINK_TRUST=unknown
    elif [[ "$HARDWARE_VIRTUALIZATION" != none ]]; then
        HARDWARE_LINK_TRUST=virtual-untrusted
    else
        case "$HARDWARE_DRIVER" in virtual|virtio*|veth|vmxnet*|xen*|hv_netvsc) HARDWARE_LINK_TRUST=virtual-untrusted ;; esac
    fi
    if (( configured_bandwidth > 0 )); then
        EFFECTIVE_BANDWIDTH_MBIT="$configured_bandwidth"
        EFFECTIVE_BANDWIDTH_SOURCE="configured"
    elif [[ "$HARDWARE_LINK_TRUST" == trusted ]] && is_uint "$link" && (( link > 0 )); then
        EFFECTIVE_BANDWIDTH_MBIT="$link"
        EFFECTIVE_BANDWIDTH_SOURCE="link"
    else
        EFFECTIVE_BANDWIDTH_MBIT=1000
        if [[ "$HARDWARE_LINK_TRUST" == virtual-untrusted ]]; then EFFECTIVE_BANDWIDTH_SOURCE="virtual-link-fallback"
        else EFFECTIVE_BANDWIDTH_SOURCE="fallback"
        fi
    fi
}

recommended_scan_cap() {
    local requested="${1:-auto}" nominal="${2:-0}" cap=5000 link
    hardware_profile_values "$requested" "$nominal" || return 1
    link="$HARDWARE_LINK_MBIT"
    if (( nominal > 0 )); then cap=$((nominal * 3 / 2)); fi
    if [[ "$HARDWARE_LINK_TRUST" == trusted ]] && is_uint "$link" && (( link > 0 && link * 5 / 4 > cap )); then cap=$((link * 5 / 4)); fi
    (( cap < 5000 )) && cap=5000
    (( cap > 1000000 )) && cap=1000000
    printf '%s\n' "$cap"
}

expanded_scan_cap() {
    local current="$1" measured="$2" observed
    is_uint "$current" && (( current >= 100 && current <= 1000000 )) || { die "扫描上限无效: $current"; return 1; }
    is_decimal "$measured" || { die "基准吞吐无效: $measured"; return 1; }
    observed=$(awk -v g="$measured" 'BEGIN {v=g*1.5; if(v<5000)v=5000; if(v>1000000)v=1000000; printf "%d", v+0.5}')
    if (( observed > current )); then printf '%s\n' "$observed"; else printf '%s\n' "$current"; fi
}

recommended_measure_duration() {
    local requested="${1:-auto}" bandwidth="${2:-0}"
    hardware_profile_values "$requested" "$bandwidth" || return 1
    if (( EFFECTIVE_BANDWIDTH_MBIT >= 40000 )); then printf '3\n'
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )); then printf '4\n'
    else printf '5\n'
    fi
}

recommended_verify_flows() {
    local requested="${1:-auto}" bandwidth="${2:-0}" flows=4 capacity
    hardware_profile_values "$requested" "$bandwidth" || return 1
    capacity="$HARDWARE_CPU_COUNT"
    if (( HARDWARE_CPU_COUNT <= 1 )); then flows=2
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 40000 )); then flows=16
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )); then flows=8
    else flows=4
    fi
    (( flows > capacity * 2 )) && flows=$((capacity * 2))
    (( flows < 2 )) && flows=2
    (( flows > 16 )) && flows=16
    printf '%s\n' "$flows"
}

hardware_scaling_note() {
    local cpu="$HARDWARE_CPU_COUNT" rx="$HARDWARE_RX_QUEUES" bandwidth="$EFFECTIVE_BANDWIDTH_MBIT"
    if (( bandwidth >= 2500 && rx == 1 && cpu >= 4 )); then
        printf 'single RX queue may limit multi-Gbit throughput; inspect RSS/RPS and IRQ affinity\n'
    elif (( bandwidth >= 10000 && cpu <= 2 )); then
        printf 'CPU count may limit line-rate processing; validate CPU saturation during load\n'
    elif (( bandwidth >= 40000 )); then
        printf 'aggregate HTB can become the local bottleneck at this rate; require clean per-core CPU metrics and A/B verification\n'
    elif [[ "$EFFECTIVE_BANDWIDTH_SOURCE" == fallback || "$EFFECTIVE_BANDWIDTH_SOURCE" == virtual-link-fallback ]]; then
        printf 'line rate is unknown or virtual; using 1000 Mbit planning until measured/configured\n'
    else
        printf 'no obvious hardware queue bottleneck detected\n'
    fi
}

median_ping_ms() {
    local target="$1" family="${2:-auto}" output
    [[ -n "$target" && "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || return 1
    case "$family" in
        4) output=$(ping -4 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        6) output=$(ping -6 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        *) output=$(ping -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
    esac
    awk -F'/' '/rtt|round-trip/ {printf "%.0f\n", $5}' <<< "$output"
}

detect_profile() {
    local requested="${1:-auto}" target="${2:-}" iface rtt="not measured" cc available
    require_commands ip awk uname || return 1
    iface=$(detect_interface "$requested") || return 1
    if [[ -n "$target" ]]; then
        [[ "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法探测目标: $target"; return 1; }
        rtt=$(median_ping_ms "$target"); [[ -n "$rtt" ]] || rtt="unreachable"
    fi
    printf '%-18s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-18s %s\n' "OS" "$(os_id) $(os_codename)"
    printf '%-18s %s\n' "Kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "Virtualization" "$(virtualization_type)"
    printf '%-18s %s\n' "CPU cores" "$(cpu_count)"
    printf '%-18s %s MB\n' "Memory" "$(memory_mb)"
    printf '%-18s %s\n' "Interface" "$iface"
    printf '%-18s %s\n' "Driver" "$(detect_driver "$iface")"
    printf '%-18s %s\n' "MTU" "$(detect_mtu "$iface")"
    local link_speed
    link_speed=$(detect_link_speed "$iface")
    [[ "$link_speed" == unknown ]] || link_speed="${link_speed} Mbps"
    printf '%-18s %s\n' "Link speed" "$link_speed"
    printf '%-18s %s\n' "RX queues" "$(detect_rx_queues "$iface")"
    printf '%-18s %s\n' "TX queues" "$(detect_tx_queues "$iface")"
    printf '%-18s %s\n' "NIC offloads" "$(detect_offload_summary "$iface")"
    hardware_profile_values "$iface" 0 || return 1
    printf '%-18s %s\n' "Hardware class" "$HARDWARE_CLASS"
    printf '%-18s %s\n' "Link trust" "$HARDWARE_LINK_TRUST"
    printf '%-18s %s Mbit (%s)\n' "Planning bandwidth" "$EFFECTIVE_BANDWIDTH_MBIT" "$EFFECTIVE_BANDWIDTH_SOURCE"
    printf '%-18s %s\n' "Scaling note" "$(hardware_scaling_note)"
    [[ "$rtt" == "not measured" || "$rtt" == unreachable ]] || rtt="${rtt} ms"
    printf '%-18s %s\n' "Target RTT" "$rtt"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    printf '%-18s %s\n' "Congestion control" "$cc"
    printf '%-18s %s\n' "Available CC" "$available"
    printf '%-18s %s\n' "BBR compatibility" "$(bbr_compatibility_status "$cc" "$available")"
}

install_measure_dependencies() {
    require_root || return 1
    local -a packages=()
    command_exists iperf3 || packages+=(iperf3)
    command_exists jq || packages+=(jq)
    command_exists ping || packages+=(iputils-ping)
    if ! command_exists ip || ! command_exists tc; then packages+=(iproute2); fi
    command_exists sysctl || packages+=(procps)
    command_exists flock || packages+=(util-linux)
    command_exists timeout || packages+=(coreutils)
    ((${#packages[@]} > 0)) || { log OK "测量依赖已经齐全"; return 0; }
    case "$(os_id)" in
        debian|ubuntu)
            log INFO "仅安装缺少的依赖包: ${packages[*]}"
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        *) die "自动安装依赖目前只支持 Debian/Ubuntu" ;;
    esac
}
