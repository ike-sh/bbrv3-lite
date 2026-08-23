# shellcheck shell=bash
# -----------------------------------------------------------------------------
# IPv6 policy engine: topology-aware planning and independently verifiable state.
# The executor in ipv6.sh owns all runtime/persistent mutations and transactions.
# -----------------------------------------------------------------------------

IPV6_POLICY_SCHEMA=1
IPV6_POLICY_REQUESTED=""
IPV6_POLICY_CURRENT=""
IPV6_POLICY_DECISION=""
IPV6_POLICY_ACTION=""
IPV6_POLICY_REASON=""
IPV6_POLICY_RISKS=""
IPV6_POLICY_BOOT=""
IPV6_POLICY_SSH=""
IPV6_POLICY_ROUTES=""
IPV6_POLICY_TOPOLOGY=""

ipv6_policy_normalize() {
    case "${1:-}" in
        native) printf 'native\n' ;;
        disabled-temporary|temporary) printf 'disabled-temporary\n' ;;
        disabled-persistent|permanent) printf 'disabled-persistent\n' ;;
        *)
            die "IPv6 policy 只支持 native/disabled-temporary/disabled-persistent（兼容别名: temporary/permanent）"
            return 1
            ;;
    esac
}

ipv6_project_policy_signature_kind() {
    local line normalized iface header=0 default_seen=0 non_lo=0 legacy_all=0 legacy_default=0 legacy_lo=0
    local -A seen=()
    [[ -f "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        normalized=${line%$'\r'}
        [[ -n "${normalized//[[:space:]]/}" ]] || continue
        if [[ "$normalized" =~ ^[[:space:]]*# ]]; then
            [[ "$normalized" == *"Managed by bbrv3-lite"* ]] && header=1
            continue
        fi
        if [[ "$normalized" =~ ^[[:space:]]*net/ipv6/conf/([-[:alnum:]_.:@+]+)/disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            ipv6_valid_interface_name "$iface" || return 1
            [[ -z "${seen[$iface]+x}" ]] || return 1
            seen["$iface"]=1
            case "$iface" in
                default) default_seen=1 ;;
                all|lo) return 1 ;;
                *) non_lo=$((non_lo + 1)) ;;
            esac
            continue
        fi
        if [[ "$normalized" =~ ^[[:space:]]*net[.]ipv6[.]conf[.](all|default|lo)[.]disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            case "$iface" in
                all) legacy_all=$((legacy_all + 1)) ;;
                default) legacy_default=$((legacy_default + 1)) ;;
                lo) legacy_lo=$((legacy_lo + 1)) ;;
            esac
            continue
        fi
        return 1
    done < "$IPV6_SYSCTL_FILE"
    (( header == 1 )) || return 1
    if (( default_seen == 1 && non_lo >= 1 && legacy_all == 0 && legacy_default == 0 && legacy_lo == 0 )); then
        printf 'interface-policy\n'
        return 0
    fi
    if (( default_seen == 0 && non_lo == 0 && legacy_all == 1 && legacy_default == 1 && legacy_lo == 1 )); then
        printf 'legacy-all-policy\n'
        return 0
    fi
    return 1
}

ipv6_policy_runtime_disabled() {
    local iface value list_file rc=0 non_lo=0
    list_file=$(mktemp) || return 2
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else rc=$?; fi
    (( rc == 0 )) || { rm -f -- "$list_file"; return 2; }
    value=$(ipv6_read_interface_value default 2>/dev/null) || { rm -f -- "$list_file"; return 2; }
    [[ "$value" == 1 ]] || { rm -f -- "$list_file"; return 1; }
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        non_lo=$((non_lo + 1))
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || { rm -f -- "$list_file"; return 2; }
        [[ "$value" == 1 ]] || { rm -f -- "$list_file"; return 1; }
    done < "$list_file"
    rm -f -- "$list_file"
    (( non_lo >= 1 )) || return 2
    return 0
}

ipv6_policy_persistent_interface_set_matches_current() {
    local line iface list_file rc=0 expected_count=0 current_count=0
    local -A expected=() current=()
    [[ -f "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*net/ipv6/conf/([-[:alnum:]_.:@+]+)/disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            case "$iface" in all|default|lo) continue ;; esac
            expected["$iface"]=1
            expected_count=$((expected_count + 1))
        fi
    done < "$IPV6_SYSCTL_FILE"
    list_file=$(mktemp) || return 1
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else rc=$?; fi
    (( rc == 0 )) || { rm -f -- "$list_file"; return 1; }
    while IFS= read -r iface; do
        case "$iface" in ''|all|default|lo) continue ;; esac
        current["$iface"]=1
        current_count=$((current_count + 1))
    done < "$list_file"
    rm -f -- "$list_file"
    (( expected_count == current_count )) || return 1
    for iface in "${!expected[@]}"; do [[ "${current[$iface]:-0}" == 1 ]] || return 1; done
}

ipv6_policy_detect_current() {
    local kind="" runtime_rc=0 baseline=0
    [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]] && baseline=1
    if [[ -e "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]]; then
        kind=$(ipv6_project_policy_signature_kind 2>/dev/null) || {
            printf 'foreign\n'
            return 0
        }
    fi
    if ipv6_policy_runtime_disabled; then runtime_rc=0; else runtime_rc=$?; fi
    case "$kind:$runtime_rc" in
        interface-policy:0)
            if ipv6_policy_persistent_interface_set_matches_current; then
                printf 'disabled-persistent\n'
            else
                printf 'disabled-persistent-drift\n'
            fi
            ;;
        interface-policy:*) printf 'disabled-persistent-drift\n' ;;
        legacy-all-policy:0) printf 'legacy-disabled-persistent\n' ;;
        legacy-all-policy:*) printf 'legacy-disabled-drift\n' ;;
        :0)
            if (( baseline )); then printf 'disabled-temporary\n'; else printf 'external-disabled\n'; fi
            ;;
        :1) printf 'native\n' ;;
        :2) printf 'unknown\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

ipv6_policy_compact_reason() {
    awk '
        NF {
            gsub(/\033\[[0-9;]*m/, "")
            gsub(/[[:space:]]+/, " ")
            sub(/^ /, ""); sub(/ $/, "")
            if (length($0)) {
                if (seen) printf "; "
                printf "%s", $0
                seen=1
            }
        }
        END { if (seen) printf "\n" }
    '
}

ipv6_policy_add_risk() {
    local risk="$1"
    [[ -n "$IPV6_POLICY_RISKS" ]] && IPV6_POLICY_RISKS+=","
    IPV6_POLICY_RISKS+="$risk"
}

ipv6_policy_block() {
    IPV6_POLICY_DECISION=blocked
    IPV6_POLICY_ACTION=none
    IPV6_POLICY_REASON="$1"
    return 1
}

ipv6_policy_collect() {
    local requested="${1:-disabled-temporary}" target output pending quality list_rc=0
    IPV6_POLICY_REQUESTED=""; IPV6_POLICY_CURRENT=""; IPV6_POLICY_DECISION=""
    IPV6_POLICY_ACTION=""; IPV6_POLICY_REASON=""; IPV6_POLICY_RISKS=""
    IPV6_POLICY_BOOT=$(ipv6_boot_disable_source 2>/dev/null || true); IPV6_POLICY_BOOT=${IPV6_POLICY_BOOT:-none}
    IPV6_POLICY_SSH=$(ipv6_ssh_family)
    IPV6_POLICY_ROUTES=$(ipv6_default_route_mode)
    IPV6_POLICY_TOPOLOGY=not-inspected

    target=$(ipv6_policy_normalize "$requested") || return 1
    IPV6_POLICY_REQUESTED="$target"
    IPV6_POLICY_CURRENT=$(ipv6_policy_detect_current) || IPV6_POLICY_CURRENT=unknown

    if pending=$(ipv6_pending_transaction 2>/dev/null); then
        ipv6_policy_block "存在未完成 IPv6 事务: ${pending//$'\t'/ }"
        return 1
    fi

    if [[ "$target" == native ]]; then
        if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
            ipv6_validate_snapshot "$IPV6_BACKUP_DIR/baseline" 1 || {
                ipv6_policy_block "IPv6 基线损坏或不完整: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
                return 1
            }
            quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
            if ! output=$(ipv6_restore_target_preflight "$IPV6_BACKUP_DIR/baseline" 2>&1); then
                output=$(ipv6_policy_compact_reason <<< "$output")
                IPV6_POLICY_TOPOLOGY=unsafe
                ipv6_policy_block "${output:-IPv6 基线恢复拓扑检查失败}"
                return 1
            fi
            if [[ "$IPV6_POLICY_BOOT" == none && "$quality" == disable-flags-exact ]] &&
               ipv6_snapshot_is_v2 "$IPV6_BACKUP_DIR/baseline" &&
               ! ipv6_snapshot_interface_set_matches_current "$IPV6_BACKUP_DIR/baseline" >/dev/null 2>&1; then
                IPV6_POLICY_TOPOLOGY='interface-set-drift'
                ipv6_policy_block "当前接口集合与首次可信 IPv6 基线不同；拒绝声称可精确恢复"
                return 1
            fi
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_TOPOLOGY='safe-for-restore'
            if [[ "$IPV6_POLICY_BOOT" != none ]]; then
                IPV6_POLICY_ACTION=restore-persistence-reboot-required
                IPV6_POLICY_REASON="启动级 IPv6 禁用仍生效；只恢复持久文件（质量: $quality），运行时需修改启动配置并重启"
                ipv6_policy_add_risk reboot-required
            else
                IPV6_POLICY_ACTION=restore-baseline
                IPV6_POLICY_REASON="恢复首次可信 disable flags 与持久文件（质量: $quality）；地址和路由只作诊断，不伪装可重放"
            fi
            [[ "$quality" == disable-flags-exact ]] || ipv6_policy_add_risk partial-legacy-baseline
            return 0
        fi
        case "$IPV6_POLICY_CURRENT" in
            disabled-persistent|disabled-persistent-drift|legacy-disabled-persistent|legacy-disabled-drift|disabled-temporary)
                ipv6_policy_block "检测到项目 IPv6 策略，但没有可验证基线；拒绝猜测原始 IPv6 状态"
                return 1
                ;;
        esac
        IPV6_POLICY_DECISION=noop
        IPV6_POLICY_ACTION=preserve-native
        IPV6_POLICY_REASON="没有项目基线或已管理策略；保持当前 IPv6 状态不变"
        return 0
    fi

    case "$IPV6_POLICY_CURRENT" in
        foreign)
            ipv6_policy_block "策略文件路径已被非本项目内容占用: $IPV6_SYSCTL_FILE"
            return 1
            ;;
        legacy-disabled-persistent|legacy-disabled-drift)
            ipv6_policy_block "检测到会修改 all/lo 的旧版 IPv6 策略；请先应用 native 恢复基线，再选择新的逐接口策略"
            return 1
            ;;
    esac
    command_exists ip || {
        ipv6_policy_block "缺少 ip 命令，不能审计 IPv6 地址和路由拓扑"
        return 1
    }
    if ipv6_list_runtime_interfaces >/dev/null 2>&1; then :; else list_rc=$?; fi
    (( list_rc == 0 )) || {
        ipv6_policy_block "无法获得完整的逐接口 IPv6 disable flags，拒绝生成不可精确恢复的策略"
        return 1
    }
    if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
        ipv6_validate_snapshot "$IPV6_BACKUP_DIR/baseline" 1 || {
            ipv6_policy_block "现有 IPv6 基线损坏或不完整: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
            return 1
        }
        quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
        [[ "$quality" == disable-flags-exact ]] || ipv6_policy_add_risk partial-legacy-baseline
    fi
    if ! output=$(ipv6_disable_preflight 2>&1); then
        output=$(ipv6_policy_compact_reason <<< "$output")
        IPV6_POLICY_TOPOLOGY=unsafe
        ipv6_policy_block "${output:-IPv6 拓扑安全检查失败}"
        return 1
    fi
    IPV6_POLICY_TOPOLOGY='safe-no-routable-ipv6'

    case "$target:$IPV6_POLICY_CURRENT" in
        disabled-temporary:disabled-temporary|disabled-persistent:disabled-persistent)
            IPV6_POLICY_DECISION=noop
            IPV6_POLICY_ACTION=verify-current
            IPV6_POLICY_REASON="当前策略已匹配；只执行独立一致性验证"
            ;;
        disabled-temporary:*)
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_ACTION=disable-runtime-remove-persistence
            IPV6_POLICY_REASON="逐接口临时禁用，保留 lo/::1；重启后由系统原生配置决定"
            ;;
        disabled-persistent:*)
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_ACTION=disable-runtime-install-persistence
            IPV6_POLICY_REASON="逐接口禁用并写入持久策略，保留 lo/::1"
            ipv6_policy_add_risk persistent-ipv6-disable
            ;;
    esac
    ipv6_policy_add_risk address-autoconfiguration-stops
    return 0
}

ipv6_policy_print_plan() {
    printf '%-22s %s\n' 'Policy module' 'IPv6'
    printf '%-22s %s\n' 'Requested policy' "${IPV6_POLICY_REQUESTED:-unknown}"
    printf '%-22s %s\n' 'Current policy' "${IPV6_POLICY_CURRENT:-unknown}"
    printf '%-22s %s\n' 'Decision' "${IPV6_POLICY_DECISION:-unknown}"
    printf '%-22s %s\n' 'Action' "${IPV6_POLICY_ACTION:-none}"
    printf '%-22s %s\n' 'Boot-level disable' "${IPV6_POLICY_BOOT:-unknown}"
    printf '%-22s %s\n' 'SSH path' "${IPV6_POLICY_SSH:-unknown}"
    printf '%-22s %s\n' 'Default routes' "${IPV6_POLICY_ROUTES:-unknown}"
    printf '%-22s %s\n' 'Topology gate' "${IPV6_POLICY_TOPOLOGY:-not-inspected}"
    printf '%-22s %s\n' 'Risks' "${IPV6_POLICY_RISKS:-none}"
    printf '%-22s %s\n' 'Reason' "${IPV6_POLICY_REASON:-none}"
    printf '%-22s %s\n' 'Plan mutation' 'none (read-only)'
}

ipv6_policy_plan() {
    local rc=0
    ipv6_policy_collect "${1:-disabled-temporary}" || rc=$?
    ipv6_policy_print_plan
    return "$rc"
}

ipv6_policy_persistent_matches_snapshot() {
    local directory="$1" state
    state=$(<"$directory/persistent.state") || return 1
    case "$state" in
        absent) [[ ! -e "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] ;;
        present)
            [[ -f "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]] || return 1
            cmp -s -- "$directory/persistent.conf" "$IPV6_SYSCTL_FILE"
            ;;
        *) return 1 ;;
    esac
}

ipv6_policy_runtime_matches_snapshot() {
    local directory="$1" quality record iface expected key value
    ipv6_validate_snapshot "$directory" 1 || return 1
    quality=$(ipv6_snapshot_quality "$directory" 1)
    if [[ "$quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$directory"; then
        ipv6_snapshot_interface_set_matches_current "$directory" || return 1
        while IFS=$'\t' read -r record iface expected; do
            [[ "$record" == INTERFACE ]] || continue
            value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || return 1
            [[ "$value" == "$expected" ]] || return 1
        done < "$directory/sysctl.tsv"
        return 0
    fi
    while IFS=$'\t' read -r key expected; do
        [[ "$key" == net.ipv6.conf.*.disable_ipv6 ]] || continue
        iface=${key#net.ipv6.conf.}; iface=${iface%.disable_ipv6}
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || return 1
        [[ "$value" == "$expected" ]] || return 1
    done < "$directory/sysctl.tsv"
}

ipv6_policy_verify() {
    local requested="${1:-}" target current base="$IPV6_BACKUP_DIR/baseline"
    if [[ -n "$requested" ]]; then
        target=$(ipv6_policy_normalize "$requested") || return 1
    else
        target=$(ipv6_policy_detect_current) || return 1
    fi
    current=$(ipv6_policy_detect_current) || return 1
    if [[ "$target" == native ]]; then
        if [[ -e "$base" || -L "$base" ]]; then
            ipv6_validate_snapshot "$base" 1 || {
                die "IPv6 native 验证失败：基线损坏"
                return 1
            }
            ipv6_policy_persistent_matches_snapshot "$base" || {
                die "IPv6 native 策略与首次可信 disable flags/持久文件不一致"
                return 1
            }
            if ipv6_boot_disabled; then
                log WARN "IPv6 native 持久状态已验证；启动级禁用仍生效，运行时需修改启动配置并重启后才能验证"
                return 0
            fi
            ipv6_policy_runtime_matches_snapshot "$base" || {
                die "IPv6 native 策略与首次可信 disable flags/持久文件不一致"
                return 1
            }
        else
            case "$current" in
                disabled-persistent|disabled-persistent-drift|legacy-disabled-persistent|legacy-disabled-drift|disabled-temporary)
                    die "IPv6 native 验证失败：存在项目策略但没有基线"
                    return 1
                    ;;
            esac
        fi
        log OK "IPv6 native 策略验证通过"
        return 0
    fi
    [[ "$target" == disabled-temporary || "$target" == disabled-persistent ]] || {
        die "当前 IPv6 状态不是可验证的规范策略: $target"
        return 1
    }

    [[ -e "$base" && -d "$base" && ! -L "$base" ]] && ipv6_validate_snapshot "$base" 1 || {
        die "IPv6 禁用策略缺少可验证基线"
        return 1
    }
    ipv6_policy_runtime_disabled || {
        die "IPv6 策略漂移：至少一个非回环接口或 default 未处于禁用状态"
        return 1
    }
    if [[ "$target" == disabled-persistent ]]; then
        [[ "$current" == disabled-persistent ]] || {
            die "IPv6 持久策略漂移: observed=$current"
            return 1
        }
    else
        [[ "$current" == disabled-temporary ]] || {
            die "IPv6 临时策略漂移: observed=$current"
            return 1
        }
        [[ ! -e "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || {
            die "IPv6 临时策略不应存在持久文件"
            return 1
        }
    fi
    log OK "IPv6 策略与运行时一致: $target"
}

ipv6_policy_apply() {
    local requested="${1:-disabled-temporary}" target mode rc=0
    target=$(ipv6_policy_normalize "$requested") || return 1
    ipv6_policy_collect "$target" || rc=$?
    ipv6_policy_print_plan
    (( rc == 0 )) || return "$rc"
    if [[ "$IPV6_POLICY_DECISION" == noop ]]; then
        if [[ "$target" == native ]]; then
            log OK "IPv6 native 策略无需修改"
            return 0
        fi
        ipv6_policy_verify "$target"
        return
    fi
    if [[ "$target" == native ]]; then
        ipv6_restore || return 1
        ipv6_policy_verify native
        return
    fi
    if [[ "$target" == disabled-persistent ]]; then mode=permanent; else mode=temporary; fi
    ipv6_disable "$mode" || return 1
    ipv6_policy_verify "$target"
}

ipv6_policy_status() {
    local current health
    current=$(ipv6_policy_detect_current 2>/dev/null || printf 'unknown\n')
    case "$current" in
        native|external-disabled) health='unmanaged/native' ;;
        disabled-temporary|disabled-persistent) health='structurally-consistent' ;;
        legacy-*) health='migration-required: restore native first' ;;
        *-drift) health='drift' ;;
        foreign) health='foreign policy file; not managed' ;;
        *) health='unavailable/unknown' ;;
    esac
    printf '%-48s %s\n' 'IPv6 policy schema' "$IPV6_POLICY_SCHEMA"
    printf '%-48s %s\n' 'IPv6 inferred policy' "$current"
    printf '%-48s %s\n' 'IPv6 policy health' "$health"
    ipv6_status
}
