# -----------------------------------------------------------------------------
# DNS: scoped systemd-resolved policy with immutable backup and action rollback.
# -----------------------------------------------------------------------------

DNS_DROPIN="${BBRV3_DNS_DROPIN:-/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf}"
DNS_RESOLV_CONF="${BBRV3_RESOLV_CONF:-/etc/resolv.conf}"
DNS_STUB_RESOLV="${BBRV3_DNS_STUB_RESOLV:-/run/systemd/resolve/stub-resolv.conf}"
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

dns_snapshot_current() {
    local directory="$1" active
    mkdir -p -- "$directory" || return 1
    dns_snapshot_path "$DNS_RESOLV_CONF" resolv.conf resolv "$directory" || return 1
    dns_snapshot_path "$DNS_DROPIN" dropin.conf dropin "$directory" || return 1
    active=$(systemctl is-active systemd-resolved 2>/dev/null || true)
    printf '%s\n' "${active:-inactive}" > "$directory/service.active" || return 1
}

dns_restore_snapshot() {
    local directory="$1" state active rc=0
    [[ -f "$directory/resolv.state" && -f "$directory/dropin.state" ]] || {
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

    if [[ -f "$directory/service.active" ]]; then active=$(<"$directory/service.active"); else active=active; fi
    case "$active" in
        active|activating|reloading) systemctl restart systemd-resolved >/dev/null 2>&1 || rc=1 ;;
        *) systemctl stop systemd-resolved >/dev/null 2>&1 || true ;;
    esac
    return "$rc"
}

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" temp_dir
    [[ -f "$base/manifest" ]] && return 0
    ensure_state_layout || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    chmod 0700 "$DNS_BACKUP_DIR" 2>/dev/null || true
    if [[ -d "$base" ]]; then
        log WARN "清理上次中断留下的不完整 DNS 基线"
        remove_tree_within "$base" "$DNS_BACKUP_DIR" || return 1
    fi
    temp_dir=$(mktemp -d "${DNS_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! dns_snapshot_current "$temp_dir" ||
       ! printf 'CREATED_AT\t%s\nCREATED_BY\t%s\n' "$(utc_now)" "$SCRIPT_VERSION" > "$temp_dir/manifest" ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$DNS_BACKUP_DIR" || true
        return 1
    fi
}

dns_transaction_begin() {
    [[ -z "$DNS_TRANSACTION_DIR" ]] || { die "已有未提交的 DNS 事务"; return 1; }
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    DNS_TRANSACTION_DIR=$(mktemp -d "${DNS_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! dns_snapshot_current "$DNS_TRANSACTION_DIR" || ! chmod -R go-rwx "$DNS_TRANSACTION_DIR"; then
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

dns_apply_steps() {
    local mode="$1" temp
    temp=$(mktemp) || return 1
    if [[ "$mode" == dot ]]; then
        cat > "$temp" <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
    else
        cat > "$temp" <<'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=8.8.8.8
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
    fi
    atomic_install "$temp" "$DNS_DROPIN" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    ln -sfn "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF" || { die "无法切换 resolv.conf"; return 1; }
    systemctl restart systemd-resolved || { die "systemd-resolved 重启失败"; return 1; }
    resolvectl query example.com >/dev/null || { die "DNS 查询验证失败"; return 1; }
}

dns_apply() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl resolvectl timeout || return 1
    local mode="${1:-auto}" rc rollback_rc=0
    [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_capture_baseline || return 1
    if [[ "$mode" == auto ]]; then
        if peer_port_open 1.1.1.1 853 || peer_port_open 9.9.9.9 853; then
            mode="dot"
        else
            mode="plain"
            log WARN "公共 DoT 853 不可达，降级到普通 DNS 53"
        fi
    fi
    dns_transaction_begin || return 1
    if dns_apply_steps "$mode"; then
        dns_transaction_commit
        log OK "DNS 策略已应用: $mode"
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
    require_root || return 1; acquire_lock || return 1; require_commands systemctl || return 1
    local base="$DNS_BACKUP_DIR/baseline" rc rollback_rc=0
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_transaction_begin || return 1
    if dns_restore_snapshot "$base"; then
        dns_transaction_commit
        log OK "DNS 已恢复到首次修改前状态"
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
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}
