# -----------------------------------------------------------------------------
# State and baseline: immutable provenance and scoped restoration.
# -----------------------------------------------------------------------------

TCP_BASELINE_SCHEMA="2"
TCP_BASELINE_FORMAT="bbrv3-lite-tcp-baseline"
TCP_BASELINE_NATIVE_SCOPE="managed-paths+tcp-sysctl+qdisc+unit-lifecycle+default-route-windows"
TCP_BASELINE_LEGACY_SCOPE="delegated-legacy-tool"
TCP_BASELINE_ROUTE_DUMPS="diagnostic-only"
TCP_BASELINE_VALIDATED_PROVENANCE=""
TCP_BASELINE_VALIDATED_INTERFACE=""
TCP_BASELINE_VALIDATED_GENERATION=""

tcp_baseline_invalid() {
    log ERR "TCP 基线无效: $*"
    return 1
}

tcp_baseline_sysctl_keys() {
    printf '%s\n' \
        net.core.default_qdisc net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog
}

tcp_baseline_regular_file() {
    [[ -f "$1" && ! -L "$1" ]]
}

# A removable/delegated executable must be an assembled bbrv3-lite script,
# not merely an arbitrary file containing one easy-to-forge marker.  Keep this
# signature version-agnostic so a trustworthy baseline captured by an older
# release remains restorable.
managed_bbr_script_signature() {
    local file="$1" first header_count version_count name_count repo_count
    [[ -f "$file" ]] || return 1
    IFS= read -r first < "$file" || return 1
    [[ "$first" == '#!/usr/bin/env bash' || "$first" == '#!/bin/bash' ]] || return 1
    header_count=$(grep -Fxc '# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu' "$file" 2>/dev/null || true)
    version_count=$(grep -Ec '^SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"$' "$file" 2>/dev/null || true)
    name_count=$(grep -Fxc 'SCRIPT_NAME="bbrv3-lite"' "$file" 2>/dev/null || true)
    repo_count=$(grep -Fxc 'PROJECT_REPO="ike-sh/bbrv3-lite"' "$file" 2>/dev/null || true)
    [[ "$header_count" == 1 && "$version_count" == 1 && "$name_count" == 1 && "$repo_count" == 1 ]]
}

tcp_baseline_manifest_validate() {
    local directory="$1" manifest="$1/manifest" line key value
    local -A fields=()
    tcp_baseline_regular_file "$manifest" || { tcp_baseline_invalid "manifest 缺失、不是常规文件或是符号链接"; return 1; }
    [[ -s "$manifest" ]] || { tcp_baseline_invalid "manifest 为空"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != *$'\t'* || "${line#*$'\t'}" == *$'\t'* ]]; then
            tcp_baseline_invalid "manifest 含非 KEY<TAB>VALUE 行"
            return 1
        fi
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -n "$key" && -n "$value" ]] || { tcp_baseline_invalid "manifest 含空字段"; return 1; }
        [[ -z "${fields[$key]+x}" ]] || { tcp_baseline_invalid "manifest 字段重复: $key"; return 1; }
        case "$key" in
            SCHEMA|FORMAT|RESTORE_SCOPE|ROUTE_DUMPS|COMPLETE|CREATED_AT|CREATED_BY|PROVENANCE|INTERFACE) ;;
            *) tcp_baseline_invalid "manifest 含未知字段: $key"; return 1 ;;
        esac
        fields[$key]="$value"
    done < "$manifest"

    [[ "${fields[CREATED_AT]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        tcp_baseline_invalid "CREATED_AT 非法"
        return 1
    }
    [[ "${fields[CREATED_BY]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || {
        tcp_baseline_invalid "CREATED_BY 非法"
        return 1
    }
    case "${fields[PROVENANCE]:-}" in native|adopt-current|legacy-reference) ;; *) tcp_baseline_invalid "PROVENANCE 非法"; return 1 ;; esac
    validate_interface_name "${fields[INTERFACE]:-}" && [[ "${fields[INTERFACE]}" != auto ]] || {
        tcp_baseline_invalid "INTERFACE 必须是已解析的具体网卡名"
        return 1
    }

    case "${fields[SCHEMA]:-}" in
        1)
            (( ${#fields[@]} == 5 )) || { tcp_baseline_invalid "旧版 manifest 字段集合不完整或混入新版字段"; return 1; }
            TCP_BASELINE_VALIDATED_GENERATION="legacy-v1"
            ;;
        "$TCP_BASELINE_SCHEMA")
            (( ${#fields[@]} == 9 )) || { tcp_baseline_invalid "v2 manifest 字段集合不完整"; return 1; }
            [[ "${fields[FORMAT]:-}" == "$TCP_BASELINE_FORMAT" ]] || { tcp_baseline_invalid "FORMAT 不匹配"; return 1; }
            [[ "${fields[ROUTE_DUMPS]:-}" == "$TCP_BASELINE_ROUTE_DUMPS" ]] || { tcp_baseline_invalid "ROUTE_DUMPS 不匹配"; return 1; }
            [[ "${fields[COMPLETE]:-}" == 1 ]] || { tcp_baseline_invalid "基线没有完成标记"; return 1; }
            if [[ "${fields[PROVENANCE]}" == legacy-reference ]]; then
                [[ "${fields[RESTORE_SCOPE]:-}" == "$TCP_BASELINE_LEGACY_SCOPE" ]] || { tcp_baseline_invalid "legacy RESTORE_SCOPE 不匹配"; return 1; }
            else
                [[ "${fields[RESTORE_SCOPE]:-}" == "$TCP_BASELINE_NATIVE_SCOPE" ]] || { tcp_baseline_invalid "native RESTORE_SCOPE 不匹配"; return 1; }
            fi
            TCP_BASELINE_VALIDATED_GENERATION="v2"
            ;;
        *) tcp_baseline_invalid "不支持的 SCHEMA: ${fields[SCHEMA]:-missing}"; return 1 ;;
    esac
    TCP_BASELINE_VALIDATED_PROVENANCE="${fields[PROVENANCE]}"
    TCP_BASELINE_VALIDATED_INTERFACE="${fields[INTERFACE]}"
}

tcp_baseline_sysctl_validate() {
    local file="$1" line key value first second third extra
    local -A allowed=() seen=()
    tcp_baseline_regular_file "$file" || { tcp_baseline_invalid "sysctl 快照缺失或类型非法"; return 1; }
    [[ -s "$file" ]] || { tcp_baseline_invalid "sysctl 快照为空"; return 1; }
    while IFS= read -r key; do allowed[$key]=1; done < <(tcp_baseline_sysctl_keys)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != *$'\t'* || "${line#*$'\t'}" == *$'\t'* ]]; then
            tcp_baseline_invalid "sysctl 快照含非法字段行"
            return 1
        fi
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -n "${allowed[$key]+x}" ]] || { tcp_baseline_invalid "sysctl key 不在恢复白名单: ${key:-empty}"; return 1; }
        [[ -z "${seen[$key]+x}" ]] || { tcp_baseline_invalid "sysctl key 重复: $key"; return 1; }
        case "$key" in
            net.core.default_qdisc|net.ipv4.tcp_congestion_control)
                [[ "$value" =~ ^[A-Za-z0-9_.+-]+$ ]] || { tcp_baseline_invalid "sysctl token 值非法: $key"; return 1; }
                ;;
            net.ipv4.tcp_rmem|net.ipv4.tcp_wmem)
                first=""; second=""; third=""; extra=""
                read -r first second third extra <<< "$value"
                is_uint "$first" && is_uint "$second" && is_uint "$third" && [[ -z "$extra" ]] || {
                    tcp_baseline_invalid "sysctl 三元组非法: $key"
                    return 1
                }
                ;;
            *) is_uint "$value" || { tcp_baseline_invalid "sysctl 数值非法: $key"; return 1; } ;;
        esac
        seen[$key]=1
    done < "$file"
    (( ${#seen[@]} == ${#allowed[@]} )) || { tcp_baseline_invalid "sysctl 快照没有覆盖全部受管 key"; return 1; }
}

tcp_baseline_path_payload_validate() {
    local directory="$1" name="$2" state_file="$1/${2}.state" payload="$1/$2" state target
    local -a lines=()
    tcp_baseline_regular_file "$state_file" || { tcp_baseline_invalid "${name}.state 缺失或类型非法"; return 1; }
    mapfile -t lines < "$state_file" || return 1
    (( ${#lines[@]} == 1 )) || { tcp_baseline_invalid "${name}.state 不是单行"; return 1; }
    state="${lines[0]}"
    case "$state" in
        absent)
            [[ ! -e "$payload" && ! -L "$payload" ]] || { tcp_baseline_invalid "$name 标记 absent 但 payload 存在"; return 1; }
            ;;
        present)
            if [[ -L "$payload" ]]; then
                target=$(readlink "$payload") || { tcp_baseline_invalid "$name 的符号链接不可读"; return 1; }
                [[ -n "$target" && "$target" != *$'\n'* && "$target" != *$'\r'* && "$target" != *$'\t'* ]] || {
                    tcp_baseline_invalid "$name 的符号链接目标非法"
                    return 1
                }
            elif [[ ! -f "$payload" ]]; then
                tcp_baseline_invalid "$name 标记 present 但 payload 不是常规文件/合法符号链接"
                return 1
            fi
            ;;
        *) tcp_baseline_invalid "${name}.state 值非法: ${state:-empty}"; return 1 ;;
    esac
}

tcp_baseline_unit_state_validate() {
    local file="$1" line enabled active
    local -a lines=()
    tcp_baseline_regular_file "$file" || { tcp_baseline_invalid "unit lifecycle 快照缺失或类型非法"; return 1; }
    mapfile -t lines < "$file" || return 1
    (( ${#lines[@]} == 1 )) || { tcp_baseline_invalid "unit lifecycle 快照不是单行"; return 1; }
    line="${lines[0]}"
    [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || { tcp_baseline_invalid "unit lifecycle 字段非法"; return 1; }
    enabled="${line%%$'\t'*}"; active="${line#*$'\t'}"
    case "$enabled" in
        enabled|enabled-runtime|disabled|masked|masked-runtime|linked|linked-runtime|alias|static|indirect|generated|transient|not-found) ;;
        *) tcp_baseline_invalid "unit-file 状态非法: ${enabled:-empty}"; return 1 ;;
    esac
    case "$active" in active|inactive) ;; *) tcp_baseline_invalid "unit active 状态不可恢复: ${active:-empty}"; return 1 ;; esac
}

tcp_baseline_qdisc_validate() {
    local file="$1" root_count kind rows unsupported
    tcp_baseline_regular_file "$file" || { tcp_baseline_invalid "qdisc 快照缺失或类型非法"; return 1; }
    [[ -s "$file" ]] || { tcp_baseline_invalid "qdisc 快照为空"; return 1; }
    root_count=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {count++} END {print count+0}' "$file") || return 1
    (( root_count == 1 )) || { tcp_baseline_invalid "qdisc 快照必须且只能包含一个 root"; return 1; }
    kind=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {print $2; exit}' "$file")
    case "$kind" in
        fq|fq_codel|noqueue|pfifo_fast) ;;
        mq)
            rows=$(mq_child_replay_rows_from_stream < "$file") || { tcp_baseline_invalid "mq 子队列无法解析"; return 1; }
            [[ -n "$rows" ]] || { tcp_baseline_invalid "mq 快照缺少子队列"; return 1; }
            unsupported=$(awk -F'\t' '$2!="fq" && $2!="fq_codel" && $2!="pfifo_fast" && $2!="pfifo" && $2!="bfifo" && $2!="noqueue" {print $2; exit}' <<< "$rows")
            [[ -z "$unsupported" ]] || { tcp_baseline_invalid "mq 含不可安全重放的子队列: $unsupported"; return 1; }
            ;;
        *) tcp_baseline_invalid "qdisc root 不可安全重放: ${kind:-missing}"; return 1 ;;
    esac
}

tcp_baseline_native_validate() {
    local directory="$1" name route_file
    tcp_baseline_sysctl_validate "$directory/sysctl.tsv" || return 1
    tcp_baseline_qdisc_validate "$directory/qdisc.txt" || return 1
    tcp_baseline_regular_file "$directory/class.txt" || { tcp_baseline_invalid "class 快照缺失或类型非法"; return 1; }
    if grep -q '[^[:space:]]' "$directory/class.txt"; then
        tcp_baseline_invalid "class 快照包含当前恢复器不能安全重放的层级"
        return 1
    fi
    for route_file in routes-v4.txt routes-v6.txt default-route-v4.txt default-route-v6.txt; do
        tcp_baseline_regular_file "$directory/$route_file" || { tcp_baseline_invalid "$route_file 缺失或类型非法"; return 1; }
    done
    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        tcp_baseline_path_payload_validate "$directory" "$name" || return 1
    done
    tcp_baseline_unit_state_validate "$directory/service.unit" || return 1
    tcp_baseline_unit_state_validate "$directory/legacy-service.unit" || return 1
}

tcp_baseline_legacy_reference_validate() {
    local directory="$1" root_count
    [[ -d "$directory/legacy-original" && ! -L "$directory/legacy-original" ]] || { tcp_baseline_invalid "legacy-original 缺失或类型非法"; return 1; }
    [[ -n "$(find "$directory/legacy-original" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || { tcp_baseline_invalid "legacy-original 为空"; return 1; }
    tcp_baseline_regular_file "$directory/legacy-tool.sh" && [[ -s "$directory/legacy-tool.sh" && -x "$directory/legacy-tool.sh" ]] || {
        tcp_baseline_invalid "legacy-tool.sh 缺失、不可执行或类型非法"
        return 1
    }
    managed_bbr_script_signature "$directory/legacy-tool.sh" || {
        tcp_baseline_invalid "legacy-tool.sh 项目签名缺失或有歧义"
        return 1
    }
    tcp_baseline_sysctl_validate "$directory/migration-current-sysctl.tsv" || return 1
    tcp_baseline_regular_file "$directory/migration-current-qdisc.txt" && [[ -s "$directory/migration-current-qdisc.txt" ]] || {
        tcp_baseline_invalid "legacy migration qdisc 诊断快照缺失"
        return 1
    }
    root_count=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {count++} END {print count+0}' "$directory/migration-current-qdisc.txt") || return 1
    (( root_count == 1 )) || { tcp_baseline_invalid "legacy migration qdisc 诊断快照无唯一 root"; return 1; }
}

tcp_baseline_validate() {
    local directory="${1:-$BASELINE_DIR}"
    TCP_BASELINE_VALIDATED_PROVENANCE=""
    TCP_BASELINE_VALIDATED_INTERFACE=""
    TCP_BASELINE_VALIDATED_GENERATION=""
    [[ -d "$directory" && ! -L "$directory" ]] || { tcp_baseline_invalid "基线路径缺失、不是目录或是符号链接: $directory"; return 1; }
    tcp_baseline_manifest_validate "$directory" || return 1
    if [[ "$TCP_BASELINE_VALIDATED_PROVENANCE" == legacy-reference ]]; then
        tcp_baseline_legacy_reference_validate "$directory"
    else
        tcp_baseline_native_validate "$directory"
    fi
}

ensure_state_layout() {
    mkdir -p -- "$STATE_DIR" "$HISTORY_DIR" || return 1
    chmod 0700 "$STATE_DIR" "$HISTORY_DIR" 2>/dev/null || true
    if [[ ! -f "$STATE_DIR/manifest" ]]; then
        local temp
        temp=$(mktemp) || return 1
        printf 'SCHEMA\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\n' "$STATE_SCHEMA" "$(utc_now)" "$SCRIPT_VERSION" > "$temp"
        atomic_install "$temp" "$STATE_DIR/manifest" 0600 || { rm -f -- "$temp"; return 1; }
        rm -f -- "$temp"
    fi
}

managed_artifacts_exist() {
    [[ -e "$CONFIG_FILE" || -e "$SYSCTL_FILE" || -e "$LEGACY_SYSCTL_FILE" ||
       -e "$SERVICE_FILE" || -e "$LEGACY_SERVICE_FILE" || -e "$PERSIST_SCRIPT" ||
       -e "$NIC_POLICY_DIR" || -L "$NIC_POLICY_DIR" ]]
}

import_legacy_baseline() {
    local iface="$1" temp_dir=""
    [[ -d "$LEGACY_BACKUP_DIR" && ! -L "$LEGACY_BACKUP_DIR" &&
       -n "$(find "$LEGACY_BACKUP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
        die "旧备份目录缺失、为空或类型不安全；拒绝创建引用基线"
        return 1
    }
    [[ -f "$PERSIST_SCRIPT" && ! -L "$PERSIST_SCRIPT" && -x "$PERSIST_SCRIPT" ]] || {
        die "找到旧备份，但没有可执行的旧版持久化脚本；请先用旧版本 restore，或显式 baseline adopt"
        return 1
    }
    temp_dir=$(mktemp -d "${STATE_DIR}/.baseline.XXXXXX") || return 1
    if ! printf 'SCHEMA\t%s\nFORMAT\t%s\nRESTORE_SCOPE\t%s\nROUTE_DUMPS\t%s\nCOMPLETE\t1\nCREATED_AT\t%s\nCREATED_BY\t%s\nPROVENANCE\tlegacy-reference\nINTERFACE\t%s\n' \
            "$TCP_BASELINE_SCHEMA" "$TCP_BASELINE_FORMAT" "$TCP_BASELINE_LEGACY_SCOPE" "$TCP_BASELINE_ROUTE_DUMPS" \
            "$(utc_now)" "$SCRIPT_VERSION" "$iface" > "$temp_dir/manifest" ||
       ! cp -a -- "$LEGACY_BACKUP_DIR" "$temp_dir/legacy-original" ||
       ! cp -a -- "$PERSIST_SCRIPT" "$temp_dir/legacy-tool.sh" ||
       ! capture_runtime_sysctls > "$temp_dir/migration-current-sysctl.tsv" ||
       ! tc qdisc show dev "$iface" > "$temp_dir/migration-current-qdisc.txt" 2>/dev/null ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! tcp_baseline_validate "$temp_dir"; then
        remove_tree_within "$temp_dir" "$STATE_DIR" || true
        die "旧版引用基线捕获不完整或不可验证；没有发布基线"
        return 1
    fi
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]] || ! mv -- "$temp_dir" "$BASELINE_DIR"; then
        remove_tree_within "$temp_dir" "$STATE_DIR" || true
        die "基线路径在发布前已存在；不会覆盖"
        return 1
    fi
    log OK "已引用旧版原始备份并保存旧版恢复工具: $BASELINE_DIR"
}

backup_path() {
    local source="$1" name="$2" directory="${3:-$BASELINE_DIR}"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$directory/$name" || return 1
        printf 'present\n' > "$directory/${name}.state" || return 1
    else
        printf 'absent\n' > "$directory/${name}.state" || return 1
    fi
}

capture_runtime_sysctls() {
    local key value
    for key in \
        net.core.default_qdisc net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog; do
        value=$(sysctl -n "$key" 2>/dev/null) || {
            log WARN "无法读取受管 sysctl，拒绝创建不完整快照: $key"
            return 1
        }
        [[ -n "$value" ]] || { log WARN "受管 sysctl 返回空值: $key"; return 1; }
        printf '%s\t%s\n' "$key" "$value"
    done
    return 0
}

capture_baseline() {
    local iface="$1" provenance="${2:-native}" temp_dir=""
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]]; then
        if tcp_baseline_validate "$BASELINE_DIR"; then
            return 0
        fi
        die "已有 TCP 基线损坏或不完整；它是不可覆盖的恢复证据，已原样保留: $BASELINE_DIR"
        return 1
    fi
    ensure_state_layout || return 1
    case "$provenance" in native|adopt-current) ;; *) die "非法基线来源: $provenance"; return 1 ;; esac
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || { die "基线必须绑定具体网卡"; return 1; }
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
    if ! printf 'SCHEMA\t%s\nFORMAT\t%s\nRESTORE_SCOPE\t%s\nROUTE_DUMPS\t%s\nCOMPLETE\t1\nCREATED_AT\t%s\nCREATED_BY\t%s\nPROVENANCE\t%s\nINTERFACE\t%s\n' \
            "$TCP_BASELINE_SCHEMA" "$TCP_BASELINE_FORMAT" "$TCP_BASELINE_NATIVE_SCOPE" "$TCP_BASELINE_ROUTE_DUMPS" \
            "$(utc_now)" "$SCRIPT_VERSION" "$provenance" "$iface" > "$temp_dir/manifest" ||
       ! capture_runtime_sysctls > "$temp_dir/sysctl.tsv" ||
       ! tc qdisc show dev "$iface" > "$temp_dir/qdisc.txt" 2>/dev/null ||
       ! tc class show dev "$iface" > "$temp_dir/class.txt" 2>/dev/null ||
       ! ip -4 route show table all > "$temp_dir/routes-v4.txt" 2>/dev/null ||
       ! ip -6 route show table all > "$temp_dir/routes-v6.txt" 2>/dev/null ||
       ! ip -4 route show default > "$temp_dir/default-route-v4.txt" 2>/dev/null ||
       ! ip -6 route show default > "$temp_dir/default-route-v6.txt" 2>/dev/null ||
       ! backup_path "$CONFIG_FILE" config "$temp_dir" ||
       ! backup_path "$SYSCTL_FILE" sysctl "$temp_dir" ||
       ! backup_path "$LEGACY_SYSCTL_FILE" legacy-sysctl "$temp_dir" ||
       ! backup_path "$SERVICE_FILE" service "$temp_dir" ||
       ! backup_path "$LEGACY_SERVICE_FILE" legacy-service "$temp_dir" ||
       ! backup_path "$PERSIST_SCRIPT" persist-script "$temp_dir" ||
       ! capture_unit_state "$SERVICE_NAME" "$temp_dir/service.unit" ||
       ! capture_unit_state bbr-optimize-persist.service "$temp_dir/legacy-service.unit" ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! tcp_baseline_validate "$temp_dir"; then
        remove_tree_within "$temp_dir" "$STATE_DIR" || true
        die "TCP 基线捕获不完整或当前 qdisc 不可安全重放；没有发布基线"
        return 1
    fi
    if [[ -e "$BASELINE_DIR" || -L "$BASELINE_DIR" ]] || ! mv -- "$temp_dir" "$BASELINE_DIR"; then
        remove_tree_within "$temp_dir" "$STATE_DIR" || true
        die "基线路径在发布前已存在；不会覆盖"
        return 1
    fi
    log OK "已保存不可覆盖的初始基线: $BASELINE_DIR ($provenance)"
}

baseline_adopt() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl || return 1; acquire_lock || return 1
    local iface
    [[ ! -e "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" ]] || {
        die "多网卡策略已经存在；请先逐网卡 unmanage 或恢复原基线，不能把受管 qdisc 重新采用为原始基线"
        return 1
    }
    iface=$(detect_interface "${1:-auto}") || return 1
    [[ ! -e "$BASELINE_DIR" && ! -L "$BASELINE_DIR" ]] || { die "基线已经存在，不会覆盖"; return 1; }
    capture_baseline "$iface" adopt-current || return 1
    log WARN "当前状态已被显式采用为基线；restore 只能回到此状态"
}

restore_backed_path() {
    local target="$1" name="$2" state
    tcp_baseline_regular_file "$BASELINE_DIR/${name}.state" || return 1
    state=$(<"$BASELINE_DIR/${name}.state")
    case "$state" in
        absent) rm -f -- "$target" || return 1 ;;
        present)
            mkdir -p -- "$(dirname "$target")" || return 1
            rm -f -- "$target" || return 1
            cp -a -- "$BASELINE_DIR/$name" "$target" || return 1
            ;;
        *) return 1 ;;
    esac
}

restore_runtime_sysctls() {
    local key value rc=0
    tcp_baseline_regular_file "$BASELINE_DIR/sysctl.tsv" || return 1
    while IFS=$'\t' read -r key value; do
        if [[ -n "$key" ]] && ! sysctl -q -w "$key=$value"; then log WARN "无法恢复 sysctl: $key"; rc=1; fi
    done < "$BASELINE_DIR/sysctl.tsv"
    return "$rc"
}

baseline_info() {
    if [[ -f "$BASELINE_DIR/manifest" ]]; then cat "$BASELINE_DIR/manifest"; else printf 'No baseline recorded.\n'; fi
}

baseline_provenance() {
    awk -F'\t' '$1=="PROVENANCE" {print $2; exit}' "$BASELINE_DIR/manifest" 2>/dev/null
}
