# -----------------------------------------------------------------------------
# DNS: scoped systemd-resolved policy with immutable backup and explicit restore.
# -----------------------------------------------------------------------------

DNS_DROPIN="/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf"

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline"
    [[ -f "$base/manifest" ]] && return 0
    [[ ! -d "$base" ]] || remove_tree_within "$base" "$DNS_BACKUP_DIR" || return 1
    mkdir -p "$base" || return 1
    if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then cp -a /etc/resolv.conf "$base/resolv.conf" || return 1; printf 'present\n' > "$base/resolv.state" || return 1; else printf 'absent\n' > "$base/resolv.state" || return 1; fi
    if [[ -e "$DNS_DROPIN" ]]; then cp -a "$DNS_DROPIN" "$base/dropin.conf" || return 1; printf 'present\n' > "$base/dropin.state" || return 1; else printf 'absent\n' > "$base/dropin.state" || return 1; fi
    printf 'CREATED_AT\t%s\n' "$(utc_now)" > "$base/manifest.pending" || return 1
    chmod -R go-rwx "$base" || return 1
    mv "$base/manifest.pending" "$base/manifest" || return 1
}

dns_restore_files() {
    local base="$DNS_BACKUP_DIR/baseline" state
    rm -f "$DNS_DROPIN"
    state=$(<"$base/dropin.state")
    [[ "$state" == present ]] && cp -a "$base/dropin.conf" "$DNS_DROPIN"
    rm -f /etc/resolv.conf
    state=$(<"$base/resolv.state")
    [[ "$state" == present ]] && cp -a "$base/resolv.conf" /etc/resolv.conf
    systemctl restart systemd-resolved 2>/dev/null || true
}

dns_apply() {
    require_root || return 1; acquire_lock || return 1; require_commands systemctl resolvectl timeout || return 1
    local mode="${1:-auto}" temp
    [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_capture_baseline || return 1
    if [[ "$mode" == auto ]]; then
        if peer_port_open 1.1.1.1 853; then mode="dot"; else mode="plain"; log WARN "DoT 853 不可达，降级到普通 DNS 53"; fi
    fi
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
    atomic_install "$temp" "$DNS_DROPIN" 0644 || { rm -f "$temp"; return 1; }
    rm -f "$temp"
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || return 1
    systemctl restart systemd-resolved || { dns_restore_files; die "systemd-resolved 重启失败，已恢复"; return 1; }
    if ! resolvectl query example.com >/dev/null; then
        dns_restore_files
        die "DNS 验证失败，已自动恢复修改前配置"
        return 1
    fi
    log OK "DNS 策略已应用: $mode"
}

dns_restore() {
    require_root || return 1; acquire_lock || return 1
    local base="$DNS_BACKUP_DIR/baseline"
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_restore_files || return 1
    log OK "DNS 已恢复到首次修改前状态"
}

dns_status() {
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink /etc/resolv.conf 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}
