# -----------------------------------------------------------------------------
# IPv6: explicit, interface-aware policy with immutable baseline and rollback.
# -----------------------------------------------------------------------------

IPV6_SYSCTL_FILE="${BBRV3_IPV6_SYSCTL_FILE:-/etc/sysctl.d/99-bbrv3-lite-ipv6.conf}"
if [[ ${BBRV3_IPV6_PROC_CONF_ROOT+x} == x ]]; then
    IPV6_PROC_CONF_ROOT_EXPLICIT=1
else
    IPV6_PROC_CONF_ROOT_EXPLICIT=0
fi
IPV6_PROC_CONF_ROOT="${BBRV3_IPV6_PROC_CONF_ROOT:-/proc/sys/net/ipv6/conf}"
IPV6_CMDLINE_FILE="${BBRV3_IPV6_CMDLINE_FILE:-/proc/cmdline}"
IPV6_MODULE_DISABLE_FILE="${BBRV3_IPV6_MODULE_DISABLE_FILE:-/sys/module/ipv6/parameters/disable}"
IPV6_SNAPSHOT_SCHEMA=2
IPV6_TRANSACTION_DIR=""
IPV6_LAST_RESTORE_QUALITY=""
IPV6_TOPOLOGY_REASON=""
IPV6_RESTORE_DISABLE_TARGETS=""
IPV6_RESTORE_DISABLES_LOOPBACK=0
IPV6_SNAPSHOT_VALIDATION_ERROR=""
IPV6_SNAPSHOT_CAPTURE=""

ipv6_valid_interface_name() {
    local iface="$1"
    [[ -n "$iface" && "$iface" != . && "$iface" != .. && "$iface" =~ ^[-[:alnum:]_.:@+]+$ ]]
}

ipv6_proc_backend_available() {
    # A shell function named sysctl normally means a unit-test or an embedding
    # shim. Do not bypass such a shim and write to the host's real /proc tree.
    if (( IPV6_PROC_CONF_ROOT_EXPLICIT == 0 )) && declare -F sysctl >/dev/null; then
        return 1
    fi
    [[ -d "$IPV6_PROC_CONF_ROOT" ]]
}

ipv6_conf_path() {
    local iface="$1"
    ipv6_valid_interface_name "$iface" || { die "无效的 IPv6 接口名: $iface"; return 1; }
    printf '%s/%s/disable_ipv6\n' "${IPV6_PROC_CONF_ROOT%/}" "$iface"
}

ipv6_list_runtime_interfaces() {
    local path iface nullglob_was_set=0
    local -a paths=()
    if ! ipv6_proc_backend_available; then
        # Compatibility-only fallback. It deliberately reports a partial view;
        # mutating transactions refuse to proceed without the /proc interface map.
        printf '%s\n' all default lo
        return 2
    fi
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    paths=( "${IPV6_PROC_CONF_ROOT%/}"/*/disable_ipv6 )
    (( nullglob_was_set )) || shopt -u nullglob
    ((${#paths[@]})) || return 1
    for path in "${paths[@]}"; do
        iface=${path%/disable_ipv6}
        iface=${iface##*/}
        ipv6_valid_interface_name "$iface" || {
            die "IPv6 接口名无法安全写入快照: $iface"
            return 1
        }
        printf '%s\n' "$iface"
    done
}

ipv6_sysctl_key() {
    local iface="$1"
    ipv6_valid_interface_name "$iface" || return 1
    printf 'net.ipv6.conf.%s.disable_ipv6\n' "$iface"
}

ipv6_read_interface_value() {
    local iface="$1" path value key
    if ipv6_proc_backend_available; then
        path=$(ipv6_conf_path "$iface") || return 1
        [[ -r "$path" ]] || return 1
        IFS= read -r value < "$path" || return 1
    else
        key=$(ipv6_sysctl_key "$iface") || return 1
        value=$(sysctl -n "$key" 2>/dev/null) || return 1
    fi
    [[ "$value" == 0 || "$value" == 1 ]] || return 1
    printf '%s\n' "$value"
}

ipv6_write_interface_value() {
    local iface="$1" value="$2" path key
    [[ "$value" == 0 || "$value" == 1 ]] || { die "无效的 IPv6 sysctl 值: $value"; return 1; }
    if ipv6_proc_backend_available; then
        path=$(ipv6_conf_path "$iface") || return 1
        [[ -e "$path" ]] || { log WARN "IPv6 接口已消失，无法恢复: $iface"; return 1; }
        if ! printf '%s\n' "$value" > "$path"; then
            log WARN "无法写入 IPv6 接口状态: $iface=$value"
            return 1
        fi
    else
        key=$(ipv6_sysctl_key "$iface") || return 1
        sysctl -q -w "$key=$value"
    fi
}

ipv6_boot_disable_source() {
    local cmdline="" module_value=""
    [[ ! -r "$IPV6_CMDLINE_FILE" ]] || cmdline=$(<"$IPV6_CMDLINE_FILE")
    if [[ " $cmdline " =~ [[:space:]]ipv6\.disable=(1|y|Y|yes|YES)[[:space:]] ]]; then
        printf 'kernel-command-line\n'
        return 0
    fi
    [[ ! -r "$IPV6_MODULE_DISABLE_FILE" ]] || module_value=$(<"$IPV6_MODULE_DISABLE_FILE")
    case "$module_value" in
        1|y|Y|yes|YES) printf 'module-parameter\n'; return 0 ;;
    esac
    printf 'none\n'
    return 1
}

ipv6_boot_disabled() {
    [[ "$(ipv6_boot_disable_source || true)" != none ]]
}

ipv6_ssh_family() {
    local client="" server="" _ignored=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client _ignored server _ignored <<< "$SSH_CONNECTION"
        if [[ "$client" == *:* || "$server" == *:* ]]; then printf 'IPv6\n'; else printf 'IPv4\n'; fi
    else
        printf 'not-ssh/unknown\n'
    fi
}

ipv6_default_route_mode() {
    local v4="" v6=""
    if command_exists ip; then
        v4=$(ip -4 route show default 2>/dev/null || true)
        v6=$(ip -6 route show default 2>/dev/null || true)
    fi
    if [[ -n "$v4" && -n "$v6" ]]; then printf 'dual-stack\n'
    elif [[ -n "$v4" ]]; then printf 'IPv4-only\n'
    elif [[ -n "$v6" ]]; then printf 'IPv6-only\n'
    else printf 'none/unknown\n'
    fi
}

ipv6_address_output_has_routable_topology() {
    local input="$1" line iface family address scope field previous=""
    local -a fields=()
    IPV6_TOPOLOGY_REASON=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r -a fields <<< "$line"
        ((${#fields[@]} >= 4)) || continue
        iface=${fields[1]%%@*}
        family=${fields[2]}
        address=${fields[3],,}
        [[ "$family" == inet6 && "$iface" != lo ]] || continue
        scope=""; previous=""
        for field in "${fields[@]}"; do
            if [[ "$previous" == scope ]]; then scope="$field"; break; fi
            previous="$field"
        done
        if [[ "$scope" == global || "${address%%/*}" =~ ^f[cd] ]]; then
            IPV6_TOPOLOGY_REASON="address $address on $iface (scope ${scope:-unknown})"
            return 0
        fi
    done <<< "$input"
    return 1
}

ipv6_address_output_has_loopback_address() {
    local input="$1" line iface family address
    local -a fields=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r -a fields <<< "$line"
        ((${#fields[@]} >= 4)) || continue
        iface=${fields[1]%%@*}
        family=${fields[2]}
        address=${fields[3],,}
        [[ "$iface" == lo && "$family" == inet6 && "${address%%/*}" == ::1 ]] || continue
        return 0
    done <<< "$input"
    return 1
}

ipv6_route_output_has_business_topology() {
    local input="$1" line first second destination="" route_type="" normalized
    IPV6_TOPOLOGY_REASON=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        first=""; second=""; destination=""; route_type=""
        read -r first second _ <<< "$line"
        route_type=""
        case "$first" in
            unreachable|blackhole|prohibit|throw)
                # These are negative policy entries, not a usable IPv6 path.
                continue
                ;;
            local|broadcast|multicast|anycast|nat)
                route_type="$first"
                destination="$second"
                ;;
            *)
                destination="$first"
                ;;
        esac
        [[ -n "$destination" ]] || continue
        if [[ "$destination" == default ]]; then
            IPV6_TOPOLOGY_REASON="default route: $line"
            return 0
        fi
        normalized=${destination,,}
        normalized=${normalized%%/*}
        case "$normalized" in
            ::1|fe[89ab]*|ff*) continue ;;
        esac
        IPV6_TOPOLOGY_REASON="${route_type:+$route_type }route $destination"
        return 0
    done <<< "$input"
    return 1
}

ipv6_read_topology_diagnostics() {
    local addresses_file="$1" routes_file="$2"
    if ! ip -6 -o addr show > "$addresses_file" 2>/dev/null; then
        die "无法读取 IPv6 地址拓扑；为避免不可恢复地删除地址，拒绝继续"
        return 1
    fi
    if ! ip -6 route show table all > "$routes_file" 2>/dev/null; then
        die "无法读取 IPv6 路由拓扑；为避免不可恢复地删除路由，拒绝继续"
        return 1
    fi
}

ipv6_disable_topology_preflight() {
    local addresses_file routes_file addresses routes reason
    addresses_file=$(mktemp) || return 1
    routes_file=$(mktemp) || { rm -f -- "$addresses_file"; return 1; }
    if ! ipv6_read_topology_diagnostics "$addresses_file" "$routes_file"; then
        rm -f -- "$addresses_file" "$routes_file"
        return 1
    fi
    addresses=$(<"$addresses_file")
    routes=$(<"$routes_file")
    rm -f -- "$addresses_file" "$routes_file"
    if ipv6_address_output_has_routable_topology "$addresses"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "检测到可路由 IPv6 地址（$reason）；禁用会删除地址且仅恢复 flag 无法重建，拒绝操作"
        return 1
    fi
    if ipv6_route_output_has_business_topology "$routes"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "检测到 IPv6 业务路由（$reason）；禁用会删除路由且仅恢复 flag 无法重建，拒绝操作"
        return 1
    fi
}

ipv6_capture_topology_diagnostics() {
    local directory="$1"
    ipv6_read_topology_diagnostics "$directory/addresses-v6.txt" "$directory/routes-v6.txt"
}

ipv6_snapshot_has_routable_topology() {
    local directory="$1" addresses="" routes=""
    [[ ! -f "$directory/addresses-v6.txt" ]] || addresses=$(<"$directory/addresses-v6.txt")
    [[ ! -f "$directory/routes-v6.txt" ]] || routes=$(<"$directory/routes-v6.txt")
    ipv6_address_output_has_routable_topology "$addresses" ||
        ipv6_route_output_has_business_topology "$routes"
}

ipv6_restore_collect_disable_targets() {
    local directory="$1" record iface value key current targets=""
    IPV6_RESTORE_DISABLE_TARGETS=""
    IPV6_RESTORE_DISABLES_LOOPBACK=0
    if ipv6_snapshot_is_v2 "$directory"; then
        while IFS=$'\t' read -r record iface value; do
            [[ "$record" == INTERFACE ]] || continue
            [[ "$value" == 0 || "$value" == 1 ]] || {
                die "IPv6 v2 快照包含无效 disable flag: $iface=$value"
                return 1
            }
            [[ "$value" == 1 && "$iface" != default ]] || continue
            current=$(ipv6_read_interface_value "$iface" 2>/dev/null) || continue
            [[ "$current" == 0 || "$current" == 1 ]] || continue
            targets+="${targets:+,}$iface"
            [[ "$iface" != lo ]] || IPV6_RESTORE_DISABLES_LOOPBACK=1
        done < "$directory/sysctl.tsv"
    else
        while IFS=$'\t' read -r key value; do
            [[ -n "$key" ]] || continue
            [[ "$value" == 0 || "$value" == 1 ]] || {
                die "旧 IPv6 快照包含无效 disable flag: $key=$value"
                return 1
            }
            [[ "$value" == 1 ]] || continue
            case "$key" in
                net.ipv6.conf.default.disable_ipv6) continue ;;
                net.ipv6.conf.all.disable_ipv6)
                    targets+="${targets:+,}all(write-trigger)"
                    IPV6_RESTORE_DISABLES_LOOPBACK=1
                    ;;
                net.ipv6.conf.*.disable_ipv6)
                    iface=${key#net.ipv6.conf.}
                    iface=${iface%.disable_ipv6}
                    if current=$(ipv6_read_interface_value "$iface" 2>/dev/null); then
                        targets+="${targets:+,}$iface"
                        [[ "$iface" != lo ]] || IPV6_RESTORE_DISABLES_LOOPBACK=1
                    fi
                    ;;
                *)
                    # The legacy restorer writes every recorded key. Unknown
                    # target=1 records therefore receive the same fail-closed gate.
                    targets+="${targets:+,}$key"
                    ;;
            esac
        done < "$directory/sysctl.tsv"
    fi
    IPV6_RESTORE_DISABLE_TARGETS="$targets"
}

ipv6_restore_target_preflight() {
    local directory="$1" addresses_file routes_file addresses routes reason
    ipv6_restore_collect_disable_targets "$directory" || return 1
    [[ -n "$IPV6_RESTORE_DISABLE_TARGETS" ]] || return 0

    addresses_file=$(mktemp) || return 1
    routes_file=$(mktemp) || { rm -f -- "$addresses_file"; return 1; }
    if ! ipv6_read_topology_diagnostics "$addresses_file" "$routes_file"; then
        rm -f -- "$addresses_file" "$routes_file"
        return 1
    fi
    addresses=$(<"$addresses_file")
    routes=$(<"$routes_file")
    rm -f -- "$addresses_file" "$routes_file"

    if (( IPV6_RESTORE_DISABLES_LOOPBACK )) && ipv6_address_output_has_loopback_address "$addresses"; then
        die "目标 IPv6 快照会禁用 lo，但当前存在 ::1；写入会删除回环地址且无法重建，拒绝恢复"
        return 1
    fi
    if ipv6_address_output_has_routable_topology "$addresses"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "目标 IPv6 快照会把现有接口置为禁用（$IPV6_RESTORE_DISABLE_TARGETS），且当前存在可路由地址（$reason）；拒绝恢复"
        return 1
    fi
    if ipv6_route_output_has_business_topology "$routes"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "目标 IPv6 快照会把现有接口置为禁用（$IPV6_RESTORE_DISABLE_TARGETS），且当前存在业务路由（$reason）；拒绝恢复"
        return 1
    fi
}

ipv6_disable_preflight() {
    local boot_source ssh_family route_mode
    boot_source=$(ipv6_boot_disable_source || true)
    [[ "$boot_source" == none ]] || {
        die "IPv6 已由启动级策略禁用（$boot_source）；运行时 sysctl 无法安全管理，需修改启动配置并重启"
        return 1
    }
    ssh_family=$(ipv6_ssh_family)
    [[ "$ssh_family" != IPv6 ]] || {
        die "当前 SSH 管理会话使用 IPv6；拒绝禁用以避免立即断开连接"
        return 1
    }
    route_mode=$(ipv6_default_route_mode)
    [[ "$route_mode" == IPv4-only ]] || {
        die "IPv6 禁用仅允许有 IPv4 默认出口且没有 IPv6 默认出口的主机；当前为 $route_mode"
        return 1
    }
    ipv6_disable_topology_preflight
}

ipv6_snapshot_is_v2() {
    local directory="$1"
    [[ -e "$directory/snapshot.meta" || -L "$directory/snapshot.meta" ]] ||
        grep -Fqx $'FORMAT\tinterface-values-v2' "$directory/manifest" 2>/dev/null ||
        awk -F'\t' '$1=="AGGREGATE" || $1=="INTERFACE" {found=1; exit} END {exit !found}' \
            "$directory/sysctl.tsv" 2>/dev/null
}

ipv6_snapshot_validation_fail() {
    IPV6_SNAPSHOT_VALIDATION_ERROR="$1"
    return 1
}

ipv6_validate_snapshot_persistent() {
    local directory="$1" state
    local -a state_lines=()
    [[ -f "$directory/persistent.state" && ! -L "$directory/persistent.state" ]] ||
        ipv6_snapshot_validation_fail "缺少常规文件 persistent.state" || return 1
    mapfile -t state_lines < "$directory/persistent.state" ||
        ipv6_snapshot_validation_fail "无法读取 persistent.state" || return 1
    ((${#state_lines[@]} == 1)) ||
        ipv6_snapshot_validation_fail "persistent.state 必须且只能包含一行" || return 1
    state=${state_lines[0]}
    [[ "$state" == present || "$state" == absent ]] ||
        ipv6_snapshot_validation_fail "persistent.state 非法: $state" || return 1
    if [[ "$state" == present && ! -f "$directory/persistent.conf" && ! -L "$directory/persistent.conf" ]]; then
        ipv6_snapshot_validation_fail "persistent.state=present 但缺少 persistent.conf"
        return 1
    fi
    if [[ "$state" == absent && ( -e "$directory/persistent.conf" || -L "$directory/persistent.conf" ) ]]; then
        ipv6_snapshot_validation_fail "persistent.state=absent 但存在多余 persistent.conf"
        return 1
    fi
}

ipv6_validate_manifest() {
    local directory="$1" is_v2="$2" line key value metadata_value
    local -A fields=()
    [[ -f "$directory/manifest" && ! -L "$directory/manifest" ]] ||
        ipv6_snapshot_validation_fail "基线缺少常规文件 manifest" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || {
            ipv6_snapshot_validation_fail "manifest 行格式非法"
            return 1
        }
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -n "$key" && -n "$value" ]] || { ipv6_snapshot_validation_fail "manifest 含空字段"; return 1; }
        [[ -z "${fields[$key]+x}" ]] || { ipv6_snapshot_validation_fail "manifest 键重复: $key"; return 1; }
        case "$key" in
            CREATED_AT|CREATED_BY|FORMAT|SCHEMA|CAPTURE|RESTORE_SCOPE|AGGREGATE_ALL|TOPOLOGY_DIAGNOSTICS) ;;
            *) ipv6_snapshot_validation_fail "manifest 含未知键: $key"; return 1 ;;
        esac
        fields[$key]="$value"
    done < "$directory/manifest"
    [[ "${fields[CREATED_AT]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        ipv6_snapshot_validation_fail "manifest CREATED_AT 非法"
        return 1
    }
    [[ "${fields[CREATED_BY]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || {
        ipv6_snapshot_validation_fail "manifest CREATED_BY 非法"
        return 1
    }
    if (( is_v2 )); then
        (( ${#fields[@]} == 8 )) || { ipv6_snapshot_validation_fail "v2 manifest 字段集合不完整"; return 1; }
        for key in FORMAT SCHEMA CAPTURE RESTORE_SCOPE AGGREGATE_ALL TOPOLOGY_DIAGNOSTICS; do
            metadata_value=$(awk -F'\t' -v wanted="$key" '$1==wanted {print $2; exit}' "$directory/snapshot.meta") || return 1
            [[ "${fields[$key]:-}" == "$metadata_value" ]] || {
                ipv6_snapshot_validation_fail "manifest 与 snapshot.meta 不一致: $key"
                return 1
            }
        done
    else
        (( ${#fields[@]} == 2 )) || { ipv6_snapshot_validation_fail "旧版 manifest 含不受支持字段"; return 1; }
    fi
}

ipv6_validate_v2_metadata() {
    local directory="$1" key value extra capture=""
    local -A seen=()
    IPV6_SNAPSHOT_CAPTURE=""
    [[ -f "$directory/snapshot.meta" && ! -L "$directory/snapshot.meta" ]] ||
        ipv6_snapshot_validation_fail "v2 快照缺少常规文件 snapshot.meta" || return 1
    while IFS=$'\t' read -r key value extra || [[ -n "$key$value$extra" ]]; do
        [[ -n "$key" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 行格式非法"
            return 1
        }
        [[ -z "${seen[$key]+x}" ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 键重复: $key"
            return 1
        }
        seen["$key"]=1
        case "$key:$value" in
            FORMAT:interface-values-v2|SCHEMA:"$IPV6_SNAPSHOT_SCHEMA"|RESTORE_SCOPE:disable-flags-only|AGGREGATE_ALL:audit-only/write-trigger/not-replayed|TOPOLOGY_DIAGNOSTICS:diagnostic-only/not-replayable) ;;
            CAPTURE:per-interface|CAPTURE:boot-disabled|CAPTURE:partial) capture="$value" ;;
            *)
                ipv6_snapshot_validation_fail "snapshot.meta 键值非法: $key=$value"
                return 1
                ;;
        esac
    done < "$directory/snapshot.meta"
    for key in FORMAT SCHEMA CAPTURE RESTORE_SCOPE AGGREGATE_ALL TOPOLOGY_DIAGNOSTICS; do
        [[ "${seen[$key]:-0}" == 1 ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 缺少键: $key"
            return 1
        }
    done
    IPV6_SNAPSHOT_CAPTURE="$capture"
}

ipv6_validate_v2_records() {
    local directory="$1" capture="$2" record iface value extra rows=0 aggregate=0 default_seen=0 lo_seen=0
    local -A interfaces=()
    [[ -f "$directory/sysctl.tsv" && ! -L "$directory/sysctl.tsv" ]] ||
        ipv6_snapshot_validation_fail "v2 快照缺少常规文件 sysctl.tsv" || return 1
    while IFS=$'\t' read -r record iface value extra || [[ -n "$record$iface$value$extra" ]]; do
        [[ -n "$record" && -n "$iface" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "sysctl.tsv 行格式非法"
            return 1
        }
        ipv6_valid_interface_name "$iface" || {
            ipv6_snapshot_validation_fail "sysctl.tsv 接口名非法: $iface"
            return 1
        }
        [[ "$value" == 0 || "$value" == 1 ]] || {
            ipv6_snapshot_validation_fail "sysctl.tsv disable flag 非法: $iface=$value"
            return 1
        }
        rows=$((rows + 1))
        case "$record:$iface" in
            AGGREGATE:all)
                aggregate=$((aggregate + 1))
                (( aggregate == 1 )) || {
                    ipv6_snapshot_validation_fail "AGGREGATE all 重复"
                    return 1
                }
                ;;
            INTERFACE:all)
                ipv6_snapshot_validation_fail "all 只能作为 AGGREGATE 审计记录"
                return 1
                ;;
            INTERFACE:*)
                [[ -z "${interfaces[$iface]+x}" ]] || {
                    ipv6_snapshot_validation_fail "INTERFACE 记录重复: $iface"
                    return 1
                }
                interfaces["$iface"]=1
                [[ "$iface" != default ]] || default_seen=1
                [[ "$iface" != lo ]] || lo_seen=1
                ;;
            *)
                ipv6_snapshot_validation_fail "sysctl.tsv 记录类型非法: $record/$iface"
                return 1
                ;;
        esac
    done < "$directory/sysctl.tsv"

    if [[ "$capture" == boot-disabled ]]; then
        (( rows == 0 )) || {
            ipv6_snapshot_validation_fail "boot-disabled 快照不得伪造运行时接口值"
            return 1
        }
    else
        (( aggregate == 1 && default_seen == 1 && lo_seen == 1 )) || {
            ipv6_snapshot_validation_fail "逐接口快照必须恰有 AGGREGATE all、INTERFACE default 和 INTERFACE lo"
            return 1
        }
    fi
}

ipv6_validate_legacy_records() {
    local directory="$1" key value extra iface rows=0
    local -A seen=()
    [[ -f "$directory/sysctl.tsv" && ! -L "$directory/sysctl.tsv" ]] ||
        ipv6_snapshot_validation_fail "旧快照缺少常规文件 sysctl.tsv" || return 1
    while IFS=$'\t' read -r key value extra || [[ -n "$key$value$extra" ]]; do
        [[ -n "$key" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl.tsv 行格式非法"
            return 1
        }
        case "$key" in
            net.ipv6.conf.*.disable_ipv6)
                iface=${key#net.ipv6.conf.}
                iface=${iface%.disable_ipv6}
                ipv6_valid_interface_name "$iface" || {
                    ipv6_snapshot_validation_fail "旧 sysctl 接口名非法: $iface"
                    return 1
                }
                ;;
            *)
                ipv6_snapshot_validation_fail "旧 sysctl key 非法: $key"
                return 1
                ;;
        esac
        [[ "$value" == 0 || "$value" == 1 ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl disable flag 非法: $key=$value"
            return 1
        }
        [[ -z "${seen[$key]+x}" ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl key 重复: $key"
            return 1
        }
        seen["$key"]=1
        rows=$((rows + 1))
    done < "$directory/sysctl.tsv"
    (( rows > 0 )) || {
        ipv6_snapshot_validation_fail "旧 sysctl.tsv 为空"
        return 1
    }
}

ipv6_validate_snapshot() {
    local directory="$1" require_manifest="${2:-0}" capture is_v2=0
    IPV6_SNAPSHOT_VALIDATION_ERROR=""
    [[ -d "$directory" && ! -L "$directory" ]] ||
        ipv6_snapshot_validation_fail "快照目录不存在或不是常规目录" || return 1
    ipv6_validate_snapshot_persistent "$directory" || return 1
    if ipv6_snapshot_is_v2 "$directory"; then
        is_v2=1
        ipv6_validate_v2_metadata "$directory" || return 1
        capture="$IPV6_SNAPSHOT_CAPTURE"
        ipv6_validate_v2_records "$directory" "$capture" || return 1
        [[ -f "$directory/addresses-v6.txt" && ! -L "$directory/addresses-v6.txt" ]] ||
            ipv6_snapshot_validation_fail "v2 快照缺少地址诊断文件" || return 1
        [[ -f "$directory/routes-v6.txt" && ! -L "$directory/routes-v6.txt" ]] ||
            ipv6_snapshot_validation_fail "v2 快照缺少路由诊断文件" || return 1
    else
        ipv6_validate_legacy_records "$directory" || return 1
    fi
    if (( require_manifest )) || [[ -e "$directory/manifest" || -L "$directory/manifest" ]]; then
        ipv6_validate_manifest "$directory" "$is_v2" || return 1
    fi
}

ipv6_snapshot_quality() {
    local directory="$1" require_manifest="${2:-0}" capture=""
    if ! ipv6_validate_snapshot "$directory" "$require_manifest"; then
        printf 'malformed/invalid\n'
        return 0
    fi
    if ipv6_snapshot_is_v2 "$directory"; then
        capture=$(awk -F'\t' '$1=="CAPTURE" {print $2}' "$directory/snapshot.meta")
    fi
    case "$capture" in
        per-interface) printf 'disable-flags-exact\n' ;;
        boot-disabled) printf 'persistent-only\n' ;;
        *) printf 'legacy/partial-best-effort\n' ;;
    esac
}

ipv6_snapshot_current() {
    local directory="$1" iface value capture=per-interface list_rc=0
    local saw_all=0 saw_default=0 saw_lo=0
    local interfaces_file
    mkdir -p -- "$directory" || return 1
    : > "$directory/sysctl.tsv" || return 1
    interfaces_file="$directory/.interfaces"
    if ipv6_boot_disabled; then
        capture=boot-disabled
        : > "$interfaces_file"
    else
        if ipv6_list_runtime_interfaces > "$interfaces_file"; then
            capture=per-interface
        else
            list_rc=$?
            (( list_rc == 2 )) || { rm -f -- "$interfaces_file"; return 1; }
            capture=partial
        fi
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            value=$(ipv6_read_interface_value "$iface") || {
                die "无法读取 IPv6 运行时状态: $iface"
                rm -f -- "$interfaces_file"
                return 1
            }
            case "$iface" in all) saw_all=1 ;; default) saw_default=1 ;; lo) saw_lo=1 ;; esac
            if [[ "$iface" == all ]]; then
                printf 'AGGREGATE\tall\t%s\n' "$value" >> "$directory/sysctl.tsv" || return 1
            else
                printf 'INTERFACE\t%s\t%s\n' "$iface" "$value" >> "$directory/sysctl.tsv" || return 1
            fi
        done < "$interfaces_file"
        if [[ "$capture" == per-interface ]] && (( saw_all == 0 || saw_default == 0 || saw_lo == 0 )); then
            die "IPv6 /proc 视图缺少 all/default/lo，无法建立逐接口 disable flags 快照"
            rm -f -- "$interfaces_file"
            return 1
        fi
    fi
    rm -f -- "$interfaces_file"

    ipv6_capture_topology_diagnostics "$directory" || return 1

    printf 'FORMAT\tinterface-values-v2\nSCHEMA\t%s\nCAPTURE\t%s\nRESTORE_SCOPE\tdisable-flags-only\nAGGREGATE_ALL\taudit-only/write-trigger/not-replayed\nTOPOLOGY_DIAGNOSTICS\tdiagnostic-only/not-replayable\n' \
        "$IPV6_SNAPSHOT_SCHEMA" "$capture" > "$directory/snapshot.meta" || return 1

    if [[ -e "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]]; then
        cp -a -- "$IPV6_SYSCTL_FILE" "$directory/persistent.conf" || return 1
        printf 'present\n' > "$directory/persistent.state" || return 1
    else
        printf 'absent\n' > "$directory/persistent.state" || return 1
    fi
    ipv6_validate_snapshot "$directory" || {
        die "刚创建的 IPv6 快照校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    }
}

ipv6_restore_persistent_snapshot() {
    local directory="$1" state=absent rc=0
    rm -f -- "$IPV6_SYSCTL_FILE" || rc=1
    [[ ! -f "$directory/persistent.state" ]] || state=$(<"$directory/persistent.state")
    if [[ "$state" == present ]]; then
        [[ -e "$directory/persistent.conf" || -L "$directory/persistent.conf" ]] || return 1
        mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")" || rc=1
        cp -a -- "$directory/persistent.conf" "$IPV6_SYSCTL_FILE" || rc=1
    fi
    return "$rc"
}

ipv6_snapshot_interface_set_matches_current() {
    local directory="$1" captured_file current_file list_rc=0 captured current
    captured_file=$(mktemp) || return 1
    current_file=$(mktemp) || { rm -f -- "$captured_file"; return 1; }
    awk -F'\t' '$1=="INTERFACE" && $2!="default" {print $2}' "$directory/sysctl.tsv" | LC_ALL=C sort -u > "$captured_file"
    if ipv6_list_runtime_interfaces | awk '$0!="all" && $0!="default"' | LC_ALL=C sort -u > "$current_file"; then
        :
    else
        list_rc=${PIPESTATUS[0]}
    fi
    if (( list_rc != 0 )); then
        rm -f -- "$captured_file" "$current_file"
        log WARN "无法枚举当前全部 IPv6 接口；拒绝声称 disable flags 精确恢复"
        return 1
    fi
    if cmp -s -- "$captured_file" "$current_file"; then
        rm -f -- "$captured_file" "$current_file"
        return 0
    fi
    captured=$(paste -sd, "$captured_file" 2>/dev/null || true)
    current=$(paste -sd, "$current_file" 2>/dev/null || true)
    rm -f -- "$captured_file" "$current_file"
    log WARN "IPv6 接口集合已变化；无法声称 disable flags 精确恢复（快照: ${captured:-none}；当前: ${current:-none}）"
    return 1
}

ipv6_restore_v2_runtime() {
    local directory="$1" record iface value default_value="" rc=0
    while IFS=$'\t' read -r record iface value; do
        case "$record:$iface" in
            INTERFACE:default) default_value="$value" ;;
        esac
    done < "$directory/sysctl.tsv"

    # all is a write trigger, not a safely replayable aggregate state. Replaying
    # even a historically observed value can delete IPv6 topology added after
    # capture. It remains in the snapshot for audit only and is never written.
    if [[ -n "$default_value" ]]; then ipv6_write_interface_value default "$default_value" || rc=1; fi
    while IFS=$'\t' read -r record iface value; do
        [[ "$record" == INTERFACE && "$iface" != default ]] || continue
        ipv6_write_interface_value "$iface" "$value" || rc=1
    done < "$directory/sysctl.tsv"
    return "$rc"
}

ipv6_restore_legacy_runtime() {
    local directory="$1" key value aggregate_key="" aggregate_value="" rc=0
    while IFS=$'\t' read -r key value; do
        [[ "$key" == net.ipv6.conf.all.disable_ipv6 ]] || continue
        aggregate_key="$key"; aggregate_value="$value"; break
    done < "$directory/sysctl.tsv"
    if [[ -n "$aggregate_key" ]] && ! sysctl -q -w "$aggregate_key=$aggregate_value"; then rc=1; fi
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" && "$key" != net.ipv6.conf.all.disable_ipv6 ]] || continue
        if ! sysctl -q -w "$key=$value"; then rc=1; fi
    done < "$directory/sysctl.tsv"
    return "$rc"
}

ipv6_restore_snapshot() {
    local directory="$1" context="${2:-baseline}" quality rc=0 interface_drift=0
    [[ "$context" == baseline || "$context" == transaction ]] || {
        die "无效的 IPv6 快照恢复上下文: $context"
        return 1
    }
    if ! ipv6_validate_snapshot "$directory"; then
        IPV6_LAST_RESTORE_QUALITY="malformed/invalid"
        die "IPv6 快照校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    fi
    quality=$(ipv6_snapshot_quality "$directory")
    IPV6_LAST_RESTORE_QUALITY="$quality"
    ipv6_restore_target_preflight "$directory" || return 1
    if ipv6_boot_disabled; then
        ipv6_restore_persistent_snapshot "$directory" || rc=1
        IPV6_LAST_RESTORE_QUALITY="persistent-only/reboot-required"
        log WARN "启动级 IPv6 禁用仍然生效；已恢复持久化文件，但运行时状态只能在修改启动配置并重启后恢复"
        return "$rc"
    fi
    if [[ "$quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$directory" &&
       ! ipv6_snapshot_interface_set_matches_current "$directory"; then
        IPV6_LAST_RESTORE_QUALITY="partial/interface-set-changed"
        if [[ "$context" == baseline ]]; then
            return 1
        fi
        interface_drift=1
    fi
    ipv6_restore_persistent_snapshot "$directory" || rc=1
    if ipv6_snapshot_is_v2 "$directory"; then
        ipv6_restore_v2_runtime "$directory" || rc=1
    else
        log WARN "旧 IPv6 基线没有逐接口原值；仅执行 best-effort 恢复，无法证明每张网卡都回到首次状态"
        ipv6_restore_legacy_runtime "$directory" || rc=1
        IPV6_LAST_RESTORE_QUALITY="legacy/partial-best-effort"
    fi
    (( interface_drift == 0 )) || rc=1
    return "$rc"
}

ipv6_capture_baseline() {
    local base="$IPV6_BACKUP_DIR/baseline" temp_dir
    # Existing baselines are immutable, including legacy/partial baselines. Their
    # reduced restore capability is reported, never hidden by recapturing current state.
    if [[ -e "$base" || -L "$base" ]]; then
        if ! ipv6_validate_snapshot "$base" 1; then
            die "现有 IPv6 基线损坏（${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}）；为避免覆盖首次基线，拒绝继续"
            return 1
        fi
        return 0
    fi
    ensure_state_layout || return 1
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    chmod 0700 "$IPV6_BACKUP_DIR" 2>/dev/null || true
    temp_dir=$(mktemp -d "${IPV6_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$temp_dir"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
    if ipv6_snapshot_has_routable_topology "$temp_dir"; then
        log ERR "IPv6 拓扑在基线捕获期间变为可路由状态；拒绝保存可能诱导不可恢复操作的基线"
        remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
    if
       ! { printf 'CREATED_AT\t%s\nCREATED_BY\t%s\n' "$(utc_now)" "$SCRIPT_VERSION"; cat "$temp_dir/snapshot.meta"; } > "$temp_dir/manifest" ||
       ! ipv6_validate_snapshot "$temp_dir" 1 ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
}

ipv6_pending_transaction() {
    local candidate
    for candidate in "$IPV6_BACKUP_DIR"/.transaction.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

ipv6_refuse_pending_transaction() {
    local pending
    if pending=$(ipv6_pending_transaction); then
        die "发现上次未完成的 IPv6 事务: $pending；为避免覆盖可审计的回滚现场，拒绝继续。请先人工核验并恢复或移走该目录"
        return 1
    fi
}

ipv6_transaction_begin() {
    local quality
    [[ -z "$IPV6_TRANSACTION_DIR" ]] || { die "已有未提交的 IPv6 事务"; return 1; }
    ipv6_refuse_pending_transaction || return 1
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    IPV6_TRANSACTION_DIR=$(mktemp -d "${IPV6_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$IPV6_TRANSACTION_DIR" || ! chmod -R go-rwx "$IPV6_TRANSACTION_DIR"; then
        remove_tree_within "$IPV6_TRANSACTION_DIR" "$IPV6_BACKUP_DIR" || true
        IPV6_TRANSACTION_DIR=""
        return 1
    fi
    quality=$(ipv6_snapshot_quality "$IPV6_TRANSACTION_DIR")
    if [[ "$quality" == legacy/partial-best-effort || "$quality" == malformed/invalid ]]; then
        die "IPv6 事务快照质量为 $quality；拒绝开始无法可靠回滚的修改"
        remove_tree_within "$IPV6_TRANSACTION_DIR" "$IPV6_BACKUP_DIR" || true
        IPV6_TRANSACTION_DIR=""
        return 1
    fi
}

ipv6_transaction_commit() {
    local directory="$IPV6_TRANSACTION_DIR"
    [[ -n "$directory" ]] || return 0
    IPV6_TRANSACTION_DIR=""
    remove_tree_within "$directory" "$IPV6_BACKUP_DIR" || log WARN "IPv6 已提交，但无法删除临时事务快照: $directory"
}

ipv6_transaction_rollback() {
    local directory="$IPV6_TRANSACTION_DIR" rc=0
    [[ -n "$directory" ]] || return 0
    ipv6_restore_snapshot "$directory" transaction || rc=1
    if (( rc == 0 )); then remove_tree_within "$directory" "$IPV6_BACKUP_DIR" || rc=1; fi
    if (( rc == 0 )); then
        IPV6_TRANSACTION_DIR=""
        log OK "已恢复本次 IPv6 操作前的逐接口 disable flags；地址和路由未作重放"
    else
        if [[ "$IPV6_LAST_RESTORE_QUALITY" == partial/interface-set-changed ]]; then
            log WARN "接口集合已变化：已尽力恢复持久策略、default 和仍存在的已捕获接口；新增接口保持当前值"
        fi
        log ERR "IPv6 自动回滚未完全成功；事务快照保留在 $directory"
    fi
    return "$rc"
}

ipv6_snapshot_interface_value() {
    local directory="$1" wanted="$2" record iface value
    while IFS=$'\t' read -r record iface value; do
        [[ "$record" == INTERFACE && "$iface" == "$wanted" ]] || continue
        printf '%s\n' "$value"
        return 0
    done < "$directory/sysctl.tsv"
    return 1
}

ipv6_disable_runtime_from_snapshot() {
    local directory="$1" record iface lo_before rc=0
    lo_before=$(ipv6_snapshot_interface_value "$directory" lo) || {
        die "IPv6 事务缺少 lo 原值"
        return 1
    }
    ipv6_write_interface_value default 1 || rc=1
    while IFS=$'\t' read -r record iface _; do
        [[ "$record" == INTERFACE ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        ipv6_write_interface_value "$iface" 1 || rc=1
    done < "$directory/sysctl.tsv"
    (( rc == 0 )) || return "$rc"

    [[ "$(ipv6_read_interface_value default 2>/dev/null || true)" == 1 ]] || {
        die "IPv6 默认接口策略禁用验证失败"
        return 1
    }
    while IFS=$'\t' read -r record iface _; do
        [[ "$record" == INTERFACE ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        [[ "$(ipv6_read_interface_value "$iface" 2>/dev/null || true)" == 1 ]] || {
            die "IPv6 禁用验证失败: $iface"
            return 1
        }
    done < "$directory/sysctl.tsv"
    [[ "$(ipv6_read_interface_value lo 2>/dev/null || true)" == "$lo_before" ]] || {
        die "IPv6 回环接口状态发生意外变化；拒绝提交"
        return 1
    }
}

ipv6_write_persistent_policy() {
    local snapshot="$1" temp record iface
    temp=$(mktemp) || return 1
    {
        printf '%s\n' '# Managed by bbrv3-lite' '# Policy: disabled-persistent' '# IPv6 is disabled per interface; lo/::1 is intentionally not modified.'
        printf '%s\n' 'net/ipv6/conf/default/disable_ipv6 = 1'
        while IFS=$'\t' read -r record iface _; do
            [[ "$record" == INTERFACE ]] || continue
            case "$iface" in all|default|lo) continue ;; esac
            printf 'net/ipv6/conf/%s/disable_ipv6 = 1\n' "$iface"
        done < "$snapshot/sysctl.tsv"
    } > "$temp"
    atomic_install "$temp" "$IPV6_SYSCTL_FILE" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

ipv6_disable_steps() {
    local mode="$1" snapshot="$2"
    ipv6_disable_runtime_from_snapshot "$snapshot" || { die "部分 IPv6 运行时值修改失败"; return 1; }
    if [[ "$mode" == permanent ]]; then
        ipv6_write_persistent_policy "$snapshot" || return 1
    else
        rm -f -- "$IPV6_SYSCTL_FILE" || return 1
    fi
}

ipv6_disable() {
    require_root || return 1; require_host_network_control || return 1
    acquire_lock || return 1; require_commands sysctl ip || return 1
    local mode="${1:-temporary}" rc rollback_rc=0 baseline_quality mode_label
    [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
    ipv6_refuse_pending_transaction || return 1
    ipv6_disable_preflight || return 1
    ipv6_capture_baseline || return 1
    baseline_quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
    if [[ "$baseline_quality" != disable-flags-exact ]]; then
        log WARN "现有 IPv6 基线为 $baseline_quality；disable flags 只能尽力恢复，地址和路由从不伪装可重放"
    fi
    ipv6_transaction_begin || return 1
    if ! ipv6_disable_topology_preflight; then
        # No runtime or persistent mutation has happened yet. Discarding the
        # transaction snapshot is safer than replaying flags over a topology that
        # may have appeared between the first preflight and this final gate.
        ipv6_transaction_commit
        return 1
    fi
    if ipv6_disable_steps "$mode" "$IPV6_TRANSACTION_DIR"; then
        ipv6_transaction_commit
        if [[ "$mode" == permanent ]]; then mode_label=永久; else mode_label=临时; fi
        log OK "IPv6 已${mode_label}禁用（保留 lo/::1）"
        return 0
    else
        rc=$?
    fi
    log WARN "IPv6 修改失败，正在恢复操作前状态"
    ipv6_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

ipv6_restore() {
    require_root || return 1; require_host_network_control || return 1
    acquire_lock || return 1; require_commands sysctl ip || return 1
    local base="$IPV6_BACKUP_DIR/baseline" rc rollback_rc=0 baseline_quality failed_quality
    ipv6_refuse_pending_transaction || return 1
    [[ -e "$base" && -d "$base" && ! -L "$base" ]] || { die "没有 IPv6 基线"; return 1; }
    if ! ipv6_validate_snapshot "$base" 1; then
        IPV6_LAST_RESTORE_QUALITY="malformed/invalid"
        die "IPv6 基线校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    fi
    baseline_quality=$(ipv6_snapshot_quality "$base" 1)
    # Run before creating the transaction snapshot or writing persistent/runtime
    # state. Any target=1 that could destroy current topology must fail closed.
    ipv6_restore_target_preflight "$base" || return 1
    if ! ipv6_boot_disabled && [[ "$baseline_quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$base" &&
       ! ipv6_snapshot_interface_set_matches_current "$base"; then
        IPV6_LAST_RESTORE_QUALITY="partial/interface-set-changed"
        return 1
    fi
    ipv6_transaction_begin || return 1
    if ! ipv6_restore_target_preflight "$base"; then
        # The first gate runs before any transaction/state mutation. Repeat
        # immediately before replay to catch topology appearing in that window;
        # no target state has been written, so discard rather than replay rollback.
        ipv6_transaction_commit
        return 1
    fi
    if ipv6_restore_snapshot "$base"; then
        ipv6_transaction_commit
        if [[ "$baseline_quality" == disable-flags-exact && "$IPV6_LAST_RESTORE_QUALITY" == disable-flags-exact ]]; then
            log OK "IPv6 disable flags 已按逐接口基线精确恢复；地址和路由仅保留诊断快照，不作重放"
        else
            log WARN "IPv6 disable flags 已按 $IPV6_LAST_RESTORE_QUALITY 恢复；无法宣称地址或路由已还原"
        fi
        return 0
    else
        rc=$?
        failed_quality="$IPV6_LAST_RESTORE_QUALITY"
    fi
    log WARN "IPv6 基线恢复失败（${failed_quality:-unknown}），正在恢复本次操作前状态"
    ipv6_transaction_rollback || rollback_rc=$?
    IPV6_LAST_RESTORE_QUALITY="${failed_quality:-unknown}"
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

ipv6_status() {
    local iface value boot_source ssh_family route_mode baseline_quality=absent list_file list_rc=0
    boot_source=$(ipv6_boot_disable_source || true)
    ssh_family=$(ipv6_ssh_family)
    route_mode=$(ipv6_default_route_mode)
    if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
        baseline_quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
    fi

    printf '%-48s %s\n' 'IPv6 boot-level disable' "$boot_source"
    printf '%-48s %s\n' 'Current SSH management path' "$ssh_family"
    printf '%-48s %s\n' 'Default-route families' "$route_mode"
    list_file=$(mktemp) || return 1
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else list_rc=$?; fi
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null || printf 'unavailable\n')
        case "$iface" in
            all) printf '%-48s %s\n' 'all write-trigger (observed; not aggregate state)' "$value" ;;
            default) printf '%-48s %s\n' 'new-interface default disable_ipv6' "$value" ;;
            lo) printf '%-48s %s\n' 'interface lo disable_ipv6' "$value" ;;
            *) printf '%-48s %s\n' "interface $iface disable_ipv6" "$value" ;;
        esac
    done < "$list_file"
    rm -f -- "$list_file"
    (( list_rc == 0 )) || printf '%-48s %s\n' 'Per-interface enumeration' 'partial/unavailable'
    printf '%-48s %s\n' 'bbrv3-lite persistent policy' "$([[ -f "$IPV6_SYSCTL_FILE" ]] && echo present || echo absent)"
    printf '%-48s %s\n' 'bbrv3-lite IPv6 baseline' "$baseline_quality"
}
