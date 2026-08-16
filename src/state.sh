# -----------------------------------------------------------------------------
# State and baseline: immutable provenance and scoped restoration.
# -----------------------------------------------------------------------------

ensure_state_layout() {
    mkdir -p -- "$STATE_DIR" "$HISTORY_DIR"
    chmod 0700 "$STATE_DIR" "$HISTORY_DIR" 2>/dev/null || true
    if [[ ! -f "$STATE_DIR/manifest" ]]; then
        local temp
        temp=$(mktemp) || return 1
        printf 'SCHEMA\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\n' "$STATE_SCHEMA" "$(utc_now)" "$SCRIPT_VERSION" > "$temp"
        atomic_install "$temp" "$STATE_DIR/manifest" 0600
        rm -f -- "$temp"
    fi
}

managed_artifacts_exist() {
    [[ -e "$CONFIG_FILE" || -e "$SYSCTL_FILE" || -e "$LEGACY_SYSCTL_FILE" || -e "$SERVICE_FILE" || -e "$LEGACY_SERVICE_FILE" ]]
}

import_legacy_baseline() {
    local iface="$1" temp_dir
    [[ -x "$PERSIST_SCRIPT" ]] || {
        die "找到旧备份，但没有可执行的旧版持久化脚本；请先用旧版本 restore，或显式 baseline adopt"
        return 1
    }
    temp_dir=$(mktemp -d "${STATE_DIR}/.baseline.XXXXXX") || return 1
    printf 'SCHEMA\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\nPROVENANCE\tlegacy-reference\nINTERFACE\t%s\n' \
        "$STATE_SCHEMA" "$(utc_now)" "$SCRIPT_VERSION" "$iface" > "$temp_dir/manifest"
    cp -a -- "$LEGACY_BACKUP_DIR" "$temp_dir/legacy-original"
    cp -a -- "$PERSIST_SCRIPT" "$temp_dir/legacy-tool.sh"
    capture_runtime_sysctls > "$temp_dir/migration-current-sysctl.tsv"
    tc qdisc show dev "$iface" > "$temp_dir/migration-current-qdisc.txt" 2>/dev/null || true
    chmod -R go-rwx "$temp_dir"
    mv "$temp_dir" "$BASELINE_DIR"
    log OK "已引用旧版原始备份并保存旧版恢复工具: $BASELINE_DIR"
}

backup_path() {
    local source="$1" name="$2"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$BASELINE_DIR/$name"
        printf 'present\n' > "$BASELINE_DIR/${name}.state"
    else
        printf 'absent\n' > "$BASELINE_DIR/${name}.state"
    fi
}

capture_runtime_sysctls() {
    local key value
    for key in \
        net.core.default_qdisc net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn \
        net.core.netdev_max_backlog; do
        value=$(sysctl -n "$key" 2>/dev/null || true)
        [[ -n "$value" ]] && printf '%s\t%s\n' "$key" "$value"
    done
}

capture_baseline() {
    local iface="$1" provenance="${2:-native}" temp_dir
    ensure_state_layout
    [[ ! -f "$BASELINE_DIR/manifest" ]] || return 0
    if managed_artifacts_exist && [[ "$provenance" != adopt-current ]]; then
        if [[ -d "$LEGACY_BACKUP_DIR" && -n "$(find "$LEGACY_BACKUP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            import_legacy_baseline "$iface"
            return
        else
            die "检测到已有调优配置但没有可信基线；请先恢复旧配置，或显式执行 baseline adopt"
            return 1
        fi
    fi
    temp_dir=$(mktemp -d "${STATE_DIR}/.baseline.XXXXXX") || return 1
    mkdir -p "$temp_dir/files"
    mv "$temp_dir" "$BASELINE_DIR"
    if ! {
        printf 'SCHEMA\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\nPROVENANCE\t%s\nINTERFACE\t%s\n' \
            "$STATE_SCHEMA" "$(utc_now)" "$SCRIPT_VERSION" "$provenance" "$iface" > "$BASELINE_DIR/manifest"
        capture_runtime_sysctls > "$BASELINE_DIR/sysctl.tsv"
        tc qdisc show dev "$iface" > "$BASELINE_DIR/qdisc.txt" 2>/dev/null || true
        tc class show dev "$iface" > "$BASELINE_DIR/class.txt" 2>/dev/null || true
        backup_path "$CONFIG_FILE" config
        backup_path "$SYSCTL_FILE" sysctl
        backup_path "$LEGACY_SYSCTL_FILE" legacy-sysctl
        backup_path "$SERVICE_FILE" service
        backup_path "$LEGACY_SERVICE_FILE" legacy-service
        chmod -R go-rwx "$BASELINE_DIR"
    }; then
        remove_tree_within "$BASELINE_DIR" "$STATE_DIR"
        return 1
    fi
    log OK "已保存不可覆盖的初始基线: $BASELINE_DIR ($provenance)"
}

baseline_adopt() {
    require_root; acquire_lock; require_commands ip tc sysctl
    local iface
    iface=$(detect_interface "${1:-auto}") || return 1
    [[ ! -e "$BASELINE_DIR" ]] || { die "基线已经存在，不会覆盖"; return 1; }
    capture_baseline "$iface" adopt-current
    log WARN "当前状态已被显式采用为基线；restore 只能回到此状态"
}

restore_backed_path() {
    local target="$1" name="$2" state
    [[ -f "$BASELINE_DIR/${name}.state" ]] || return 0
    state=$(<"$BASELINE_DIR/${name}.state")
    rm -f -- "$target"
    if [[ "$state" == present ]]; then cp -a -- "$BASELINE_DIR/$name" "$target"; fi
}

restore_runtime_sysctls() {
    local key value
    [[ -f "$BASELINE_DIR/sysctl.tsv" ]] || return 0
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] && sysctl -q -w "$key=$value" || true
    done < "$BASELINE_DIR/sysctl.tsv"
}

baseline_info() {
    if [[ -f "$BASELINE_DIR/manifest" ]]; then cat "$BASELINE_DIR/manifest"; else printf 'No baseline recorded.\n'; fi
}

baseline_provenance() {
    awk -F'\t' '$1=="PROVENANCE" {print $2; exit}' "$BASELINE_DIR/manifest" 2>/dev/null
}
