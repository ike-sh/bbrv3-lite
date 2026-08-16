# -----------------------------------------------------------------------------
# IPv6: explicit temporary/permanent disable with action-level rollback.
# -----------------------------------------------------------------------------

IPV6_SYSCTL_FILE="${BBRV3_IPV6_SYSCTL_FILE:-/etc/sysctl.d/99-bbrv3-lite-ipv6.conf}"
IPV6_TRANSACTION_DIR=""

ipv6_snapshot_current() {
    local directory="$1" key value
    mkdir -p -- "$directory" || return 1
    : > "$directory/sysctl.tsv" || return 1
    for key in all default lo; do
        value=$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null) || {
            die "无法读取 IPv6 运行时状态: $key"
            return 1
        }
        printf 'net.ipv6.conf.%s.disable_ipv6\t%s\n' "$key" "$value" >> "$directory/sysctl.tsv" || return 1
    done
    if [[ -e "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]]; then
        cp -a -- "$IPV6_SYSCTL_FILE" "$directory/persistent.conf" || return 1
        printf 'present\n' > "$directory/persistent.state" || return 1
    else
        printf 'absent\n' > "$directory/persistent.state" || return 1
    fi
}

ipv6_restore_snapshot() {
    local directory="$1" key value state=absent rc=0
    [[ -f "$directory/sysctl.tsv" ]] || { die "IPv6 快照不完整: $directory"; return 1; }
    rm -f -- "$IPV6_SYSCTL_FILE" || rc=1
    if [[ -f "$directory/persistent.state" ]]; then state=$(<"$directory/persistent.state"); fi
    if [[ "$state" == present ]]; then
        mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")" || rc=1
        cp -a -- "$directory/persistent.conf" "$IPV6_SYSCTL_FILE" || rc=1
    fi
    while IFS=$'\t' read -r key value; do
        if [[ -n "$key" ]] && ! sysctl -q -w "$key=$value"; then rc=1; fi
    done < "$directory/sysctl.tsv"
    return "$rc"
}

ipv6_capture_baseline() {
    local base="$IPV6_BACKUP_DIR/baseline" temp_dir
    [[ -f "$base/sysctl.tsv" ]] && return 0
    ensure_state_layout || return 1
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    chmod 0700 "$IPV6_BACKUP_DIR" 2>/dev/null || true
    if [[ -d "$base" ]]; then
        log WARN "清理上次中断留下的不完整 IPv6 基线"
        remove_tree_within "$base" "$IPV6_BACKUP_DIR" || return 1
    fi
    temp_dir=$(mktemp -d "${IPV6_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$temp_dir" ||
       ! printf 'CREATED_AT\t%s\nCREATED_BY\t%s\n' "$(utc_now)" "$SCRIPT_VERSION" > "$temp_dir/manifest" ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
}

ipv6_transaction_begin() {
    [[ -z "$IPV6_TRANSACTION_DIR" ]] || { die "已有未提交的 IPv6 事务"; return 1; }
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    IPV6_TRANSACTION_DIR=$(mktemp -d "${IPV6_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$IPV6_TRANSACTION_DIR" || ! chmod -R go-rwx "$IPV6_TRANSACTION_DIR"; then
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
    ipv6_restore_snapshot "$directory" || rc=1
    if (( rc == 0 )); then remove_tree_within "$directory" "$IPV6_BACKUP_DIR" || rc=1; fi
    if (( rc == 0 )); then
        IPV6_TRANSACTION_DIR=""
        log OK "已恢复本次 IPv6 操作前状态"
    else
        log ERR "IPv6 自动回滚未完全成功；事务快照保留在 $directory"
    fi
    return "$rc"
}

ipv6_set_disabled() {
    local value="$1" key rc=0
    for key in all default lo; do
        sysctl -q -w "net.ipv6.conf.${key}.disable_ipv6=$value" || rc=1
    done
    return "$rc"
}

ipv6_verify_disabled() {
    local key value
    for key in all default lo; do
        value=$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || true)
        [[ "$value" == 1 ]] || { die "IPv6 禁用验证失败: $key=${value:-unavailable}"; return 1; }
    done
}

ipv6_disable_steps() {
    local mode="$1" temp
    ipv6_set_disabled 1 || { die "部分 IPv6 运行时值修改失败"; return 1; }
    if [[ "$mode" == permanent ]]; then
        temp=$(mktemp) || return 1
        printf '%s\n' \
            '# Managed by bbrv3-lite' \
            'net.ipv6.conf.all.disable_ipv6 = 1' \
            'net.ipv6.conf.default.disable_ipv6 = 1' \
            'net.ipv6.conf.lo.disable_ipv6 = 1' > "$temp"
        atomic_install "$temp" "$IPV6_SYSCTL_FILE" 0644 || { rm -f -- "$temp"; return 1; }
        rm -f -- "$temp"
    else
        rm -f -- "$IPV6_SYSCTL_FILE" || return 1
    fi
    ipv6_verify_disabled || return 1
}

ipv6_disable() {
    require_root || return 1; require_host_network_control || return 1
    acquire_lock || return 1; require_commands sysctl || return 1
    local mode="${1:-temporary}" rc rollback_rc=0
    [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
    ipv6_capture_baseline || return 1
    ipv6_transaction_begin || return 1
    if ipv6_disable_steps "$mode"; then
        ipv6_transaction_commit
        log OK "IPv6 已${mode/temporary/临时}${mode/permanent/永久}禁用"
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
    require_root || return 1; acquire_lock || return 1; require_commands sysctl || return 1
    local base="$IPV6_BACKUP_DIR/baseline" rc rollback_rc=0
    [[ -f "$base/sysctl.tsv" ]] || { die "没有 IPv6 基线"; return 1; }
    ipv6_transaction_begin || return 1
    if ipv6_restore_snapshot "$base"; then
        ipv6_transaction_commit
        log OK "IPv6 已恢复到首次修改前状态"
        return 0
    else
        rc=$?
    fi
    log WARN "IPv6 基线恢复失败，正在恢复本次操作前状态"
    ipv6_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

ipv6_status() {
    local key
    for key in all default lo; do printf '%-42s %s\n' "net.ipv6.conf.${key}.disable_ipv6" "$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || echo unavailable)"; done
    printf '%-42s %s\n' "bbrv3-lite persistent policy" "$([[ -f "$IPV6_SYSCTL_FILE" ]] && echo present || echo absent)"
    printf '%-42s %s\n' "bbrv3-lite IPv6 baseline" "$([[ -f "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" ]] && echo recorded || echo absent)"
}
