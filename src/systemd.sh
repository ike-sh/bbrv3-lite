# -----------------------------------------------------------------------------
# Persistence, legacy migration, restore and uninstall.
# -----------------------------------------------------------------------------

ACTION_TRANSACTION_DIR=""
ACTION_TRANSACTION_IFACE=""
ACTION_TRANSACTION_ROLLING_BACK=0

current_script_path() {
    local source="${BASH_SOURCE[0]}"
    case "$source" in /dev/fd/*|/proc/*/fd/*) return 1 ;; esac
    [[ -f "$source" ]] || return 1
    readlink -f "$source"
}

verified_download_current_script() {
    local target="$1" base expected actual candidate
    require_commands curl sha256sum awk || return 1
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
        grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$candidate" || continue
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
    atomic_install "$source" "$PERSIST_SCRIPT" 0755 || { rm -f -- "$source_temp"; die "安装持久化脚本失败"; return 1; }
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

capture_unit_state() {
    local unit="$1" file="$2" enabled active
    if ! command_exists systemctl; then
        printf 'unavailable\tunavailable\n' > "$file"
        return
    fi
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '%s\t%s\n' "${enabled:-not-found}" "${active:-inactive}" > "$file"
}

restore_unit_state() {
    local unit="$1" file="$2" enabled active rc=0
    [[ -f "$file" ]] || return 0
    IFS=$'\t' read -r enabled active < "$file" || return 1
    [[ "$enabled" != unavailable ]] || return 0
    command_exists systemctl || { log WARN "无法恢复 systemd unit 状态: $unit"; return 1; }
    case "$enabled" in
        enabled|enabled-runtime|linked|linked-runtime|alias) systemctl enable "$unit" >/dev/null 2>&1 || rc=1 ;;
        masked|masked-runtime) systemctl mask "$unit" >/dev/null 2>&1 || rc=1 ;;
        *) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    esac
    case "$active" in
        active|activating|reloading) systemctl start "$unit" >/dev/null 2>&1 || rc=1 ;;
        *) systemctl stop "$unit" >/dev/null 2>&1 || true ;;
    esac
    return "$rc"
}

action_transaction_snapshot_path() {
    local source="$1" name="$2"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$ACTION_TRANSACTION_DIR/files/$name" || return 1
        printf 'present\n' > "$ACTION_TRANSACTION_DIR/${name}.state"
    else
        printf 'absent\n' > "$ACTION_TRANSACTION_DIR/${name}.state"
    fi
}

action_transaction_restore_path() {
    local target="$1" name="$2" state
    state=$(<"$ACTION_TRANSACTION_DIR/${name}.state") || return 1
    rm -f -- "$target" || return 1
    if [[ "$state" == present ]]; then
        mkdir -p -- "$(dirname "$target")" || return 1
        cp -a -- "$ACTION_TRANSACTION_DIR/files/$name" "$target" || return 1
    fi
}

action_transaction_capture_unit() {
    capture_unit_state "$1" "$ACTION_TRANSACTION_DIR/$2.unit"
}

action_transaction_restore_unit() {
    restore_unit_state "$1" "$ACTION_TRANSACTION_DIR/$2.unit"
}

action_transaction_restore_routes() {
    local family file baseline current token i rc=0
    local -a route=() clean=()
    for family in -4 -6; do
        file="$ACTION_TRANSACTION_DIR/default-route-v${family#-}.txt"
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
        ip "$family" route replace "${clean[@]}" || rc=1
    done
    return "$rc"
}

action_transaction_begin() {
    local iface="$1" dir
    [[ -z "$ACTION_TRANSACTION_DIR" ]] || { die "已有未提交的系统配置事务"; return 1; }
    ensure_state_layout || return 1
    dir=$(mktemp -d "${STATE_DIR}/.transaction.XXXXXX") || return 1
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE="$iface"
    mkdir -p "$dir/files" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; return 1; }
    action_qdisc_snapshot "$iface" "$dir/qdisc.snapshot" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; return 1; }
    capture_runtime_sysctls > "$dir/sysctl.tsv" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; return 1; }
    ip -4 route show default > "$dir/default-route-v4.txt" 2>/dev/null || true
    ip -6 route show default > "$dir/default-route-v6.txt" 2>/dev/null || true
    if ! action_transaction_snapshot_path "$CONFIG_FILE" config ||
       ! action_transaction_snapshot_path "$SYSCTL_FILE" sysctl ||
       ! action_transaction_snapshot_path "$SERVICE_FILE" service ||
       ! action_transaction_snapshot_path "$LEGACY_SERVICE_FILE" legacy-service ||
       ! action_transaction_snapshot_path "$PERSIST_SCRIPT" persist-script; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
        return 1
    fi
    if ! action_transaction_capture_unit "$SERVICE_NAME" service ||
       ! action_transaction_capture_unit bbr-optimize-persist.service legacy-service ||
       ! chmod -R go-rwx "$dir"; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
        return 1
    fi
    log INFO "已创建本次操作回滚点: $dir"
}

action_transaction_commit() {
    local dir="$ACTION_TRANSACTION_DIR"
    [[ -n "$dir" ]] || return 0
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
    remove_tree_within "$dir" "$STATE_DIR" || log WARN "操作已提交，但无法删除临时事务快照: $dir"
}

action_transaction_rollback() {
    local dir="$ACTION_TRANSACTION_DIR" iface="$ACTION_TRANSACTION_IFACE" key value rc=0 had_lock="$LOCK_HELD"
    [[ -n "$dir" ]] || return 0
    (( ACTION_TRANSACTION_ROLLING_BACK == 0 )) || return 1
    ACTION_TRANSACTION_ROLLING_BACK=1
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    action_transaction_restore_path "$CONFIG_FILE" config || rc=1
    action_transaction_restore_path "$SYSCTL_FILE" sysctl || rc=1
    action_transaction_restore_path "$SERVICE_FILE" service || rc=1
    action_transaction_restore_path "$LEGACY_SERVICE_FILE" legacy-service || rc=1
    action_transaction_restore_path "$PERSIST_SCRIPT" persist-script || rc=1
    rmdir "$PERSIST_DIR" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    while IFS=$'\t' read -r key value; do
        if [[ -n "$key" ]] && ! sysctl -q -w "$key=$value"; then rc=1; fi
    done < "$dir/sysctl.tsv"
    action_transaction_restore_routes || rc=1
    restore_action_qdisc "$iface" "$dir/qdisc.snapshot" || rc=1
    (( had_lock == 0 )) || release_lock
    action_transaction_restore_unit "$SERVICE_NAME" service || rc=1
    action_transaction_restore_unit bbr-optimize-persist.service legacy-service || rc=1
    if (( had_lock )) && ! acquire_lock 30; then rc=1; fi
    if (( rc == 0 )); then
        remove_tree_within "$dir" "$STATE_DIR" || rc=1
    fi
    if (( rc == 0 )); then
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
        log OK "已恢复本次操作前的 qdisc、sysctl、配置和服务状态"
    else
        log ERR "自动回滚未完全成功；事务快照保留在 $dir"
    fi
    ACTION_TRANSACTION_ROLLING_BACK=0
    return "$rc"
}

run_action_transaction() {
    local iface="$1" rc rollback_rc=0; shift
    action_transaction_begin "$iface" || return 1
    if "$@"; then
        action_transaction_commit
        return
    else
        rc=$?
    fi
    action_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
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

install_base_tuning_steps() {
    local iface="$1" requested="$2" profile="$3" role="$4" bandwidth="$5" rtt="$6"
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    load_config || return 1
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

install_base_tuning() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands ip tc sysctl modprobe systemctl || return 1
    local requested="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" iface
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    run_action_transaction "$iface" install_base_tuning_steps "$iface" "$requested" "$profile" "$role" "$bandwidth" "$rtt"
}

prepare_auto_tuning_runtime() {
    local iface="$1" requested="$2" profile="$3" role="$4" bandwidth="$5" rtt="$6"
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    load_config || return 1
    SYSCTL_PROFILE="$profile"; ROLE="$role"; BANDWIDTH_MBIT="$bandwidth"; RTT_MS="$rtt"
    BBR_ENABLED=1; TC_INTERFACE="$requested"; TC_ENABLED=0; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
    validate_config_value SYSCTL_PROFILE "$SYSCTL_PROFILE" && validate_config_value ROLE "$ROLE" || { die "非法 profile/role"; return 1; }
    apply_sysctl_profile runtime || return 1
    apply_fq "$iface" || return 1
    apply_initial_windows || return 1
    log OK "基础调优已临时应用；最终复验通过前不会写入配置或服务"
}

verify_runtime_tuning() {
    local iface="$1" rc=0
    verify_sysctl_profile_runtime || rc=1
    if (( TC_ENABLED )); then verify_shaping "$iface" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    (( rc == 0 )) || { die "临时调优状态验证失败"; return 1; }
    log OK "临时运行时状态验证通过"
}

persist_current_tuning() {
    apply_sysctl_profile persistent || return 1
    save_config || { die "配置提交失败"; return 1; }
    install_persistence || { die "持久化安装失败"; return 1; }
    restart_and_verify_persistence || return 1
    verify_system_state || return 1
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
    restore_backed_path "$PERSIST_SCRIPT" persist-script || rc=1
    restore_runtime_sysctls || rc=1
    restore_baseline_route_windows || rc=1
    restore_baseline_qdisc || rc=1
    systemctl daemon-reload 2>/dev/null || true
    restore_unit_state "$SERVICE_NAME" "$BASELINE_DIR/service.unit" || rc=1
    restore_unit_state bbr-optimize-persist.service "$BASELINE_DIR/legacy-service.unit" || rc=1
    if (( rc == 0 )); then log OK "已恢复首次可信基线；基线和测量历史仍保留在 $STATE_DIR"
    else die "基线只完成了部分恢复；快照仍保留在 $BASELINE_DIR，请查看上述警告"; fi
}

managed_bbr_command() {
    local file="$1"
    [[ -f "$file" || -L "$file" ]] || return 1
    grep -Eq 'SCRIPT_NAME="bbrv3-lite"|github[.]com/ike-sh/bbrv3-lite' "$file" 2>/dev/null
}

remove_legacy_shell_commands() {
    local rc_file temp changed=0
    for rc_file in "${HOME:-/root}/.bashrc" "${HOME:-/root}/.bash_profile" "${HOME:-/root}/.zshrc"; do
        [[ -f "$rc_file" ]] || continue
        grep -Fq '# ================ net-tcp-tune 快捷别名 ================' "$rc_file" || continue
        temp=$(mktemp "${rc_file}.bbrv3-lite.XXXXXX") || return 1
        if ! sed '/^# ================ net-tcp-tune 快捷别名 ================/,/^# ================ net-tcp-tune 快捷别名结束 ================/d' "$rc_file" > "$temp"; then
            rm -f -- "$temp"; return 1
        fi
        chmod --reference="$rc_file" "$temp" 2>/dev/null || true
        [[ "${EUID:-$(id -u)}" -ne 0 ]] || chown --reference="$rc_file" "$temp" 2>/dev/null || true
        mv -f -- "$temp" "$rc_file" || return 1
        log OK "已从 $rc_file 删除旧版 bbr shell function"
        ((changed+=1))
    done
    LEGACY_SHELL_REMOVED="$changed"
}

remove_cli_command() {
    local current="" candidate resolved removed=0
    local -A seen=()
    current=$(current_script_path 2>/dev/null || true)
    for candidate in "${BBRV3_CLI_PATH:-}" "$current" "/usr/local/bin/bbr" "${HOME:-/root}/.local/bin/bbr"; do
        [[ -n "$candidate" ]] || continue
        resolved=$(readlink -m "$candidate" 2>/dev/null || printf '%s' "$candidate")
        [[ -z "${seen[$resolved]:-}" ]] || continue
        seen[$resolved]=1
        [[ "${candidate##*/}" == bbr ]] || continue
        managed_bbr_command "$candidate" || continue
        rm -f -- "$candidate" || { die "无法删除 bbr 命令: $candidate"; return 1; }
        log OK "已删除 bbr 命令: $candidate"
        ((removed+=1))
    done
    remove_legacy_shell_commands || return 1
    if (( removed == 0 && ${LEGACY_SHELL_REMOVED:-0} == 0 )); then
        log WARN "未在标准位置找到本项目的 bbr 命令；自定义 --prefix 安装需用安装器 uninstall 删除"
    fi
}

uninstall_managed() {
    require_root || return 1; acquire_lock || return 1
    local purge="${1:-0}" iface="" resolved_state restored_tcp=0 restored_dns=0 restored_ipv6=0

    # Restore before deleting either the executable or the only recovery data.
    if [[ -f "$BASELINE_DIR/manifest" ]]; then
        restore_baseline || return 1
        restored_tcp=1
    else
        load_config || true
        iface=$(detect_interface "${TC_INTERFACE:-auto}" 2>/dev/null || true)
        if [[ -n "$iface" ]] && managed_htb "$iface"; then apply_fq "$iface" || return 1; fi
        remove_persistence
        rm -f -- "$CONFIG_FILE" "$SYSCTL_FILE"
        log WARN "没有 TCP 基线：已移除管理文件和 HTB，但无法精确恢复修改前的运行时 sysctl/qdisc"
    fi
    if [[ -f "$DNS_BACKUP_DIR/baseline/manifest" ]]; then dns_restore || return 1; restored_dns=1; fi
    if [[ -f "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" ]]; then ipv6_restore || return 1; restored_ipv6=1; fi

    remove_cli_command || return 1
    if (( purge )); then
        resolved_state=$(readlink -m "$STATE_DIR")
        [[ "$resolved_state" == /var/lib/bbrv3-lite || "$resolved_state" == /tmp/bbrv3-lite-test-* ]] || { die "拒绝清理非标准状态目录: $resolved_state"; return 1; }
        [[ ! -e "$resolved_state" ]] || rm -rf -- "$resolved_state"
        log WARN "已完整卸载并永久删除状态目录"
    elif [[ -d "$STATE_DIR" ]]; then
        log OK "已完整卸载；可用基线已恢复，备份和历史保留在 $STATE_DIR"
    else
        log OK "已完整卸载；此前没有可保留的基线或历史"
    fi
    log INFO "恢复结果: TCP=$restored_tcp DNS=$restored_dns IPv6=$restored_ipv6；重新打开 shell 后 bbr 命令将消失"
    log INFO "当前 shell 如缓存过旧命令，可执行: unset -f bbr 2>/dev/null; hash -r"
}

persistence_script_state() {
    local version current
    [[ -f "$PERSIST_SCRIPT" ]] || { printf 'absent\n'; return; }
    grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$PERSIST_SCRIPT" 2>/dev/null || { printf 'foreign/unrecognized\n'; return; }
    version=$(awk -F'"' '$1=="SCRIPT_VERSION=" {print $2; exit}' "$PERSIST_SCRIPT" 2>/dev/null)
    [[ -x "$PERSIST_SCRIPT" ]] || { printf 'v%s / not executable\n' "${version:-unknown}"; return; }
    current=$(current_script_path 2>/dev/null || true)
    if [[ -n "$current" && "$(readlink -f "$current")" != "$(readlink -f "$PERSIST_SCRIPT")" ]] && command_exists cmp; then
        if cmp -s "$current" "$PERSIST_SCRIPT"; then
            printf 'v%s / synced\n' "${version:-unknown}"
        else
            printf 'v%s / differs from current command\n' "${version:-unknown}"
        fi
    else
        printf 'v%s\n' "${version:-unknown}"
    fi
}

verify_persistence_artifacts() {
    local rc=0 version current
    [[ -f "$CONFIG_FILE" ]] || { log ERR "运行配置缺失: $CONFIG_FILE"; rc=1; }
    verify_sysctl_profile_file || rc=1
    [[ -f "$SERVICE_FILE" ]] || { log ERR "systemd unit 缺失: $SERVICE_FILE"; rc=1; }
    if [[ -f "$SERVICE_FILE" ]] && ! grep -Fqx "ExecStart=${PERSIST_SCRIPT} apply" "$SERVICE_FILE"; then
        log ERR "systemd unit 的 ExecStart 与受管脚本路径不一致"
        rc=1
    fi
    if [[ ! -x "$PERSIST_SCRIPT" ]]; then
        log ERR "持久化脚本缺失或不可执行: $PERSIST_SCRIPT"
        rc=1
    elif ! grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$PERSIST_SCRIPT"; then
        log ERR "持久化脚本不属于本项目: $PERSIST_SCRIPT"
        rc=1
    else
        version=$(awk -F'"' '$1=="SCRIPT_VERSION=" {print $2; exit}' "$PERSIST_SCRIPT")
        if [[ "$version" != "$SCRIPT_VERSION" ]]; then
            log ERR "持久化脚本版本漂移: v${version:-unknown}（期望 v$SCRIPT_VERSION）"
            rc=1
        fi
        current=$(current_script_path 2>/dev/null || true)
        if [[ -n "$current" && "$(readlink -f "$current")" != "$(readlink -f "$PERSIST_SCRIPT")" ]]; then
            if ! command_exists cmp || ! cmp -s "$current" "$PERSIST_SCRIPT"; then
                log ERR "当前 bbr 命令与 systemd 持久化脚本内容不一致"
                rc=1
            fi
        fi
    fi
    return "$rc"
}

show_status() {
    local iface="" cc available profile_state service_state service_active shaping=off config_state baseline_state buffer_state="unavailable" script_state
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
    if buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" 2>/dev/null; then
        buffer_state="$(human_bytes "$BUFFER_MAX") ($BUFFER_REASON)"
    fi
    script_state=$(persistence_script_state)
    printf '%-20s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-20s %s\n' "Kernel" "$(uname -r)"
    printf '%-20s %s\n' "Congestion control" "$cc (available: $available)"
    printf '%-20s %s\n' "BBR generation" "$(bbr_generation_status "$cc")"
    printf '%-20s %s\n' "Sysctl profile" "$SYSCTL_PROFILE ($profile_state)"
    printf '%-20s %s\n' "Tuning model" "$ROLE / ${BANDWIDTH_MBIT} Mbit / ${RTT_MS} ms"
    printf '%-20s %s\n' "Buffer ceiling" "$buffer_state"
    printf '%-20s %s\n' "Persistence" "$service_state / $service_active"
    printf '%-20s %s\n' "Persistence script" "$script_state"
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
    local rc=0 iface
    load_config || return 1
    iface=$(detect_interface "$TC_INTERFACE") || return 1
    verify_sysctl_profile_runtime || rc=1
    verify_persistence_artifacts || rc=1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未启用"; rc=1; }
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未运行"; rc=1; }
    if (( TC_ENABLED )); then verify_shaping "$iface" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    if (( rc == 0 )); then log OK "运行时与持久化状态一致"; else die "验证发现不一致"; fi
}
