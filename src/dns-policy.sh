# shellcheck shell=bash
# -----------------------------------------------------------------------------
# DNS policy engine: read-only planning, canonical policy names and verification.
# The executor in dns.sh remains the only code allowed to mutate resolver state.
# -----------------------------------------------------------------------------

DNS_POLICY_SCHEMA=1
DNS_POLICY_REQUESTED=""
DNS_POLICY_CURRENT=""
DNS_POLICY_DECISION=""
DNS_POLICY_ACTION=""
DNS_POLICY_REASON=""
DNS_POLICY_RISKS=""
DNS_POLICY_OWNER=""
DNS_POLICY_UNIT=""
DNS_POLICY_ROUTING=""

dns_policy_normalize() {
    case "${1:-}" in
        native) printf 'native\n' ;;
        strict-dot|dot|auto) printf 'strict-dot\n' ;;
        plain) printf 'plain\n' ;;
        *)
            die "DNS policy 只支持 native/strict-dot/plain（兼容别名: auto/dot）"
            return 1
            ;;
    esac
}

dns_policy_detect_current() {
    local dot_value
    if [[ ! -e "$DNS_DROPIN" && ! -L "$DNS_DROPIN" ]]; then
        printf 'native\n'
        return 0
    fi
    dns_project_dropin_signature_valid || {
        printf 'foreign\n'
        return 0
    }
    dot_value=$(awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*DNSOverTLS[[:space:]]*=/ {
            value=$2
            gsub(/[[:space:]]/, "", value)
            print tolower(value)
            exit
        }
    ' "$DNS_DROPIN" 2>/dev/null) || return 1
    case "$dot_value" in
        yes) printf 'strict-dot\n' ;;
        no) printf 'plain\n' ;;
        *) printf 'foreign\n' ;;
    esac
}

dns_policy_compact_reason() {
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

dns_policy_add_risk() {
    local risk="$1"
    [[ -n "$DNS_POLICY_RISKS" ]] && DNS_POLICY_RISKS+=","
    DNS_POLICY_RISKS+="$risk"
}

dns_policy_block() {
    DNS_POLICY_DECISION=blocked
    DNS_POLICY_ACTION=none
    DNS_POLICY_REASON="$1"
    return 1
}

dns_policy_collect() {
    local requested="${1:-strict-dot}" target output pending enabled active routing_reason routing_rc
    DNS_POLICY_REQUESTED=""; DNS_POLICY_CURRENT=""; DNS_POLICY_DECISION=""
    DNS_POLICY_ACTION=""; DNS_POLICY_REASON=""; DNS_POLICY_RISKS=""
    DNS_POLICY_OWNER=unavailable; DNS_POLICY_UNIT=unavailable; DNS_POLICY_ROUTING=unavailable

    target=$(dns_policy_normalize "$requested") || return 1
    DNS_POLICY_REQUESTED="$target"
    DNS_POLICY_CURRENT=$(dns_policy_detect_current) || DNS_POLICY_CURRENT=unknown
    DNS_POLICY_OWNER=$(dns_resolver_owner 2>/dev/null || printf 'unavailable\n')

    if command_exists systemctl; then
        enabled=$(dns_unit_enabled_state 2>/dev/null || printf 'unavailable\n')
        active=$(dns_unit_active_state 2>/dev/null || printf 'unavailable\n')
        DNS_POLICY_UNIT="$enabled/$active"
    fi
    if command_exists resolvectl; then
        if routing_reason=$(dns_complex_routing_reason 2>/dev/null); then
            DNS_POLICY_ROUTING="complex: $routing_reason"
        else
            routing_rc=$?
            if (( routing_rc == 1 )); then DNS_POLICY_ROUTING=simple; else DNS_POLICY_ROUTING=unavailable; fi
        fi
    fi

    if pending=$(dns_pending_transaction 2>/dev/null); then
        dns_policy_block "存在未完成 DNS 事务: ${pending//$'\t'/ }"
        return 1
    fi

    if [[ "$target" == native ]]; then
        if [[ -e "$DNS_BACKUP_DIR/baseline" || -L "$DNS_BACKUP_DIR/baseline" ]]; then
            dns_validate_snapshot "$DNS_BACKUP_DIR/baseline" 1 || {
                dns_policy_block "DNS 基线损坏或不完整，不能安全恢复"
                return 1
            }
            DNS_POLICY_DECISION=ready
            DNS_POLICY_ACTION=restore-baseline
            DNS_POLICY_REASON="恢复首次可信 DNS 基线；不推测或重建原解析器配置"
            return 0
        fi
        if [[ "$DNS_POLICY_CURRENT" == strict-dot || "$DNS_POLICY_CURRENT" == plain ]]; then
            dns_policy_block "检测到项目 DNS 策略，但没有可验证基线；拒绝猜测原始 DNS 状态"
            return 1
        fi
        DNS_POLICY_DECISION=noop
        DNS_POLICY_ACTION=preserve-native
        DNS_POLICY_REASON="没有项目基线或已管理策略；保持现有解析器不变"
        return 0
    fi
    if [[ "$DNS_POLICY_CURRENT" == foreign ]]; then
        dns_policy_block "策略文件路径已被非本项目内容占用: $DNS_DROPIN"
        return 1
    fi
    command_exists systemctl && command_exists resolvectl || {
        dns_policy_block "缺少 systemctl/resolvectl，不能管理 systemd-resolved"
        return 1
    }
    if ! output=$(systemctl cat systemd-resolved 2>&1); then
        dns_policy_block "系统未提供 systemd-resolved"
        return 1
    fi
    if ! output=$(dns_preflight_takeover 2>&1); then
        output=$(dns_policy_compact_reason <<< "$output")
        dns_policy_block "${output:-DNS 接管安全检查失败}"
        return 1
    fi
    if ! output=$(dns_require_legacy_baseline_lifecycle_safety 2>&1); then
        output=$(dns_policy_compact_reason <<< "$output")
        dns_policy_block "${output:-旧 DNS 基线缺少安全生命周期信息}"
        return 1
    fi

    DNS_POLICY_DECISION=ready
    if [[ "$DNS_POLICY_CURRENT" == "$target" ]]; then
        DNS_POLICY_ACTION=verify-and-repair
        DNS_POLICY_REASON="策略文件已匹配；仍将事务性重载并执行真实查询验证"
    elif [[ "$target" == strict-dot ]]; then
        DNS_POLICY_ACTION=install-strict-dot
        DNS_POLICY_REASON="配置经认证 DoT；任何验证失败都会恢复操作前状态，不降级"
    else
        DNS_POLICY_ACTION=install-plain
        DNS_POLICY_REASON="显式配置普通公共 DNS；不会由 strict-dot 自动降级到该策略"
        dns_policy_add_risk plaintext-dns
    fi
    [[ "$DNS_POLICY_OWNER" == absent ]] && dns_policy_add_risk create-resolver-owner
    [[ "$DNS_POLICY_UNIT" == disabled/active || "$DNS_POLICY_UNIT" == enabled-runtime/active ]] &&
        dns_policy_add_risk persist-systemd-resolved
    return 0
}

dns_policy_print_plan() {
    printf '%-20s %s\n' 'Policy module' 'DNS'
    printf '%-20s %s\n' 'Requested policy' "${DNS_POLICY_REQUESTED:-unknown}"
    printf '%-20s %s\n' 'Current policy' "${DNS_POLICY_CURRENT:-unknown}"
    printf '%-20s %s\n' 'Decision' "${DNS_POLICY_DECISION:-unknown}"
    printf '%-20s %s\n' 'Action' "${DNS_POLICY_ACTION:-none}"
    printf '%-20s %s\n' 'Resolver owner' "${DNS_POLICY_OWNER:-unavailable}"
    printf '%-20s %s\n' 'Resolved lifecycle' "${DNS_POLICY_UNIT:-unavailable}"
    printf '%-20s %s\n' 'Routing domains' "${DNS_POLICY_ROUTING:-unavailable}"
    printf '%-20s %s\n' 'Risks' "${DNS_POLICY_RISKS:-none}"
    printf '%-20s %s\n' 'Reason' "${DNS_POLICY_REASON:-none}"
    printf '%-20s %s\n' 'Plan mutation' 'none (read-only)'
}

dns_policy_plan() {
    local rc=0
    dns_policy_collect "${1:-strict-dot}" || rc=$?
    dns_policy_print_plan
    return "$rc"
}

dns_policy_snapshot_object_matches() {
    local left="$1" right="$2"
    if [[ -L "$left" || -L "$right" ]]; then
        [[ -L "$left" && -L "$right" ]] || return 1
        [[ "$(readlink "$left")" == "$(readlink "$right")" ]]
    else
        [[ -f "$left" && -f "$right" ]] || return 1
        cmp -s -- "$left" "$right"
    fi
}

dns_policy_native_matches_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" state name temp rc=0
    dns_validate_snapshot "$base" 1 || return 1
    temp=$(mktemp -d) || return 1
    if ! dns_snapshot_current "$temp" || ! dns_validate_snapshot "$temp" 0; then
        rm -rf -- "$temp"
        return 1
    fi
    for name in resolv dropin; do
        cmp -s -- "$base/${name}.state" "$temp/${name}.state" || { rc=1; continue; }
        state=$(<"$base/${name}.state") || { rc=1; continue; }
        if [[ "$state" == present ]]; then
            dns_policy_snapshot_object_matches "$base/${name}.conf" "$temp/${name}.conf" || rc=1
        fi
    done
    if [[ -f "$base/service.unit" ]]; then
        cmp -s -- "$base/service.unit" "$temp/service.unit" || rc=1
    else
        cmp -s -- "$base/service.active" "$temp/service.active" || rc=1
    fi
    rm -rf -- "$temp"
    return "$rc"
}

dns_policy_verify() {
    local requested="${1:-}" target current owner enabled active base="$DNS_BACKUP_DIR/baseline"
    if [[ -n "$requested" ]]; then
        target=$(dns_policy_normalize "$requested") || return 1
    else
        target=$(dns_policy_detect_current) || return 1
    fi
    current=$(dns_policy_detect_current) || return 1
    if [[ "$target" == native ]]; then
        if [[ -e "$base" || -L "$base" ]]; then
            dns_policy_native_matches_baseline || {
                die "DNS native 策略与首次可信文件/服务生命周期基线不一致"
                return 1
            }
        elif [[ "$current" != native ]]; then
            die "DNS native 策略无法验证: observed=$current 且没有可信基线"
            return 1
        fi
        log OK "DNS native 策略验证通过：项目未接管当前解析器"
        return 0
    fi
    [[ "$target" == strict-dot || "$target" == plain ]] || {
        die "当前 DNS 状态不是可验证的规范策略: $target"
        return 1
    }
    [[ "$current" == "$target" ]] || {
        die "DNS 策略漂移: expected=$target observed=$current"
        return 1
    }

    require_commands systemctl resolvectl timeout || return 1
    owner=$(dns_resolver_owner) || return 1
    enabled=$(dns_unit_enabled_state) || return 1
    active=$(dns_unit_active_state) || return 1
    [[ "$owner" == systemd-resolved && "$enabled" == enabled && "$active" == active ]] || {
        die "DNS 运行时漂移: owner=$owner unit=$enabled/$active"
        return 1
    }
    if [[ "$target" == strict-dot ]]; then
        dns_verify_runtime dot || return 1
    else
        dns_verify_runtime plain || return 1
    fi
    log OK "DNS 策略与运行时一致: $target"
}

dns_policy_apply() {
    local requested="${1:-strict-dot}" target rc=0
    target=$(dns_policy_normalize "$requested") || return 1
    dns_policy_collect "$target" || rc=$?
    dns_policy_print_plan
    (( rc == 0 )) || return "$rc"
    if [[ "$DNS_POLICY_DECISION" == noop ]]; then
        log OK "DNS native 策略无需修改"
        return 0
    fi
    if [[ "$target" == native ]]; then
        dns_restore || return 1
        dns_policy_verify native
    elif [[ "$target" == strict-dot ]]; then
        dns_apply dot || return 1
        [[ "$(dns_policy_detect_current)" == strict-dot ]] || {
            die "DNS 提交后策略识别失败"
            return 1
        }
    else
        dns_apply plain || return 1
        [[ "$(dns_policy_detect_current)" == plain ]] || {
            die "DNS 提交后策略识别失败"
            return 1
        }
    fi
}

dns_policy_status() {
    local current owner enabled active health=unmanaged
    current=$(dns_policy_detect_current 2>/dev/null || printf 'unknown\n')
    owner=$(dns_resolver_owner 2>/dev/null || printf 'unavailable\n')
    enabled=$(dns_unit_enabled_state 2>/dev/null || printf 'unavailable\n')
    active=$(dns_unit_active_state 2>/dev/null || printf 'unavailable\n')
    if [[ "$current" == strict-dot || "$current" == plain ]]; then
        if [[ "$owner" == systemd-resolved && "$enabled" == enabled && "$active" == active ]]; then
            health='structurally-consistent; run dns verify for live-query proof'
        else
            health="drift ($owner, $enabled/$active)"
        fi
    elif [[ "$current" == foreign ]]; then
        health='foreign policy file; not managed'
    fi
    printf '%-24s %s\n' 'DNS policy schema' "$DNS_POLICY_SCHEMA"
    printf '%-24s %s\n' 'DNS inferred policy' "$current"
    printf '%-24s %s\n' 'DNS policy health' "$health"
    dns_status
}
