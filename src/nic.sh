# -----------------------------------------------------------------------------
# Multi-NIC policy: one global TCP model plus independently managed qdiscs.
# -----------------------------------------------------------------------------

NIC_POLICY_SCHEMA="1"
NIC_POLICY_FORMAT="bbrv3-lite-nic-policy"
NIC_BASELINE_SCHEMA="1"
NIC_BASELINE_FORMAT="bbrv3-lite-nic-baseline"
NIC_RUNTIME_TRANSACTION_DIR=""
NIC_RUNTIME_TRANSACTION_PARENT=""
NIC_RUNTIME_TRANSACTION_MUTATED=0
NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
NIC_RUNTIME_TRANSACTION_READY=0

nic_policy_reset_record() {
    NIC_POLICY_INTERFACE=""
    NIC_POLICY_MATCH_MAC=""
    NIC_POLICY_MODE=""
    NIC_POLICY_RATE_MBIT=0
    NIC_POLICY_KNEE_MBIT=0
    NIC_POLICY_MARGIN_PERCENT=3
    NIC_POLICY_PROFILE=balanced
    NIC_POLICY_ROLE=mixed
    NIC_POLICY_BANDWIDTH_MBIT=0
    NIC_POLICY_RTT_MS=0
}

nic_sysfs_root() { printf '%s\n' "${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}"; }

nic_interface_exists() {
    local iface="$1" root
    root=$(nic_sysfs_root)
    validate_interface_name "$iface" && [[ "$iface" != auto && ( -e "$root/$iface" || -L "$root/$iface" ) ]]
}

nic_current_mac() {
    local iface="$1" root value
    root=$(nic_sysfs_root)
    value=$(tr 'A-F' 'a-f' < "$root/$iface/address" 2>/dev/null || true)
    if [[ "$value" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}

nic_validate_mac() { [[ "$1" == unknown || "$1" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; }

nic_interface_manageability() {
    local iface="$1"
    if ! nic_interface_exists "$iface"; then printf 'missing\n'; return 1; fi
    if [[ "$iface" == lo ]]; then printf 'loopback\n'; return 1; fi
    if interface_is_excluded "$iface" && [[ "${BBRV3_ALLOW_VIRTUAL_NIC:-0}" != 1 ]]; then
        printf 'protected-virtual\n'
        return 1
    fi
    printf 'eligible\n'
}

nic_require_manageable() {
    local iface="$1" state
    state=$(nic_interface_manageability "$iface") || {
        die "网卡 $iface 不可由多网卡策略接管: $state"
        return 1
    }
}

nic_policy_manifest_validate() {
    local file="$NIC_POLICY_DIR/.manifest" line1 line2 mode owner
    [[ -d "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" ]] || return 1
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mode=$(stat -c '%a' "$NIC_POLICY_DIR" 2>/dev/null) || return 1
    [[ "$mode" == 700 ]] || return 1
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        owner=$(stat -c '%u:%g' "$NIC_POLICY_DIR" 2>/dev/null) || return 1
        [[ "$owner" == 0:0 ]] || return 1
    fi
    check_config_permissions "$file" || return 1
    IFS= read -r line1 < "$file" || return 1
    line2=$(sed -n '2p' "$file") || return 1
    [[ "$line1" == $'SCHEMA\t'"$NIC_POLICY_SCHEMA" && "$line2" == $'FORMAT\t'"$NIC_POLICY_FORMAT" ]] || return 1
    [[ "$(wc -l < "$file" | awk '{print $1}')" == 2 ]]
}

nic_policy_directory_entries_validate() {
    local entry name had_nullglob=0 had_dotglob=0
    local -a entries=()
    [[ -d "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" && -r "$NIC_POLICY_DIR" && -x "$NIC_POLICY_DIR" ]] || return 1
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    entries=("$NIC_POLICY_DIR"/*)
    (( had_nullglob )) || shopt -u nullglob
    (( had_dotglob )) || shopt -u dotglob
    for entry in "${entries[@]}"; do
        name="${entry##*/}"
        case "$name" in
            .manifest) [[ -f "$entry" && ! -L "$entry" ]] || { die "网卡策略清单类型非法: $entry"; return 1; } ;;
            *.conf) [[ -f "$entry" && ! -L "$entry" ]] || { die "网卡策略必须是非符号链接常规文件: $entry"; return 1; } ;;
            *) die "多网卡策略目录含未知条目: $entry"; return 1 ;;
        esac
    done
}

nic_policy_layout_state() {
    if [[ ! -e "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" ]]; then printf 'absent\n'
    elif nic_policy_manifest_validate; then printf 'managed\n'
    else printf 'foreign-or-corrupt\n'
    fi
}

nic_policy_ensure_layout() {
    local state temp
    state=$(nic_policy_layout_state)
    case "$state" in
        managed) return 0 ;;
        foreign-or-corrupt)
            die "多网卡策略目录存在但缺少有效项目清单，拒绝接管: $NIC_POLICY_DIR"
            return 1
            ;;
    esac
    mkdir -p -- "$NIC_POLICY_DIR" || return 1
    chmod 0700 "$NIC_POLICY_DIR" 2>/dev/null || true
    temp=$(mktemp) || return 1
    printf 'SCHEMA\t%s\nFORMAT\t%s\n' "$NIC_POLICY_SCHEMA" "$NIC_POLICY_FORMAT" > "$temp"
    atomic_install "$temp" "$NIC_POLICY_DIR/.manifest" 0600 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

nic_policy_files() {
    local file
    [[ "$(nic_policy_layout_state)" == managed ]] || return 0
    for file in "$NIC_POLICY_DIR"/*.conf; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        printf '%s\n' "$file"
    done | LC_ALL=C sort
}

# Buffer the producer before exposing any path to a caller.  In particular, a
# glob/sort/read failure must not leak a valid-looking prefix that a process
# substitution could mistake for the complete policy set.
nic_policy_files_checked() {
    local files
    if ! files=$(nic_policy_files); then
        die "无法完整枚举多网卡策略；拒绝使用不完整策略集合"
        return 1
    fi
    [[ -z "$files" ]] || printf '%s\n' "$files"
}

nic_policy_load_file() {
    local file="$1" line key value lineno=0 expected count=0
    local -A seen=()
    nic_policy_reset_record
    [[ -f "$file" && ! -L "$file" ]] || { die "网卡策略不是常规文件: $file"; return 1; }
    check_config_permissions "$file" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno+=1)); line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]] || {
            die "非法网卡策略格式: $file:$lineno"
            return 1
        }
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]+x}" ]] || { die "网卡策略字段重复: $file:$lineno:$key"; return 1; }
        seen[$key]=1; ((count+=1))
        case "$key" in
            SCHEMA) [[ "$value" == "$NIC_POLICY_SCHEMA" ]] || { die "网卡策略 schema 不兼容: $value"; return 1; } ;;
            FORMAT) [[ "$value" == "$NIC_POLICY_FORMAT" ]] || { die "网卡策略格式标记不匹配"; return 1; } ;;
            INTERFACE) validate_interface_name "$value" && [[ "$value" != auto ]] || { die "网卡策略接口非法: $value"; return 1; }; NIC_POLICY_INTERFACE="$value" ;;
            MATCH_MAC) nic_validate_mac "$value" || { die "网卡策略 MAC 非法: $value"; return 1; }; NIC_POLICY_MATCH_MAC="$value" ;;
            MODE) [[ "$value" == fq || "$value" == shape ]] || { die "网卡策略 MODE 只支持 fq/shape"; return 1; }; NIC_POLICY_MODE="$value" ;;
            RATE_MBIT) validate_config_value TC_RATE_MBIT "$value" || return 1; NIC_POLICY_RATE_MBIT="$value" ;;
            KNEE_MBIT) validate_config_value TC_KNEE_MBIT "$value" || return 1; NIC_POLICY_KNEE_MBIT="$value" ;;
            MARGIN_PERCENT) validate_config_value TC_MARGIN_PERCENT "$value" || return 1; NIC_POLICY_MARGIN_PERCENT="$value" ;;
            PROFILE) validate_config_value SYSCTL_PROFILE "$value" || return 1; NIC_POLICY_PROFILE="$value" ;;
            ROLE) validate_config_value ROLE "$value" || return 1; NIC_POLICY_ROLE="$value" ;;
            BANDWIDTH_MBIT) validate_config_value BANDWIDTH_MBIT "$value" || return 1; NIC_POLICY_BANDWIDTH_MBIT="$value" ;;
            RTT_MS) validate_config_value RTT_MS "$value" || return 1; NIC_POLICY_RTT_MS="$value" ;;
            *) die "网卡策略含未知字段: $file:$lineno:$key"; return 1 ;;
        esac
    done < "$file"
    (( count == 12 )) || { die "网卡策略字段集合不完整: $file"; return 1; }
    expected="${file##*/}"; expected="${expected%.conf}"
    [[ "$expected" == "$NIC_POLICY_INTERFACE" ]] || { die "网卡策略文件名与 INTERFACE 不一致: $file"; return 1; }
    if [[ "$NIC_POLICY_MODE" == shape ]]; then
        (( NIC_POLICY_RATE_MBIT > 0 )) || { die "shape 策略 RATE_MBIT 必须大于 0: $file"; return 1; }
        (( NIC_POLICY_KNEE_MBIT == 0 || NIC_POLICY_KNEE_MBIT >= NIC_POLICY_RATE_MBIT )) || { die "KNEE_MBIT 不能低于 RATE_MBIT: $file"; return 1; }
    else
        (( NIC_POLICY_RATE_MBIT == 0 && NIC_POLICY_KNEE_MBIT == 0 )) || { die "fq 策略不能携带整形速率: $file"; return 1; }
    fi
    (( NIC_POLICY_BANDWIDTH_MBIT == 0 && NIC_POLICY_RTT_MS == 0 )) ||
        (( NIC_POLICY_BANDWIDTH_MBIT > 0 && NIC_POLICY_RTT_MS > 0 )) || {
            die "网卡策略 bandwidth/rtt 必须同时为零或同时非零: $file"
            return 1
        }
    [[ "$NIC_POLICY_PROFILE" != adaptive || ( "$NIC_POLICY_BANDWIDTH_MBIT" -gt 0 && "$NIC_POLICY_RTT_MS" -gt 0 ) ]] || {
        die "adaptive 网卡策略必须提供非零 bandwidth/rtt: $file"
        return 1
    }
}

nic_policy_path() { printf '%s/%s.conf\n' "$NIC_POLICY_DIR" "$1"; }
nic_policy_exists() { [[ -f "$(nic_policy_path "$1")" && ! -L "$(nic_policy_path "$1")" ]]; }

nic_policy_set_validate_files() {
    local files="$1" state file count=0
    state=$(nic_policy_layout_state)
    [[ "$state" == managed ]] || { die "多网卡模式需要有效策略目录，当前: $state"; return 1; }
    nic_policy_directory_entries_validate || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || return 1
        ((count+=1))
    done <<< "$files"
    return 0
}

nic_policy_set_validate() {
    local files
    files=$(nic_policy_files_checked) || return 1
    nic_policy_set_validate_files "$files"
}

nic_policy_write() {
    local iface="$1" mode="$2" rate="$3" knee="$4" margin="$5" profile="$6" role="$7" bandwidth="$8" rtt="$9"
    local mac temp path
    nic_require_manageable "$iface" || return 1
    [[ "$mode" == fq || "$mode" == shape ]] || return 1
    validate_config_value TC_RATE_MBIT "$rate" && validate_config_value TC_KNEE_MBIT "$knee" &&
        validate_config_value TC_MARGIN_PERCENT "$margin" && validate_config_value SYSCTL_PROFILE "$profile" && validate_config_value ROLE "$role" &&
        validate_config_value BANDWIDTH_MBIT "$bandwidth" && validate_config_value RTT_MS "$rtt" || return 1
    if [[ "$mode" == shape ]]; then
        (( rate > 0 && ( knee == 0 || knee >= rate ) )) || { die "非法整形速率/knee"; return 1; }
    else rate=0; knee=0
    fi
    (( bandwidth == 0 && rtt == 0 )) || (( bandwidth > 0 && rtt > 0 )) || { die "bandwidth/rtt 必须成对提供"; return 1; }
    [[ "$profile" != adaptive || ( "$bandwidth" -gt 0 && "$rtt" -gt 0 ) ]] || { die "adaptive 策略必须提供非零 bandwidth/rtt"; return 1; }
    nic_policy_ensure_layout || return 1
    mac=$(nic_current_mac "$iface")
    path=$(nic_policy_path "$iface")
    temp=$(mktemp) || return 1
    printf '%s\n' \
        "# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}; strict data file." \
        "SCHEMA=${NIC_POLICY_SCHEMA}" "FORMAT=${NIC_POLICY_FORMAT}" "INTERFACE=${iface}" "MATCH_MAC=${mac}" \
        "MODE=${mode}" "RATE_MBIT=${rate}" "KNEE_MBIT=${knee}" "MARGIN_PERCENT=${margin}" \
        "PROFILE=${profile}" "ROLE=${role}" "BANDWIDTH_MBIT=${bandwidth}" "RTT_MS=${rtt}" > "$temp"
    atomic_install "$temp" "$path" 0600 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    nic_policy_load_file "$path"
}

nic_policy_remove() {
    local iface="$1" path
    path=$(nic_policy_path "$iface")
    [[ ! -e "$path" && ! -L "$path" ]] || { [[ -f "$path" && ! -L "$path" ]] || { die "拒绝删除非普通策略文件: $path"; return 1; }; rm -f -- "$path"; }
}

nic_policy_interface_list() {
    local files file interfaces=""
    files=$(nic_policy_files_checked) || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" >/dev/null || return 1
        interfaces+="${interfaces:+$'\n'}$NIC_POLICY_INTERFACE"
    done <<< "$files"
    [[ -z "$interfaces" ]] || printf '%s\n' "$interfaces"
}

nic_policy_validate_identity() {
    local iface="$NIC_POLICY_INTERFACE" current
    nic_interface_exists "$iface" || { die "受管网卡已消失: $iface"; return 1; }
    current=$(nic_current_mac "$iface")
    if [[ "$NIC_POLICY_MATCH_MAC" != unknown && "$current" != "$NIC_POLICY_MATCH_MAC" ]]; then
        die "网卡身份漂移: $iface MAC=$current，策略记录=$NIC_POLICY_MATCH_MAC；拒绝把旧速率应用到新设备"
        return 1
    fi
}

nic_aggregate_model_rows() {
    local record_profile record_role record_bandwidth record_rtt record_iface extra score role_rank count=0 adaptive_seen=0 adaptive_score=-1 balanced_score=-1
    local profile=balanced role=mixed bandwidth=0 rtt=0 iface=auto global_role=proxy global_role_rank=-1
    local adaptive_bandwidth=0 adaptive_rtt=0 adaptive_iface=auto balanced_bandwidth=0 balanced_rtt=0 balanced_iface=auto
    while IFS=$'\t' read -r record_profile record_role record_bandwidth record_rtt record_iface extra; do
        [[ -n "$record_profile" ]] || continue
        [[ -z "$extra" ]] || return 1
        validate_config_value SYSCTL_PROFILE "$record_profile" && validate_config_value ROLE "$record_role" &&
            validate_config_value BANDWIDTH_MBIT "$record_bandwidth" && validate_config_value RTT_MS "$record_rtt" &&
            validate_interface_name "$record_iface" || return 1
        (( record_bandwidth == 0 && record_rtt == 0 )) || (( record_bandwidth > 0 && record_rtt > 0 )) || return 1
        [[ "$record_profile" != adaptive || ( "$record_bandwidth" -gt 0 && "$record_rtt" -gt 0 ) ]] || return 1
        ((count+=1))
        case "$record_role" in proxy) role_rank=0 ;; mixed) role_rank=1 ;; bulk) role_rank=2 ;; *) return 1 ;; esac
        if (( role_rank > global_role_rank )); then global_role_rank=$role_rank; global_role="$record_role"; fi
        if [[ "$record_profile" == adaptive ]]; then
            adaptive_seen=1
            score=$((record_bandwidth * record_rtt))
            if (( score > adaptive_score )); then
                adaptive_score=$score; adaptive_bandwidth="$record_bandwidth"; adaptive_rtt="$record_rtt"; adaptive_iface="$record_iface"
            fi
        elif [[ "$record_profile" == balanced ]] && (( record_bandwidth > balanced_score )); then
            balanced_score="$record_bandwidth"; balanced_bandwidth="$record_bandwidth"; balanced_rtt="$record_rtt"; balanced_iface="$record_iface"
        else
            [[ "$record_profile" == balanced ]] || return 1
        fi
    done
    if (( count == 0 )); then
        printf 'balanced\tmixed\t0\t0\tauto\n'
        return 0
    fi
    role="$global_role"
    if (( adaptive_seen )); then
        profile=adaptive; bandwidth="$adaptive_bandwidth"; rtt="$adaptive_rtt"; iface="$adaptive_iface"
    else
        profile=balanced; bandwidth="$balanced_bandwidth"; rtt="$balanced_rtt"; iface="$balanced_iface"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$profile" "$role" "$bandwidth" "$rtt" "$iface"
}

nic_policy_model_rows_files() {
    local excluded="$1" files="$2" file rows=""
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" >/dev/null || return 1
        [[ -z "$excluded" || "$NIC_POLICY_INTERFACE" != "$excluded" ]] || continue
        rows+="${rows:+$'\n'}${NIC_POLICY_PROFILE}"$'\t'"${NIC_POLICY_ROLE}"$'\t'"${NIC_POLICY_BANDWIDTH_MBIT}"$'\t'"${NIC_POLICY_RTT_MS}"$'\t'"${NIC_POLICY_INTERFACE}"
    done <<< "$files"
    [[ -z "$rows" ]] || printf '%s\n' "$rows"
}

nic_policy_model_rows() {
    local excluded="${1:-}" files
    files=$(nic_policy_files_checked) || return 1
    nic_policy_model_rows_files "$excluded" "$files"
}

nic_policy_global_model_files() {
    local files="$1" rows
    nic_policy_set_validate_files "$files" || return 1
    rows=$(nic_policy_model_rows_files "" "$files") || return 1
    nic_aggregate_model_rows <<< "$rows"
}

nic_policy_global_model() {
    local files
    files=$(nic_policy_files_checked) || return 1
    nic_policy_global_model_files "$files"
}

nic_policy_candidate_global_model() {
    local target="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" rows legacy_rtt files=""
    case "$(nic_policy_layout_state)" in
        managed)
            files=$(nic_policy_files_checked) || return 1
            nic_policy_set_validate_files "$files" || return 1
            ;;
        absent) ;;
        *) return 1 ;;
    esac
    rows=$(nic_policy_model_rows_files "$target" "$files") || return 1
    if (( ${MULTI_NIC_ENABLED:-0} == 0 )) && [[ "${TC_INTERFACE:-auto}" != auto && "${TC_INTERFACE:-auto}" != "$target" ]]; then
        legacy_rtt="$RTT_MS"
        if [[ "$SYSCTL_PROFILE" == balanced ]] && (( BANDWIDTH_MBIT == 0 )); then legacy_rtt=0; fi
        rows+="${rows:+$'\n'}${SYSCTL_PROFILE}"$'\t'"${ROLE}"$'\t'"${BANDWIDTH_MBIT}"$'\t'"${legacy_rtt}"$'\t'"${TC_INTERFACE}"
    fi
    rows+="${rows:+$'\n'}${profile}"$'\t'"${role}"$'\t'"${bandwidth}"$'\t'"${rtt}"$'\t'"${target}"
    nic_aggregate_model_rows <<< "$rows"
}

nic_auto_policy_reset() {
    AUTO_POLICY_INTERFACE=""
    AUTO_POLICY_PROFILE=""
    AUTO_POLICY_ROLE=""
    AUTO_POLICY_BANDWIDTH_MBIT=0
    AUTO_POLICY_RTT_MS=0
}

# Stage the target NIC model separately from the global TCP model.  TCP sysctls
# are host-wide, so a temporary auto-tune run must already honour every other
# managed NIC.  Keeping the target values in AUTO_POLICY_* also prevents the
# aggregate model from being written back into the target's policy file.
nic_stage_candidate_global_model() {
    local iface="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" values
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || { die "自动调优必须绑定具体网卡"; return 1; }
    validate_config_value SYSCTL_PROFILE "$profile" && validate_config_value ROLE "$role" &&
        validate_config_value BANDWIDTH_MBIT "$bandwidth" && validate_config_value RTT_MS "$rtt" || return 1
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; fi
    (( bandwidth == 0 && rtt == 0 )) || (( bandwidth > 0 && rtt > 0 )) || {
        die "自动调优目标的 bandwidth/rtt 必须同时为零或同时非零"
        return 1
    }
    [[ "$profile" != adaptive || ( "$bandwidth" -gt 0 && "$rtt" -gt 0 ) ]] || {
        die "adaptive 自动调优目标必须提供非零 bandwidth/rtt"
        return 1
    }
    values=$(nic_policy_candidate_global_model "$iface" "$profile" "$role" "$bandwidth" "$rtt") || return 1
    AUTO_POLICY_INTERFACE="$iface"
    AUTO_POLICY_PROFILE="$profile"
    AUTO_POLICY_ROLE="$role"
    AUTO_POLICY_BANDWIDTH_MBIT="$bandwidth"
    AUTO_POLICY_RTT_MS="$rtt"
    IFS=$'\t' read -r SYSCTL_PROFILE ROLE BANDWIDTH_MBIT RTT_MS NIC_MODEL_INTERFACE <<< "$values"
}

nic_sync_global_model() {
    local values
    values=$(nic_policy_global_model) || return 1
    IFS=$'\t' read -r SYSCTL_PROFILE ROLE BANDWIDTH_MBIT RTT_MS NIC_MODEL_INTERFACE <<< "$values"
}

nic_global_model_verify_files() {
    local files="$1" values expected_profile expected_role expected_bandwidth expected_rtt expected_iface
    values=$(nic_policy_global_model_files "$files") || return 1
    IFS=$'\t' read -r expected_profile expected_role expected_bandwidth expected_rtt expected_iface <<< "$values"
    NIC_MODEL_INTERFACE="$expected_iface"
    [[ "$SYSCTL_PROFILE" == "$expected_profile" && "$ROLE" == "$expected_role" &&
       "$BANDWIDTH_MBIT" == "$expected_bandwidth" && "$RTT_MS" == "$expected_rtt" ]] || {
        die "全局 TCP 模型与多网卡策略不一致：当前 $SYSCTL_PROFILE/$ROLE/$BANDWIDTH_MBIT/$RTT_MS，期望 $expected_profile/$expected_role/$expected_bandwidth/$expected_rtt"
        return 1
    }
}

nic_global_model_verify() {
    local files
    files=$(nic_policy_files_checked) || return 1
    nic_global_model_verify_files "$files"
}

nic_reset_legacy_tc_fields() {
    TC_ENABLED=0; TC_INTERFACE=auto; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
}

nic_baseline_dir() { printf '%s/%s\n' "$NIC_STATE_DIR" "$1"; }

nic_baseline_validate() {
    local iface="$1" dir manifest line key value source="" recorded_iface="" mac="" count=0 mode owner entry name
    local -A seen=()
    dir=$(nic_baseline_dir "$iface"); manifest="$dir/manifest"
    [[ -d "$dir" && ! -L "$dir" && -f "$manifest" && ! -L "$manifest" ]] || { die "网卡基线缺失或类型非法: $iface"; return 1; }
    mode=$(stat -c '%a' "$dir" 2>/dev/null) || return 1
    [[ "$mode" == 700 ]] || { die "网卡基线目录权限必须为 700: $dir"; return 1; }
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        owner=$(stat -c '%u:%g' "$dir" 2>/dev/null) || return 1
        [[ "$owner" == 0:0 ]] || { die "网卡基线目录必须属于 root:root: $dir"; return 1; }
    fi
    check_config_permissions "$manifest" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || { die "网卡基线清单格式非法: $iface"; return 1; }
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -z "${seen[$key]+x}" ]] || { die "网卡基线字段重复: $iface/$key"; return 1; }
        seen[$key]=1; ((count+=1))
        case "$key" in
            SCHEMA) [[ "$value" == "$NIC_BASELINE_SCHEMA" ]] || return 1 ;;
            FORMAT) [[ "$value" == "$NIC_BASELINE_FORMAT" ]] || return 1 ;;
            INTERFACE) recorded_iface="$value" ;;
            MATCH_MAC) mac="$value" ;;
            SOURCE) source="$value" ;;
            CREATED_AT) [[ "$value" =~ ^[0-9]{4}- ]] || return 1 ;;
            CREATED_BY) [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1 ;;
            *) die "网卡基线含未知字段: $key"; return 1 ;;
        esac
    done < "$manifest"
    (( count == 7 )) && [[ "$recorded_iface" == "$iface" ]] && nic_validate_mac "$mac" || { die "网卡基线字段集合非法: $iface"; return 1; }
    case "$source" in
        global)
            tcp_baseline_validate "$BASELINE_DIR" >/dev/null || return 1
            [[ "$TCP_BASELINE_VALIDATED_INTERFACE" == "$iface" && "$TCP_BASELINE_VALIDATED_PROVENANCE" != legacy-reference ]] || {
                die "网卡基线引用的全局基线不匹配: $iface"
                return 1
            }
            [[ ! -e "$dir/qdisc.snapshot" && ! -L "$dir/qdisc.snapshot" ]] || return 1
            ;;
        snapshot)
            [[ -f "$dir/qdisc.snapshot" && ! -L "$dir/qdisc.snapshot" ]] || return 1
            check_config_permissions "$dir/qdisc.snapshot" || return 1
            action_qdisc_snapshot_validate "$dir/qdisc.snapshot" || { die "网卡 qdisc 基线格式非法: $iface"; return 1; }
            ;;
        *) die "网卡基线 SOURCE 非法: $iface"; return 1 ;;
    esac
    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        case "$name" in manifest|qdisc.snapshot) ;; *) die "网卡基线目录含未知条目: $entry"; return 1 ;; esac
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

nic_baseline_identity_validate() {
    local iface="$1" dir recorded current
    dir=$(nic_baseline_dir "$iface")
    recorded=$(awk -F'\t' '$1=="MATCH_MAC" {print $2}' "$dir/manifest")
    current=$(nic_current_mac "$iface")
    [[ "$recorded" == unknown || "$recorded" == "$current" ]] || {
        die "网卡基线身份漂移: $iface MAC=$current，基线记录=$recorded"
        return 1
    }
}

nic_baseline_capture() {
    local iface="$1" dir temp source=snapshot mac
    dir=$(nic_baseline_dir "$iface")
    if [[ -e "$dir" || -L "$dir" ]]; then
        nic_baseline_validate "$iface" && nic_interface_exists "$iface" && nic_baseline_identity_validate "$iface"
        return
    fi
    nic_require_manageable "$iface" || return 1
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]] && tcp_baseline_validate "$BASELINE_DIR" >/dev/null 2>&1 &&
       [[ "$TCP_BASELINE_VALIDATED_INTERFACE" == "$iface" && "$TCP_BASELINE_VALIDATED_PROVENANCE" != legacy-reference ]]; then
        source=global
    fi
    qdisc_guard "$iface" || return 1
    if [[ "$source" == snapshot ]] && managed_htb "$iface" && ! nic_policy_exists "$iface" &&
       ! { (( ${MULTI_NIC_ENABLED:-0} == 0 && ${TC_ENABLED:-0} == 1 )) && [[ "${TC_INTERFACE:-auto}" == "$iface" ]]; } &&
       ! session_owned_htb "$iface"; then
        die "拒绝把没有策略或旧配置归属的 HTB 采用为 $iface 原始基线"
        return 1
    fi
    ensure_state_layout || return 1
    if [[ -e "$NIC_STATE_DIR" || -L "$NIC_STATE_DIR" ]]; then
        [[ -d "$NIC_STATE_DIR" && ! -L "$NIC_STATE_DIR" ]] || { die "网卡基线根目录类型不安全: $NIC_STATE_DIR"; return 1; }
    else
        mkdir -p -- "$NIC_STATE_DIR" || return 1
    fi
    chmod 0700 "$NIC_STATE_DIR" 2>/dev/null || true
    temp=$(mktemp -d "${STATE_DIR}/.nic-baseline.XXXXXX") || return 1
    mac=$(nic_current_mac "$iface")
    printf 'SCHEMA\t%s\nFORMAT\t%s\nINTERFACE\t%s\nMATCH_MAC\t%s\nSOURCE\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\n' \
        "$NIC_BASELINE_SCHEMA" "$NIC_BASELINE_FORMAT" "$iface" "$mac" "$source" "$(utc_now)" "$SCRIPT_VERSION" > "$temp/manifest" || {
            remove_tree_within "$temp" "$STATE_DIR" || true
            return 1
        }
    if [[ "$source" == snapshot ]]; then action_qdisc_snapshot "$iface" "$temp/qdisc.snapshot" || { remove_tree_within "$temp" "$STATE_DIR"; return 1; }; fi
    chmod -R go-rwx "$temp" 2>/dev/null || true
    if [[ -e "$dir" || -L "$dir" ]] || ! mv -- "$temp" "$dir"; then
        remove_tree_within "$temp" "$STATE_DIR" || true
        die "网卡基线路径在发布前已存在: $dir"
        return 1
    fi
    nic_baseline_validate "$iface" || return 1
    log OK "已保存网卡原始 qdisc 基线: $iface ($source)"
}

nic_baseline_restore() {
    local iface="$1" dir source
    nic_baseline_validate "$iface" || return 1
    dir=$(nic_baseline_dir "$iface")
    nic_baseline_identity_validate "$iface" || { die "拒绝向身份已变化的网卡恢复 qdisc: $iface"; return 1; }
    source=$(awk -F'\t' '$1=="SOURCE" {print $2}' "$dir/manifest")
    case "$source" in
        global) restore_qdisc_text_snapshot "$iface" "$BASELINE_DIR/qdisc.txt" ;;
        snapshot) restore_action_qdisc "$iface" "$dir/qdisc.snapshot" ;;
        *) return 1 ;;
    esac
}

nic_restore_secondary_baselines() {
    local iface source rc=0 interfaces
    [[ "$(nic_policy_layout_state)" == managed ]] || return 0
    nic_policy_set_validate || return 1
    interfaces=$(nic_policy_interface_list) || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        nic_baseline_validate "$iface" || { rc=1; continue; }
        source=$(awk -F'\t' '$1=="SOURCE" {print $2}' "$(nic_baseline_dir "$iface")/manifest")
        [[ "$source" == snapshot ]] || continue
        nic_baseline_restore "$iface" || rc=1
    done <<< "$interfaces"
    return "$rc"
}

nic_restore_preflight() {
    local state iface dir source interfaces
    state=$(nic_policy_layout_state)
    case "$state" in absent) return 0 ;; managed) nic_policy_set_validate || return 1 ;; *) die "多网卡策略目录损坏，恢复尚未开始"; return 1 ;; esac
    interfaces=$(nic_policy_interface_list) || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        dir=$(nic_baseline_dir "$iface")
        nic_baseline_validate "$iface" || return 1
        nic_interface_exists "$iface" || { die "网卡基线绑定的接口已消失: $iface"; return 1; }
        nic_baseline_identity_validate "$iface" || return 1
        tc qdisc show dev "$iface" >/dev/null 2>&1 && tc class show dev "$iface" >/dev/null 2>&1 || {
            die "无法读取 $iface 的 qdisc/class，恢复尚未开始"
            return 1
        }
        qdisc_filter_guard "$iface" || return 1
        source=$(awk -F'\t' '$1=="SOURCE" {print $2}' "$dir/manifest")
        if [[ "$source" == snapshot ]] && ! mq_snapshot_queue_preflight "$iface" "$dir/qdisc.snapshot"; then
            die "$iface 的 MQ 基线与当前 TX queue 数不一致，恢复尚未开始"
            return 1
        fi
    done <<< "$interfaces"
}

nic_policy_remove_tree() {
    local parent
    [[ ! -e "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" ]] && return 0
    nic_policy_set_validate || { die "拒绝删除损坏或不属于本项目的策略目录: $NIC_POLICY_DIR"; return 1; }
    parent=$(dirname "$NIC_POLICY_DIR")
    remove_tree_within "$NIC_POLICY_DIR" "$parent"
}

nic_migrate_legacy_policy() {
    local iface mode rate knee margin profile role bandwidth rtt kind runtime_rate
    (( MULTI_NIC_ENABLED == 0 )) || { nic_policy_set_validate; return; }
    iface="$TC_INTERFACE"; rate="$TC_RATE_MBIT"; knee="$TC_KNEE_MBIT"; margin="$TC_MARGIN_PERCENT"
    profile="$SYSCTL_PROFILE"; role="$ROLE"; bandwidth="$BANDWIDTH_MBIT"; rtt="$RTT_MS"
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; RTT_MS=0; fi
    if [[ "$iface" == auto ]]; then
        (( TC_ENABLED == 0 )) || { die "旧版 auto 整形配置无法安全迁移到多网卡模式"; return 1; }
        return 0
    fi
    nic_require_manageable "$iface" || return 1
    nic_baseline_capture "$iface" || return 1
    if (( TC_ENABLED == 1 )); then
        managed_htb "$iface" || { die "旧版配置声明整形，但 $iface 没有可验证的受管 HTB"; return 1; }
        runtime_rate=$(managed_rate_mbit "$iface" 2>/dev/null || true)
        [[ "$runtime_rate" == "$rate" ]] || { die "旧版配置与 $iface 运行速率不一致，拒绝迁移"; return 1; }
        mode=shape
    else
        kind=$(root_qdisc_kind "$iface")
        [[ "$kind" == fq ]] || { die "旧版配置声明 FQ，但 $iface root qdisc 为 ${kind:-unknown}"; return 1; }
        mode=fq; rate=0; knee=0
    fi
    nic_policy_write "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
    log OK "已把旧版单网卡配置迁移为独立策略: $iface/$mode"
}

nic_finalize_multi_config() {
    MULTI_NIC_ENABLED=1
    nic_reset_legacy_tc_fields
    nic_sync_global_model || return 1
}

nic_policy_ownership_preflight_files() {
    local target="$1" files="$2" file iface managed policies=""
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || return 1
        nic_policy_validate_identity || return 1
        qdisc_guard "$NIC_POLICY_INTERFACE" || return 1
        policies+="${policies:+$'\n'}$NIC_POLICY_INTERFACE"
    done <<< "$files"
    if (( ${MULTI_NIC_ENABLED:-0} == 0 && ${TC_ENABLED:-0} == 1 )) && [[ "${TC_INTERFACE:-auto}" != auto ]]; then
        policies+="${policies:+$'\n'}$TC_INTERFACE"
    fi
    managed=$(managed_htb_interfaces_strict) || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        if ! grep -Fqx -- "$iface" <<< "$policies"; then
            die "发现没有策略归属的受管 HTB: $iface；拒绝继续修改"
            return 1
        fi
    done <<< "$managed"
    [[ -z "$target" ]] || { nic_require_manageable "$target" && qdisc_guard "$target"; }
}

nic_policy_ownership_preflight() {
    local target="${1:-}" files=""
    case "$(nic_policy_layout_state)" in
        absent) ;;
        managed) files=$(nic_policy_files_checked) || return 1 ;;
        *) die "多网卡策略目录损坏或不属于本项目"; return 1 ;;
    esac
    nic_policy_ownership_preflight_files "$target" "$files"
}

nic_restore_runtime_snapshot() {
    local directory="$1" rc=0
    [[ -f "$directory/sysctl.tsv" ]] || return 1
    restore_tcp_sysctl_snapshot_file "$directory/sysctl.tsv" || rc=1
    restore_default_route_windows_snapshot "$directory" || rc=1
    return "$rc"
}

nic_runtime_transaction_begin() {
    local parent="$1"
    [[ -z "$NIC_RUNTIME_TRANSACTION_DIR" ]] || { die "已有未完成的网络运行时事务"; return 1; }
    NIC_RUNTIME_TRANSACTION_DIR=$(mktemp -d "$parent/${SCRIPT_NAME}.multi-nic.XXXXXX") || return 1
    NIC_RUNTIME_TRANSACTION_PARENT="$parent"
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    NIC_RUNTIME_TRANSACTION_READY=0
}

nic_runtime_transaction_discard() {
    local dir="$NIC_RUNTIME_TRANSACTION_DIR" parent="$NIC_RUNTIME_TRANSACTION_PARENT"
    [[ -n "$dir" && -n "$parent" ]] || return 0
    remove_tree_within "$dir" "$parent" || return 1
    NIC_RUNTIME_TRANSACTION_DIR=""
    NIC_RUNTIME_TRANSACTION_PARENT=""
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    NIC_RUNTIME_TRANSACTION_READY=0
}

nic_runtime_transaction_commit() {
    local dir="$NIC_RUNTIME_TRANSACTION_DIR" parent="$NIC_RUNTIME_TRANSACTION_PARENT"
    NIC_RUNTIME_TRANSACTION_DIR=""
    NIC_RUNTIME_TRANSACTION_PARENT=""
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    NIC_RUNTIME_TRANSACTION_READY=0
    [[ -z "$dir" ]] || remove_tree_within "$dir" "$parent" || log WARN "网络运行时状态已提交，但无法删除事务快照: $dir"
}

nic_runtime_transaction_write_interfaces() {
    local interfaces="$1" dir="$NIC_RUNTIME_TRANSACTION_DIR" iface temp count=0
    local -A seen=()
    [[ -n "$dir" && -d "$dir" && ! -L "$dir" && "$NIC_RUNTIME_TRANSACTION_MUTATED" == 0 ]] || return 1
    [[ -n "$interfaces" ]] || { die "运行时事务接口清单为空"; return 1; }
    [[ ! -e "$dir/interfaces.list" && ! -L "$dir/interfaces.list" ]] || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || { die "运行时事务接口清单含空行"; return 1; }
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1
        [[ -z "${seen[$iface]+x}" ]] || { die "运行时事务接口清单重复: $iface"; return 1; }
        seen[$iface]=1
        [[ -f "$dir/$iface.snapshot" && ! -L "$dir/$iface.snapshot" ]] || return 1
        action_qdisc_snapshot_validate "$dir/$iface.snapshot" || return 1
        mq_snapshot_queue_preflight "$iface" "$dir/$iface.snapshot" || return 1
        ((count+=1))
    done <<< "$interfaces"
    (( count > 0 )) || return 1
    temp=$(mktemp "$dir/.interfaces.XXXXXX") || return 1
    if ! printf '%s\n' "$interfaces" > "$temp" || ! chmod 0600 "$temp" || ! mv -- "$temp" "$dir/interfaces.list"; then
        rm -f -- "$temp"
        return 1
    fi
}

nic_runtime_transaction_snapshot_validate() {
    local dir="$NIC_RUNTIME_TRANSACTION_DIR" file iface count=0 expected_count=0
    local -A expected=()
    [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || return 1
    [[ -f "$dir/COMPLETE" && ! -L "$dir/COMPLETE" && "$(<"$dir/COMPLETE")" == complete ]] || return 1
    tcp_baseline_sysctl_validate "$dir/sysctl.tsv" >/dev/null || return 1
    [[ -f "$dir/default-route-v4.txt" && ! -L "$dir/default-route-v4.txt" ]] || return 1
    [[ -f "$dir/default-route-v6.txt" && ! -L "$dir/default-route-v6.txt" ]] || return 1
    default_route_windows_snapshot_preflight "$dir" || return 1
    [[ -f "$dir/interfaces.list" && ! -L "$dir/interfaces.list" ]] || return 1
    check_config_permissions "$dir/interfaces.list" || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || return 1
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1
        [[ -z "${expected[$iface]+x}" ]] || return 1
        expected[$iface]=1
        [[ -f "$dir/$iface.snapshot" && ! -L "$dir/$iface.snapshot" ]] || return 1
        ((expected_count+=1))
    done < "$dir/interfaces.list"
    (( expected_count > 0 )) || return 1
    for file in "$dir"/*.snapshot; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        iface="${file##*/}"; iface="${iface%.snapshot}"
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1
        [[ -n "${expected[$iface]+x}" ]] || return 1
        action_qdisc_snapshot_validate "$file" || return 1
        mq_snapshot_queue_preflight "$iface" "$file" || return 1
        qdisc_filter_guard "$iface" || return 1
        ((count+=1))
    done
    (( count == expected_count ))
}

nic_runtime_transaction_mark_mutated() {
    [[ -n "$NIC_RUNTIME_TRANSACTION_DIR" && "$NIC_RUNTIME_TRANSACTION_MUTATED" == 0 ]] || return 1
    if ! chmod -R go-rwx "$NIC_RUNTIME_TRANSACTION_DIR" ||
       ! printf 'complete\n' > "$NIC_RUNTIME_TRANSACTION_DIR/COMPLETE" ||
       ! chmod 0600 "$NIC_RUNTIME_TRANSACTION_DIR/COMPLETE"; then
        return 1
    fi
    NIC_RUNTIME_TRANSACTION_READY=1
    nic_runtime_transaction_snapshot_validate || { NIC_RUNTIME_TRANSACTION_READY=0; return 1; }
    NIC_RUNTIME_TRANSACTION_MUTATED=1
}

nic_runtime_transaction_rollback() {
    local dir="$NIC_RUNTIME_TRANSACTION_DIR" parent="$NIC_RUNTIME_TRANSACTION_PARENT" iface rc=0
    [[ -n "$dir" && -n "$parent" ]] || return 0
    (( NIC_RUNTIME_TRANSACTION_ROLLING_BACK == 0 )) || return 1
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=1
    if (( NIC_RUNTIME_TRANSACTION_MUTATED )); then
        if (( NIC_RUNTIME_TRANSACTION_READY != 1 )) || ! nic_runtime_transaction_snapshot_validate; then
            log ERR "网络运行时事务快照已损坏，或运行时 qdisc filter/队列/路由身份已漂移且不可完整验证；拒绝执行回滚，证据保留在 $dir"
            rc=1
        else
            nic_restore_runtime_snapshot "$dir" || rc=1
            while IFS= read -r iface; do
                restore_action_qdisc "$iface" "$dir/$iface.snapshot" || rc=1
            done < "$dir/interfaces.list"
        fi
    fi
    if (( rc == 0 )); then
        remove_tree_within "$dir" "$parent" || rc=1
    fi
    if (( rc == 0 )); then
        NIC_RUNTIME_TRANSACTION_DIR=""
        NIC_RUNTIME_TRANSACTION_PARENT=""
        NIC_RUNTIME_TRANSACTION_MUTATED=0
        NIC_RUNTIME_TRANSACTION_READY=0
    fi
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    return "$rc"
}

nic_verify_runtime_policies_files() {
    local only="$1" files="$2" file iface managed policies="" rc=0 found=0
    (( MULTI_NIC_ENABLED == 1 )) || { die "当前不是多网卡配置"; return 1; }
    nic_policy_set_validate_files "$files" || return 1
    nic_global_model_verify_files "$files" || rc=1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || { rc=1; continue; }
        iface="$NIC_POLICY_INTERFACE"; policies+="${policies:+$'\n'}$iface"
        [[ -z "$only" || "$only" == "$iface" ]] || continue
        found=1
        nic_policy_validate_identity || { rc=1; continue; }
        if [[ "$NIC_POLICY_MODE" == shape ]]; then
            verify_shaping "$iface" "$NIC_POLICY_RATE_MBIT" || rc=1
            [[ "$(managed_rate_mbit "$iface" 2>/dev/null || true)" == "$NIC_POLICY_RATE_MBIT" ]] || { log ERR "$iface 整形速率漂移"; rc=1; }
        else
            [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "$iface root qdisc 不是 fq"; rc=1; }
        fi
    done <<< "$files"
    [[ -z "$only" || $found == 1 ]] || { die "没有找到网卡策略: $only"; return 1; }
    if [[ -z "$only" ]]; then
        managed=$(managed_htb_interfaces_strict) || return 1
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            grep -Fqx -- "$iface" <<< "$policies" || { log ERR "发现孤立受管 HTB: $iface"; rc=1; }
        done <<< "$managed"
    fi
    (( rc == 0 )) || { die "多网卡运行时验证失败"; return 1; }
    log OK "多网卡运行时与策略一致${only:+: $only}"
}

nic_verify_runtime_policies() {
    local only="${1:-}" files
    files=$(nic_policy_files_checked) || return 1
    nic_verify_runtime_policies_files "$only" "$files"
}

nic_apply_runtime_policies() {
    local file iface rc=0 mutated=0 snapshot_dir="" snapshot_parent rollback_rc=0 policy_files interfaces=""
    policy_files=$(nic_policy_files_checked) || return 1
    [[ -n "$policy_files" ]] || { die "多网卡持久化应用需要至少一个网卡策略"; return 1; }
    nic_policy_set_validate_files "$policy_files" || return 1
    nic_global_model_verify_files "$policy_files" || return 1
    nic_policy_ownership_preflight_files "" "$policy_files" || return 1
    snapshot_parent="${TMPDIR:-/tmp}"
    nic_runtime_transaction_begin "$snapshot_parent" || return 1
    snapshot_dir="$NIC_RUNTIME_TRANSACTION_DIR"
    if ! capture_runtime_sysctls > "$snapshot_dir/sysctl.tsv"; then
        nic_runtime_transaction_discard || true
        return 1
    fi
    if ! ip -4 route show default > "$snapshot_dir/default-route-v4.txt" 2>/dev/null ||
       ! ip -6 route show default > "$snapshot_dir/default-route-v6.txt" 2>/dev/null; then
        if ! nic_runtime_transaction_discard; then
            die "多网卡持久化应用无法完整读取 IPv4/IPv6 默认路由；未修改运行时状态，但临时快照无法删除: $snapshot_dir"
        else
            die "多网卡持久化应用无法完整读取 IPv4/IPv6 默认路由；未修改运行时状态"
        fi
        return 1
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || { rc=1; break; }
        action_qdisc_snapshot "$NIC_POLICY_INTERFACE" "$snapshot_dir/$NIC_POLICY_INTERFACE.snapshot" || { rc=1; break; }
        interfaces+="${interfaces:+$'\n'}$NIC_POLICY_INTERFACE"
    done <<< "$policy_files"
    if (( rc == 0 )); then nic_runtime_transaction_write_interfaces "$interfaces" || rc=1; fi
    if (( rc == 0 )); then nic_runtime_transaction_mark_mutated || rc=1; fi
    if (( rc == 0 )); then
        mutated=1
        apply_sysctl_profile runtime || rc=1
    fi
    if (( rc == 0 )); then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            nic_policy_load_file "$file" || { rc=1; break; }
            iface="$NIC_POLICY_INTERFACE"
            if [[ "$NIC_POLICY_MODE" == shape ]]; then apply_shaping "$iface" "$NIC_POLICY_RATE_MBIT" || { rc=1; break; }
            else apply_fq "$iface" || { rc=1; break; }
            fi
        done <<< "$policy_files"
    fi
    if (( rc == 0 )); then apply_initial_windows || rc=1; fi
    if (( rc == 0 )); then nic_verify_runtime_policies_files "" "$policy_files" || rc=1; fi
    if (( rc != 0 )); then
        if (( mutated )); then
            nic_runtime_transaction_rollback || rollback_rc=$?
        else
            nic_runtime_transaction_discard || rollback_rc=$?
        fi
        if (( mutated && rollback_rc == 0 )); then die "多网卡持久化应用失败，已恢复本轮 qdisc、sysctl 与路由窗口快照"
        elif (( mutated )); then die "多网卡持久化应用失败且回滚不完整；快照保留在 $snapshot_dir，请人工检查"
        elif (( rollback_rc != 0 )); then die "多网卡持久化应用在只读快照阶段失败；未修改运行时状态，但临时快照无法删除: $snapshot_dir"
        else die "多网卡持久化应用在只读快照阶段失败；未修改运行时状态"
        fi
        return 1
    fi
    nic_runtime_transaction_commit
}

nic_manage_steps() {
    local iface="$1" mode="$2" rate="$3" knee="$4" margin="$5" profile="$6" role="$7" bandwidth="$8" rtt="$9"
    capture_baseline "$iface" || return 1
    migrate_legacy_config || return 1
    load_config || return 1
    nic_migrate_legacy_policy || return 1
    nic_baseline_capture "$iface" || return 1
    if [[ "$mode" == shape ]]; then apply_shaping "$iface" "$rate" || return 1; else apply_fq "$iface" || return 1; fi
    nic_policy_write "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt" || return 1
    nic_finalize_multi_config || return 1
    apply_sysctl_profile persistent || return 1
    apply_initial_windows || return 1
    save_config || return 1
    install_persistence || return 1
    restart_and_verify_persistence || return 1
    verify_system_state || return 1
    if [[ "$mode" == shape ]]; then log OK "网卡策略已提交: $iface/$mode/${rate}Mbit"
    else log OK "网卡策略已提交: $iface/$mode"
    fi
}

nic_manage() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands ip tc sysctl systemctl modprobe || return 1
    local requested="$1" mode="$2" rate="$3" knee="$4" margin="$5" profile="$6" role="$7" bandwidth="$8" rtt="$9" iface
    iface=$(detect_interface "$requested") || return 1
    nic_require_manageable "$iface" || return 1
    load_config || return 1
    nic_policy_ownership_preflight "$iface" || return 1
    BANDWIDTH_MBIT="$bandwidth"
    network_tuning_preflight "$iface" "$([[ "$mode" == shape ]] && printf 1 || printf 0)" || return 1
    run_action_transaction_multi "$iface" nic_manage_steps "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
}

nic_unmanage_steps() {
    local iface="$1"
    nic_baseline_restore "$iface" || return 1
    nic_policy_remove "$iface" || return 1
    nic_finalize_multi_config || return 1
    apply_sysctl_profile persistent || return 1
    save_config || return 1
    install_persistence || return 1
    restart_and_verify_persistence || return 1
    verify_system_state || return 1
    log OK "已解除网卡管理并恢复原始 qdisc: $iface"
}

nic_unmanage() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands ip tc sysctl systemctl || return 1
    local iface="$1"
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || { die "unmanage 必须显式指定具体网卡"; return 1; }
    load_config || return 1
    (( MULTI_NIC_ENABLED == 1 )) || { die "当前不是多网卡配置"; return 1; }
    nic_policy_exists "$iface" || { die "网卡没有受管策略: $iface"; return 1; }
    nic_policy_ownership_preflight "$iface" || return 1
    nic_baseline_validate "$iface" || { die "网卡原始 qdisc 基线无效，解除管理尚未开始: $iface"; return 1; }
    run_action_transaction_multi "$iface" nic_unmanage_steps "$iface"
}

nic_route_role() {
    local iface="$1" roles="" output interfaces
    output=$(default_route_output -4); interfaces=$(route_output_interfaces <<< "$output")
    grep -Fqx -- "$iface" <<< "$interfaces" && roles=default4
    output=$(default_route_output -6); interfaces=$(route_output_interfaces <<< "$output")
    grep -Fqx -- "$iface" <<< "$interfaces" && roles+="${roles:+,}default6"
    printf '%s\n' "${roles:-secondary}"
}

nic_inventory() {
    local root path iface state mac driver mtu speed rx tx qdisc policy mode rate role layout file rc=0 policy_files=""
    layout=$(nic_policy_layout_state)
    case "$layout" in
        managed)
            policy_files=$(nic_policy_files_checked) || return 1
            nic_policy_set_validate_files "$policy_files" || return 1
            ;;
        absent) ;;
        *) die "多网卡策略目录损坏或不属于本项目: $NIC_POLICY_DIR"; return 1 ;;
    esac
    root=$(nic_sysfs_root)
    printf '%-15s %-18s %-17s %-8s %-8s %-7s %-9s %-12s %s\n' Interface Eligibility Route Policy Mode Rate Link Queues Qdisc
    for path in "$root"/*; do
        [[ -e "$path" || -L "$path" ]] || continue
        iface="${path##*/}"; validate_interface_name "$iface" && [[ "$iface" != auto ]] || continue
        state=$(nic_interface_manageability "$iface" 2>/dev/null || true); state="${state:-unknown}"
        role=$(nic_route_role "$iface")
        policy=no; mode=-; rate=-
        if nic_policy_exists "$iface" && nic_policy_load_file "$(nic_policy_path "$iface")" >/dev/null 2>&1; then
            policy=yes; mode="$NIC_POLICY_MODE"; rate=$([[ "$mode" == shape ]] && printf '%sM' "$NIC_POLICY_RATE_MBIT" || printf '-')
            if ! nic_policy_validate_identity; then policy=drift; rc=1; fi
        fi
        mac=$(nic_current_mac "$iface")
        driver=$(detect_driver "$iface"); mtu=$(detect_mtu "$iface"); speed=$(detect_link_speed "$iface"); rx=$(detect_rx_queues "$iface"); tx=$(detect_tx_queues "$iface")
        qdisc=$(root_qdisc_kind "$iface" 2>/dev/null || printf unknown)
        printf '%-15s %-18s %-17s %-8s %-8s %-7s %-9s %-12s %s\n' "$iface" "$state" "$role" "$policy" "$mode" "$rate" "${speed}M" "${rx}:${tx}" "$qdisc"
        [[ "${NIC_INVENTORY_VERBOSE:-0}" == 1 ]] && printf '  identity=%s driver=%s mtu=%s\n' "$mac" "$driver" "$mtu"
    done
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" >/dev/null || { rc=1; continue; }
        iface="$NIC_POLICY_INTERFACE"
        nic_interface_exists "$iface" && continue
        mode="$NIC_POLICY_MODE"; rate=$([[ "$mode" == shape ]] && printf '%sM' "$NIC_POLICY_RATE_MBIT" || printf '-')
        printf '%-15s %-18s %-17s %-8s %-8s %-7s %-9s %-12s %s\n' "$iface" missing unknown missing "$mode" "$rate" unknown unknown missing
        log ERR "受管网卡已消失: $iface"
        rc=1
    done <<< "$policy_files"
    return "$rc"
}

nic_plan() {
    local iface="$1" mode="${2:-fq}" rate="${3:-0}" knee="${4:-0}" margin="${5:-3}" profile="${6:-balanced}" role="${7:-mixed}" bandwidth="${8:-0}" rtt="${9:-0}"
    local state policy=absent action=create requested current_model='-' candidate readiness=ready
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || { die "plan 必须指定具体网卡"; return 1; }
    [[ "$mode" == fq || "$mode" == shape ]] && validate_config_value TC_RATE_MBIT "$rate" && validate_config_value TC_KNEE_MBIT "$knee" &&
        validate_config_value TC_MARGIN_PERCENT "$margin" && validate_config_value SYSCTL_PROFILE "$profile" && validate_config_value ROLE "$role" &&
        validate_config_value BANDWIDTH_MBIT "$bandwidth" && validate_config_value RTT_MS "$rtt" || { die "plan 参数非法"; return 1; }
    if [[ "$mode" == shape ]]; then (( rate > 0 && ( knee == 0 || knee >= rate ) )) || { die "shape plan 的 rate/knee 非法"; return 1; }
    else (( rate == 0 && knee == 0 )) || { die "fq plan 不能携带 rate/knee"; return 1; }
    fi
    (( bandwidth == 0 && rtt == 0 )) || (( bandwidth > 0 && rtt > 0 )) || { die "plan 的 bandwidth/rtt 必须成对提供"; return 1; }
    [[ "$profile" != adaptive || ( "$bandwidth" -gt 0 && "$rtt" -gt 0 ) ]] || { die "adaptive plan 需要非零 bandwidth/rtt"; return 1; }
    state=$(nic_interface_manageability "$iface" 2>/dev/null || true)
    if nic_policy_exists "$iface"; then
        nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
        policy="$NIC_POLICY_MODE/$NIC_POLICY_PROFILE/$NIC_POLICY_ROLE/$NIC_POLICY_BANDWIDTH_MBIT/$NIC_POLICY_RTT_MS"
        action=update
    fi
    if [[ "$mode" == shape ]]; then requested="$mode/$rate"; else requested="$mode"; fi
    candidate=$(nic_policy_candidate_global_model "$iface" "$profile" "$role" "$bandwidth" "$rtt") || return 1
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then current_model=$(nic_policy_global_model | tr '\t' '/'); fi
    if ! nic_policy_ownership_preflight "$iface" >/dev/null 2>&1; then readiness=blocked; fi
    printf '%-22s %s\n' 'Policy module' 'Multi-NIC' 'Interface' "$iface" 'Identity' "$(nic_current_mac "$iface")" \
        'Eligibility' "${state:-missing}" 'Route role' "$(nic_route_role "$iface")" 'Current qdisc' "$(root_qdisc_kind "$iface" 2>/dev/null || printf unknown)" \
        'Current policy' "$policy" 'Requested qdisc' "$requested (knee=$knee, margin=$margin%)" \
        'Requested model' "$profile/$role/$bandwidth/$rtt" 'Current global model' "$current_model" \
        'Global model after apply' "$(tr '\t' '/' <<< "$candidate")" 'Action' "$action" 'Readiness' "$readiness" 'Plan mutation' 'none (read-only)'
    [[ "$state" == eligible && "$readiness" == ready ]] || return 1
}

nic_policy_reset_record
nic_auto_policy_reset
