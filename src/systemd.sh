# -----------------------------------------------------------------------------
# Persistence, legacy migration, restore and uninstall.
# -----------------------------------------------------------------------------

ACTION_TRANSACTION_DIR=""
ACTION_TRANSACTION_IFACE=""
ACTION_TRANSACTION_INTERFACES=""
ACTION_TRANSACTION_ROLLING_BACK=0
ACTION_TRANSACTION_READY=0
ACTION_TRANSACTION_MUTATED=0

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
        managed_bbr_script_signature "$candidate" || continue
        grep -Fxc "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$candidate" >/dev/null || continue
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
    if [[ -n "$source" ]] && managed_bbr_script_signature "$source" &&
       grep -Fxc "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$source" >/dev/null; then
        printf '%s\n' "$source"
        return 0
    fi
    for candidate in "$(command -v bbr 2>/dev/null || true)" "$PERSIST_SCRIPT"; do
        [[ -f "$candidate" ]] || continue
        managed_bbr_script_signature "$candidate" || continue
        grep -Fxc "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$candidate" >/dev/null || continue
        printf '%s\n' "$candidate"
        return 0
    done
    verified_download_current_script "$target" || return 1
    printf '%s\n' "$target"
}

migrate_legacy_config() {
    local file="${1:-$CONFIG_FILE}" line key value
    [[ -f "$file" ]] || return 0
    if grep -Fxq 'SCHEMA_VERSION=1' "$file" && ! grep -Fxq 'SYSCTL_PROFILE=balanced-minimal' "$file"; then return 0; fi
    log INFO "迁移旧版配置: $file"
    reset_config
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        case "$key" in
            BBR_ENABLED|TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT|TC_BASELINE_MBIT|TC_PERCENT|INITCWND|INITRWND|MULTI_NIC_ENABLED)
                case "$key" in
                    TC_BASELINE_MBIT) BANDWIDTH_MBIT="$value" ;;
                    TC_PERCENT)
                        if is_uint "$value" && (( value <= 100 )); then TC_MARGIN_PERCENT=$((100-value)); fi
                        ;;
                    *) validate_config_value "$key" "$value" 2>/dev/null && printf -v "$key" '%s' "$value" ;;
                esac
                ;;
            SYSCTL_PROFILE) [[ "$value" == balanced-minimal || "$value" == balanced ]] && SYSCTL_PROFILE=balanced ;;
        esac
    done < "$file"
    save_config "$file"
}

retire_legacy_sysctl() {
    [[ "$LEGACY_SYSCTL_FILE" != "$SYSCTL_FILE" ]] || return 0
    [[ -e "$LEGACY_SYSCTL_FILE" || -L "$LEGACY_SYSCTL_FILE" ]] || return 0
    if [[ -d "$LEGACY_SYSCTL_FILE" && ! -L "$LEGACY_SYSCTL_FILE" ]]; then
        die "旧版 sysctl 路径不是文件，拒绝删除: $LEGACY_SYSCTL_FILE"
        return 1
    fi
    [[ -n "$ACTION_TRANSACTION_DIR" && -f "$ACTION_TRANSACTION_DIR/legacy-sysctl.state" ]] || {
        die "旧版 sysctl 尚未进入本次事务回滚点，拒绝删除: $LEGACY_SYSCTL_FILE"
        return 1
    }
    tcp_baseline_validate "$BASELINE_DIR" >/dev/null 2>&1 || {
        die "首次可信基线缺失或损坏，拒绝退役旧版 sysctl: $LEGACY_SYSCTL_FILE"
        return 1
    }
    rm -f -- "$LEGACY_SYSCTL_FILE" || {
        die "无法退役旧版 sysctl: $LEGACY_SYSCTL_FILE"
        return 1
    }
    log INFO "已在事务内退役旧版 sysctl（首次可信基线仍可恢复）: $LEGACY_SYSCTL_FILE"
}

install_persistence() {
    require_root || return 1; require_commands systemctl install || return 1
    local source temp_unit source_temp
    retire_legacy_sysctl || return 1
    source_temp=$(mktemp) || return 1
    source=$(resolve_install_source "$source_temp") || { rm -f -- "$source_temp"; return 1; }
    managed_bbr_script_signature "$source" &&
        grep -Fxc "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$source" >/dev/null || {
        rm -f -- "$source_temp"
        die "持久化来源缺少完整项目签名或版本不匹配"
        return 1
    }
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
    local rc=0
    if command_exists systemctl; then
        if [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]] ||
            systemctl is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 ||
            systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1; then
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || {
                log WARN "无法停止并禁用持久化服务: $SERVICE_NAME"
                rc=1
            }
        fi
    fi
    rm -f -- "$SERVICE_FILE" "$PERSIST_SCRIPT" || {
        log WARN "无法删除持久化服务或脚本"
        rc=1
    }
    if [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" || -e "$PERSIST_SCRIPT" || -L "$PERSIST_SCRIPT" ]]; then
        log WARN "持久化服务或脚本删除后仍然存在"
        rc=1
    fi
    rmdir "$PERSIST_DIR" 2>/dev/null || true
    if command_exists systemctl && ! systemctl daemon-reload; then
        log WARN "systemd daemon-reload 失败"
        rc=1
    fi
    return "$rc"
}

query_unit_enabled_state() {
    local unit="$1" state="" query_rc=0 printable
    if state=$(systemctl is-enabled "$unit" 2>&1); then
        query_rc=0
    else
        query_rc=$?
    fi
    # A non-zero status is normal for disabled/masked/not-found units.  The
    # state token, rather than the command status alone, distinguishes those
    # states from a failed manager/D-Bus query (which has no known token).
    case "$state" in
        enabled|enabled-runtime|disabled|masked|masked-runtime|linked|linked-runtime|alias|static|indirect|generated|transient|not-found)
            printf '%s\n' "$state"
            return 0
            ;;
    esac
    printable=${state//$'\n'/'; '}
    log WARN "无法读取 systemd unit-file 状态: $unit (exit=$query_rc, output=${printable:-empty})"
    return 1
}

query_unit_active_state() {
    local unit="$1" state="" query_rc=0 printable
    if state=$(systemctl is-active "$unit" 2>&1); then
        query_rc=0
    else
        query_rc=$?
    fi
    # Only stable states can be recreated by start/stop.  Treat failed and
    # transitional states as non-restorable instead of silently recording
    # them as inactive.
    case "$state" in
        active|inactive)
            printf '%s\n' "$state"
            return 0
            ;;
    esac
    printable=${state//$'\n'/'; '}
    log WARN "无法读取可恢复的 systemd active 状态: $unit (exit=$query_rc, output=${printable:-empty})"
    return 1
}

unit_enabled_state_is_mutable() {
    case "$1" in
        enabled|enabled-runtime|disabled|masked|masked-runtime) return 0 ;;
        *) return 1 ;;
    esac
}

capture_unit_state() {
    local unit="$1" file="$2" enabled active
    command_exists systemctl || { log WARN "无法捕获 systemd unit 状态（systemctl 不可用）: $unit"; return 1; }
    enabled=$(query_unit_enabled_state "$unit") || return 1
    active=$(query_unit_active_state "$unit") || return 1
    printf '%s\t%s\n' "$enabled" "$active" > "$file"
}

unit_state_snapshot_validate() {
    local file="$1" line enabled active
    local -a state_lines=()
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mapfile -t state_lines < "$file" || return 1
    (( ${#state_lines[@]} == 1 )) || return 1
    line="${state_lines[0]}"
    [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || return 1
    enabled="${line%%$'\t'*}"
    active="${line#*$'\t'}"
    case "$enabled" in
        enabled|enabled-runtime|disabled|masked|masked-runtime|linked|linked-runtime|alias|static|indirect|generated|transient|not-found) ;;
        *) return 1 ;;
    esac
    case "$active" in active|inactive) ;; *) return 1 ;; esac
}

restore_unit_state() {
    local unit="$1" file="$2" line enabled active current_enabled current_active
    local actual_enabled actual_active rc=0 remask=0
    local -a state_lines=()
    [[ -e "$file" || -L "$file" ]] || return 0
    if ! unit_state_snapshot_validate "$file"; then
        log ERR "systemd unit 状态快照格式损坏: $file"
        return 1
    fi
    mapfile -t state_lines < "$file" || return 1
    line="${state_lines[0]}"
    enabled="${line%%$'\t'*}"
    active="${line#*$'\t'}"
    command_exists systemctl || { log WARN "无法恢复 systemd unit 状态（systemctl 不可用）: $unit"; return 1; }
    current_enabled=$(query_unit_enabled_state "$unit") || return 1
    current_active=$(query_unit_active_state "$unit") || return 1

    # linked/alias/static/indirect/generated/transient/not-found describe how
    # the unit was supplied, not a state that `systemctl enable` can safely
    # reconstruct.  The restored unit files must already reproduce it.
    if ! unit_enabled_state_is_mutable "$enabled"; then
        if [[ "$current_enabled" != "$enabled" ]]; then
            log ERR "不能安全合成 systemd unit-file 状态 '$enabled': $unit (current=$current_enabled)"
            return 1
        fi
    elif [[ "$enabled" != masked && "$enabled" != masked-runtime ]] &&
         ! unit_enabled_state_is_mutable "$current_enabled"; then
        log ERR "拒绝把不可合成的 systemd unit-file 状态 '$current_enabled' 改写为 '$enabled': $unit"
        return 1
    fi

    case "$enabled" in
        masked|masked-runtime)
            # A masked service must be temporarily unmasked before it can be
            # started.  Changing permanent/runtime mask scope also requires
            # removing the old mask first.  Masking is deliberately done last.
            if [[ "$current_enabled" == masked || "$current_enabled" == masked-runtime ]]; then
                if [[ "$current_enabled" != "$enabled" || ( "$active" == active && "$current_active" != active ) ]]; then
                    case "$current_enabled" in
                        masked)
                            if ! systemctl unmask "$unit" >/dev/null 2>&1; then
                                log WARN "移除 systemd 永久 mask 失败: $unit"
                                rc=1
                            fi
                            ;;
                        masked-runtime)
                            if ! systemctl unmask --runtime "$unit" >/dev/null 2>&1; then
                                log WARN "移除 systemd runtime mask 失败: $unit"
                                rc=1
                            fi
                            ;;
                    esac
                    current_enabled=$(query_unit_enabled_state "$unit") || return 1
                    remask=1
                fi
            elif [[ "$current_enabled" != "$enabled" ]]; then
                remask=1
            fi

            if [[ "$active" == active && "$current_active" != active ]]; then
                if ! systemctl start "$unit" >/dev/null 2>&1; then
                    log WARN "启动 systemd unit 失败: $unit"
                    rc=1
                fi
            elif [[ "$active" == inactive && "$current_active" != inactive ]]; then
                if ! systemctl stop "$unit" >/dev/null 2>&1; then
                    log WARN "停止 systemd unit 失败: $unit"
                    rc=1
                fi
            fi

            if (( remask )); then
                if [[ "$enabled" == masked-runtime ]]; then
                    if ! systemctl mask --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd runtime mask 失败: $unit"
                        rc=1
                    fi
                elif ! systemctl mask "$unit" >/dev/null 2>&1; then
                    log WARN "恢复 systemd 永久 mask 失败: $unit"
                    rc=1
                fi
            fi
            ;;
        enabled|enabled-runtime|disabled)
            case "$current_enabled" in
                masked)
                    if ! systemctl unmask "$unit" >/dev/null 2>&1; then
                        log WARN "移除 systemd 永久 mask 失败: $unit"
                        rc=1
                    fi
                    current_enabled=$(query_unit_enabled_state "$unit") || return 1
                    ;;
                masked-runtime)
                    if ! systemctl unmask --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "移除 systemd runtime mask 失败: $unit"
                        rc=1
                    fi
                    current_enabled=$(query_unit_enabled_state "$unit") || return 1
                    ;;
            esac
            if ! unit_enabled_state_is_mutable "$current_enabled"; then
                log ERR "解除 mask 后得到不可安全改写的 unit-file 状态 '$current_enabled': $unit"
                return 1
            fi

            case "$enabled:$current_enabled" in
                enabled:enabled|enabled-runtime:enabled-runtime|disabled:disabled) ;;
                enabled:enabled-runtime)
                    if ! systemctl disable --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "移除 systemd runtime enable 失败: $unit"
                        rc=1
                    fi
                    if ! systemctl enable "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd 永久 enable 失败: $unit"
                        rc=1
                    fi
                    ;;
                enabled:disabled)
                    if ! systemctl enable "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd 永久 enable 失败: $unit"
                        rc=1
                    fi
                    ;;
                enabled-runtime:enabled)
                    if ! systemctl disable "$unit" >/dev/null 2>&1; then
                        log WARN "移除 systemd 永久 enable 失败: $unit"
                        rc=1
                    fi
                    if ! systemctl enable --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd runtime enable 失败: $unit"
                        rc=1
                    fi
                    ;;
                enabled-runtime:disabled)
                    if ! systemctl enable --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd runtime enable 失败: $unit"
                        rc=1
                    fi
                    ;;
                disabled:enabled)
                    if ! systemctl disable "$unit" >/dev/null 2>&1; then
                        log WARN "恢复 systemd disabled 状态失败: $unit"
                        rc=1
                    fi
                    ;;
                disabled:enabled-runtime)
                    if ! systemctl disable --runtime "$unit" >/dev/null 2>&1; then
                        log WARN "移除 systemd runtime enable 失败: $unit"
                        rc=1
                    fi
                    ;;
                *)
                    log ERR "不支持的 systemd unit-file 状态转换: $current_enabled -> $enabled ($unit)"
                    rc=1
                    ;;
            esac

            if [[ "$active" == active && "$current_active" != active ]]; then
                if ! systemctl start "$unit" >/dev/null 2>&1; then
                    log WARN "启动 systemd unit 失败: $unit"
                    rc=1
                fi
            elif [[ "$active" == inactive && "$current_active" != inactive ]]; then
                if ! systemctl stop "$unit" >/dev/null 2>&1; then
                    log WARN "停止 systemd unit 失败: $unit"
                    rc=1
                fi
            fi
            ;;
        *)
            # Non-synthesizable unit-file states were checked for equality
            # above; start/stop is still safe for their runtime state.
            if [[ "$active" == active && "$current_active" != active ]]; then
                if ! systemctl start "$unit" >/dev/null 2>&1; then
                    log WARN "启动 systemd unit 失败: $unit"
                    rc=1
                fi
            elif [[ "$active" == inactive && "$current_active" != inactive ]]; then
                if ! systemctl stop "$unit" >/dev/null 2>&1; then
                    log WARN "停止 systemd unit 失败: $unit"
                    rc=1
                fi
            fi
            ;;
    esac

    actual_enabled=$(query_unit_enabled_state "$unit") || actual_enabled=query-failed
    actual_active=$(query_unit_active_state "$unit") || actual_active=query-failed
    if [[ "$actual_enabled" != "$enabled" ]]; then
        log ERR "systemd unit-file 恢复验证失败: $unit expected=$enabled actual=$actual_enabled"
        rc=1
    fi
    if [[ "$actual_active" != "$active" ]]; then
        log ERR "systemd active 恢复验证失败: $unit expected=$active actual=$actual_active"
        rc=1
    fi
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

action_transaction_snapshot_tree() {
    local source="$1" name="$2"
    if [[ -e "$source" || -L "$source" ]]; then
        [[ -d "$source" && ! -L "$source" ]] || { die "事务目录快照目标类型不安全: $source"; return 1; }
        cp -a -- "$source" "$ACTION_TRANSACTION_DIR/files/$name" || return 1
        printf 'present\n' > "$ACTION_TRANSACTION_DIR/${name}.state"
    else
        printf 'absent\n' > "$ACTION_TRANSACTION_DIR/${name}.state"
    fi
}

action_transaction_restore_tree() {
    local target="$1" name="$2" state parent
    state=$(<"$ACTION_TRANSACTION_DIR/${name}.state") || return 1
    parent=$(dirname "$target")
    if [[ -e "$target" || -L "$target" ]]; then remove_tree_within "$target" "$parent" || return 1; fi
    if [[ "$state" == present ]]; then
        mkdir -p -- "$parent" || return 1
        cp -a -- "$ACTION_TRANSACTION_DIR/files/$name" "$target" || return 1
    elif [[ "$state" != absent ]]; then return 1
    fi
}

action_transaction_capture_unit() {
    capture_unit_state "$1" "$ACTION_TRANSACTION_DIR/$2.unit"
}

action_transaction_restore_unit() {
    restore_unit_state "$1" "$ACTION_TRANSACTION_DIR/$2.unit"
}

action_transaction_restore_routes() {
    restore_default_route_windows_snapshot "$ACTION_TRANSACTION_DIR"
}

action_transaction_path_snapshot_validate() {
    local name="$1" type="${2:-file}" state_file payload state
    local -a lines=()
    state_file="$ACTION_TRANSACTION_DIR/${name}.state"
    payload="$ACTION_TRANSACTION_DIR/files/$name"
    [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
    mapfile -t lines < "$state_file" || return 1
    (( ${#lines[@]} == 1 )) || return 1
    state="${lines[0]}"
    case "$state:$type" in
        absent:file|absent:tree)
            [[ ! -e "$payload" && ! -L "$payload" ]]
            ;;
        present:file)
            [[ ( -f "$payload" || -L "$payload" ) && ! ( -d "$payload" && ! -L "$payload" ) ]]
            ;;
        present:tree)
            [[ -d "$payload" && ! -L "$payload" ]]
            ;;
        *) return 1 ;;
    esac
}

action_transaction_snapshot_validate() {
    local dir="$ACTION_TRANSACTION_DIR" file iface count=0
    local -A expected=() observed=()
    [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || return 1
    [[ -f "$dir/COMPLETE" && ! -L "$dir/COMPLETE" && "$(<"$dir/COMPLETE")" == complete ]] || return 1
    [[ -f "$dir/sysctl.tsv" && ! -L "$dir/sysctl.tsv" ]] || return 1
    tcp_baseline_sysctl_validate "$dir/sysctl.tsv" >/dev/null || return 1
    [[ -f "$dir/default-route-v4.txt" && ! -L "$dir/default-route-v4.txt" ]] || return 1
    [[ -f "$dir/default-route-v6.txt" && ! -L "$dir/default-route-v6.txt" ]] || return 1
    default_route_windows_snapshot_preflight "$dir" || return 1
    for file in "$dir/qdiscs"/*.snapshot; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        iface="${file##*/}"; iface="${iface%.snapshot}"
        validate_interface_name "$iface" && [[ "$iface" != auto && -z "${observed[$iface]+x}" ]] || return 1
        action_qdisc_snapshot_validate "$file" || return 1
        mq_snapshot_queue_preflight "$iface" "$file" || return 1
        qdisc_filter_guard "$iface" || return 1
        observed[$iface]=1
        ((count+=1))
    done
    (( count > 0 )) || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        validate_interface_name "$iface" && [[ "$iface" != auto && -z "${expected[$iface]+x}" ]] || return 1
        expected[$iface]=1
        [[ -n "${observed[$iface]+x}" ]] || return 1
    done <<< "$ACTION_TRANSACTION_INTERFACES"
    (( ${#expected[@]} == ${#observed[@]} )) || return 1
    [[ -f "$dir/qdisc.snapshot" && ! -L "$dir/qdisc.snapshot" ]] || return 1
    action_qdisc_snapshot_validate "$dir/qdisc.snapshot" || return 1
    action_transaction_path_snapshot_validate config || return 1
    action_transaction_path_snapshot_validate sysctl || return 1
    action_transaction_path_snapshot_validate legacy-sysctl || return 1
    action_transaction_path_snapshot_validate service || return 1
    action_transaction_path_snapshot_validate legacy-service || return 1
    action_transaction_path_snapshot_validate persist-script || return 1
    action_transaction_path_snapshot_validate nic-policy-dir tree || return 1
    unit_state_snapshot_validate "$dir/service.unit" || return 1
    unit_state_snapshot_validate "$dir/legacy-service.unit" || return 1
}

action_transaction_begin() {
    local iface="$1" dir path stale=""
    [[ -z "$ACTION_TRANSACTION_DIR" ]] || { die "已有未提交的系统配置事务"; return 1; }
    for path in "$STATE_DIR"/.transaction.*; do
        [[ -e "$path" || -L "$path" ]] || continue
        stale+="${stale:+, }$path"
    done
    if [[ -n "$stale" ]]; then
        die "发现上次中断遗留的系统配置事务，拒绝叠加新修改: $stale。请先核验并人工恢复该快照"
        return 1
    fi
    ensure_state_layout || return 1
    dir=$(mktemp -d "${STATE_DIR}/.transaction.XXXXXX") || return 1
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE="$iface"; ACTION_TRANSACTION_INTERFACES="$iface"
    ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
    mkdir -p "$dir/files" "$dir/qdiscs" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; return 1; }
    action_qdisc_snapshot "$iface" "$dir/qdisc.snapshot" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; return 1; }
    cp -- "$dir/qdisc.snapshot" "$dir/qdiscs/$iface.snapshot" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; return 1; }
    capture_runtime_sysctls > "$dir/sysctl.tsv" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; return 1; }
    if ! ip -4 route show default > "$dir/default-route-v4.txt" 2>/dev/null ||
       ! ip -6 route show default > "$dir/default-route-v6.txt" 2>/dev/null; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
        die "无法完整读取 IPv4/IPv6 默认路由；未创建系统配置事务，也不会修改运行时状态"
        return 1
    fi
    if ! action_transaction_snapshot_path "$CONFIG_FILE" config ||
       ! action_transaction_snapshot_path "$SYSCTL_FILE" sysctl ||
       ! action_transaction_snapshot_path "$LEGACY_SYSCTL_FILE" legacy-sysctl ||
       ! action_transaction_snapshot_path "$SERVICE_FILE" service ||
       ! action_transaction_snapshot_path "$LEGACY_SERVICE_FILE" legacy-service ||
       ! action_transaction_snapshot_path "$PERSIST_SCRIPT" persist-script ||
       ! action_transaction_snapshot_tree "$NIC_POLICY_DIR" nic-policy-dir; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
        return 1
    fi
    if ! action_transaction_capture_unit "$SERVICE_NAME" service ||
       ! action_transaction_capture_unit bbr-optimize-persist.service legacy-service ||
       ! chmod -R go-rwx "$dir"; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
        return 1
    fi
    log INFO "已创建本次操作回滚点: $dir"
}

action_transaction_add_interface() {
    local iface="$1"
    [[ -n "$ACTION_TRANSACTION_DIR" ]] || return 1
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1
    grep -Fqx -- "$iface" <<< "$ACTION_TRANSACTION_INTERFACES" && return 0
    action_qdisc_snapshot "$iface" "$ACTION_TRANSACTION_DIR/qdiscs/$iface.snapshot" || return 1
    ACTION_TRANSACTION_INTERFACES+=$'\n'"$iface"
}

action_transaction_discard_snapshot() {
    local dir="$ACTION_TRANSACTION_DIR"
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
    ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
    [[ -z "$dir" ]] || remove_tree_within "$dir" "$STATE_DIR"
}

action_transaction_begin_multi() {
    local primary="$1" iface interfaces
    action_transaction_begin "$primary" || return 1
    if [[ "$(nic_policy_layout_state 2>/dev/null || true)" == managed ]]; then
        if ! nic_policy_set_validate; then action_transaction_discard_snapshot || true; return 1; fi
        if ! interfaces=$(nic_policy_interface_list); then
            action_transaction_discard_snapshot || true
            die "无法完整枚举多网卡策略接口；未开始系统配置事务"
            return 1
        fi
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            if ! action_transaction_add_interface "$iface"; then action_transaction_discard_snapshot || true; return 1; fi
        done <<< "$interfaces"
    fi
    if (( ${MULTI_NIC_ENABLED:-0} == 0 )) && [[ "${TC_INTERFACE:-auto}" != auto ]]; then
        if ! action_transaction_add_interface "$TC_INTERFACE"; then action_transaction_discard_snapshot || true; return 1; fi
    fi
    if ! chmod -R go-rwx "$ACTION_TRANSACTION_DIR" ||
       ! printf 'complete\n' > "$ACTION_TRANSACTION_DIR/COMPLETE" ||
       ! chmod 0600 "$ACTION_TRANSACTION_DIR/COMPLETE"; then
        action_transaction_discard_snapshot || true
        return 1
    fi
    ACTION_TRANSACTION_READY=1
}

action_transaction_mark_mutated() {
    [[ -n "$ACTION_TRANSACTION_DIR" && "$ACTION_TRANSACTION_READY" == 1 && "$ACTION_TRANSACTION_MUTATED" == 0 ]] || {
        die "系统配置事务尚未完成只读快照，拒绝开始写入"
        return 1
    }
    action_transaction_snapshot_validate || {
        die "系统配置事务快照不完整，或运行时 qdisc filter/队列/路由身份已漂移，拒绝开始写入"
        return 1
    }
    ACTION_TRANSACTION_MUTATED=1
}

configured_state_target_preflight() {
    local target="$1" interfaces other
    interfaces=$(managed_htb_interfaces_strict) || return 1
    while IFS= read -r other; do
        [[ -n "$other" ]] || continue
        if [[ "$other" != "$target" ]]; then
            die "检测到另一张网卡 $other 上仍有受管 HTB；拒绝在 $target 应用持久化状态。请先执行 ${0##*/} tc disable --interface $other"
            return 1
        fi
    done <<< "$interfaces"
    qdisc_guard "$target"
}

tcp_restore_runtime_preflight() {
    local iface="$1" net_root="${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}" key
    validate_interface_name "$iface" && [[ "$iface" != auto && -e "$net_root/$iface" ]] || {
        die "基线绑定的网卡不存在或名称非法: $iface"
        return 1
    }
    tc qdisc show dev "$iface" >/dev/null 2>&1 || { die "无法读取 $iface 的 qdisc；恢复尚未开始"; return 1; }
    tc class show dev "$iface" >/dev/null 2>&1 || { die "无法读取 $iface 的 class；恢复尚未开始"; return 1; }
    qdisc_filter_guard "$iface" || return 1
    if [[ -f "$BASELINE_DIR/qdisc.txt" ]] && ! mq_snapshot_queue_preflight "$iface" "$BASELINE_DIR/qdisc.txt"; then
        die "$iface 的 MQ 基线与当前 TX queue 数不一致，恢复尚未开始"
        return 1
    fi
    while IFS= read -r key; do
        sysctl -n "$key" >/dev/null 2>&1 || { die "无法读取恢复目标 sysctl: $key"; return 1; }
    done < <(tcp_baseline_sysctl_keys)
    ip -4 route show default >/dev/null 2>&1 || { die "无法读取 IPv4 默认路由；恢复尚未开始"; return 1; }
    ip -6 route show default >/dev/null 2>&1 || { die "无法读取 IPv6 默认路由；恢复尚未开始"; return 1; }
    query_unit_enabled_state "$SERVICE_NAME" >/dev/null || return 1
    query_unit_active_state "$SERVICE_NAME" >/dev/null || return 1
    query_unit_enabled_state bbr-optimize-persist.service >/dev/null || return 1
    query_unit_active_state bbr-optimize-persist.service >/dev/null || return 1
}

action_transaction_commit() {
    local dir="$ACTION_TRANSACTION_DIR"
    [[ -n "$dir" ]] || return 0
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
    ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
    remove_tree_within "$dir" "$STATE_DIR" || log WARN "操作已提交，但无法删除临时事务快照: $dir"
}

action_transaction_rollback() {
    local dir="$ACTION_TRANSACTION_DIR" iface="$ACTION_TRANSACTION_IFACE" file rc=0 had_lock="$LOCK_HELD"
    [[ -n "$dir" ]] || return 0
    (( ACTION_TRANSACTION_ROLLING_BACK == 0 )) || return 1
    if (( ACTION_TRANSACTION_MUTATED == 0 )); then
        log INFO "系统配置事务仍处于只读快照阶段；正在丢弃快照，不执行运行时回滚"
        action_transaction_discard_snapshot
        return
    fi
    if (( ACTION_TRANSACTION_READY != 1 )) ||
       [[ ! -f "$dir/COMPLETE" || -L "$dir/COMPLETE" || "$(<"$dir/COMPLETE")" != complete ]]; then
        log ERR "系统配置事务已标记写入但快照不完整；拒绝执行可能破坏系统的回滚，证据保留在 $dir"
        return 1
    fi
    if ! action_transaction_snapshot_validate; then
        log ERR "系统配置事务快照已损坏，或运行时 qdisc filter/队列/路由身份已漂移且不可完整验证；拒绝执行回滚，证据保留在 $dir"
        return 1
    fi
    ACTION_TRANSACTION_ROLLING_BACK=1
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    action_transaction_restore_path "$CONFIG_FILE" config || rc=1
    action_transaction_restore_path "$SYSCTL_FILE" sysctl || rc=1
    action_transaction_restore_path "$LEGACY_SYSCTL_FILE" legacy-sysctl || rc=1
    action_transaction_restore_path "$SERVICE_FILE" service || rc=1
    action_transaction_restore_path "$LEGACY_SERVICE_FILE" legacy-service || rc=1
    action_transaction_restore_path "$PERSIST_SCRIPT" persist-script || rc=1
    action_transaction_restore_tree "$NIC_POLICY_DIR" nic-policy-dir || rc=1
    rmdir "$PERSIST_DIR" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    restore_tcp_sysctl_snapshot_file "$dir/sysctl.tsv" || rc=1
    action_transaction_restore_routes || rc=1
    if [[ -d "$dir/qdiscs" ]]; then
        for file in "$dir/qdiscs"/*.snapshot; do
            [[ -f "$file" ]] || continue
            iface="${file##*/}"; iface="${iface%.snapshot}"
            validate_interface_name "$iface" && [[ "$iface" != auto ]] || { rc=1; continue; }
            restore_action_qdisc "$iface" "$file" || rc=1
        done
    else
        restore_action_qdisc "$iface" "$dir/qdisc.snapshot" || rc=1
    fi
    (( had_lock == 0 )) || release_lock
    action_transaction_restore_unit "$SERVICE_NAME" service || rc=1
    action_transaction_restore_unit bbr-optimize-persist.service legacy-service || rc=1
    if (( had_lock )) && ! acquire_lock 30; then rc=1; fi
    if (( rc == 0 )); then
        remove_tree_within "$dir" "$STATE_DIR" || rc=1
    fi
    if (( rc == 0 )); then
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
        ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0
        log OK "已恢复本次操作前的 qdisc、sysctl、配置和服务状态"
    else
        log ERR "自动回滚未完全成功；事务快照保留在 $dir"
    fi
    ACTION_TRANSACTION_ROLLING_BACK=0
    return "$rc"
}

run_action_transaction_multi() {
    local iface="$1" rc rollback_rc=0; shift
    action_transaction_begin_multi "$iface" || return 1
    action_transaction_mark_mutated || { action_transaction_discard_snapshot || true; return 1; }
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

apply_configured_runtime_steps() {
    local iface="$1"
    # The persistent artifacts already exist when the systemd apply entry is
    # invoked.  Reapply only runtime state here so a later qdisc/route failure
    # cannot rewrite the sysctl drop-in outside this runtime transaction.
    apply_sysctl_profile runtime || return 1
    if (( TC_ENABLED == 1 )); then
        apply_shaping "$iface" "$TC_RATE_MBIT" || return 1
    else
        apply_fq "$iface" || return 1
    fi
    apply_initial_windows
}

apply_configured_runtime_transaction() {
    local iface="$1" snapshot_parent="${TMPDIR:-/tmp}" snapshot_dir rc=0 rollback_rc=0
    nic_runtime_transaction_begin "$snapshot_parent" || return 1
    snapshot_dir="$NIC_RUNTIME_TRANSACTION_DIR"
    if ! capture_runtime_sysctls > "$snapshot_dir/sysctl.tsv"; then
        nic_runtime_transaction_discard || true
        die "持久化运行时应用无法完整快照 sysctl；未修改运行时状态"
        return 1
    fi
    if ! ip -4 route show default > "$snapshot_dir/default-route-v4.txt" 2>/dev/null ||
       ! ip -6 route show default > "$snapshot_dir/default-route-v6.txt" 2>/dev/null; then
        nic_runtime_transaction_discard || true
        die "持久化运行时应用无法完整读取 IPv4/IPv6 默认路由；未修改运行时状态"
        return 1
    fi
    if ! action_qdisc_snapshot "$iface" "$snapshot_dir/$iface.snapshot" ||
       ! nic_runtime_transaction_write_interfaces "$iface" ||
       ! nic_runtime_transaction_mark_mutated; then
        nic_runtime_transaction_discard || true
        die "持久化运行时应用无法建立完整回滚点；未修改运行时状态"
        return 1
    fi
    if apply_configured_runtime_steps "$iface"; then
        nic_runtime_transaction_commit
        return
    else
        rc=$?
    fi
    nic_runtime_transaction_rollback || rollback_rc=$?
    if (( rollback_rc == 0 )); then
        die "持久化运行时应用失败，已恢复本轮 qdisc、sysctl 与路由窗口快照"
        return "$rc"
    fi
    die "持久化运行时应用失败且回滚不完整；快照保留在 $snapshot_dir，请人工检查"
    return "$rollback_rc"
}

apply_configured_state() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl modprobe || return 1; acquire_lock 30 || return 1
    [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || {
        die "持久化配置缺失、不是常规文件或是符号链接: $CONFIG_FILE"
        return 1
    }
    check_config_permissions "$CONFIG_FILE" || return 1
    load_config || return 1
    (( BBR_ENABLED == 1 )) || return 0
    if (( MULTI_NIC_ENABLED == 1 )); then
        nic_apply_runtime_policies
        return
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto ]]; then
        die "检测到旧版 auto 整形配置；为避免默认路由变化后把 ${TC_RATE_MBIT} Mbit 迁移到另一网卡，本次拒绝应用。请重新运行自动调优或显式执行 tc enable RATE --interface DEV"
        return 1
    fi
    local iface
    iface=$(detect_interface "$TC_INTERFACE") || return 1
    configured_state_target_preflight "$iface" || return 1
    if (( TC_ENABLED == 1 )); then
        [[ "$TC_INTERFACE" == "$iface" ]] || { die "整形配置与解析后的目标网卡不一致"; return 1; }
        (( TC_RATE_MBIT > 0 )) || { die "TC_ENABLED=1 但 TC_RATE_MBIT=0"; return 1; }
    fi
    network_tuning_preflight "$iface" "$TC_ENABLED" || return 1
    # All dependency, interface, ownership and qdisc checks above are
    # deliberately read-only.  No sysctl is written until every gate passes.
    apply_configured_runtime_transaction "$iface"
}

install_base_tuning_steps() {
    local iface="$1" profile="$3" role="$4" bandwidth="$5" rtt="$6" mode=fq rate=0 knee=0 margin=3
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    retire_legacy_sysctl || return 1
    load_config || return 1
    nic_migrate_legacy_policy || return 1
    nic_baseline_capture "$iface" || return 1
    if nic_policy_exists "$iface"; then
        nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
        mode="$NIC_POLICY_MODE"; rate="$NIC_POLICY_RATE_MBIT"; knee="$NIC_POLICY_KNEE_MBIT"; margin="$NIC_POLICY_MARGIN_PERCENT"
    fi
    validate_config_value SYSCTL_PROFILE "$profile" && validate_config_value ROLE "$role" || { die "非法 profile/role"; return 1; }
    if [[ "$mode" == shape ]]; then apply_shaping "$iface" "$rate" || return 1; else apply_fq "$iface" || return 1; fi
    nic_policy_write "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt" || return 1
    nic_finalize_multi_config || return 1
    BBR_ENABLED=1
    apply_sysctl_profile || return 1
    apply_initial_windows || return 1
    save_config || { die "运行时已生效，但配置保存失败；未报告安装成功"; return 1; }
    install_persistence || { die "运行时已生效，但持久化安装失败；请修复后重试 install"; return 1; }
    restart_and_verify_persistence || { die "运行时已生效，但开机持久化验证失败"; return 1; }
    log OK "基础调优已安装: BBR + ${SYSCTL_PROFILE} + $([[ "$mode" == shape ]] && echo 'HTB/FQ' || echo 'FQ')（$iface）"
}

install_base_tuning() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands ip tc sysctl modprobe systemctl || return 1
    local requested="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" iface
    iface=$(detect_interface "$requested") || return 1
    [[ "$requested" != auto ]] || auto_tune_route_guard "$iface" "" || return 1
    load_config || return 1
    nic_policy_ownership_preflight "$iface" || return 1
    qdisc_guard "$iface" || return 1
    BANDWIDTH_MBIT="$bandwidth"; network_tuning_preflight "$iface" 1 || return 1
    run_action_transaction_multi "$iface" install_base_tuning_steps "$iface" "$requested" "$profile" "$role" "$bandwidth" "$rtt"
}

prepare_auto_tuning_runtime() {
    local iface="$1" requested="$2" profile="$3" role="$4" bandwidth="$5" rtt="$6"
    shaping_target_preflight "$iface" auto "$requested" || return 1
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    retire_legacy_sysctl || return 1
    load_config || return 1
    nic_migrate_legacy_policy || return 1
    nic_baseline_capture "$iface" || return 1
    nic_stage_candidate_global_model "$iface" "$profile" "$role" "$bandwidth" "$rtt" || return 1
    BBR_ENABLED=1; TC_INTERFACE="$iface"; TC_ENABLED=0; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
    validate_config_value SYSCTL_PROFILE "$SYSCTL_PROFILE" && validate_config_value ROLE "$ROLE" || { die "非法 profile/role"; return 1; }
    apply_sysctl_profile runtime || return 1
    apply_fq "$iface" || return 1
    apply_initial_windows || return 1
    log OK "基础调优已临时应用；最终复验通过前不会写入配置或服务"
}

verify_runtime_tuning() {
    local iface="$1" rc=0
    verify_sysctl_profile_runtime || rc=1
    if (( TC_ENABLED )); then verify_shaping "$iface" "$TC_RATE_MBIT" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    (( rc == 0 )) || { die "临时调优状态验证失败"; return 1; }
    log OK "临时运行时状态验证通过"
}

persist_current_tuning() {
    local iface="$TC_INTERFACE" mode=fq rate=0 knee=0 margin="$TC_MARGIN_PERCENT"
    local profile role bandwidth rtt expected actual
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || { die "自动调优没有绑定具体网卡，拒绝持久化"; return 1; }
    [[ "${AUTO_POLICY_INTERFACE:-}" == "$iface" && -n "${AUTO_POLICY_PROFILE:-}" && -n "${AUTO_POLICY_ROLE:-}" ]] || {
        die "自动调优目标模型缺失或与运行网卡不一致，拒绝持久化"
        return 1
    }
    profile="$AUTO_POLICY_PROFILE"; role="$AUTO_POLICY_ROLE"
    bandwidth="$AUTO_POLICY_BANDWIDTH_MBIT"; rtt="$AUTO_POLICY_RTT_MS"
    expected=$(nic_policy_candidate_global_model "$iface" "$profile" "$role" "$bandwidth" "$rtt") || return 1
    actual="${SYSCTL_PROFILE}"$'\t'"${ROLE}"$'\t'"${BANDWIDTH_MBIT}"$'\t'"${RTT_MS}"$'\t'"${NIC_MODEL_INTERFACE}"
    [[ "$actual" == "$expected" ]] || {
        die "临时全局 TCP 模型已漂移，拒绝把自动调优结果持久化"
        return 1
    }
    if (( TC_ENABLED == 1 )); then mode=shape; rate="$TC_RATE_MBIT"; knee="$TC_KNEE_MBIT"; fi
    nic_policy_write "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt" || return 1
    nic_finalize_multi_config || return 1
    apply_sysctl_profile persistent || return 1
    save_config || { die "配置提交失败"; return 1; }
    install_persistence || { die "持久化安装失败"; return 1; }
    restart_and_verify_persistence || return 1
    verify_system_state || return 1
}

restore_baseline_qdisc() {
    local iface kind
    iface="$TCP_BASELINE_VALIDATED_INTERFACE"
    [[ -n "$iface" ]] || { die "内部错误：恢复 qdisc 前没有已验证的基线网卡"; return 1; }
    [[ -e "${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}/$iface" ]] || { die "基线网卡已消失: $iface"; return 1; }
    kind=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {print $2; exit}' "$BASELINE_DIR/qdisc.txt" 2>/dev/null)
    if ! restore_qdisc_text_snapshot "$iface" "$BASELINE_DIR/qdisc.txt"; then
        log WARN "基线 root qdisc 为 '$kind'，文本快照无法无损重放；已保留快照供人工恢复"
        return 1
    fi
}

restore_baseline_route_windows() {
    restore_default_route_windows_snapshot "$BASELINE_DIR" || {
        log WARN "未能完整恢复默认路由窗口参数"
        return 1
    }
}

restore_baseline() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl || return 1; acquire_lock || return 1
    local rc=0 provenance iface
    [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]] || { die "没有可恢复的基线"; return 1; }
    tcp_baseline_validate "$BASELINE_DIR" || { die "TCP 基线校验失败；未修改运行配置"; return 1; }
    provenance="$TCP_BASELINE_VALIDATED_PROVENANCE"
    iface="$TCP_BASELINE_VALIDATED_INTERFACE"
    log INFO "TCP 基线校验通过: $TCP_BASELINE_VALIDATED_GENERATION / $provenance / $iface"
    tcp_restore_runtime_preflight "$iface" || return 1
    nic_restore_preflight || return 1
    if [[ "$provenance" == legacy-reference ]]; then
        remove_persistence || { die "无法安全移除当前持久化服务；旧版委托恢复尚未执行"; return 1; }
        nic_restore_secondary_baselines || { die "旧版委托恢复前，逐网卡 qdisc 恢复失败；策略和基线均已保留"; return 1; }
        release_lock
        log INFO "将恢复操作交给迁移时保存的旧版本工具"
        bash "$BASELINE_DIR/legacy-tool.sh" restore || { die "旧版本恢复失败；旧备份仍在 $LEGACY_BACKUP_DIR"; return 1; }
        acquire_lock 30 || { die "旧版恢复完成，但无法重新取得管理锁"; return 1; }
        nic_policy_remove_tree || { die "旧版基线已恢复，但无法删除 v8 多网卡策略目录"; return 1; }
        log OK "旧版可信基线恢复完成"
        return 0
    fi
    remove_persistence || rc=1
    nic_restore_secondary_baselines || rc=1
    restore_backed_path "$CONFIG_FILE" config || rc=1
    restore_backed_path "$SYSCTL_FILE" sysctl || rc=1
    restore_backed_path "$LEGACY_SYSCTL_FILE" legacy-sysctl || rc=1
    restore_backed_path "$SERVICE_FILE" service || rc=1
    restore_backed_path "$LEGACY_SERVICE_FILE" legacy-service || rc=1
    restore_backed_path "$PERSIST_SCRIPT" persist-script || rc=1
    restore_runtime_sysctls || rc=1
    restore_baseline_route_windows || rc=1
    restore_baseline_qdisc || rc=1
    nic_policy_remove_tree || rc=1
    systemctl daemon-reload 2>/dev/null || rc=1
    restore_unit_state "$SERVICE_NAME" "$BASELINE_DIR/service.unit" || rc=1
    restore_unit_state bbr-optimize-persist.service "$BASELINE_DIR/legacy-service.unit" || rc=1
    if (( rc == 0 )); then log OK "已恢复首次可信基线；基线和测量历史仍保留在 $STATE_DIR"
    else die "基线只完成了部分恢复；快照仍保留在 $BASELINE_DIR，请查看上述警告"; fi
}

managed_bbr_command() {
    local file="$1"
    [[ -f "$file" || -L "$file" ]] || return 1
    managed_bbr_script_signature "$file"
}

LEGACY_SHELL_START='# ================ net-tcp-tune 快捷别名 ================'
LEGACY_SHELL_END='# ================ net-tcp-tune 快捷别名结束 ================'

legacy_shell_block_valid() {
    local file="$1" start_count end_count start_line end_line
    [[ -f "$file" && ! -L "$file" ]] || return 1
    start_count=$(grep -Fxc "$LEGACY_SHELL_START" "$file" 2>/dev/null || true)
    end_count=$(grep -Fxc "$LEGACY_SHELL_END" "$file" 2>/dev/null || true)
    [[ "$start_count" == 1 && "$end_count" == 1 ]] || return 1
    start_line=$(grep -Fxn "$LEGACY_SHELL_START" "$file" | cut -d: -f1)
    end_line=$(grep -Fxn "$LEGACY_SHELL_END" "$file" | cut -d: -f1)
    [[ "$start_line" =~ ^[0-9]+$ && "$end_line" =~ ^[0-9]+$ && "$start_line" -lt "$end_line" ]]
}

legacy_shell_commands_preflight() {
    local rc_file start_count end_count
    for rc_file in "${HOME:-/root}/.bashrc" "${HOME:-/root}/.bash_profile" "${HOME:-/root}/.zshrc"; do
        [[ -e "$rc_file" || -L "$rc_file" ]] || continue
        [[ -f "$rc_file" ]] || { die "shell 配置不是常规文件: $rc_file"; return 1; }
        start_count=$(grep -Fxc "$LEGACY_SHELL_START" "$rc_file" 2>/dev/null || true)
        end_count=$(grep -Fxc "$LEGACY_SHELL_END" "$rc_file" 2>/dev/null || true)
        if (( start_count == 0 && end_count == 0 )); then continue; fi
        legacy_shell_block_valid "$rc_file" || {
            die "旧版 bbr shell function 标记缺失、重复、倒置或位于符号链接中；拒绝编辑: $rc_file"
            return 1
        }
    done
}

remove_legacy_shell_commands() {
    local rc_file temp changed=0
    legacy_shell_commands_preflight || return 1
    for rc_file in "${HOME:-/root}/.bashrc" "${HOME:-/root}/.bash_profile" "${HOME:-/root}/.zshrc"; do
        [[ -f "$rc_file" ]] || continue
        grep -Fqx "$LEGACY_SHELL_START" "$rc_file" || continue
        temp=$(mktemp "${rc_file}.bbrv3-lite.XXXXXX") || return 1
        if ! sed '/^# ================ net-tcp-tune 快捷别名 ================/,/^# ================ net-tcp-tune 快捷别名结束 ================/d' "$rc_file" > "$temp"; then
            rm -f -- "$temp"; return 1
        fi
        chmod --reference="$rc_file" "$temp" || { rm -f -- "$temp"; die "无法保留 $rc_file 的权限"; return 1; }
        chown --reference="$rc_file" "$temp" || { rm -f -- "$temp"; die "无法保留 $rc_file 的所有者"; return 1; }
        mv -f -- "$temp" "$rc_file" || { rm -f -- "$temp"; return 1; }
        log OK "已从 $rc_file 删除旧版 bbr shell function"
        ((changed+=1))
    done
    LEGACY_SHELL_REMOVED="$changed"
}

remove_cli_command() {
    local current="" candidate resolved removed=0
    local -A seen=()
    legacy_shell_commands_preflight || return 1
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

remove_empty_nic_policy_parent() {
    local owned="${1:-0}" policy="${NIC_POLICY_DIR%/}" parent entry
    case "$owned" in 0) return 0 ;; 1) ;; *) return 1 ;; esac
    [[ ! -e "$policy" && ! -L "$policy" ]] || {
        die "受管策略目录在恢复后仍然存在，拒绝删除管理入口: $policy"
        return 1
    }
    parent=$(dirname -- "$policy") || return 1

    # Only the exact standard path is project-owned at the parent level.
    # Custom paths may point into a directory that existed before this tool,
    # even when their final components happen to use the same names.
    if [[ "$policy" != "$STANDARD_NIC_POLICY_DIR" ]]; then
        log WARN "策略目录使用自定义父路径，卸载不会删除其父目录: $parent"
        return 0
    fi
    if [[ -L "$parent" ]]; then
        log WARN "策略父目录是符号链接，卸载不会删除: $parent"
        return 0
    fi
    [[ -d "$parent" ]] || return 0
    if rmdir -- "$parent" 2>/dev/null; then
        log INFO "已删除空策略父目录: $parent"
        return 0
    fi
    for entry in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
        if [[ -e "$entry" || -L "$entry" ]]; then
            log WARN "策略父目录包含非项目内容，已保留: $parent"
            return 0
        fi
    done
    die "策略父目录为空但无法删除: $parent"
    return 1
}

uninstall_managed() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl readlink grep cut sed mktemp mv rm rmdir dirname chmod chown || return 1
    local purge="${1:-0}" resolved_state restored_tcp=0 restored_dns=0 restored_ipv6=0 interfaces other
    local policy_layout policy_parent_owned=0

    case "$purge" in 0|1) ;; *) die "非法卸载清理模式: $purge"; return 1 ;; esac
    if (( purge )); then
        resolved_state=$(readlink -m -- "$STATE_DIR") || { die "无法解析状态目录: $STATE_DIR"; return 1; }
        [[ "$resolved_state" == /var/lib/bbrv3-lite || "$resolved_state" == /tmp/bbrv3-lite-test-* ]] || {
            die "拒绝清理非标准状态目录: $resolved_state"
            return 1
        }
    fi
    legacy_shell_commands_preflight || return 1
    acquire_lock || return 1

    policy_layout=$(nic_policy_layout_state) || { die "无法识别多网卡策略目录状态"; return 1; }
    case "$policy_layout" in
        absent) ;;
        managed)
            nic_policy_set_validate || return 1
            policy_parent_owned=1
            ;;
        *) die "多网卡策略目录损坏或不属于本项目；为保留恢复证据，本次不会卸载"; return 1 ;;
    esac

    # Restore before deleting either the executable or the only recovery data.
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]]; then
        tcp_baseline_validate "$BASELINE_DIR" || { die "TCP 基线损坏；为保留恢复能力，本次不会卸载任何管理组件"; return 1; }
        restore_baseline || return 1
        restored_tcp=1
    else
        if [[ -e "$NIC_POLICY_DIR" || -L "$NIC_POLICY_DIR" ]]; then
            die "存在多网卡策略但没有可信 TCP 基线；为避免丢失逐网卡恢复信息，本次不会卸载"
            return 1
        fi
        interfaces=$(managed_htb_interfaces_strict) || return 1
        if [[ -n "$interfaces" ]]; then
            while IFS= read -r other; do
                [[ -n "$other" ]] && log ERR "仍有受管 HTB: $other；请先执行 ${0##*/} tc disable --interface $other"
            done <<< "$interfaces"
            die "没有可信 TCP 基线且仍有受管 HTB；已保留配置、服务和 bbr 命令"
            return 1
        fi
        remove_persistence || {
            die "无法完整移除持久化服务；已保留 bbr 命令、配置和恢复状态"
            return 1
        }
        rm -f -- "$CONFIG_FILE" "$SYSCTL_FILE" || {
            die "无法删除管理配置；已保留 bbr 命令和恢复状态"
            return 1
        }
        if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" || -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" ]]; then
            die "管理配置删除后仍然存在；已保留 bbr 命令和恢复状态"
            return 1
        fi
        log WARN "没有 TCP 基线：未发现任何受管 HTB，已移除管理文件；无法精确恢复修改前的运行时 sysctl/qdisc"
    fi
    interfaces=$(managed_htb_interfaces_strict) || return 1
    if [[ -n "$interfaces" ]]; then
        while IFS= read -r other; do
            [[ -n "$other" ]] && log ERR "恢复后仍有受管 HTB: $other；请执行 ${0##*/} tc disable --interface $other"
        done <<< "$interfaces"
        die "为避免遗留整形失去管理入口，已保留 bbr 命令与状态"
        return 1
    fi
    if [[ -f "$DNS_BACKUP_DIR/baseline/manifest" ]]; then dns_restore || return 1; restored_dns=1; fi
    if [[ -f "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" ]]; then ipv6_restore || return 1; restored_ipv6=1; fi

    remove_empty_nic_policy_parent "$policy_parent_owned" || return 1
    remove_cli_command || return 1
    if (( purge )); then
        if [[ -e "$resolved_state" || -L "$resolved_state" ]]; then
            rm -rf -- "$resolved_state" || { die "无法永久删除状态目录: $resolved_state"; return 1; }
        fi
        [[ ! -e "$resolved_state" && ! -L "$resolved_state" ]] || {
            die "状态目录删除后仍然存在: $resolved_state"
            return 1
        }
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
    managed_bbr_script_signature "$PERSIST_SCRIPT" || { printf 'foreign/unrecognized\n'; return; }
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
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then nic_policy_set_validate || rc=1; fi
    verify_sysctl_profile_file || rc=1
    if [[ "$LEGACY_SYSCTL_FILE" != "$SYSCTL_FILE" && ( -e "$LEGACY_SYSCTL_FILE" || -L "$LEGACY_SYSCTL_FILE" ) ]]; then
        log ERR "检测到旧版 sysctl 仍会与当前配置同时加载: $LEGACY_SYSCTL_FILE"
        rc=1
    fi
    [[ -f "$SERVICE_FILE" ]] || { log ERR "systemd unit 缺失: $SERVICE_FILE"; rc=1; }
    if [[ -f "$SERVICE_FILE" ]] && ! grep -Fqx "ExecStart=${PERSIST_SCRIPT} apply" "$SERVICE_FILE"; then
        log ERR "systemd unit 的 ExecStart 与受管脚本路径不一致"
        rc=1
    fi
    if [[ ! -x "$PERSIST_SCRIPT" ]]; then
        log ERR "持久化脚本缺失或不可执行: $PERSIST_SCRIPT"
        rc=1
    elif ! managed_bbr_script_signature "$PERSIST_SCRIPT"; then
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
    local hardware_state="unavailable" queue_state="unavailable" backlog_state="unavailable" scaling_state="unavailable" path_state="none"
    local nic_policy_state=single status_rc=0
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )); then
        nic_policy_state=valid
        if ! nic_global_model_verify; then nic_policy_state=invalid; status_rc=1; fi
        iface="${NIC_MODEL_INTERFACE:-}"
        [[ "$iface" != auto ]] || iface=""
    else
        iface=$(detect_interface "$TC_INTERFACE" 2>/dev/null || true)
    fi
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    profile_state=$([[ -f "$SYSCTL_FILE" ]] && echo installed || echo absent)
    if [[ ! -f "$SERVICE_FILE" ]]; then service_state=absent
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then service_state=enabled
    else service_state=disabled; fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then service_active=active; else service_active=inactive; fi
    config_state=$([[ -f "$CONFIG_FILE" ]] && echo present || echo absent)
    if [[ -f "$BASELINE_DIR/manifest" ]]; then baseline_state="recorded ($(baseline_provenance))"; else baseline_state=missing; fi
    if buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "${iface:-${TC_INTERFACE:-auto}}" 2>/dev/null; then
        buffer_state="$(human_bytes "$BUFFER_MAX") ($BUFFER_REASON)"
        hardware_state="$HARDWARE_CLASS / ${HARDWARE_CPU_COUNT} CPU / ${HARDWARE_MEMORY_MB} MiB"
        queue_state="${HARDWARE_DRIVER} / RX ${HARDWARE_RX_QUEUES} / TX ${HARDWARE_TX_QUEUES} / MTU ${HARDWARE_MTU} / link ${HARDWARE_LINK_MBIT} (${HARDWARE_LINK_TRUST})"
        backlog_state="listen/SYN ${SOMAXCONN}/${TCP_MAX_SYN_BACKLOG} / netdev ${NETDEV_BACKLOG}"
        scaling_state=$(hardware_scaling_note)
    fi
    script_state=$(persistence_script_state)
    path_state=$(latest_path_brief 2>/dev/null || printf 'none\n')
    printf '%-20s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-20s %s\n' "Kernel" "$(uname -r)"
    printf '%-20s %s\n' "Congestion control" "$cc (available: $available)"
    printf '%-20s %s\n' "BBR generation" "$(bbr_generation_status "$cc")"
    printf '%-20s %s\n' "BBR compatibility" "$(bbr_compatibility_status "$cc" "$available")"
    printf '%-20s %s\n' "Sysctl profile" "$SYSCTL_PROFILE ($profile_state)"
    printf '%-20s %s\n' "Tuning model" "$ROLE / ${BANDWIDTH_MBIT} Mbit / ${RTT_MS} ms"
    printf '%-20s %s\n' "Hardware model" "$hardware_state"
    printf '%-20s %s\n' "NIC model" "$queue_state"
    if [[ -n "$iface" ]]; then printf '%-20s %s\n' "NIC offloads" "$(detect_offload_summary "$iface")"; fi
    printf '%-20s %s\n' "Effective bandwidth" "${EFFECTIVE_BANDWIDTH_MBIT:-unknown} Mbit (${EFFECTIVE_BANDWIDTH_SOURCE:-unknown})"
    printf '%-20s %s\n' "Buffer ceiling" "$buffer_state"
    printf '%-20s %s\n' "Queue budgets" "$backlog_state"
    printf '%-20s %s\n' "Scaling note" "$scaling_state"
    printf '%-20s %s\n' "Persistence" "$service_state / $service_active"
    printf '%-20s %s\n' "Persistence script" "$script_state"
    printf '%-20s %s\n' "Config" "$config_state ($CONFIG_FILE)"
    printf '%-20s %s\n' "Baseline" "$baseline_state"
    printf '%-20s %s\n' "Latest path" "$path_state"
    if (( MULTI_NIC_ENABLED == 1 )); then
        printf '%-20s %s\n' "NIC policy mode" "multi / $nic_policy_state / $(nic_policy_interface_list 2>/dev/null | grep -c . || true) managed"
        nic_inventory || status_rc=1
        return "$status_rc"
    fi
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
    if [[ "$kernel" == *xanmod* ]]; then
        printf 'v3 expected (XanMod default; runtime API cannot prove generation)\n'
    elif [[ -n "$module_version" ]]; then
        printf 'unknown (vendor module version %s is not BBR generation proof)\n' "$module_version"
    else
        printf 'unknown (BBR active; not proof of BBRv3)\n'
    fi
}

verify_system_state() {
    local rc=0 iface
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )); then
        nic_global_model_verify || rc=1
        verify_sysctl_profile_runtime || rc=1
        verify_persistence_artifacts || rc=1
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未启用"; rc=1; }
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未运行"; rc=1; }
        nic_verify_runtime_policies || rc=1
        if (( rc == 0 )); then log OK "全部网卡运行时与持久化状态一致"; else die "多网卡验证发现不一致"; fi
        return "$rc"
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto ]]; then
        die "旧版 auto 整形配置未固化实际网卡；持久化应用已暂停，请重新调优或显式指定接口"
        return 1
    fi
    iface=$(detect_interface "$TC_INTERFACE") || return 1
    verify_sysctl_profile_runtime || rc=1
    verify_persistence_artifacts || rc=1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未启用"; rc=1; }
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || { log ERR "持久化服务未运行"; rc=1; }
    if (( TC_ENABLED )); then verify_shaping "$iface" "$TC_RATE_MBIT" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    if (( rc == 0 )); then log OK "运行时与持久化状态一致"; else die "验证发现不一致"; fi
}
