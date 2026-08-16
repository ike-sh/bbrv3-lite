# -----------------------------------------------------------------------------
# Persistence, legacy migration, restore and uninstall.
# -----------------------------------------------------------------------------

current_script_path() {
    local source="${BASH_SOURCE[0]}"
    case "$source" in /dev/fd/*|/proc/*/fd/*) return 1 ;; esac
    [[ -f "$source" ]] || return 1
    readlink -f "$source"
}

verified_download_current_script() {
    local target="$1" base expected actual candidate
    require_commands curl sha256sum awk
    for base in \
        "https://github.com/${PROJECT_REPO}/releases/download/v${SCRIPT_VERSION}" \
        "https://raw.githubusercontent.com/${PROJECT_REPO}/v${SCRIPT_VERSION}" \
        "https://raw.githubusercontent.com/${PROJECT_REPO}/main"; do
        candidate="${target}.candidate"
        rm -f -- "$candidate" "${target}.sha"
        curl -fsSL --connect-timeout 15 --max-time 120 "$base/net-tcp-tune.sh" -o "$candidate" || continue
        curl -fsSL --connect-timeout 15 --max-time 30 "$base/SHA256SUMS" -o "${target}.sha" || continue
        expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "${target}.sha")
        actual=$(sha256sum "$candidate" | awk '{print $1}')
        [[ -n "$expected" && "$actual" == "$expected" ]] || continue
        grep -Fq "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$candidate" || continue
        bash -n "$candidate" || continue
        mv -f -- "$candidate" "$target"
        rm -f -- "${target}.sha"
        log INFO "已取得并校验同版本持久化副本: $base"
        return 0
    done
    rm -f -- "${target}.candidate" "${target}.sha"
    die "无法取得 v${SCRIPT_VERSION} 的校验副本；请先运行 install-alias.sh，或检查 GitHub Release"
}

resolve_install_source() {
    local target="$1" source candidate
    source=$(current_script_path 2>/dev/null || true)
    if [[ -n "$source" ]]; then printf '%s\n' "$source"; return 0; fi
    for candidate in "$(command -v bbr 2>/dev/null || true)" "$PERSIST_SCRIPT"; do
        [[ -f "$candidate" ]] || continue
        grep -Fq "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$candidate" || continue
        printf '%s\n' "$candidate"
        return 0
    done
    verified_download_current_script "$target" || return 1
    printf '%s\n' "$target"
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
    require_root || return 1; require_commands systemctl install || return 1
    local source temp_unit source_temp
    source_temp=$(mktemp) || return 1
    source=$(resolve_install_source "$source_temp") || { rm -f -- "$source_temp"; return 1; }
    mkdir -p -- "$PERSIST_DIR"
    install -m 0755 "$source" "$PERSIST_SCRIPT" || { rm -f -- "$source_temp"; die "安装持久化脚本失败"; return 1; }
    rm -f -- "$source_temp"
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
    atomic_install "$temp_unit" "$SERVICE_FILE" 0644 || { rm -f -- "$temp_unit"; return 1; }
    rm -f -- "$temp_unit"
    if [[ "$LEGACY_SERVICE_FILE" != "$SERVICE_FILE" && -e "$LEGACY_SERVICE_FILE" ]]; then
        systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
        rm -f -- "$LEGACY_SERVICE_FILE"
    fi
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME" >/dev/null || return 1
}

restart_and_verify_persistence() {
    local had_lock="$LOCK_HELD" rc=0 reason=""
    # The service runs this script's `apply`, which takes the same global lock.
    # Hand the lock over before systemctl starts it, then reacquire for a caller
    # (notably the auto wizard) that still has more transactional work to do.
    (( had_lock == 0 )) || release_lock
    if ! systemctl restart "$SERVICE_NAME"; then rc=1; reason="持久化服务启动失败"
    elif ! systemctl is-enabled --quiet "$SERVICE_NAME"; then rc=1; reason="持久化服务未启用"
    elif ! systemctl is-active --quiet "$SERVICE_NAME"; then rc=1; reason="持久化服务未通过运行验证"
    fi
    if (( had_lock )) && ! acquire_lock 30; then
        die "服务运行后无法重新取得配置锁；请稍后重试"
        return 1
    fi
    if (( rc != 0 )); then
        systemctl status "$SERVICE_NAME" --no-pager -l >&2 || true
        die "$reason"
        return 1
    fi
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
    require_root || return 1; acquire_lock 30 || return 1
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
    require_root || return 1; acquire_lock || return 1; require_commands ip tc sysctl modprobe systemctl || return 1
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
    save_config || { die "运行时已生效，但配置保存失败；未报告安装成功"; return 1; }
    install_persistence || { die "运行时已生效，但持久化安装失败；请修复后重试 install"; return 1; }
    restart_and_verify_persistence || { die "运行时已生效，但开机持久化验证失败"; return 1; }
    log OK "基础调优已安装: BBR + ${SYSCTL_PROFILE} + $( ((TC_ENABLED)) && echo 'HTB/FQ' || echo 'FQ' )"
}

restore_baseline_qdisc() {
    local iface kind
    iface=$(awk -F'\t' '$1=="INTERFACE" {print $2}' "$BASELINE_DIR/manifest" 2>/dev/null)
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] || return 0
    kind=$(awk '$1=="qdisc" && $0~/ root / {print $2; exit}' "$BASELINE_DIR/qdisc.txt" 2>/dev/null)
    if ! restore_qdisc_text_snapshot "$iface" "$BASELINE_DIR/qdisc.txt"; then
        log WARN "基线 root qdisc 为 '$kind'，文本快照无法无损重放；已保留快照供人工恢复"
        return 1
    fi
}

restore_baseline_route_windows() {
    local family file baseline current token i rc=0
    local -a route=() clean=()
    for family in -4 -6; do
        file="$BASELINE_DIR/default-route-v${family#-}.txt"
        [[ -s "$file" ]] || continue
        baseline=$(head -n1 "$file")
        current=$(ip "$family" route show default 2>/dev/null | head -n1 || true)
        [[ "$baseline$current" == *initcwnd* || "$baseline$current" == *initrwnd* ]] || continue
        [[ -n "$current" ]] || continue
        read -r -a route <<< "$current"; clean=()
        for ((i=0; i<${#route[@]}; i++)); do
            token="${route[$i]}"
            if [[ "$token" == initcwnd || "$token" == initrwnd ]]; then ((i+=1)); continue; fi
            clean+=("$token")
        done
        if [[ "$baseline" =~ (^|[[:space:]])initcwnd[[:space:]]+([0-9]+) ]]; then clean+=(initcwnd "${BASH_REMATCH[2]}"); fi
        if [[ "$baseline" =~ (^|[[:space:]])initrwnd[[:space:]]+([0-9]+) ]]; then clean+=(initrwnd "${BASH_REMATCH[2]}"); fi
        ip "$family" route replace "${clean[@]}" || { log WARN "未能恢复 IPv${family#-} 默认路由窗口参数"; rc=1; }
    done
    return "$rc"
}

restore_baseline() {
    require_root || return 1; acquire_lock || return 1
    local rc=0
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
    restore_backed_path "$CONFIG_FILE" config || rc=1
    restore_backed_path "$SYSCTL_FILE" sysctl || rc=1
    restore_backed_path "$LEGACY_SYSCTL_FILE" legacy-sysctl || rc=1
    restore_backed_path "$SERVICE_FILE" service || rc=1
    restore_backed_path "$LEGACY_SERVICE_FILE" legacy-service || rc=1
    restore_runtime_sysctls || rc=1
    restore_baseline_route_windows || rc=1
    restore_baseline_qdisc || rc=1
    systemctl daemon-reload 2>/dev/null || true
    if (( rc == 0 )); then log OK "已恢复首次可信基线；基线和测量历史仍保留在 $STATE_DIR"
    else die "基线只完成了部分恢复；快照仍保留在 $BASELINE_DIR，请查看上述警告"; fi
}

uninstall_managed() {
    require_root || return 1; acquire_lock || return 1
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
    local iface="" cc available profile_state service_state service_active shaping=off config_state baseline_state
    load_config || return 1
    iface=$(detect_interface "$TC_INTERFACE" 2>/dev/null || true)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    profile_state=$([[ -f "$SYSCTL_FILE" ]] && echo installed || echo absent)
    if [[ ! -f "$SERVICE_FILE" ]]; then service_state=absent
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then service_state=enabled
    else service_state=disabled; fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then service_active=active; else service_active=inactive; fi
    config_state=$([[ -f "$CONFIG_FILE" ]] && echo present || echo absent)
    if [[ -f "$BASELINE_DIR/manifest" ]]; then baseline_state="recorded ($(baseline_provenance))"; else baseline_state=missing; fi
    printf '%-20s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-20s %s\n' "Kernel" "$(uname -r)"
    printf '%-20s %s\n' "Congestion control" "$cc (available: $available)"
    printf '%-20s %s\n' "BBR generation" "$(bbr_generation_status "$cc")"
    printf '%-20s %s\n' "Sysctl profile" "$SYSCTL_PROFILE ($profile_state)"
    printf '%-20s %s\n' "Persistence" "$service_state / $service_active"
    printf '%-20s %s\n' "Config" "$config_state ($CONFIG_FILE)"
    printf '%-20s %s\n' "Baseline" "$baseline_state"
    if [[ -n "$iface" ]]; then
        if managed_htb "$iface"; then shaping="$(managed_rate_mbit "$iface") Mbit"; fi
        printf '%-20s %s\n' "Interface" "$iface"
        printf '%-20s %s\n' "Root qdisc" "$(root_qdisc_kind "$iface")"
        printf '%-20s %s\n' "Shaping" "$shaping"
    fi
}

bbr_generation_status() {
    local cc="${1:-}" module_version kernel
    [[ "$cc" == bbr ]] || { printf 'inactive\n'; return 0; }
    module_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; exit}')
    kernel=$(uname -r)
    if [[ "$module_version" =~ ^3([.-]|$) ]]; then
        printf 'v3 verified (module %s)\n' "$module_version"
    elif [[ "$kernel" == *xanmod* ]]; then
        printf 'likely v3 (XanMod; kernel API cannot prove generation)\n'
    else
        printf 'unknown (BBR active; not proof of BBRv3)\n'
    fi
}

verify_system_state() {
    local rc=0 iface cc
    load_config || return 1
    iface=$(detect_interface "$TC_INTERFACE") || return 1
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    [[ "$cc" == bbr ]] || { log ERR "拥塞控制不是 bbr: ${cc:-unknown}"; rc=1; }
    [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == fq ]] || { log ERR "default_qdisc 不是 fq"; rc=1; }
    [[ -f "$SYSCTL_FILE" ]] || { log ERR "sysctl 持久化文件缺失"; rc=1; }
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未启用"; rc=1; }
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未运行"; rc=1; }
    if (( TC_ENABLED )); then verify_shaping "$iface" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    if (( rc == 0 )); then log OK "运行时与持久化状态一致"; else die "验证发现不一致"; fi
}
