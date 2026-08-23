# -----------------------------------------------------------------------------
# Config: strict KEY=VALUE parser. Configuration is data and is never sourced.
# -----------------------------------------------------------------------------

reset_config() {
    SCHEMA_VERSION="$STATE_SCHEMA"
    BBR_ENABLED=1
    SYSCTL_PROFILE="balanced"
    ROLE="mixed"
    BANDWIDTH_MBIT=0
    RTT_MS=0
    TC_ENABLED=0
    TC_INTERFACE="auto"
    TC_RATE_MBIT=0
    TC_KNEE_MBIT=0
    TC_MARGIN_PERCENT=3
    INITCWND=0
    INITRWND=0
    MULTI_NIC_ENABLED=0
    NIC_MODEL_INTERFACE=auto
}

config_key_known() {
    case "$1" in
        SCHEMA_VERSION|BBR_ENABLED|SYSCTL_PROFILE|ROLE|BANDWIDTH_MBIT|RTT_MS|TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT|TC_KNEE_MBIT|TC_MARGIN_PERCENT|INITCWND|INITRWND|MULTI_NIC_ENABLED) return 0 ;;
        *) return 1 ;;
    esac
}

validate_interface_name() {
    local iface="${1:-}"
    [[ "$iface" == auto ]] && return 0
    # Linux IFNAMSIZ permits at most 15 visible bytes. Reject path-like dot
    # components even though later tc/ip calls would normally fail: interface
    # names are also used below /sys and in immutable snapshot metadata.
    [[ "$iface" != . && "$iface" != .. && "$iface" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]
}

validate_config_value() {
    local key="$1" value="$2"
    case "$key" in
        SCHEMA_VERSION) [[ "$value" == "$STATE_SCHEMA" ]] ;;
        BBR_ENABLED|TC_ENABLED|MULTI_NIC_ENABLED) [[ "$value" == 0 || "$value" == 1 ]] ;;
        SYSCTL_PROFILE) [[ "$value" == balanced || "$value" == adaptive ]] ;;
        ROLE) [[ "$value" == proxy || "$value" == bulk || "$value" == mixed ]] ;;
        BANDWIDTH_MBIT|TC_RATE_MBIT|TC_KNEE_MBIT) is_uint "$value" && (( value >= 0 && value <= 1000000 )) ;;
        RTT_MS) is_uint "$value" && (( value >= 0 && value <= 60000 )) ;;
        TC_MARGIN_PERCENT) is_uint "$value" && (( value <= 25 )) ;;
        INITCWND|INITRWND) is_uint "$value" && (( value <= 100 )) ;;
        TC_INTERFACE) validate_interface_name "$value" ;;
        *) return 1 ;;
    esac
}

set_config_value() {
    local key="$1" value="$2"
    config_key_known "$key" || return 1
    validate_config_value "$key" "$value" || return 1
    printf -v "$key" '%s' "$value"
}

check_config_permissions() {
    local file="$1" mode owner
    [[ -e "$file" ]] || return 0
    mode=$(stat -c '%a' "$file" 2>/dev/null) || return 1
    owner=$(stat -c '%u:%g' "$file" 2>/dev/null) || return 1
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        [[ "$owner" == "0:0" ]] || die "配置文件必须属于 root:root: $file"
    fi
    [[ "$mode" == 600 || "$mode" == 644 ]] || die "配置文件权限必须为 600 或 644: $file (当前 $mode)"
}

load_config() {
    local file="${1:-$CONFIG_FILE}" line key value lineno=0
    local -A seen=()
    reset_config
    [[ -f "$file" ]] || return 0
    check_config_permissions "$file" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno+=1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]]; then
            die "非法配置格式: ${file}:${lineno}"
            return 1
        fi
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]+x}" ]] || { die "配置字段重复: ${file}:${lineno}: ${key}"; return 1; }
        seen[$key]=1
        if ! set_config_value "$key" "$value"; then
            die "未知或非法配置: ${file}:${lineno}: ${key}"
            return 1
        fi
    done < "$file"
    [[ "$SCHEMA_VERSION" == "$STATE_SCHEMA" ]] || die "配置 schema 不兼容: $SCHEMA_VERSION"
}

write_config_stream() {
    printf '%s\n' \
        "# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}; do not source this file." \
        "SCHEMA_VERSION=${STATE_SCHEMA}" \
        "BBR_ENABLED=${BBR_ENABLED}" \
        "SYSCTL_PROFILE=${SYSCTL_PROFILE}" \
        "ROLE=${ROLE}" \
        "BANDWIDTH_MBIT=${BANDWIDTH_MBIT}" \
        "RTT_MS=${RTT_MS}" \
        "TC_ENABLED=${TC_ENABLED}" \
        "TC_INTERFACE=${TC_INTERFACE}" \
        "TC_RATE_MBIT=${TC_RATE_MBIT}" \
        "TC_KNEE_MBIT=${TC_KNEE_MBIT}" \
        "TC_MARGIN_PERCENT=${TC_MARGIN_PERCENT}" \
        "INITCWND=${INITCWND}" \
        "INITRWND=${INITRWND}" \
        "MULTI_NIC_ENABLED=${MULTI_NIC_ENABLED}"
}

save_config() {
    local file="${1:-$CONFIG_FILE}" temp runtime_iface runtime_rate
    # Old configurations with TC_INTERFACE=auto remain readable. New shaping
    # commits, however, must pin the interface that was actually changed so a
    # later default-route change cannot move an old rate onto another NIC.
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto && -n "${TC_SESSION_HTB_IFACE:-}" ]]; then
        runtime_iface="$TC_SESSION_HTB_IFACE"
        validate_interface_name "$runtime_iface" || { die "拒绝固化非法运行时网卡: $runtime_iface"; return 1; }
        managed_htb "$runtime_iface" || { die "拒绝固化 auto 网卡：$runtime_iface 上没有可验证的受管 HTB"; return 1; }
        runtime_rate=$(managed_rate_mbit "$runtime_iface" 2>/dev/null || true)
        [[ "$runtime_rate" == "$TC_RATE_MBIT" ]] || {
            die "拒绝固化 auto 网卡：$runtime_iface 运行速率 ${runtime_rate:-unknown} 与配置 $TC_RATE_MBIT 不一致"
            return 1
        }
        TC_INTERFACE="$runtime_iface"
        log INFO "已将整形持久化接口固化为实际网卡: $TC_INTERFACE"
    fi
    if (( MULTI_NIC_ENABLED == 1 )); then
        [[ "$TC_ENABLED" == 0 && "$TC_INTERFACE" == auto && "$TC_RATE_MBIT" == 0 && "$TC_KNEE_MBIT" == 0 ]] || {
            die "多网卡模式不能同时保存旧版单网卡 TC 字段"
            return 1
        }
        if declare -F nic_policy_set_validate >/dev/null; then nic_policy_set_validate || return 1; fi
    fi
    for key in SCHEMA_VERSION BBR_ENABLED SYSCTL_PROFILE ROLE BANDWIDTH_MBIT RTT_MS TC_ENABLED TC_INTERFACE TC_RATE_MBIT TC_KNEE_MBIT TC_MARGIN_PERCENT INITCWND INITRWND MULTI_NIC_ENABLED; do
        validate_config_value "$key" "${!key}" || { die "拒绝写入非法配置: $key=${!key}"; return 1; }
    done
    temp=$(mktemp) || return 1
    write_config_stream > "$temp"
    atomic_install "$temp" "$file" 0600 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

reset_config
