# -----------------------------------------------------------------------------
# DNS: scoped systemd-resolved policy with immutable backup and action rollback.
# -----------------------------------------------------------------------------

DNS_DROPIN="${BBRV3_DNS_DROPIN:-/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf}"
DNS_RESOLV_CONF="${BBRV3_RESOLV_CONF:-/etc/resolv.conf}"
DNS_STUB_RESOLV="${BBRV3_DNS_STUB_RESOLV:-/run/systemd/resolve/stub-resolv.conf}"
DNS_FULL_RESOLV="${BBRV3_DNS_FULL_RESOLV:-/run/systemd/resolve/resolv.conf}"
DNS_TRANSACTION_DIR=""

dns_snapshot_path() {
    local source="$1" name="$2" state_name="$3" directory="$4"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$directory/$name" || return 1
        printf 'present\n' > "$directory/${state_name}.state" || return 1
    else
        printf 'absent\n' > "$directory/${state_name}.state" || return 1
    fi
}

dns_unit_enabled_state() {
    local state
    state=$(systemctl is-enabled systemd-resolved 2>/dev/null || true)
    case "$state" in
        enabled|enabled-runtime|linked|linked-runtime|alias|masked|masked-runtime|static|indirect|disabled|generated|transient|bad|not-found)
            printf '%s\n' "$state"
            ;;
        *) return 1 ;;
    esac
}

dns_unit_active_state() {
    local state
    state=$(systemctl is-active systemd-resolved 2>/dev/null || true)
    case "$state" in
        active|reloading|inactive|failed|activating|deactivating|maintenance|refreshing)
            printf '%s\n' "$state"
            ;;
        *) return 1 ;;
    esac
}

dns_unit_load_state() {
    local state
    state=$(systemctl show systemd-resolved --property=LoadState --value 2>/dev/null) || return 1
    case "$state" in
        loaded|error|masked|not-found|bad-setting|transient|stub|merged) printf '%s\n' "$state" ;;
        *) return 1 ;;
    esac
}

dns_snapshot_unit_state() {
    local directory="$1" enabled active load
    enabled=$(dns_unit_enabled_state) || return 1
    active=$(dns_unit_active_state) || return 1
    load=$(dns_unit_load_state) || return 1
    case "$enabled" in bad|not-found) return 1 ;; esac
    # A transient service state cannot be faithfully reconstructed during a
    # later rollback. Wait for it to settle instead of recording a lie.
    case "$active" in active|inactive) ;; *) return 1 ;; esac
    case "$load" in loaded|masked) ;; *) return 1 ;; esac
    case "$enabled" in
        masked|masked-runtime)
            [[ "$load" == masked ]] || return 1
            ;;
        *)
            [[ "$load" == loaded ]] || return 1
            ;;
    esac
    printf '%s\t%s\t%s\n' "$enabled" "$active" "$load" > "$directory/service.unit" || return 1
    # Retain the old file so older executables can still consume this baseline.
    printf '%s\n' "$active" > "$directory/service.active" || return 1
}

dns_snapshot_current() {
    local directory="$1"
    mkdir -p -- "$directory" || return 1
    dns_snapshot_path "$DNS_RESOLV_CONF" resolv.conf resolv "$directory" || return 1
    dns_snapshot_path "$DNS_DROPIN" dropin.conf dropin "$directory" || return 1
    dns_snapshot_unit_state "$directory" || return 1
}

dns_valid_unit_enabled_value() {
    case "$1" in
        enabled|enabled-runtime|linked|linked-runtime|alias|masked|masked-runtime|static|indirect|disabled|generated|transient) return 0 ;;
        *) return 1 ;;
    esac
}

dns_validate_snapshot() {
    local directory="$1" require_manifest="${2:-0}" name state enabled active load extra legacy_active
    local line key value require_unit=0 unit_lines snapshot_schema
    local -A manifest_fields=()
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    if (( require_manifest )); then
        [[ -f "$directory/manifest" && ! -L "$directory/manifest" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || return 1
            key="${line%%$'\t'*}"; value="${line#*$'\t'}"
            [[ -n "$key" && -n "$value" ]] || return 1
            [[ -z "${manifest_fields[$key]+x}" ]] || return 1
            case "$key" in CREATED_AT|CREATED_BY|SCHEMA|DNS_UNIT_LIFECYCLE) ;; *) return 1 ;; esac
            manifest_fields[$key]="$value"
        done < "$directory/manifest"
        [[ "${manifest_fields[CREATED_AT]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
        [[ "${manifest_fields[CREATED_BY]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || return 1
        if [[ -n "${manifest_fields[SCHEMA]:-}" || -n "${manifest_fields[DNS_UNIT_LIFECYCLE]:-}" ]]; then
            [[ "${manifest_fields[SCHEMA]:-}" == 2 && "${manifest_fields[DNS_UNIT_LIFECYCLE]:-}" == 1 ]] || return 1
            (( ${#manifest_fields[@]} == 4 )) || return 1
            require_unit=1
        else
            # v7.2.0 and earlier baselines only carried their creation fields.
            (( ${#manifest_fields[@]} == 2 )) || return 1
        fi
    fi
    if [[ -e "$directory/.snapshot.schema" || -L "$directory/.snapshot.schema" ]]; then
        [[ -f "$directory/.snapshot.schema" && ! -L "$directory/.snapshot.schema" ]] || return 1
        snapshot_schema=$(<"$directory/.snapshot.schema") || return 1
        [[ "$snapshot_schema" == 2 ]] || return 1
        require_unit=1
    fi
    for name in resolv dropin; do
        [[ -f "$directory/${name}.state" && ! -L "$directory/${name}.state" ]] || return 1
        state=$(<"$directory/${name}.state") || return 1
        case "$state" in
            present) [[ -f "$directory/${name}.conf" || -L "$directory/${name}.conf" ]] || return 1 ;;
            absent) [[ ! -e "$directory/${name}.conf" && ! -L "$directory/${name}.conf" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    [[ ! -L "$directory/service.unit" ]] || return 1
    if [[ -f "$directory/service.unit" ]]; then
        unit_lines=$(wc -l < "$directory/service.unit") || return 1
        (( unit_lines == 1 )) || return 1
        IFS=$'\t' read -r enabled active load extra < "$directory/service.unit" || return 1
        [[ -z "$extra" ]] || return 1
        dns_valid_unit_enabled_value "$enabled" || return 1
        [[ "$active" == active || "$active" == inactive ]] || return 1
        [[ "$load" == loaded || "$load" == masked ]] || return 1
        case "$enabled" in
            masked|masked-runtime) [[ "$load" == masked ]] || return 1 ;;
            *) [[ "$load" == loaded ]] || return 1 ;;
        esac
        [[ -f "$directory/service.active" && ! -L "$directory/service.active" ]] || return 1
        legacy_active=$(<"$directory/service.active") || return 1
        [[ "$legacy_active" == "$active" ]] || return 1
    else
        (( require_unit == 0 )) || return 1
        [[ -f "$directory/service.active" && ! -L "$directory/service.active" ]] || return 1
        legacy_active=$(<"$directory/service.active") || return 1
        [[ "$legacy_active" == active || "$legacy_active" == inactive ]] || return 1
    fi
}

dns_require_legacy_baseline_lifecycle_safety() {
    local base="$DNS_BACKUP_DIR/baseline" enabled
    [[ -e "$base" || -L "$base" ]] || return 0
    dns_validate_snapshot "$base" 1 || {
        die "现有 DNS 基线损坏或不完整，拒绝覆盖: $base"
        return 1
    }
    [[ ! -f "$base/service.unit" ]] || return 0
    enabled=$(dns_unit_enabled_state) || {
        die "无法读取 systemd-resolved unit-file 状态，旧 DNS 基线不具备安全恢复能力"
        return 1
    }
    case "$enabled" in
        disabled|enabled-runtime)
            die "旧 DNS 基线没有 unit-file 状态；本次操作需要把 systemd-resolved 从 $enabled 改为 enabled，拒绝修改"
            return 1
            ;;
    esac
}

dns_pending_transaction() {
    local candidate quality
    for candidate in "$DNS_BACKUP_DIR"/.transaction.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        if dns_validate_snapshot "$candidate" 0 >/dev/null 2>&1; then quality=valid; else quality=corrupt; fi
        printf '%s\t%s\n' "$quality" "$candidate"
        return 0
    done
    return 1
}

dns_refuse_pending_transaction() {
    local pending quality path
    if pending=$(dns_pending_transaction); then
        IFS=$'\t' read -r quality path <<< "$pending"
        die "发现未完成的 DNS 事务快照 ($quality): $path；拒绝叠加新操作，请先人工核对并恢复"
        return 1
    fi
}

dns_restore_unit_state() {
    local enabled="$1" active="$2" current_enabled current_active actual_enabled actual_active rc=0 active_handled=0

    current_enabled=$(dns_unit_enabled_state) || {
        log ERR "无法读取恢复前的 systemd-resolved unit-file 状态"
        return 1
    }
    current_active=$(dns_unit_active_state) || {
        log ERR "无法读取恢复前的 systemd-resolved active 状态"
        return 1
    }
    [[ "$current_active" == active || "$current_active" == inactive ]] || {
        log ERR "恢复前的 systemd-resolved active 状态尚未稳定: $current_active"
        return 1
    }

    case "$enabled" in
        masked|masked-runtime)
            if [[ "$current_enabled" == "$enabled" && "$active" == inactive ]]; then
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                active_handled=1
            else
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
                if [[ "$active" == active ]]; then
                    if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                elif ! systemctl stop systemd-resolved >/dev/null 2>&1; then
                    rc=1
                fi
                if [[ "$enabled" == masked-runtime ]]; then
                    if ! systemctl mask --runtime systemd-resolved >/dev/null 2>&1; then rc=1; fi
                elif ! systemctl mask systemd-resolved >/dev/null 2>&1; then
                    rc=1
                fi
                active_handled=1
            fi
            ;;
        enabled)
            if [[ "$current_enabled" != enabled ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl enable systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        enabled-runtime)
            if [[ "$current_enabled" != enabled-runtime ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
                if ! systemctl enable --runtime systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        disabled)
            if [[ "$current_enabled" != disabled ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        linked|linked-runtime|alias|static|indirect|generated|transient)
            # Apply refuses these states, so a normal transaction never has to
            # synthesize them. Unmasking can reveal an inherent static/alias
            # state; the exact postcondition check below catches anything else.
            case "$current_enabled" in
                masked|masked-runtime)
                    if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                    ;;
            esac
            ;;
        *)
            log ERR "DNS 快照包含无效 unit-file 状态: $enabled"
            return 1
            ;;
    esac

    if (( active_handled == 0 )); then
        case "$active" in
            active)
                if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            inactive)
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            *)
                log ERR "DNS 快照包含不可恢复的 active 状态: $active"
                return 1
                ;;
        esac
    fi

    actual_enabled=$(dns_unit_enabled_state 2>/dev/null) || actual_enabled='query-failed'
    actual_active=$(dns_unit_active_state 2>/dev/null) || actual_active='query-failed'
    if [[ "$actual_enabled" != "$enabled" ]]; then
        log ERR "systemd-resolved unit-file 恢复验证失败: expected=$enabled actual=$actual_enabled"
        rc=1
    fi
    if [[ "$actual_active" != "$active" ]]; then
        log ERR "systemd-resolved active 恢复验证失败: expected=$active actual=$actual_active"
        rc=1
    fi
    return "$rc"
}

dns_restore_snapshot() {
    local directory="$1" state enabled active load actual_active rc=0
    dns_validate_snapshot "$directory" 0 || {
        die "DNS 快照不完整: $directory"
        return 1
    }
    rm -f -- "$DNS_DROPIN" || rc=1
    state=$(<"$directory/dropin.state") || return 1
    if [[ "$state" == present ]]; then
        mkdir -p -- "$(dirname "$DNS_DROPIN")" || rc=1
        cp -a -- "$directory/dropin.conf" "$DNS_DROPIN" || rc=1
    fi
    rm -f -- "$DNS_RESOLV_CONF" || rc=1
    state=$(<"$directory/resolv.state") || return 1
    if [[ "$state" == present ]]; then cp -a -- "$directory/resolv.conf" "$DNS_RESOLV_CONF" || rc=1; fi

    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    if [[ -f "$directory/service.unit" ]]; then
        IFS=$'\t' read -r enabled active load < "$directory/service.unit" || return 1
        dns_restore_unit_state "$enabled" "$active" || rc=1
    else
        # Legacy baselines only captured whether the service was active.
        active=$(<"$directory/service.active") || return 1
        case "$active" in
            active)
                if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            inactive)
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
        esac
        actual_active=$(dns_unit_active_state 2>/dev/null) || actual_active='query-failed'
        if [[ "$actual_active" != "$active" ]]; then
            log ERR "旧 DNS 基线 active 恢复验证失败: expected=$active actual=$actual_active"
            rc=1
        fi
    fi
    return "$rc"
}

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" temp_dir
    if [[ -e "$base" || -L "$base" ]]; then
        dns_validate_snapshot "$base" 1 || {
            die "现有 DNS 基线损坏或不完整，拒绝覆盖: $base"
            return 1
        }
        return 0
    fi
    ensure_state_layout || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    chmod 0700 "$DNS_BACKUP_DIR" 2>/dev/null || true
    temp_dir=$(mktemp -d "${DNS_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! dns_snapshot_current "$temp_dir" ||
       ! dns_validate_snapshot "$temp_dir" 0 ||
       ! printf 'CREATED_AT\t%s\nCREATED_BY\t%s\nSCHEMA\t2\nDNS_UNIT_LIFECYCLE\t1\n' "$(utc_now)" "$SCRIPT_VERSION" > "$temp_dir/manifest" ||
       ! dns_validate_snapshot "$temp_dir" 1 ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$DNS_BACKUP_DIR" || true
        return 1
    fi
}

dns_transaction_begin() {
    [[ -z "$DNS_TRANSACTION_DIR" ]] || { die "已有未提交的 DNS 事务"; return 1; }
    dns_refuse_pending_transaction || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    DNS_TRANSACTION_DIR=$(mktemp -d "${DNS_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! dns_snapshot_current "$DNS_TRANSACTION_DIR" ||
       ! printf '2\n' > "$DNS_TRANSACTION_DIR/.snapshot.schema" ||
       ! dns_validate_snapshot "$DNS_TRANSACTION_DIR" 0 ||
       ! chmod -R go-rwx "$DNS_TRANSACTION_DIR"; then
        remove_tree_within "$DNS_TRANSACTION_DIR" "$DNS_BACKUP_DIR" || true
        DNS_TRANSACTION_DIR=""
        return 1
    fi
}

dns_transaction_commit() {
    local directory="$DNS_TRANSACTION_DIR"
    [[ -n "$directory" ]] || return 0
    DNS_TRANSACTION_DIR=""
    remove_tree_within "$directory" "$DNS_BACKUP_DIR" || log WARN "DNS 已提交，但无法删除临时事务快照: $directory"
}

dns_transaction_rollback() {
    local directory="$DNS_TRANSACTION_DIR" rc=0
    [[ -n "$directory" ]] || return 0
    dns_restore_snapshot "$directory" || rc=1
    if (( rc == 0 )); then
        remove_tree_within "$directory" "$DNS_BACKUP_DIR" || rc=1
    fi
    if (( rc == 0 )); then
        DNS_TRANSACTION_DIR=""
        log OK "已恢复本次 DNS 操作前状态"
    else
        log ERR "DNS 自动回滚未完全成功；事务快照保留在 $directory"
    fi
    return "$rc"
}

dns_normalized_link_target() {
    local target
    target=$(readlink "$DNS_RESOLV_CONF" 2>/dev/null) || return 1
    if [[ "$target" == /* ]]; then
        readlink -m -- "$target"
    else
        readlink -m -- "$(dirname "$DNS_RESOLV_CONF")/$target"
    fi
}

dns_project_dropin_signature_valid() {
    local content old_dot old_plain new_dot new_plain
    [[ -f "$DNS_DROPIN" && ! -L "$DNS_DROPIN" ]] || return 1
    content=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$DNS_DROPIN") || return 1
    old_dot=$'[Resolve]\nDNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net\nFallbackDNS=8.8.8.8#dns.google\nDomains=~.\nDNSOverTLS=yes\nDNSSEC=allow-downgrade'
    old_plain=$'[Resolve]\nDNS=1.1.1.1 9.9.9.9\nFallbackDNS=8.8.8.8\nDomains=~.\nDNSOverTLS=no\nDNSSEC=allow-downgrade'
    new_dot=$'[Resolve]\nDNS=\nFallbackDNS=\nDomains=\nDNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net\nFallbackDNS=8.8.8.8#dns.google 2001:4860:4860::8888#dns.google\nDomains=~.\nDNSOverTLS=yes\nDNSSEC=allow-downgrade'
    new_plain=$'[Resolve]\nDNS=\nFallbackDNS=\nDomains=\nDNS=1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe\nFallbackDNS=8.8.8.8 2001:4860:4860::8888\nDomains=~.\nDNSOverTLS=no\nDNSSEC=allow-downgrade'
    [[ "$content" == "$old_dot" || "$content" == "$old_plain" || "$content" == "$new_dot" || "$content" == "$new_plain" ]]
}

dns_resolver_owner() {
    local target stub full
    if [[ ! -e "$DNS_RESOLV_CONF" && ! -L "$DNS_RESOLV_CONF" ]]; then
        printf 'absent\n'
        return 0
    fi
    if [[ -L "$DNS_RESOLV_CONF" ]]; then
        target=$(dns_normalized_link_target 2>/dev/null || true)
        stub=$(readlink -m -- "$DNS_STUB_RESOLV")
        full=$(readlink -m -- "$DNS_FULL_RESOLV")
        case "$target" in
            "$stub"|"$full") printf 'systemd-resolved\n' ;;
            */run/NetworkManager/*) printf 'NetworkManager\n' ;;
            */run/resolvconf/*) printf 'resolvconf\n' ;;
            *) printf 'symlink:%s\n' "${target:-unknown}" ;;
        esac
        return 0
    fi
    if grep -Eiq 'NetworkManager' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'NetworkManager\n'
    elif grep -Eiq 'resolvconf|openresolv' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'resolvconf\n'
    elif grep -Eiq 'cloud-init' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'cloud-init\n'
    elif grep -Eiq 'systemd-resolved|stub-resolv[.]conf' "$DNS_RESOLV_CONF" 2>/dev/null; then
        # A copied stub is still a regular file: it is not updated atomically by
        # systemd-resolved and therefore does not prove resolver ownership.
        printf 'regular-file:systemd-marker\n'
    else
        printf 'regular-file\n'
    fi
}

dns_complex_routing_reason_from_domains() {
    local output="$1" line payload token section saw_global=0 saw_unknown=0 trimmed
    while IFS= read -r line; do
        trimmed=${line#"${line%%[![:space:]]*}"}
        [[ -n "$trimmed" ]] || continue
        case "$line" in
            Link\ *:*) section='link' ;;
            Global:*) section='global'; (( saw_global += 1 )) ;;
            *) saw_unknown=1; continue ;;
        esac
        payload=${line#*:}
        payload=${payload#"${payload%%[![:space:]]*}"}
        [[ -n "$payload" && "$payload" != none ]] || continue
        if [[ "$section" == link ]]; then
            printf '检测到 per-link DNS 域: %s' "$line"
            return 0
        fi
        for token in $payload; do
            # Empty assignments in the project drop-in deliberately replace
            # the global list with only ~. Any other global search or route-only
            # domain may be private and must block takeover.
            if [[ "$token" == '~.' ]] && dns_project_dropin_signature_valid; then continue; fi
            printf '检测到全局 DNS 域: %s' "$token"
            return 0
        done
    done <<< "$output"
    (( saw_global == 1 && saw_unknown == 0 )) || return 2
    return 1
}

dns_complex_routing_reason_from_status() {
    local output="$1" line context=unknown payload token saw_global=0 domain_continuation=0 trimmed
    while IFS= read -r line; do
        case "$line" in
            Global) context='global'; (( saw_global += 1 )); domain_continuation=0; continue ;;
            Link\ *) context='link'; domain_continuation=0; continue ;;
        esac
        trimmed=${line#"${line%%[![:space:]]*}"}
        if [[ "$trimmed" =~ ^DNS[[:space:]]+Domains?([[:space:]]*:[[:space:]]*|[[:space:]]+)(.*)$ ]]; then
            payload=${BASH_REMATCH[2]}
            domain_continuation=1
        elif (( domain_continuation )); then
            [[ -n "$trimmed" ]] || continue
            if [[ "$trimmed" =~ ^(Protocols|Current[[:space:]]+DNS[[:space:]]+Server|DNS[[:space:]]+Servers?|Fallback[[:space:]]+DNS[[:space:]]+Servers?|DNSSEC|DNSOverTLS|DefaultRoute|Current[[:space:]]+Scopes|LLMNR|MulticastDNS)([[:space:]:]|$) ]]; then
                domain_continuation=0
                continue
            fi
            payload=$trimmed
        else
            continue
        fi
        payload=${payload#"${payload%%[![:space:]]*}"}
        [[ -n "$payload" && "$payload" != none ]] || continue
        if [[ "$context" == unknown ]]; then
            return 2
        elif [[ "$context" == link ]]; then
            printf '检测到 per-link DNS 域: %s' "$payload"
            return 0
        fi
        for token in $payload; do
            if [[ "$token" == '~.' ]] && dns_project_dropin_signature_valid; then continue; fi
            printf '检测到全局 DNS 域: %s' "$token"
            return 0
        done
    done <<< "$output"
    (( saw_global == 1 )) || return 2
    return 1
}

dns_complex_routing_reason() {
    local output rc
    if output=$(LC_ALL=C resolvectl domain 2>/dev/null); then
        if dns_complex_routing_reason_from_domains "$output"; then return 0; else rc=$?; fi
        (( rc == 1 )) && return 1
    fi
    if output=$(LC_ALL=C resolvectl status 2>/dev/null); then
        if dns_complex_routing_reason_from_status "$output"; then return 0; else rc=$?; fi
        (( rc == 1 )) && return 1
    fi
    # First takeover fails closed when split-DNS cannot be inspected. Existing
    # project policy may enter its transaction path for repair/rollback.
    dns_project_dropin_signature_valid && return 2
    printf '无法读取 systemd-resolved 的 routing domains'
    return 0
}

dns_preflight_takeover() {
    local owner enabled active load reason routing_rc
    owner=$(dns_resolver_owner) || return 1
    enabled=$(dns_unit_enabled_state) || { die "无法读取 systemd-resolved unit-file 状态"; return 1; }
    active=$(dns_unit_active_state) || { die "无法读取 systemd-resolved active 状态"; return 1; }
    load=$(dns_unit_load_state) || { die "无法读取 systemd-resolved LoadState"; return 1; }

    case "$load" in
        loaded) ;;
        *) die "systemd-resolved 不可用（LoadState=$load）"; return 1 ;;
    esac
    case "$active" in
        active) ;;
        inactive)
            die "systemd-resolved 当前未运行；为避免 resolvectl 通过 D-Bus 自动激活并污染修改前基线，拒绝接管 DNS"
            return 1
            ;;
        *) die "systemd-resolved 状态尚未稳定: $active"; return 1 ;;
    esac
    case "$enabled" in
        masked|masked-runtime) die "systemd-resolved 已被屏蔽；拒绝自动解除屏蔽并接管 DNS"; return 1 ;;
        not-found|bad) die "无法确认 systemd-resolved 的持久化状态: $enabled"; return 1 ;;
        generated|transient) die "systemd-resolved unit 状态为 $enabled，不适合持久 DNS 接管"; return 1 ;;
        linked|linked-runtime|alias|static|indirect)
            die "systemd-resolved unit 状态为 $enabled，无法证明重启后会自动运行；拒绝把 resolv.conf 指向运行时 stub"
            return 1
            ;;
    esac
    case "$owner" in
        systemd-resolved|absent) ;;
        *)
            die "当前 resolv.conf 由 '$owner' 管理；仅支持接管 systemd-resolved，未作任何修改"
            return 1
            ;;
    esac
    if reason=$(dns_complex_routing_reason); then
        die "$reason；为保护 VPN/私有域/split DNS，拒绝设置全局 Domains=~."
        return 1
    else
        routing_rc=$?
        if (( routing_rc == 2 )); then
            log WARN "旧版项目 DNS 策略存在，但无法读取 routing domains；仅允许事务性修复，应用后仍会严格验证"
        fi
    fi
}

dns_prepare_resolved_service() {
    local enabled actual_enabled actual_active
    enabled=$(dns_unit_enabled_state) || { die "无法读取 systemd-resolved unit-file 状态"; return 1; }
    case "$enabled" in
        disabled|enabled-runtime)
            systemctl enable systemd-resolved >/dev/null || {
                die "无法持久启用 systemd-resolved；DNS 配置不会在重启后可靠生效"
                return 1
            }
            ;;
        enabled) ;;
        *) die "不支持的 systemd-resolved unit 状态: $enabled"; return 1 ;;
    esac
    systemctl restart systemd-resolved || { die "systemd-resolved 重启失败"; return 1; }
    actual_enabled=$(dns_unit_enabled_state) || { die "无法验证 systemd-resolved unit-file 状态"; return 1; }
    actual_active=$(dns_unit_active_state) || { die "无法验证 systemd-resolved active 状态"; return 1; }
    [[ "$actual_enabled" == enabled && "$actual_active" == active ]] || {
        die "systemd-resolved 生命周期验证失败: unit=$actual_enabled active=$actual_active"
        return 1
    }
}

dns_resolvectl_query() {
    local name="$1"
    if [[ $(type -t resolvectl) == function ]]; then
        LC_ALL=C resolvectl query "$name"
    else
        LC_ALL=C timeout 15 resolvectl query "$name"
    fi
}

dns_global_status_section() {
    awk '
        /^Global$/ { count++; in_global=(count == 1); next }
        /^Link [0-9]+/ { in_global=0; next }
        in_global { print }
        END { if (count != 1) exit 1 }
    '
}

dns_verify_applied_routing_domains() {
    local output reason global_line global_domains routing_rc
    output=$(LC_ALL=C resolvectl domain 2>/dev/null) || {
        die "应用后无法读取 routing domains；拒绝提交 DNS 策略"
        return 1
    }
    if reason=$(dns_complex_routing_reason_from_domains "$output"); then
        die "$reason；应用后 routing-domain 验证失败"
        return 1
    else
        routing_rc=$?
        if (( routing_rc != 1 )); then
            die "应用后的 routing-domain 输出无法可靠解析；拒绝提交 DNS 策略"
            return 1
        fi
    fi
    global_line=$(awk '/^Global:/ { print; exit }' <<< "$output")
    [[ -n "$global_line" ]] || { die "应用后缺少 Global DNS domain 状态"; return 1; }
    global_domains=${global_line#*:}
    global_domains=${global_domains#"${global_domains%%[![:space:]]*}"}
    [[ "$global_domains" == '~.' ]] || {
        die "应用后的 Global DNS domains 不是项目唯一的 ~.: ${global_domains:-empty}"
        return 1
    }
}

dns_verify_effective_global_servers() {
    local mode="$1" dns_output servers server global_count seen_cloudflare=0 seen_quad9=0
    dns_output=$(LC_ALL=C resolvectl dns 2>/dev/null) || {
        die "无法读取 effective Global DNS servers"
        return 1
    }
    global_count=$(grep -Ec '^Global:' <<< "$dns_output" || true)
    (( global_count == 1 )) || { die "effective DNS 状态必须且只能包含一个 Global 段"; return 1; }
    servers=$(awk '
        /^Global:/ {
            if (found) exit 2
            found=1
            sub(/^Global:[[:space:]]*/, "")
            if (length) printf "%s ", $0
            next
        }
        /^Link [0-9]+/ { if (found) exit; next }
        found && /^[[:space:]]+/ {
            sub(/^[[:space:]]+/, "")
            if (length) printf "%s ", $0
            next
        }
        found { exit }
        END { if (!found) exit 1 }
    ' <<< "$dns_output") || { die "effective DNS 状态缺少或无法解析 Global servers"; return 1; }
    servers=${servers% }
    [[ -n "$servers" ]] || { die "effective Global DNS servers 为空"; return 1; }
    for server in $servers; do
        if [[ "$mode" == dot ]]; then
            case "$server" in
                1.1.1.1#cloudflare-dns.com|1.1.1.1:53#cloudflare-dns.com|1.1.1.1:853#cloudflare-dns.com|2606:4700:4700::1111#cloudflare-dns.com|'[2606:4700:4700::1111]'#cloudflare-dns.com|'[2606:4700:4700::1111]':53#cloudflare-dns.com|'[2606:4700:4700::1111]':853#cloudflare-dns.com) seen_cloudflare=1 ;;
                9.9.9.9#dns.quad9.net|9.9.9.9:53#dns.quad9.net|9.9.9.9:853#dns.quad9.net|2620:fe::fe#dns.quad9.net|'[2620:fe::fe]'#dns.quad9.net|'[2620:fe::fe]':53#dns.quad9.net|'[2620:fe::fe]':853#dns.quad9.net) seen_quad9=1 ;;
                *) die "effective Global DoT servers 含有非项目上游: $server"; return 1 ;;
            esac
        else
            case "$server" in
                1.1.1.1|1.1.1.1:53|2606:4700:4700::1111|'[2606:4700:4700::1111]'|'[2606:4700:4700::1111]':53) seen_cloudflare=1 ;;
                9.9.9.9|9.9.9.9:53|2620:fe::fe|'[2620:fe::fe]'|'[2620:fe::fe]':53) seen_quad9=1 ;;
                *) die "effective Global DNS servers 含有非项目上游: $server"; return 1 ;;
            esac
        fi
    done
    (( seen_cloudflare == 1 && seen_quad9 == 1 )) || {
        die "effective Global DNS servers 缺少 Cloudflare 或 Quad9 上游: $servers"
        return 1
    }
}

dns_verify_effective_global_fallbacks() {
    local mode="$1" status global fallbacks server seen_google=0
    status=$(LC_ALL=C resolvectl status 2>/dev/null) || {
        die "无法读取 effective Global fallback DNS servers"
        return 1
    }
    global=$(dns_global_status_section <<< "$status") || {
        die "systemd-resolved 状态缺少 Global 段"
        return 1
    }
    fallbacks=$(awk '
        /^[[:space:]]*Fallback DNS Servers?([[:space:]]*:[[:space:]]*|[[:space:]]+)/ {
            if (found) exit 2
            found=1
            line=$0
            sub(/^[[:space:]]*Fallback DNS Servers?([[:space:]]*:[[:space:]]*|[[:space:]]+)/, "", line)
            if (length(line)) {
                if (line !~ /^([0-9]|\[)/) exit 2
                printf "%s ", line
            }
            collecting=1
            next
        }
        collecting {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (length(line) && line ~ /^([0-9]|\[)/) {
                printf "%s ", line
                next
            }
            exit
        }
        END { if (!found) exit 1 }
    ' <<< "$global") || {
        die "effective Global fallback DNS 状态缺失或无法解析"
        return 1
    }
    fallbacks=${fallbacks% }
    [[ -n "$fallbacks" ]] || { die "effective Global fallback DNS servers 为空"; return 1; }
    for server in $fallbacks; do
        if [[ "$mode" == dot ]]; then
            case "$server" in
                8.8.8.8#dns.google|8.8.8.8:53#dns.google|8.8.8.8:853#dns.google|2001:4860:4860::8888#dns.google|'[2001:4860:4860::8888]'#dns.google|'[2001:4860:4860::8888]':53#dns.google|'[2001:4860:4860::8888]':853#dns.google) seen_google=1 ;;
                *) die "effective Global DoT fallback 含有非项目上游: $server"; return 1 ;;
            esac
        else
            case "$server" in
                8.8.8.8|8.8.8.8:53|2001:4860:4860::8888|'[2001:4860:4860::8888]'|'[2001:4860:4860::8888]':53) seen_google=1 ;;
                *) die "effective Global DNS fallback 含有非项目上游: $server"; return 1 ;;
            esac
        fi
    done
    (( seen_google == 1 )) || { die "effective Global DNS fallback 缺少 Google 上游"; return 1; }
}

dns_verify_dot_global_status() {
    local status global
    status=$(LC_ALL=C resolvectl status 2>/dev/null) || {
        die "无法读取 systemd-resolved 状态，不能确认 DoT 已启用"
        return 1
    }
    global=$(dns_global_status_section <<< "$status") || {
        die "systemd-resolved 状态缺少 Global 段"
        return 1
    }
    grep -Eq '(^|[[:space:]])[+]DNSOverTLS([[:space:]]|$)|DNSOverTLS setting:[[:space:]]*yes' <<< "$global" || {
        die "systemd-resolved Global 段未报告 DNSOverTLS=yes"
        return 1
    }
    grep -Eq '(1[.]1[.]1[.]1(:53|:853)?|2606:4700:4700::1111|\[2606:4700:4700::1111\](:53|:853)?)#cloudflare-dns[.]com' <<< "$global" &&
        grep -Eq '(9[.]9[.]9[.]9(:53|:853)?|2620:fe::fe|\[2620:fe::fe\](:53|:853)?)#dns[.]quad9[.]net' <<< "$global" &&
        grep -Eq '(8[.]8[.]8[.]8(:53|:853)?|2001:4860:4860::8888|\[2001:4860:4860::8888\](:53|:853)?)#dns[.]google' <<< "$global" || {
        die "systemd-resolved Global 段未加载本项目的 DoT servers"
        return 1
    }
    grep -Eq 'DNS Domains?([[:space:]]*:[[:space:]]*|[[:space:]]+)~[.]([[:space:]]|$)' <<< "$global" || {
        die "systemd-resolved Global 段未加载项目的 Domains=~."
        return 1
    }

}

dns_verify_runtime() {
    local mode="$1" name query_output
    resolvectl flush-caches >/dev/null 2>&1 || true
    dns_verify_applied_routing_domains || return 1
    dns_verify_effective_global_servers "$mode" || return 1
    dns_verify_effective_global_fallbacks "$mode" || return 1
    if [[ "$mode" == dot ]]; then
        dns_verify_dot_global_status || return 1
    fi
    for name in example.com iana.org; do
        query_output=$(dns_resolvectl_query "$name" 2>/dev/null) || {
            if [[ "$mode" == dot ]]; then
                die "DoT 查询验证失败 ($name)；不会降级为普通公共 DNS"
            else
                die "DNS 查询验证失败 ($name)"
            fi
            return 1
        }
        if [[ "$mode" == dot ]] &&
           ! grep -Eiq 'Data was acquired via local or encrypted transport:[[:space:]]*yes' <<< "$query_output"; then
            die "DoT 查询缺少加密传输证据 ($name)；不会提交 DNS 策略"
            return 1
        fi
    done
}

dns_apply_steps() {
    local mode="$1" temp
    temp=$(mktemp) || return 1
    if [[ "$mode" == dot ]]; then
        cat > "$temp" <<'EOF' || { rm -f -- "$temp"; return 1; }
# Policy: strict-dot
[Resolve]
DNS=
FallbackDNS=
Domains=
DNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google 2001:4860:4860::8888#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
    else
        cat > "$temp" <<'EOF' || { rm -f -- "$temp"; return 1; }
# Policy: plain
[Resolve]
DNS=
FallbackDNS=
Domains=
DNS=1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe
FallbackDNS=8.8.8.8 2001:4860:4860::8888
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
    fi
    atomic_install "$temp" "$DNS_DROPIN" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    ln -sfn "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF" || { die "无法切换 resolv.conf"; return 1; }
    systemctl daemon-reload >/dev/null || { die "systemd 配置重载失败"; return 1; }
    dns_prepare_resolved_service || return 1
    dns_verify_runtime "$mode"
}

dns_apply() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl resolvectl timeout || return 1
    local mode="${1:-}" rc rollback_rc=0
    [[ "$mode" == dot || "$mode" == plain ]] || { die "内部 DNS mode 只支持 dot/plain"; return 1; }
    dns_refuse_pending_transaction || return 1
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_preflight_takeover || return 1
    dns_require_legacy_baseline_lifecycle_safety || return 1
    dns_capture_baseline || return 1
    dns_transaction_begin || return 1
    if dns_apply_steps "$mode"; then
        dns_transaction_commit
        if [[ "$mode" == dot ]]; then
            log OK "DNS 策略已应用: strict-dot"
        else
            log OK "DNS 策略已应用: plain"
        fi
        return 0
    else
        rc=$?
    fi
    log WARN "DNS 应用失败，正在恢复操作前状态"
    dns_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

dns_restore() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl || return 1
    local base="$DNS_BACKUP_DIR/baseline" rc rollback_rc=0
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_validate_snapshot "$base" 1 || { die "DNS 基线损坏或不完整: $base"; return 1; }
    dns_transaction_begin || return 1
    if dns_restore_snapshot "$base"; then
        dns_transaction_commit
        if [[ -f "$base/service.unit" ]]; then
            log OK "DNS 已恢复到首次修改前状态"
        else
            log WARN "DNS 文件与服务 active 状态已按旧基线恢复；旧基线未记录 unit-file 生命周期，enabled/masked 状态只能尽力保留"
        fi
        return 0
    else
        rc=$?
    fi
    log WARN "DNS 基线恢复失败，正在恢复本次操作前状态"
    dns_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

dns_status() {
    local owner enabled active routing="unavailable" reason routing_rc pending transaction="none"
    owner=$(dns_resolver_owner 2>/dev/null || printf 'unknown\n')
    if command_exists systemctl; then
        enabled=$(dns_unit_enabled_state 2>/dev/null) || enabled=unavailable
        active=$(dns_unit_active_state 2>/dev/null) || active=unavailable
    else
        enabled=unavailable
        active=unavailable
    fi
    if command_exists resolvectl; then
        if reason=$(dns_complex_routing_reason); then
            routing="complex ($reason)"
        else
            routing_rc=$?
            if (( routing_rc == 1 )); then routing=simple; else routing=unavailable; fi
        fi
    fi
    if pending=$(dns_pending_transaction); then transaction=${pending//$'\t'/': '}; fi
    printf 'Resolver owner: %s\n' "$owner"
    printf 'systemd-resolved: %s / %s\n' "$enabled" "$active"
    printf 'Routing domains: %s\n' "$routing"
    printf 'Pending transaction: %s\n' "$transaction"
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}
