# -----------------------------------------------------------------------------
# Persistence, legacy migration, restore and uninstall.
# -----------------------------------------------------------------------------

current_script_path() {
    local source="${BASH_SOURCE[0]}"
    case "$source" in /dev/fd/*|/proc/*/fd/*) die "不能从进程替换安装持久化副本；请先用 install-alias.sh 安装 bbr 命令"; return 1 ;; esac
    [[ -f "$source" ]] || return 1
    readlink -f "$source"
}

migrate_legacy_config() {
    local file="${1:-$CONFIG_FILE}" line key value
    [[ -f "$file" ]] || return 0
    if grep -q '^SCHEMA_VERSION=1$' "$file" && ! grep -q 'balanced-minimal' "$file"; then return 0; fi
    log INFO "迁移旧版配置: $file"
    reset_config
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        case "$key" in
            BBR_ENABLED|TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT|TC_BASELINE_MBIT|TC_PERCENT|INITCWND|INITRWND)
                case "$key" in
                    TC_BASELINE_MBIT) BANDWIDTH_MBIT="$value" ;;
                    TC_PERCENT) TC_MARGIN_PERCENT=$((100-value)); ((TC_MARGIN_PERCENT<0)) && TC_MARGIN_PERCENT=3 ;;
                    *) validate_config_value "$key" "$value" 2>/dev/null && printf -v "$key" '%s' "$value" ;;
                esac
                ;;
            SYSCTL_PROFILE) [[ "$value" == balanced-minimal || "$value" == balanced ]] && SYSCTL_PROFILE=balanced ;;
        esac
    done < "$file"
    save_config "$file"
}

install_persistence() {
    require_root; require_commands systemctl install
    local source temp_unit
    source=$(current_script_path) || { die "找不到当前单文件脚本，先运行 scripts/build.sh"; return 1; }
    mkdir -p -- "$PERSIST_DIR"
    install -m 0755 "$source" "$PERSIST_SCRIPT"
    temp_unit=$(mktemp) || return 1
    cat > "$temp_unit" <<EOF
[Unit]
Description=BBRv3 Lite measured TCP tuning
Documentation=${PROJECT_URL}
Wants=network-online.target
After=network-online.target
ConditionPathExists=${CONFIG_FILE}

[Service]
Type=oneshot
ExecStart=${PERSIST_SCRIPT} apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    atomic_install "$temp_unit" "$SERVICE_FILE" 0644
    rm -f -- "$temp_unit"
    if [[ "$LEGACY_SERVICE_FILE" != "$SERVICE_FILE" && -e "$LEGACY_SERVICE_FILE" ]]; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
        rm -f -- "$LEGACY_SERVICE_FILE"
    fi
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
}

remove_persistence() {
    if command_exists systemctl; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$SERVICE_FILE" "$PERSIST_SCRIPT"
    rmdir "$PERSIST_DIR" 2>/dev/null || true
    command_exists systemctl && systemctl daemon-reload || true
}

apply_configured_state() {
    require_root; acquire_lock
    load_config || return 1
    (( BBR_ENABLED == 1 )) || return 0
    apply_sysctl_profile || return 1
    local iface
    iface=$(detect_interface "$TC_INTERFACE") || return 1
    if (( TC_ENABLED == 1 )); then
        (( TC_RATE_MBIT > 0 )) || { die "TC_ENABLED=1 但 TC_RATE_MBIT=0"; return 1; }
        apply_shaping "$iface" "$TC_RATE_MBIT" || return 1
    else
        apply_fq "$iface" || return 1
    fi
    apply_initial_windows
}

install_base_tuning() {
    require_root; acquire_lock; require_commands ip tc sysctl modprobe systemctl
    local requested="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" iface
    iface=$(detect_interface "$requested") || return 1
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    load_config
    SYSCTL_PROFILE="$profile"; ROLE="$role"; BANDWIDTH_MBIT="$bandwidth"; RTT_MS="$rtt"
    BBR_ENABLED=1; TC_INTERFACE="$requested"
    validate_config_value SYSCTL_PROFILE "$SYSCTL_PROFILE" && validate_config_value ROLE "$ROLE" || { die "非法 profile/role"; return 1; }
    apply_sysctl_profile || return 1
    if (( TC_ENABLED == 1 && TC_RATE_MBIT > 0 )); then apply_shaping "$iface" "$TC_RATE_MBIT" || return 1; else apply_fq "$iface" || return 1; fi
    apply_initial_windows || return 1
    save_config
    install_persistence
    systemctl restart "$SERVICE_NAME"
    log OK "基础调优已安装: BBR + ${SYSCTL_PROFILE} + $( ((TC_ENABLED)) && echo 'HTB/FQ' || echo 'FQ' )"
}

restore_baseline_qdisc() {
    local iface kind
    iface=$(awk -F'\t' '$1=="INTERFACE" {print $2}' "$BASELINE_DIR/manifest" 2>/dev/null)
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] || return 0
    kind=$(awk '$1=="qdisc" && $0~/ root / {print $2; exit}' "$BASELINE_DIR/qdisc.txt" 2>/dev/null)
    restore_qdisc_text_snapshot "$iface" "$BASELINE_DIR/qdisc.txt" ||
        log WARN "基线 root qdisc 为 '$kind'，文本快照无法无损重放；已保留快照供人工恢复"
}

restore_baseline() {
    require_root; acquire_lock
    [[ -f "$BASELINE_DIR/manifest" ]] || { die "没有可恢复的基线"; return 1; }
    if [[ "$(baseline_provenance)" == legacy-reference ]]; then
        [[ -x "$BASELINE_DIR/legacy-tool.sh" ]] || { die "旧版恢复工具缺失，不能自动恢复"; return 1; }
        remove_persistence
        release_lock
        log INFO "将恢复操作交给迁移时保存的旧版本工具"
        bash "$BASELINE_DIR/legacy-tool.sh" restore || { die "旧版本恢复失败；旧备份仍在 $LEGACY_BACKUP_DIR"; return 1; }
        log OK "旧版可信基线恢复完成"
        return 0
    fi
    remove_persistence
    rm -f -- "$CONFIG_FILE" "$SYSCTL_FILE"
    restore_backed_path "$CONFIG_FILE" config
    restore_backed_path "$SYSCTL_FILE" sysctl
    restore_backed_path "$LEGACY_SYSCTL_FILE" legacy-sysctl
    restore_backed_path "$SERVICE_FILE" service
    restore_backed_path "$LEGACY_SERVICE_FILE" legacy-service
    restore_runtime_sysctls
    restore_baseline_qdisc
    systemctl daemon-reload 2>/dev/null || true
    log OK "已恢复首次可信基线；基线和测量历史仍保留在 $STATE_DIR"
}

uninstall_managed() {
    require_root; acquire_lock
    local purge="${1:-0}" iface="" resolved_state
    load_config || true
    iface=$(detect_interface "${TC_INTERFACE:-auto}" 2>/dev/null || true)
    [[ -n "$iface" ]] && managed_htb "$iface" && tc qdisc replace dev "$iface" root fq || true
    remove_persistence
    rm -f -- "$CONFIG_FILE" "$SYSCTL_FILE"
    if (( purge )); then
        resolved_state=$(readlink -m "$STATE_DIR")
        [[ "$resolved_state" == /var/lib/bbrv3-lite || "$resolved_state" == /tmp/bbrv3-lite-test-* ]] || { die "拒绝清理非标准状态目录: $resolved_state"; return 1; }
        rm -rf -- "$resolved_state"
        log WARN "已删除配置、服务和状态历史；基线不可恢复"
    else
        log OK "已卸载管理组件；基线和历史保留在 $STATE_DIR"
    fi
}

show_status() {
    local iface="" cc available profile_state service_state shaping=off
    load_config || return 1
    iface=$(detect_interface "$TC_INTERFACE" 2>/dev/null || true)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    profile_state=$([[ -f "$SYSCTL_FILE" ]] && echo installed || echo absent)
    service_state=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo disabled)
    printf '%-20s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-20s %s\n' "Kernel" "$(uname -r)"
    printf '%-20s %s\n' "Congestion control" "$cc (available: $available)"
    printf '%-20s %s\n' "Sysctl profile" "$SYSCTL_PROFILE ($profile_state)"
    printf '%-20s %s\n' "Persistence" "$service_state"
    printf '%-20s %s\n' "Config" "$CONFIG_FILE"
    printf '%-20s %s\n' "Baseline" "$([[ -f "$BASELINE_DIR/manifest" ]] && echo recorded || echo missing)"
    if [[ -n "$iface" ]]; then
        if managed_htb "$iface"; then shaping="$(managed_rate_mbit "$iface") Mbit"; fi
        printf '%-20s %s\n' "Interface" "$iface"
        printf '%-20s %s\n' "Root qdisc" "$(root_qdisc_kind "$iface")"
        printf '%-20s %s\n' "Shaping" "$shaping"
    fi
}
