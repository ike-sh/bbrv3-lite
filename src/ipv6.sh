# -----------------------------------------------------------------------------
# IPv6: explicit temporary/permanent disable with exact sysctl-value restore.
# -----------------------------------------------------------------------------

IPV6_SYSCTL_FILE="/etc/sysctl.d/99-bbrv3-lite-ipv6.conf"

ipv6_capture_baseline() {
    local base="$IPV6_BACKUP_DIR/baseline" key
    [[ -f "$base/sysctl.tsv" ]] && return 0
    mkdir -p "$base"
    for key in all default lo; do
        printf 'net.ipv6.conf.%s.disable_ipv6\t%s\n' "$key" "$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || echo 0)"
    done > "$base/sysctl.tsv"
    chmod -R go-rwx "$base"
}

ipv6_set_disabled() {
    local value="$1" key
    for key in all default lo; do sysctl -q -w "net.ipv6.conf.${key}.disable_ipv6=$value"; done
}

ipv6_disable() {
    require_root; acquire_lock; require_commands sysctl
    local mode="${1:-temporary}" temp
    [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
    ipv6_capture_baseline
    ipv6_set_disabled 1
    if [[ "$mode" == permanent ]]; then
        temp=$(mktemp) || return 1
        printf '%s\n' \
            '# Managed by bbrv3-lite' \
            'net.ipv6.conf.all.disable_ipv6 = 1' \
            'net.ipv6.conf.default.disable_ipv6 = 1' \
            'net.ipv6.conf.lo.disable_ipv6 = 1' > "$temp"
        atomic_install "$temp" "$IPV6_SYSCTL_FILE" 0644
        rm -f "$temp"
    fi
    log OK "IPv6 已${mode/temporary/临时}${mode/permanent/永久}禁用"
}

ipv6_restore() {
    require_root; acquire_lock
    local base="$IPV6_BACKUP_DIR/baseline" key value
    [[ -f "$base/sysctl.tsv" ]] || { die "没有 IPv6 基线"; return 1; }
    rm -f "$IPV6_SYSCTL_FILE"
    while IFS=$'\t' read -r key value; do sysctl -q -w "$key=$value" || true; done < "$base/sysctl.tsv"
    log OK "IPv6 已恢复到首次修改前状态"
}

ipv6_status() {
    local key
    for key in all default lo; do printf '%-42s %s\n' "net.ipv6.conf.${key}.disable_ipv6" "$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || echo unavailable)"; done
    printf '%-42s %s\n' "persistent file" "$([[ -f "$IPV6_SYSCTL_FILE" ]] && echo present || echo absent)"
}
