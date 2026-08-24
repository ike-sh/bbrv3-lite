#!/usr/bin/env bash
# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu
# This file is assembled from src/*.sh by scripts/build.sh.
# shellcheck shell=bash

SCRIPT_VERSION="8.0.1"
SCRIPT_NAME="bbrv3-lite"
PROJECT_REPO="ike-sh/bbrv3-lite"
PROJECT_URL="https://github.com/${PROJECT_REPO}"
STATE_SCHEMA="1"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
fi

# -----------------------------------------------------------------------------
# Core: paths, logging, locks, input helpers and atomic file operations.
# -----------------------------------------------------------------------------

CONFIG_FILE="${BBRV3_CONFIG:-/etc/bbrv3-lite.conf}"
STATE_DIR="${BBRV3_STATE_DIR:-/var/lib/bbrv3-lite}"
BASELINE_DIR="${BBRV3_BASELINE_DIR:-${STATE_DIR}/baseline}"
LEGACY_BACKUP_DIR="${BBRV3_LEGACY_BACKUP_DIR:-${STATE_DIR}/original}"
HISTORY_DIR="${BBRV3_HISTORY_DIR:-${STATE_DIR}/history}"
PERSIST_DIR="${BBRV3_PERSIST_DIR:-/usr/local/lib/bbrv3-lite}"
PERSIST_SCRIPT="${BBRV3_PERSIST_SCRIPT:-${PERSIST_DIR}/net-tcp-tune.sh}"
SERVICE_NAME="bbrv3-lite.service"
SERVICE_FILE="${BBRV3_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}}"
LEGACY_SERVICE_FILE="${BBRV3_LEGACY_SERVICE_FILE:-/etc/systemd/system/bbr-optimize-persist.service}"
SYSCTL_FILE="${BBRV3_SYSCTL_FILE:-/etc/sysctl.d/99-bbrv3-lite.conf}"
LEGACY_SYSCTL_FILE="${BBRV3_LEGACY_SYSCTL_FILE:-/etc/sysctl.d/99-bbr-ultimate.conf}"
LOCK_FILE="${BBRV3_LOCK_FILE:-/run/lock/bbrv3-lite.lock}"
DNS_BACKUP_DIR="${BBRV3_DNS_BACKUP_DIR:-${STATE_DIR}/dns}"
IPV6_BACKUP_DIR="${BBRV3_IPV6_BACKUP_DIR:-${STATE_DIR}/ipv6}"
NIC_POLICY_DIR="${BBRV3_NIC_POLICY_DIR:-/etc/bbrv3-lite/interfaces.d}"
NIC_STATE_DIR="${BBRV3_NIC_STATE_DIR:-${STATE_DIR}/interfaces}"

COLOR_ENABLED=0
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then COLOR_ENABLED=1; fi

color() {
    local code="$1"; shift
    if (( COLOR_ENABLED )); then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}

log() {
    local level="$1"; shift
    local prefix
    case "$level" in
        INFO) prefix=$(color '1;36' '[*]') ;;
        OK)   prefix=$(color '1;32' '[+]') ;;
        WARN) prefix=$(color '1;33' '[!]') ;;
        ERR)  prefix=$(color '1;31' '[x]') ;;
        *)    prefix="[$level]" ;;
    esac
    printf '%s %s\n' "$prefix" "$*" >&2
}

die() { log ERR "$*"; return 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]{0,17})$ ]]; }
is_decimal() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "此操作需要 root 权限"
}

require_commands() {
    local missing=() cmd
    for cmd in "$@"; do command_exists "$cmd" || missing+=("$cmd"); done
    ((${#missing[@]} == 0)) || die "缺少命令: ${missing[*]}"
}

confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then return 1; fi
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n] " answer || return 1
        [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
    else
        read -r -p "$prompt [y/N] " answer || return 1
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

LOCK_HELD=0
acquire_lock() {
    local wait_seconds="${1:-0}"
    (( LOCK_HELD == 0 )) || return 0
    require_commands flock || return 1
    is_uint "$wait_seconds" || { die "锁等待时间无效: $wait_seconds"; return 1; }
    mkdir -p -- "$(dirname "$LOCK_FILE")" || return 1
    exec {BBRV3_LOCK_FD}>"$LOCK_FILE" || return 1
    if (( wait_seconds > 0 )); then
        if ! flock -w "$wait_seconds" "$BBRV3_LOCK_FD"; then
            exec {BBRV3_LOCK_FD}>&-
            die "等待 ${wait_seconds}s 后仍有另一个 ${SCRIPT_NAME} 进程占用配置锁"
            return 1
        fi
    elif ! flock -n "$BBRV3_LOCK_FD"; then
        exec {BBRV3_LOCK_FD}>&-
        die "已有另一个 ${SCRIPT_NAME} 进程正在修改网络配置"
        return 1
    fi
    LOCK_HELD=1
}

release_lock() {
    if (( LOCK_HELD )); then
        flock -u "$BBRV3_LOCK_FD" 2>/dev/null || true
        exec {BBRV3_LOCK_FD}>&-
        LOCK_HELD=0
    fi
}

make_temp_for() {
    local target="$1"
    mkdir -p -- "$(dirname "$target")"
    mktemp "${target}.tmp.XXXXXX"
}

atomic_install() {
    local source="$1" target="$2" mode="${3:-0644}" owner="${4:-root}" group="${5:-root}"
    local temp
    temp=$(make_temp_for "$target") || return 1
    local -a install_args=(-m "$mode")
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then install_args+=(-o "$owner" -g "$group"); fi
    if ! install "${install_args[@]}" "$source" "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    mv -f -- "$temp" "$target"
}

remove_tree_within() {
    local target="$1" parent="$2" resolved_target resolved_parent
    resolved_target=$(readlink -m "$target") || return 1
    resolved_parent=$(readlink -m "$parent") || return 1
    [[ "$resolved_parent" != / && "$resolved_target" == "$resolved_parent/"* ]] || {
        die "拒绝递归删除越界路径: $resolved_target (parent $resolved_parent)"
        return 1
    }
    rm -rf -- "$resolved_target"
}

utc_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
history_stamp() { date -u +'%Y%m%dT%H%M%SZ'; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i=1;
        while (b >= 1024 && i < 5) { b/=1024; i++ }
        printf (i == 1 ? "%.0f %s" : "%.2f %s"), b, u[i]
    }'
}

cleanup_core() {
    local rc=$?
    if [[ -n "${TC_TRIAL_IFACE:-}" && -n "${TC_TRIAL_SNAPSHOT:-}" ]] && declare -F tc_trial_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交的临时 TC 操作，正在恢复操作前 qdisc"
        tc_trial_transaction_rollback || true
    fi
    if [[ -n "${MEASURE_IFACE:-}" && -n "${MEASURE_SNAPSHOT:-}" ]] && declare -F measure_restore >/dev/null; then
        log WARN "进程退出时仍有测量快照，正在恢复操作前 qdisc"
        measure_restore || true
    fi
    if [[ -n "${DNS_TRANSACTION_DIR:-}" ]] && declare -F dns_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交 DNS 事务，正在恢复操作前状态"
        dns_transaction_rollback || true
    fi
    if [[ -n "${IPV6_TRANSACTION_DIR:-}" ]] && declare -F ipv6_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交 IPv6 事务，正在恢复操作前状态"
        ipv6_transaction_rollback || true
    fi
    if [[ -n "${ACTION_TRANSACTION_DIR:-}" ]] && declare -F action_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交事务，正在恢复操作前状态"
        action_transaction_rollback || true
    fi
    release_lock
    return "$rc"
}

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

# -----------------------------------------------------------------------------
# Platform detection: OS, interface, machine facts and dependency installation.
# -----------------------------------------------------------------------------

os_id() { awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null; }
os_codename() {
    awk -F= '$1=="VERSION_CODENAME" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
}

virtualization_type() {
    if command_exists systemd-detect-virt; then systemd-detect-virt 2>/dev/null || printf 'none\n';
    elif [[ -f /.dockerenv ]]; then printf 'docker\n';
    else printf 'unknown\n'; fi
}

is_container() {
    if command_exists systemd-detect-virt && systemd-detect-virt --quiet --container 2>/dev/null; then return 0; fi
    case "$(virtualization_type)" in docker|lxc|openvz|podman|container-other|systemd-nspawn|wsl) return 0 ;; *) return 1 ;; esac
}

require_host_network_control() {
    if is_container; then
        die "容器环境不能安全修改宿主机内核、sysctl 或 qdisc；请在 VPS 宿主系统执行"
        return 1
    fi
    return 0
}

require_systemd_runtime() {
    require_commands systemctl || return 1
    [[ -d /run/systemd/system ]] || { die "当前系统没有运行 systemd，不能安装持久化服务"; return 1; }
    systemctl show-environment >/dev/null 2>&1 || { die "无法连接 systemd，不能安全提交持久化配置"; return 1; }
}

route_output_interfaces() {
    # "dev" is not at a fixed column (for example, "default dev ppp0"), and
    # multipath output can contain more than one dev token on the same line.
    awk '{for (i=1; i<NF; i++) if ($i=="dev") print $(i+1)}' | awk '!seen[$0]++'
}

default_route_output() {
    local family="$1"
    [[ "$family" == -4 || "$family" == -6 ]] || return 1
    ip "$family" route show default 2>/dev/null || true
}

default_route_interface_for_family() {
    local family="$1" output
    output=$(default_route_output "$family") || return 1
    route_output_interfaces <<< "$output" | sed -n '1p'
}

default_route_interface() {
    local iface
    iface=$(default_route_interface_for_family -4)
    [[ -n "$iface" ]] || iface=$(default_route_interface_for_family -6)
    printf '%s\n' "$iface"
}

default_route_count() {
    local family="$1" output
    output=$(default_route_output "$family") || return 1
    awk '$1=="default" {count++} END {print count+0}' <<< "$output"
}

route_output_has_multipath() {
    local output="$1"
    [[ "$output" == *"nexthop"* ]] && return 0
    awk '
        {
            devs=0
            for (i=1; i<NF; i++) if ($i=="dev") devs++
            if (devs>1) found=1
        }
        END {exit !found}
    ' <<< "$output"
}

route_output_has_unresolved_nhid() {
    local output="$1"
    [[ "$output" =~ (^|[[:space:]])nhid([[:space:]]|$) ]]
}

default_route_has_multipath() {
    local family="$1" output
    output=$(default_route_output "$family") || return 1
    route_output_has_multipath "$output"
}

resolve_route_target_addresses() {
    local target="$1" address
    if [[ "$target" == *:* ]]; then
        printf '6\t%s\n' "$target"
        return 0
    fi
    if [[ "$target" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        printf '4\t%s\n' "$target"
        return 0
    fi
    command_exists getent || { die "无法解析测速目标路由：缺少 getent"; return 1; }
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        if [[ "$address" == *:* ]]; then printf '6\t%s\n' "$address"
        elif [[ "$address" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then printf '4\t%s\n' "$address"
        fi
    done < <(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++')
}

target_route_records() {
    local target="$1" family address output fibmatch iface fib_iface dev_count fib_dev_count addresses
    local resolved_count=0 verified_count=0
    addresses=$(resolve_route_target_addresses "$target") || return 1
    [[ -n "$addresses" ]] || { die "无法解析测速目标 $target 的任何路由候选地址"; return 1; }
    while IFS=$'\t' read -r family address; do
        [[ -n "$family" && -n "$address" ]] || continue
        ((resolved_count+=1))
        if ! output=$(ip "-$family" route get "$address" 2>/dev/null) || [[ -z "$output" ]]; then
            die "测速目标 $address 无法完成 route-get；所有解析候选都必须可核验，已停止"
            return 1
        fi
        if route_output_has_unresolved_nhid "$output"; then
            die "测速目标 $address 的 route-get 包含未解析的 nexthop object (nhid)；无法证明出口唯一，已停止"
            return 1
        fi
        if route_output_has_multipath "$output"; then
            die "测速目标 $address 的 route-get 返回 ECMP/nexthop；v${SCRIPT_VERSION} 不会在多路径上自动调优"
            return 1
        fi
        dev_count=$(route_output_interfaces <<< "$output" | wc -l | awk '{print $1}')
        if ! is_uint "${dev_count:-}" || (( dev_count != 1 )); then
            die "测速目标 $address 的 route-get 无法确定唯一出口"
            return 1
        fi
        iface=$(route_output_interfaces <<< "$output" | sed -n '1p')
        validate_interface_name "$iface" || { die "测速目标 $address 返回非法出口网卡: $iface"; return 1; }

        # `route get` can hash an ECMP route and expose only one selected dev.
        # fibmatch returns the underlying FIB entry (including its nexthops).
        if ! fibmatch=$(ip "-$family" route get fibmatch "$address" 2>/dev/null) || [[ -z "$fibmatch" ]]; then
            die "当前 iproute2 无法用 fibmatch 核验测速目标 $address；不完整的 route-show fallback 不能证明策略路由出口，已停止"
            return 1
        fi
        if route_output_has_unresolved_nhid "$fibmatch"; then
            die "测速目标 $address 的 FIB 匹配包含未解析的 nexthop object (nhid)；无法证明出口唯一，已停止"
            return 1
        fi
        if route_output_has_multipath "$fibmatch"; then
            die "测速目标 $address 的 FIB 匹配包含 ECMP/nexthop；v${SCRIPT_VERSION} 不会自动选择其中一条路径"
            return 1
        fi
        fib_dev_count=$(route_output_interfaces <<< "$fibmatch" | wc -l | awk '{print $1}')
        if ! is_uint "${fib_dev_count:-}" || (( fib_dev_count != 1 )); then
            die "测速目标 $address 的 fibmatch 无法确定唯一出口"
            return 1
        fi
        fib_iface=$(route_output_interfaces <<< "$fibmatch" | sed -n '1p')
        validate_interface_name "$fib_iface" || { die "测速目标 $address 的 fibmatch 返回非法出口网卡: $fib_iface"; return 1; }
        [[ "$fib_iface" == "$iface" ]] || {
            die "测速目标 $address 的 route-get/fibmatch 出口不一致（$iface/$fib_iface）；无法证明路径稳定，已停止"
            return 1
        }
        printf '%s\t%s\t%s\n' "$family" "$address" "$iface"
        ((verified_count+=1))
    done <<< "$addresses"
    (( resolved_count > 0 )) || { die "无法取得测速目标 $target 的路由候选地址"; return 1; }
    (( verified_count == resolved_count )) || {
        die "测速目标 $target 仅核验了 ${verified_count}/${resolved_count} 个解析候选；已停止"
        return 1
    }
}

# Path-safety gate: inspect every resolved candidate before the formal
# measurement freezes one literal/source/interface tuple. Ambiguous paths fail
# closed and no route is altered.
auto_tune_route_guard() {
    local expected_iface="$1" target="${2:-}" family output count v4_iface v6_iface records
    local route_family address iface first_iface=""
    validate_interface_name "$expected_iface" || { die "自动调优选中了非法网卡: $expected_iface"; return 1; }

    # Once endpoint discovery has frozen a literal address, only that address
    # and family can influence the formal measurement. An unrelated broken
    # AAAA/default IPv6 path must not veto a proven IPv4 endpoint (and vice
    # versa). The literal still goes through the full route-get/fibmatch gate.
    if [[ -n "$target" ]] && { [[ "$target" == *:* ]] || [[ "$target" =~ ^[0-9]+([.][0-9]+){3}$ ]]; }; then
        records=$(target_route_records "$target") || return 1
        IFS=$'\t' read -r route_family address iface <<< "$records"
        [[ -n "$route_family" && -n "$address" && -n "$iface" ]] || {
            die "测速地址 $target 没有返回完整路由记录"
            return 1
        }
        [[ "$iface" == "$expected_iface" ]] || {
            die "测速地址 $address 实际通过 $iface，但自动调优选中 $expected_iface；拒绝在错误网卡上应用 TC"
            return 1
        }
        log INFO "测速目标路由检查通过: $address (IPv${route_family}) -> $expected_iface"
        return 0
    fi

    for family in -4 -6; do
        output=$(default_route_output "$family") || return 1
        count=$(awk '$1=="default" {count++} END {print count+0}' <<< "$output")
        if route_output_has_unresolved_nhid "$output"; then
            die "IPv${family#-} 默认路由包含未解析的 nexthop object (nhid)；无法证明出口唯一，已停止"
            return 1
        fi
        if [[ "$output" == *"nexthop"* ]] || default_route_has_multipath "$family"; then
            die "IPv${family#-} 默认路由包含 ECMP/nexthop；v${SCRIPT_VERSION} 不会自动选择其中一条路径"
            return 1
        fi
        if (( count > 1 )); then
            log WARN "检测到 ${count} 条 IPv${family#-} 默认路由；将以具体测速目标的 route-get 结果决定是否可安全继续"
        fi
    done

    v4_iface=$(default_route_interface_for_family -4)
    v6_iface=$(default_route_interface_for_family -6)
    if [[ -z "$target" ]]; then
        # There is no peer whose route can disambiguate this BBR+FQ-only run.
        if [[ -n "$v4_iface" && -n "$v6_iface" && "$v4_iface" != "$v6_iface" ]]; then
            die "IPv4/IPv6 默认出口分别为 $v4_iface/$v6_iface；未测速时无法证明应调优哪张网卡"
            return 1
        fi
        for family in -4 -6; do
            count=$(default_route_count "$family") || return 1
            output=$(default_route_output "$family") || return 1
            if (( count > 1 )) && (( $(route_output_interfaces <<< "$output" | wc -l) > 1 )); then
                die "IPv${family#-} 存在跨网卡的多条默认路由；未提供测速目标，拒绝自动选择"
                return 1
            fi
        done
        [[ "$expected_iface" == "${v4_iface:-$v6_iface}" ]] || {
            die "自动选择网卡 $expected_iface 与当前默认出口 ${v4_iface:-$v6_iface} 不一致"
            return 1
        }
        log INFO "自动调优出口检查通过: $expected_iface（未运行测速）"
        return 0
    fi

    records=$(target_route_records "$target") || return 1
    while IFS=$'\t' read -r route_family address iface; do
        [[ -n "$route_family" && -n "$iface" ]] || continue
        if [[ -z "$first_iface" ]]; then first_iface="$iface"; fi
        if [[ "$iface" != "$first_iface" ]]; then
            die "测速目标 $target 的候选地址出口不一致（$first_iface/$iface）；未固定地址族时拒绝自动调优"
            return 1
        fi
        if [[ "$iface" != "$expected_iface" ]]; then
            die "测速目标 $address 实际通过 $iface，但自动调优选中 $expected_iface；拒绝在错误网卡上应用 TC"
            return 1
        fi
    done <<< "$records"
    log INFO "测速目标路由检查通过: $target -> $expected_iface"
}

interface_is_excluded() {
    case "$1" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*) return 0 ;; *) return 1 ;; esac
}

detect_interface() {
    local requested="${1:-auto}" iface
    if [[ "$requested" != auto ]]; then
        validate_interface_name "$requested" || { die "非法网卡名: $requested"; return 1; }
        [[ -e "/sys/class/net/$requested" ]] || { die "网卡不存在: $requested"; return 1; }
        printf '%s\n' "$requested"
        return 0
    fi
    iface=$(default_route_interface)
    [[ -n "$iface" ]] || { die "没有检测到 IPv4/IPv6 默认路由出口"; return 1; }
    interface_is_excluded "$iface" && { die "默认出口是受保护的虚拟接口: $iface，请显式指定 --interface"; return 1; }
    validate_interface_name "$iface" || { die "检测到非法网卡名: $iface"; return 1; }
    printf '%s\n' "$iface"
}

detect_mtu() { cat "/sys/class/net/$1/mtu" 2>/dev/null || printf '1500\n'; }
detect_link_speed() {
    local value
    value=$(cat "/sys/class/net/$1/speed" 2>/dev/null || true)
    # Some virtual drivers expose UINT32_MAX or another sentinel instead of a
    # usable line rate. Treat anything beyond the CLI's supported 1 Tbit/s
    # range as unknown rather than feeding it into buffer/traffic estimates.
    if is_uint "${value:-}" && (( value > 0 && value <= 1000000 )); then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
detect_rx_queues() {
    local count
    count=$(find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | awk '{print $1}')
    is_uint "${count:-}" && (( count > 0 )) && printf '%s\n' "$count" || printf '1\n'
}
detect_tx_queues() {
    local count
    count=$(find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l | awk '{print $1}')
    is_uint "${count:-}" && (( count > 0 )) && printf '%s\n' "$count" || printf '1\n'
}
detect_driver() {
    local path
    path=$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null || true)
    [[ -n "$path" ]] && basename "$path" || printf 'virtual\n'
}
detect_offload_summary() {
    local iface="$1" output feature value summary="" key
    command_exists ethtool || { printf 'unavailable (ethtool not installed)\n'; return 0; }
    output=$(ethtool -k "$iface" 2>/dev/null || true)
    [[ -n "$output" ]] || { printf 'unavailable\n'; return 0; }
    for key in tcp-segmentation-offload generic-segmentation-offload generic-receive-offload; do
        value=$(awk -F': ' -v key="$key" '$1==key {print $2; exit}' <<< "$output")
        value="${value%% *}"
        case "$key" in tcp-segmentation-offload) feature=tso ;; generic-segmentation-offload) feature=gso ;; *) feature=gro ;; esac
        [[ -n "$value" ]] && summary+="${summary:+ }${feature}=${value}"
    done
    printf '%s\n' "${summary:-unavailable}"
}
memory_mb() {
    local value
    value=$(awk '/MemTotal:/ {printf "%d\n", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)
    is_uint "${value:-}" && (( value > 0 )) && printf '%s\n' "$value" || printf '1024\n'
}
cpu_count() {
    local value
    value=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)
    is_uint "${value:-}" && (( value > 0 )) && printf '%s\n' "$value" || printf '1\n'
}

hardware_class_for() {
    local cpu="$1" ram="$2"
    if (( ram < 768 || cpu <= 1 )); then printf 'micro\n'
    elif (( ram < 2048 || cpu <= 2 )); then printf 'small\n'
    elif (( ram < 8192 || cpu <= 8 )); then printf 'standard\n'
    elif (( ram < 32768 || cpu <= 32 )); then printf 'high\n'
    else printf 'extreme\n'
    fi
}

# Populate a single, auditable hardware model used by sysctl sizing, scan
# bounds and status output. The configured/observed bandwidth always wins over
# a NIC-reported line rate because virtual NIC speeds are often synthetic.
hardware_profile_values() {
    local requested="${1:-auto}" configured_bandwidth="${2:-0}" iface="" link="unknown"
    is_uint "$configured_bandwidth" && (( configured_bandwidth <= 1000000 )) || {
        die "硬件模型带宽无效: $configured_bandwidth"
        return 1
    }
    HARDWARE_CPU_COUNT=$(cpu_count)
    HARDWARE_MEMORY_MB=$(memory_mb)
    iface=$(detect_interface "$requested" 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
        link=$(detect_link_speed "$iface")
        HARDWARE_RX_QUEUES=$(detect_rx_queues "$iface")
        HARDWARE_TX_QUEUES=$(detect_tx_queues "$iface")
        HARDWARE_MTU=$(detect_mtu "$iface")
        HARDWARE_DRIVER=$(detect_driver "$iface")
    else
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1; HARDWARE_MTU=1500; HARDWARE_DRIVER=unknown
    fi
    HARDWARE_LINK_MBIT="$link"
    HARDWARE_CLASS=$(hardware_class_for "$HARDWARE_CPU_COUNT" "$HARDWARE_MEMORY_MB")
    HARDWARE_VIRTUALIZATION=$(virtualization_type)
    HARDWARE_LINK_TRUST=trusted
    if [[ "$link" == unknown ]]; then
        HARDWARE_LINK_TRUST=unknown
    elif [[ "$HARDWARE_VIRTUALIZATION" != none ]]; then
        HARDWARE_LINK_TRUST=virtual-untrusted
    else
        case "$HARDWARE_DRIVER" in virtual|virtio*|veth|vmxnet*|xen*|hv_netvsc) HARDWARE_LINK_TRUST=virtual-untrusted ;; esac
    fi
    if (( configured_bandwidth > 0 )); then
        EFFECTIVE_BANDWIDTH_MBIT="$configured_bandwidth"
        EFFECTIVE_BANDWIDTH_SOURCE="configured"
    elif [[ "$HARDWARE_LINK_TRUST" == trusted ]] && is_uint "$link" && (( link > 0 )); then
        EFFECTIVE_BANDWIDTH_MBIT="$link"
        EFFECTIVE_BANDWIDTH_SOURCE="link"
    else
        EFFECTIVE_BANDWIDTH_MBIT=1000
        if [[ "$HARDWARE_LINK_TRUST" == virtual-untrusted ]]; then EFFECTIVE_BANDWIDTH_SOURCE="virtual-link-fallback"
        else EFFECTIVE_BANDWIDTH_SOURCE="fallback"
        fi
    fi
}

recommended_scan_cap() {
    local requested="${1:-auto}" nominal="${2:-0}" cap=5000 link
    hardware_profile_values "$requested" "$nominal" || return 1
    link="$HARDWARE_LINK_MBIT"
    if (( nominal > 0 )); then cap=$((nominal * 3 / 2)); fi
    if [[ "$HARDWARE_LINK_TRUST" == trusted ]] && is_uint "$link" && (( link > 0 && link * 5 / 4 > cap )); then cap=$((link * 5 / 4)); fi
    (( cap < 5000 )) && cap=5000
    (( cap > 1000000 )) && cap=1000000
    printf '%s\n' "$cap"
}

expanded_scan_cap() {
    local current="$1" measured="$2" observed
    is_uint "$current" && (( current >= 100 && current <= 1000000 )) || { die "扫描上限无效: $current"; return 1; }
    is_decimal "$measured" || { die "基准吞吐无效: $measured"; return 1; }
    observed=$(awk -v g="$measured" 'BEGIN {v=g*1.5; if(v<5000)v=5000; if(v>1000000)v=1000000; printf "%d", v+0.5}')
    if (( observed > current )); then printf '%s\n' "$observed"; else printf '%s\n' "$current"; fi
}

recommended_measure_duration() {
    local requested="${1:-auto}" bandwidth="${2:-0}"
    hardware_profile_values "$requested" "$bandwidth" || return 1
    if (( EFFECTIVE_BANDWIDTH_MBIT >= 40000 )); then printf '3\n'
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )); then printf '4\n'
    else printf '5\n'
    fi
}

recommended_verify_flows() {
    local requested="${1:-auto}" bandwidth="${2:-0}" flows=4 capacity
    hardware_profile_values "$requested" "$bandwidth" || return 1
    capacity="$HARDWARE_CPU_COUNT"
    if (( HARDWARE_CPU_COUNT <= 1 )); then flows=2
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 40000 )); then flows=16
    elif (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )); then flows=8
    else flows=4
    fi
    (( flows > capacity * 2 )) && flows=$((capacity * 2))
    (( flows < 2 )) && flows=2
    (( flows > 16 )) && flows=16
    printf '%s\n' "$flows"
}

hardware_scaling_note() {
    local cpu="$HARDWARE_CPU_COUNT" rx="$HARDWARE_RX_QUEUES" bandwidth="$EFFECTIVE_BANDWIDTH_MBIT"
    if (( bandwidth >= 2500 && rx == 1 && cpu >= 4 )); then
        printf 'single RX queue may limit multi-Gbit throughput; inspect RSS/RPS and IRQ affinity\n'
    elif (( bandwidth >= 10000 && cpu <= 2 )); then
        printf 'CPU count may limit line-rate processing; validate CPU saturation during load\n'
    elif (( bandwidth >= 40000 )); then
        printf 'aggregate HTB can become the local bottleneck at this rate; require clean per-core CPU metrics and A/B verification\n'
    elif [[ "$EFFECTIVE_BANDWIDTH_SOURCE" == fallback || "$EFFECTIVE_BANDWIDTH_SOURCE" == virtual-link-fallback ]]; then
        printf 'line rate is unknown or virtual; using 1000 Mbit planning until measured/configured\n'
    else
        printf 'no obvious hardware queue bottleneck detected\n'
    fi
}

median_ping_ms() {
    local target="$1" family="${2:-auto}" output
    [[ -n "$target" && "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || return 1
    case "$family" in
        4) output=$(ping -4 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        6) output=$(ping -6 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        *) output=$(ping -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
    esac
    awk -F'/' '/rtt|round-trip/ {printf "%.0f\n", $5}' <<< "$output"
}

detect_profile() {
    local requested="${1:-auto}" target="${2:-}" iface rtt="not measured" cc available
    require_commands ip awk uname || return 1
    iface=$(detect_interface "$requested") || return 1
    if [[ -n "$target" ]]; then
        [[ "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法探测目标: $target"; return 1; }
        rtt=$(median_ping_ms "$target"); [[ -n "$rtt" ]] || rtt="unreachable"
    fi
    printf '%-18s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-18s %s\n' "OS" "$(os_id) $(os_codename)"
    printf '%-18s %s\n' "Kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "Virtualization" "$(virtualization_type)"
    printf '%-18s %s\n' "CPU cores" "$(cpu_count)"
    printf '%-18s %s MB\n' "Memory" "$(memory_mb)"
    printf '%-18s %s\n' "Interface" "$iface"
    printf '%-18s %s\n' "Driver" "$(detect_driver "$iface")"
    printf '%-18s %s\n' "MTU" "$(detect_mtu "$iface")"
    local link_speed
    link_speed=$(detect_link_speed "$iface")
    [[ "$link_speed" == unknown ]] || link_speed="${link_speed} Mbps"
    printf '%-18s %s\n' "Link speed" "$link_speed"
    printf '%-18s %s\n' "RX queues" "$(detect_rx_queues "$iface")"
    printf '%-18s %s\n' "TX queues" "$(detect_tx_queues "$iface")"
    printf '%-18s %s\n' "NIC offloads" "$(detect_offload_summary "$iface")"
    hardware_profile_values "$iface" 0 || return 1
    printf '%-18s %s\n' "Hardware class" "$HARDWARE_CLASS"
    printf '%-18s %s\n' "Link trust" "$HARDWARE_LINK_TRUST"
    printf '%-18s %s Mbit (%s)\n' "Planning bandwidth" "$EFFECTIVE_BANDWIDTH_MBIT" "$EFFECTIVE_BANDWIDTH_SOURCE"
    printf '%-18s %s\n' "Scaling note" "$(hardware_scaling_note)"
    [[ "$rtt" == "not measured" || "$rtt" == unreachable ]] || rtt="${rtt} ms"
    printf '%-18s %s\n' "Target RTT" "$rtt"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)
    printf '%-18s %s\n' "Congestion control" "$cc"
    printf '%-18s %s\n' "Available CC" "$available"
    printf '%-18s %s\n' "BBR compatibility" "$(bbr_compatibility_status "$cc" "$available")"
}

install_measure_dependencies() {
    require_root || return 1
    local -a packages=()
    command_exists iperf3 || packages+=(iperf3)
    command_exists jq || packages+=(jq)
    command_exists ping || packages+=(iputils-ping)
    if ! command_exists ip || ! command_exists tc; then packages+=(iproute2); fi
    command_exists sysctl || packages+=(procps)
    command_exists flock || packages+=(util-linux)
    command_exists timeout || packages+=(coreutils)
    ((${#packages[@]} > 0)) || { log OK "测量依赖已经齐全"; return 0; }
    case "$(os_id)" in
        debian|ubuntu)
            log INFO "仅安装缺少的依赖包: ${packages[*]}"
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        *) die "自动安装依赖目前只支持 Debian/Ubuntu" ;;
    esac
}

# -----------------------------------------------------------------------------
# Network path awareness: stable route identity, RTT distribution and PMTU.
# This module is observational. It never changes routes, addresses or links.
# -----------------------------------------------------------------------------

PATH_PROFILE_SCHEMA="1"
PATH_ROUTE_FINGERPRINT=""
PATH_ENDPOINT_FINGERPRINT=""
PATH_GATEWAY="none"
PATH_TABLE="main"
PATH_INTERFACE_MTU="unknown"
PATH_ROUTE_MTU="unknown"
PATH_PMTU="unknown"
PATH_MSS="unknown"
PATH_PMTU_PROBE_CAPPED=0
PATH_PING_SENT=0
PATH_PING_RECEIVED=0
PATH_LOSS_PERCENT="na"
PATH_RTT_MIN_MS="na"
PATH_RTT_MEDIAN_MS="na"
PATH_RTT_P95_MS="na"
PATH_RTT_MAX_MS="na"
PATH_RTT_JITTER_P95_MS="na"
PATH_GATEWAY_RTT_MS="na"
PATH_LATENCY_CLASS="unknown"
PATH_STABILITY="unknown"
PATH_PROFILE_SCORE=0
PATH_PROFILE_GRADE="low"
PATH_DECISION="limited"
PATH_RISK_FLAGS="unavailable"
PATH_CAPTURED_AT=""

path_profile_reset_metrics() {
    PATH_PMTU="unknown"; PATH_MSS="unknown"; PATH_PMTU_PROBE_CAPPED=0
    PATH_PING_SENT=0; PATH_PING_RECEIVED=0; PATH_LOSS_PERCENT="na"
    PATH_RTT_MIN_MS="na"; PATH_RTT_MEDIAN_MS="na"; PATH_RTT_P95_MS="na"; PATH_RTT_MAX_MS="na"
    PATH_RTT_JITTER_P95_MS="na"; PATH_GATEWAY_RTT_MS="na"
    PATH_LATENCY_CLASS="unknown"; PATH_STABILITY="unknown"
    PATH_PROFILE_SCORE=0; PATH_PROFILE_GRADE="low"; PATH_DECISION="limited"
    PATH_RISK_FLAGS="unavailable"; PATH_CAPTURED_AT=""
}

path_state_reset() {
    PATH_ROUTE_FINGERPRINT=""; PATH_ENDPOINT_FINGERPRINT=""
    PATH_GATEWAY="none"; PATH_TABLE="main"
    PATH_INTERFACE_MTU="unknown"; PATH_ROUTE_MTU="unknown"
    path_profile_reset_metrics
}

path_token_after() {
    local token="$1"
    awk -v token="$token" '{for (i=1; i<NF; i++) if ($i==token) {print $(i+1); exit}}'
}

path_route_normalize() {
    local address="$1"
    awk -v address="$address" '
        {
            out=""
            for (i=1; i<=NF; i++) {
                # Everything after the cache marker is a mutable destination
                # exception (RTT/cwnd/expiry/etc.), not forwarding identity.
                # Route MTU is captured separately so a real PMTU change still
                # changes the fingerprint.
                if ($i=="cache") break
                if ($i=="uid" || $i=="expires") {i++; continue}
                value=$i
                if (value==address) value="<target>"
                out=(out=="" ? value : out " " value)
            }
            if (out!="") print out
        }
    '
}

path_hash_payload() {
    if command_exists sha256sum; then
        sha256sum | awk '{print $1}'
    elif command_exists openssl; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        die "路径指纹需要 sha256sum 或 openssl"
        return 1
    fi
}

# Print one tab-separated identity record:
# route-fingerprint, endpoint-fingerprint, gateway, table, interface-mtu,
# route-mtu. The route fingerprint deliberately canonicalizes the target
# literal so a hostname moving between addresses on the same proven route does
# not look like an egress change. The endpoint fingerprint retains the literal.
path_capture_route_identity() {
    local family="$1" address="$2" source="$3" iface="$4"
    local route fib route_norm fib_norm gateway table iface_mtu route_mtu route_payload
    local route_fp endpoint_fp route_iface fib_iface
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    measure_source_address_is_valid "$family" "$source" || return 1
    validate_interface_name "$iface" && [[ "$iface" != auto ]] || return 1

    route=$(ip "-$family" route get "$address" from "$source" 2>/dev/null) || return 1
    fib=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || return 1
    [[ -n "$route" && -n "$fib" ]] || return 1
    route_iface=$(measure_unique_route_iface "$route" "路径指纹 route-get") || return 1
    fib_iface=$(measure_unique_route_iface "$fib" "路径指纹 fibmatch") || return 1
    [[ "$route_iface" == "$iface" && "$fib_iface" == "$iface" ]] || {
        die "路径指纹出口与冻结网卡不一致（route=$route_iface, fib=$fib_iface, expected=$iface）"
        return 1
    }

    route_norm=$(path_route_normalize "$address" <<< "$route") || return 1
    fib_norm=$(path_route_normalize "$address" <<< "$fib") || return 1
    [[ -n "$route_norm" && -n "$fib_norm" ]] || return 1
    gateway=$(path_token_after via <<< "$route"); gateway="${gateway:-none}"
    table=$(path_token_after table <<< "$fib"); table="${table:-main}"
    iface_mtu=$(detect_mtu "$iface"); is_uint "$iface_mtu" || iface_mtu=unknown
    route_mtu=$(path_token_after mtu <<< "$route")
    if ! is_uint "${route_mtu:-}"; then route_mtu="$iface_mtu"; fi

    route_payload=$(printf 'family=%s\nsource=%s\ninterface=%s\ngateway=%s\ntable=%s\ninterface_mtu=%s\nroute_mtu=%s\nroute=%s\nfib=%s\n' \
        "$family" "$source" "$iface" "$gateway" "$table" "$iface_mtu" "$route_mtu" "$route_norm" "$fib_norm") || return 1
    route_fp=$(path_hash_payload <<< "$route_payload") || return 1
    endpoint_fp=$(printf '%saddress=%s\n' "$route_payload" "$address" | path_hash_payload) || return 1
    [[ "$route_fp" =~ ^[0-9a-f]{64}$ && "$endpoint_fp" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$route_fp" "$endpoint_fp" "$gateway" "$table" "$iface_mtu" "$route_mtu"
}

path_lock_route_identity() {
    local state
    state=$(path_capture_route_identity "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" \
        "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE") || {
        die "无法建立测速路径指纹"
        return 1
    }
    IFS=$'\t' read -r PATH_ROUTE_FINGERPRINT PATH_ENDPOINT_FINGERPRINT PATH_GATEWAY PATH_TABLE \
        PATH_INTERFACE_MTU PATH_ROUTE_MTU <<< "$state"
    [[ -n "$PATH_ROUTE_FINGERPRINT" && -n "$PATH_ENDPOINT_FINGERPRINT" ]] || return 1
}

path_verify_route_identity() {
    local state route_fp endpoint_fp gateway table iface_mtu route_mtu
    [[ -n "$PATH_ROUTE_FINGERPRINT" && -n "$PATH_ENDPOINT_FINGERPRINT" ]] || {
        die "测速路径尚未建立指纹"
        return 1
    }
    state=$(path_capture_route_identity "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" \
        "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE") || return 1
    IFS=$'\t' read -r route_fp endpoint_fp gateway table iface_mtu route_mtu <<< "$state"
    [[ "$endpoint_fp" == "$PATH_ENDPOINT_FINGERPRINT" ]] || {
        die "测速端点路径指纹发生变化；拒绝使用本次样本"
        return 1
    }
    [[ "$route_fp" == "$PATH_ROUTE_FINGERPRINT" ]] || {
        die "测速出口路径指纹发生变化；拒绝使用本次样本"
        return 1
    }
}

path_ping_values() {
    awk '
        match($0,/time[=<][0-9.]+/) {
            value=substr($0,RSTART,RLENGTH)
            if (value ~ /^time</) {sub(/^time</,"",value); value=value/2}
            else sub(/^time=/,"",value)
            if (value ~ /^[0-9]+([.][0-9]+)?$/) print value
        }
    '
}

path_percentile_95() {
    sort -n | awk '{a[NR]=$1} END {if(NR){i=int((NR*95+99)/100); if(i<1)i=1; if(i>NR)i=NR; print a[i]}}'
}

path_ping_command() {
    local target="$1" count="$2"
    ping "-$MEASURE_PEER_FAMILY" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" \
        -n -i 0.2 -W 1 -c "$count" -- "$target"
}

path_probe_pmtu() {
    local enabled="$1" family="$MEASURE_PEER_FAMILY" interface_mtu="$PATH_INTERFACE_MTU"
    local icmp_overhead tcp_overhead minimum high low mid payload best=0 probe_cap="${BBRV3_PATH_PMTU_CAP:-9000}"
    (( enabled == 1 )) || { printf 'disabled\tunknown\t0\n'; return 0; }
    is_uint "$interface_mtu" && (( interface_mtu >= 576 )) || { printf 'unknown\tunknown\t0\n'; return 0; }
    is_uint "$probe_cap" && (( probe_cap >= 1280 && probe_cap <= 65535 )) || probe_cap=9000
    if [[ "$family" == 6 ]]; then
        icmp_overhead=48; tcp_overhead=60; minimum=1280
    else
        icmp_overhead=28; tcp_overhead=40; minimum=576
    fi
    high="$interface_mtu"; PATH_PMTU_PROBE_CAPPED=0
    if (( high > probe_cap )); then high="$probe_cap"; PATH_PMTU_PROBE_CAPPED=1; fi
    (( high >= minimum )) || { printf '%s\tunknown\t%s\n' "$high" "$PATH_PMTU_PROBE_CAPPED"; return 0; }
    payload=$((minimum - icmp_overhead)); (( payload >= 0 )) || return 1
    if ! ping "-$family" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" -M "do" \
            -n -W 1 -c 1 -s "$payload" -- "$MEASURE_PEER_ADDRESS" >/dev/null 2>&1; then
        printf 'unknown\tunknown\t%s\n' "$PATH_PMTU_PROBE_CAPPED"
        return 0
    fi
    low="$minimum"; best="$minimum"
    while (( low <= high )); do
        mid=$(((low + high) / 2)); payload=$((mid - icmp_overhead))
        if ping "-$family" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" -M "do" \
                -n -W 1 -c 1 -s "$payload" -- "$MEASURE_PEER_ADDRESS" >/dev/null 2>&1; then
            best="$mid"; low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done
    # PMTU probing uses ICMP payload size, but the reported MSS is a TCP
    # quantity: PMTU minus IP and TCP headers (40 bytes for IPv4, 60 for IPv6).
    printf '%s\t%s\t%s\n' "$best" "$((best-tcp_overhead))" "$PATH_PMTU_PROBE_CAPPED"
}

path_latency_class() {
    local median="$1"
    if ! is_decimal "$median"; then printf 'unknown\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=10)}'; then printf 'local\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=40)}'; then printf 'near\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=100)}'; then printf 'regional\n'
    elif awk -v v="$median" 'BEGIN {exit !(v<=200)}'; then printf 'long-haul\n'
    else printf 'extreme\n'; fi
}

path_profile_classify() {
    local score=100 decision=trusted stability=stable grade risk minimum_mtu jitter_limit variable_limit
    local -a risks=()
    if [[ "$MEASURE_PEER_FAMILY" == 6 ]]; then minimum_mtu=1280; else minimum_mtu=576; fi
    PATH_LATENCY_CLASS=$(path_latency_class "$PATH_RTT_MEDIAN_MS")
    if (( PATH_PING_RECEIVED == 0 )); then
        stability=unknown; decision=limited; score=$((score - 30)); risks+=(icmp-unavailable)
    else
        if awk -v l="$PATH_LOSS_PERCENT" 'BEGIN {exit !(l>=20)}'; then
            stability=unstable; decision=unsafe; score=$((score - 55)); risks+=(icmp-loss-high)
        elif awk -v l="$PATH_LOSS_PERCENT" 'BEGIN {exit !(l>0)}'; then
            stability=variable; score=$((score - 20)); risks+=(icmp-loss)
        fi
        if is_decimal "$PATH_RTT_JITTER_P95_MS" && is_decimal "$PATH_RTT_MEDIAN_MS"; then
            jitter_limit=$(awk -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {v=m*0.35; if(v<15)v=15; printf "%.2f",v}')
            variable_limit=$(awk -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {v=m*0.15; if(v<3)v=3; printf "%.2f",v}')
            if awk -v j="$PATH_RTT_JITTER_P95_MS" -v m="$jitter_limit" 'BEGIN {exit !(j>m)}'; then
                stability=unstable; decision=unsafe; score=$((score - 35)); risks+=(jitter-high)
            elif awk -v j="$PATH_RTT_JITTER_P95_MS" -v m="$variable_limit" 'BEGIN {exit !(j>m)}'; then
                [[ "$stability" == stable ]] && stability=variable
                score=$((score - 15)); risks+=(jitter-variable)
            fi
        fi
    fi
    if ! is_uint "$PATH_PMTU"; then
        score=$((score - 5)); risks+=(pmtu-unavailable)
    elif (( PATH_PMTU < minimum_mtu )); then
        decision=unsafe; score=$((score - 50)); risks+=(pmtu-below-family-minimum)
    elif is_uint "$PATH_INTERFACE_MTU" && (( PATH_PMTU < PATH_INTERFACE_MTU )) && (( PATH_PMTU_PROBE_CAPPED == 0 )); then
        score=$((score - 10)); risks+=(reduced-pmtu)
    fi
    case "$PATH_LATENCY_CLASS" in extreme) risks+=(extreme-rtt) ;; long-haul) risks+=(long-haul) ;; esac
    (( score < 0 )) && score=0
    if (( score >= 90 )); then grade=high
    elif (( score >= 65 )); then grade=medium
    else grade=low; fi
    if [[ "$decision" == trusted && "$grade" == low ]]; then decision=limited; fi
    PATH_STABILITY="$stability"; PATH_PROFILE_SCORE="$score"; PATH_PROFILE_GRADE="$grade"; PATH_DECISION="$decision"
    if ((${#risks[@]})); then local IFS=,; risk="${risks[*]}"; else risk=clean; fi
    PATH_RISK_FLAGS="$risk"
}

path_profile_capture() {
    local samples="${1:-7}" pmtu_enabled="${2:-1}" output_file values_file received pmtu_state gateway_output
    is_uint "$samples" && (( samples >= 3 && samples <= 20 )) || { die "路径画像样本数必须是 3–20"; return 1; }
    [[ "$pmtu_enabled" == 0 || "$pmtu_enabled" == 1 ]] || return 1
    [[ -n "$MEASURE_PEER_ADDRESS" && -n "$MEASURE_PEER_SOURCE" && -n "$MEASURE_PEER_IFACE" ]] || {
        die "路径画像需要已冻结的测速端点"
        return 1
    }
    path_verify_route_identity || return 1
    path_profile_reset_metrics
    PATH_CAPTURED_AT=$(utc_now)
    PATH_PING_SENT="$samples"
    output_file=$(mktemp) || return 1
    values_file=$(mktemp) || { rm -f -- "$output_file"; return 1; }
    path_ping_command "$MEASURE_PEER_ADDRESS" "$samples" > "$output_file" 2>/dev/null || true
    path_ping_values < "$output_file" > "$values_file"
    received=$(awk 'END {print NR+0}' "$values_file"); PATH_PING_RECEIVED="$received"
    PATH_LOSS_PERCENT=$(awk -v s="$samples" -v r="$received" 'BEGIN {printf "%.2f",(s-r)*100/s}')
    if (( received > 0 )); then
        PATH_RTT_MIN_MS=$(sort -n "$values_file" | sed -n '1p')
        PATH_RTT_MEDIAN_MS=$(median_numbers < "$values_file")
        PATH_RTT_P95_MS=$(path_percentile_95 < "$values_file")
        PATH_RTT_MAX_MS=$(sort -n "$values_file" | tail -n1)
        PATH_RTT_JITTER_P95_MS=$(awk -v p="$PATH_RTT_P95_MS" -v m="$PATH_RTT_MEDIAN_MS" 'BEGIN {d=p-m; if(d<0)d=0; printf "%.2f",d}')
    fi
    if [[ "$PATH_GATEWAY" != none ]]; then
        gateway_output=$(path_ping_command "$PATH_GATEWAY" 3 2>/dev/null || true)
        PATH_GATEWAY_RTT_MS=$(path_ping_values <<< "$gateway_output" | median_numbers)
        [[ -n "$PATH_GATEWAY_RTT_MS" ]] || PATH_GATEWAY_RTT_MS=na
    fi
    pmtu_state=$(path_probe_pmtu "$pmtu_enabled") || { rm -f -- "$output_file" "$values_file"; return 1; }
    IFS=$'\t' read -r PATH_PMTU PATH_MSS PATH_PMTU_PROBE_CAPPED <<< "$pmtu_state"
    path_verify_route_identity || { rm -f -- "$output_file" "$values_file"; return 1; }
    path_profile_classify
    if [[ -n "${MEASURE_RUN_DIR:-}" && -d "$MEASURE_RUN_DIR" ]]; then
        {
            printf 'SAMPLE\tRTT_MS\n'
            awk '{print NR "\t" $1}' "$values_file"
        } > "$MEASURE_RUN_DIR/path-rtt.tsv"
        chmod 0600 "$MEASURE_RUN_DIR/path-rtt.tsv" 2>/dev/null || true
    fi
    rm -f -- "$output_file" "$values_file"
}

path_profile_tuning_gate() {
    local force="${1:-0}"
    [[ "$force" == 0 || "$force" == 1 ]] || return 1
    case "$PATH_DECISION" in
        trusted) return 0 ;;
        limited)
            log WARN "路径画像不完整或置信度有限（${PATH_RISK_FLAGS}）；测量可以继续，但结论会降级"
            return 0
            ;;
        unsafe)
            if (( force )); then
                log WARN "路径画像不稳定（${PATH_RISK_FLAGS}）；已按 --force-scan 继续，仅供人工判断"
                return 0
            fi
            die "路径画像不稳定（${PATH_RISK_FLAGS}）；拒绝自动生成或持久化整形建议"
            return 2
            ;;
        *) die "路径画像决策状态非法: ${PATH_DECISION:-missing}"; return 1 ;;
    esac
}

path_safe_summary_value() {
    local value="$1"
    value=${value//$'\t'/ }; value=${value//$'\n'/ }; value=${value//$'\r'/ }
    printf '%s' "$value"
}

path_profile_append_summary() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    printf 'PATH_PROFILE_SCHEMA\t%s\nPATH_CAPTURED_AT\t%s\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_GATEWAY\t%s\nPATH_TABLE\t%s\nPATH_INTERFACE_MTU\t%s\nPATH_ROUTE_MTU\t%s\nPATH_PMTU\t%s\nPATH_MSS\t%s\nPATH_PMTU_PROBE_CAPPED\t%s\nPATH_PING_SENT\t%s\nPATH_PING_RECEIVED\t%s\nPATH_LOSS_PERCENT\t%s\nPATH_RTT_MIN_MS\t%s\nPATH_RTT_MEDIAN_MS\t%s\nPATH_RTT_P95_MS\t%s\nPATH_RTT_MAX_MS\t%s\nPATH_RTT_JITTER_P95_MS\t%s\nPATH_GATEWAY_RTT_MS\t%s\nPATH_LATENCY_CLASS\t%s\nPATH_STABILITY\t%s\nPATH_PROFILE_SCORE\t%s\nPATH_PROFILE_GRADE\t%s\nPATH_DECISION\t%s\nPATH_RISK_FLAGS\t%s\n' \
        "$PATH_PROFILE_SCHEMA" "$PATH_CAPTURED_AT" "$PATH_ROUTE_FINGERPRINT" "$PATH_ENDPOINT_FINGERPRINT" \
        "$(path_safe_summary_value "$PATH_GATEWAY")" "$(path_safe_summary_value "$PATH_TABLE")" \
        "$PATH_INTERFACE_MTU" "$PATH_ROUTE_MTU" "$PATH_PMTU" "$PATH_MSS" "$PATH_PMTU_PROBE_CAPPED" \
        "$PATH_PING_SENT" "$PATH_PING_RECEIVED" "$PATH_LOSS_PERCENT" "$PATH_RTT_MIN_MS" "$PATH_RTT_MEDIAN_MS" \
        "$PATH_RTT_P95_MS" "$PATH_RTT_MAX_MS" "$PATH_RTT_JITTER_P95_MS" "$PATH_GATEWAY_RTT_MS" \
        "$PATH_LATENCY_CLASS" "$PATH_STABILITY" "$PATH_PROFILE_SCORE" "$PATH_PROFILE_GRADE" "$PATH_DECISION" \
        "$(path_safe_summary_value "$PATH_RISK_FLAGS")" >> "$file"
}

path_profile_report() {
    printf '%-22s %s\n' 'Target' "$MEASURE_PEER_HOST -> $MEASURE_PEER_ADDRESS"
    printf '%-22s %s\n' 'Route' "IPv${MEASURE_PEER_FAMILY} / src $MEASURE_PEER_SOURCE / dev $MEASURE_PEER_IFACE"
    printf '%-22s %s\n' 'Gateway / table' "$PATH_GATEWAY / $PATH_TABLE"
    printf '%-22s %s\n' 'Route fingerprint' "$PATH_ROUTE_FINGERPRINT"
    printf '%-22s %s\n' 'RTT distribution' "min $PATH_RTT_MIN_MS / median $PATH_RTT_MEDIAN_MS / p95 $PATH_RTT_P95_MS / max $PATH_RTT_MAX_MS ms"
    printf '%-22s %s\n' 'Jitter / ICMP loss' "$PATH_RTT_JITTER_P95_MS ms / $PATH_LOSS_PERCENT% ($PATH_PING_RECEIVED/$PATH_PING_SENT)"
    printf '%-22s %s\n' 'Gateway RTT' "$PATH_GATEWAY_RTT_MS ms"
    printf '%-22s %s\n' 'MTU / PMTU / MSS' "$PATH_INTERFACE_MTU / $PATH_PMTU / $PATH_MSS"
    printf '%-22s %s\n' 'Path class' "$PATH_LATENCY_CLASS / $PATH_STABILITY"
    printf '%-22s %s\n' 'Path confidence' "$PATH_PROFILE_GRADE ($PATH_PROFILE_SCORE/100)"
    printf '%-22s %s\n' 'Tuning decision' "$PATH_DECISION ($PATH_RISK_FLAGS)"
}

path_summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

latest_path_summary() {
    local file
    [[ -d "$HISTORY_DIR" && ! -L "$HISTORY_DIR" ]] || return 1
    while IFS= read -r file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        [[ "$(path_summary_value "$file" PATH_PROFILE_SCHEMA)" == "$PATH_PROFILE_SCHEMA" ]] || continue
        printf '%s\n' "$file"
        return 0
    done < <(find "$HISTORY_DIR" -mindepth 2 -maxdepth 2 -type f -name summary.tsv -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    return 1
}

latest_path_brief() {
    local file peer iface family latency stability pmtu score
    file=$(latest_path_summary 2>/dev/null) || { printf 'none\n'; return 0; }
    peer=$(path_summary_value "$file" PEER); iface=$(path_summary_value "$file" LOCKED_INTERFACE)
    family=$(path_summary_value "$file" LOCKED_FAMILY); latency=$(path_summary_value "$file" PATH_LATENCY_CLASS)
    stability=$(path_summary_value "$file" PATH_STABILITY); pmtu=$(path_summary_value "$file" PATH_PMTU)
    score=$(path_summary_value "$file" PATH_PROFILE_SCORE)
    printf '%s / %s / IPv%s / %s / %s / PMTU %s / %s/100\n' \
        "${peer:-unknown}" "${iface:-unknown}" "${family:-?}" "${latency:-unknown}" "${stability:-unknown}" "${pmtu:-unknown}" "${score:-0}"
}

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

# procfs represents the TCP buffer triplets as whitespace-separated values.
# Depending on the kernel/procps combination, `sysctl -n` may preserve the
# procfs TABs or print spaces.  Snapshot files use TAB as the key/value
# delimiter, so normalize every value before writing it and again before
# replay.  This keeps the on-disk format unambiguous without weakening the
# restore whitelist.
tcp_sysctl_snapshot_value_normalize() {
    local key="$1" value="$2" first="" second="" third="" extra=""
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    case "$key" in
        net.core.default_qdisc|net.ipv4.tcp_congestion_control)
            [[ "$value" =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
            printf '%s\n' "$value"
            ;;
        net.ipv4.tcp_rmem|net.ipv4.tcp_wmem)
            IFS=$' \t' read -r first second third extra <<< "$value"
            is_uint "$first" && is_uint "$second" && is_uint "$third" && [[ -z "$extra" ]] || return 1
            printf '%s %s %s\n' "$first" "$second" "$third"
            ;;
        net.core.rmem_max|net.core.wmem_max|net.ipv4.tcp_mtu_probing|net.ipv4.tcp_fastopen|\
        net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|net.core.netdev_max_backlog)
            is_uint "$value" || return 1
            printf '%s\n' "$value"
            ;;
        *) return 1 ;;
    esac
}

restore_tcp_sysctl_snapshot_file() {
    local file="$1" line key raw_value value rc=0
    tcp_baseline_regular_file "$file" || return 1
    if ! tcp_baseline_sysctl_validate "$file"; then
        log WARN "拒绝恢复不完整或非法的 sysctl 快照: $file"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != *$'\t'* ]]; then
            log WARN "无法恢复格式非法的 sysctl 快照行"
            rc=1
            continue
        fi
        key="${line%%$'\t'*}"
        raw_value="${line#*$'\t'}"
        if ! value=$(tcp_sysctl_snapshot_value_normalize "$key" "$raw_value"); then
            log WARN "无法恢复非法 sysctl 快照值: ${key:-empty}"
            rc=1
            continue
        fi
        if ! sysctl -q -w "$key=$value"; then
            log WARN "无法恢复 sysctl: $key"
            rc=1
        fi
    done < "$file"
    return "$rc"
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
    local file="$1" line key value
    local -A allowed=() seen=()
    tcp_baseline_regular_file "$file" || { tcp_baseline_invalid "sysctl 快照缺失或类型非法"; return 1; }
    [[ -s "$file" ]] || { tcp_baseline_invalid "sysctl 快照为空"; return 1; }
    while IFS= read -r key; do allowed[$key]=1; done < <(tcp_baseline_sysctl_keys)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != *$'\t'* ]]; then
            tcp_baseline_invalid "sysctl 快照含非法字段行"
            return 1
        fi
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -n "$key" && -n "$value" ]] || { tcp_baseline_invalid "sysctl 快照含空字段"; return 1; }
        tcp_sysctl_snapshot_value_normalize "$key" "$value" >/dev/null || {
            tcp_baseline_invalid "sysctl key 或值非法: $key"
            return 1
        }
        [[ -n "${allowed[$key]+x}" ]] || { tcp_baseline_invalid "sysctl key 不在恢复白名单: ${key:-empty}"; return 1; }
        [[ -z "${seen[$key]+x}" ]] || { tcp_baseline_invalid "sysctl key 重复: $key"; return 1; }
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
    local key raw_value value
    for key in \
        net.core.default_qdisc net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog; do
        raw_value=$(sysctl -n "$key" 2>/dev/null) || {
            log WARN "无法读取受管 sysctl，拒绝创建不完整快照: $key"
            return 1
        }
        if ! value=$(tcp_sysctl_snapshot_value_normalize "$key" "$raw_value"); then
            log WARN "受管 sysctl 返回不可安全序列化的值: $key"
            return 1
        fi
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
    tcp_baseline_regular_file "$BASELINE_DIR/sysctl.tsv" || return 1
    restore_tcp_sysctl_snapshot_file "$BASELINE_DIR/sysctl.tsv"
}

baseline_info() {
    if [[ -f "$BASELINE_DIR/manifest" ]]; then cat "$BASELINE_DIR/manifest"; else printf 'No baseline recorded.\n'; fi
}

baseline_provenance() {
    awk -F'\t' '$1=="PROVENANCE" {print $2; exit}' "$BASELINE_DIR/manifest" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Sysctl: auditable balanced/adaptive profiles, BBR verification and route IW.
# -----------------------------------------------------------------------------

BALANCED_BUFFER_MAX=16777216
BUFFER_ABSOLUTE_CAP=2147483647

hardware_tuning_values() {
    local role="$1" bandwidth="$2" requested="${3:-${TC_INTERFACE:-auto}}"
    local desired_floor memory_cap platform_cap backlog_limit
    hardware_profile_values "$requested" "$bandwidth" || return 1

    # Keep the per-socket ceiling proportional to available RAM. Low-memory
    # VPSes no longer inherit a forced 16 MiB floor, while large-memory systems
    # can reach the signed sysctl ceiling (about 2 GiB) when BDP actually needs it.
    if (( HARDWARE_MEMORY_MB < 512 )); then desired_floor=4194304; platform_cap=8388608
    elif (( HARDWARE_MEMORY_MB < 1024 )); then desired_floor=8388608; platform_cap=16777216
    elif (( HARDWARE_MEMORY_MB < 2048 )); then desired_floor=16777216; platform_cap=33554432
    elif (( HARDWARE_MEMORY_MB < 4096 )); then desired_floor=16777216; platform_cap=67108864
    elif (( HARDWARE_MEMORY_MB < 8192 )); then desired_floor=16777216; platform_cap=134217728
    elif (( HARDWARE_MEMORY_MB < 12288 )); then desired_floor=16777216; platform_cap=268435456
    elif (( HARDWARE_MEMORY_MB < 24576 )); then desired_floor=16777216; platform_cap=536870912
    elif (( HARDWARE_MEMORY_MB < 49152 )); then desired_floor=16777216; platform_cap=1073741824
    else desired_floor=16777216; platform_cap=$BUFFER_ABSOLUTE_CAP
    fi
    memory_cap=$((HARDWARE_MEMORY_MB * 1024 * 1024 / 32))
    (( memory_cap < 1048576 )) && memory_cap=1048576
    (( platform_cap > BUFFER_ABSOLUTE_CAP )) && platform_cap=$BUFFER_ABSOLUTE_CAP
    BUFFER_CAP="$memory_cap"; (( BUFFER_CAP > platform_cap )) && BUFFER_CAP="$platform_cap"
    BUFFER_FLOOR="$desired_floor"; (( BUFFER_FLOOR > BUFFER_CAP )) && BUFFER_FLOOR="$BUFFER_CAP"
    BUFFER_MEMORY_CAP="$memory_cap"
    BUFFER_PLATFORM_CAP="$platform_cap"

    SOMAXCONN=4096
    if [[ "$role" == proxy ]] && (( HARDWARE_CPU_COUNT >= 4 && HARDWARE_MEMORY_MB >= 2048 )); then SOMAXCONN=8192; fi
    if [[ "$role" == proxy ]] && (( HARDWARE_CPU_COUNT >= 16 && HARDWARE_MEMORY_MB >= 8192 )); then SOMAXCONN=16384; fi
    if [[ "$role" == mixed ]] && (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 && HARDWARE_CPU_COUNT >= 8 )); then SOMAXCONN=8192; fi
    TCP_MAX_SYN_BACKLOG="$SOMAXCONN"

    if (( EFFECTIVE_BANDWIDTH_MBIT <= 1000 )); then NETDEV_BACKLOG=4096
    elif (( EFFECTIVE_BANDWIDTH_MBIT <= 10000 )); then NETDEV_BACKLOG=8192
    elif (( EFFECTIVE_BANDWIDTH_MBIT <= 40000 )); then NETDEV_BACKLOG=16384
    else NETDEV_BACKLOG=32768
    fi
    if (( HARDWARE_CPU_COUNT <= 1 || HARDWARE_MEMORY_MB < 1024 )); then backlog_limit=4096
    elif (( HARDWARE_CPU_COUNT <= 2 || HARDWARE_MEMORY_MB < 2048 )); then backlog_limit=8192
    elif (( HARDWARE_CPU_COUNT <= 4 )); then backlog_limit=16384
    else backlog_limit=32768
    fi
    (( NETDEV_BACKLOG > backlog_limit )) && NETDEV_BACKLOG="$backlog_limit"
    return 0
}

role_tuning_rtt_floor() {
    case "$1" in
        proxy) printf '150\n' ;;
        mixed|bulk) printf '100\n' ;;
        *) die "未知业务用途: $1"; return 1 ;;
    esac
}

recommended_tuning_rtt() {
    local role="$1" observed="${2:-0}" floor
    is_uint "$observed" && (( observed <= 60000 )) || { die "观测 RTT 无效: $observed"; return 1; }
    floor=$(role_tuning_rtt_floor "$role") || return 1
    if (( observed > floor )); then printf '%s\n' "$observed"; else printf '%s\n' "$floor"; fi
}

ensure_bbr_available() {
    local available current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ "$current" == bbr* && "$current" != bbr ]]; then
        die "检测到当前拥塞控制为第三方 BBR 变体 '$current'；为避免静默替换或与其 sysctl 冲突，已中止。请先人工切换到 cubic/标准 bbr 并确认迁移意图"
        return 1
    fi
    modprobe tcp_bbr 2>/dev/null || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<< "$available"; then
        die "当前内核不提供 BBR；不会静默回退到 cubic"
        return 1
    fi
}

bbr_compatibility_status() {
    local current="${1:-}" available="${2:-}"
    [[ -n "$current" ]] || current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    [[ -n "$available" ]] || available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ "$current" == bbr* && "$current" != bbr ]]; then
        printf 'conflict: third-party variant %s would be replaced\n' "$current"
    elif [[ "$current" == bbr ]]; then
        printf 'compatible: standard bbr runtime API\n'
    elif grep -qw bbr <<< "$available"; then
        printf 'ready: standard bbr is available\n'
    else
        printf 'unavailable\n'
    fi
}

bbr_kernel_support_status() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$available"; then
        printf 'available (built-in or loaded)\n'
    elif modinfo tcp_bbr >/dev/null 2>&1; then
        printf 'module present, not loaded\n'
    else
        printf 'unavailable\n'
    fi
}

buffer_profile_values() {
    local profile="$1" role="$2" bandwidth="$3" rtt="$4" requested="${5:-${TC_INTERFACE:-auto}}"
    local bdp max default_r=131072 default_w=65536
    hardware_tuning_values "$role" "$bandwidth" "$requested" || return 1
    if [[ "$profile" == balanced ]]; then
        BUFFER_MAX="$BALANCED_BUFFER_MAX"; (( BUFFER_MAX > BUFFER_CAP )) && BUFFER_MAX="$BUFFER_CAP"
        BUFFER_R_DEFAULT=$default_r
        BUFFER_W_DEFAULT=$default_w
        (( BUFFER_R_DEFAULT > BUFFER_MAX )) && BUFFER_R_DEFAULT="$BUFFER_MAX"
        (( BUFFER_W_DEFAULT > BUFFER_MAX )) && BUFFER_W_DEFAULT="$BUFFER_MAX"
        BUFFER_REASON="balanced ceiling, hardware-bounded by RAM/32"
        return 0
    fi
    (( bandwidth > 0 && rtt > 0 )) || { die "adaptive profile 需要 --bandwidth 和 --rtt"; return 1; }
    # bytes = Mbps * ms * 125; keep two BDPs and apply the hardware budget.
    bdp=$(( bandwidth * rtt * 125 ))
    max=$(( bdp * 2 ))
    (( max < BUFFER_FLOOR )) && max=$BUFFER_FLOOR
    (( max > BUFFER_CAP )) && max=$BUFFER_CAP
    case "$role" in
        proxy) default_r=131072; default_w=65536 ;;
        mixed) default_r=262144; default_w=131072 ;;
        bulk)
            default_r=1048576; default_w=1048576
            (( EFFECTIVE_BANDWIDTH_MBIT >= 10000 )) && default_r=2097152 && default_w=2097152
            ;;
    esac
    (( default_r > max )) && default_r=$max
    (( default_w > max )) && default_w=$max
    BUFFER_MAX=$max
    BUFFER_R_DEFAULT=$default_r
    BUFFER_W_DEFAULT=$default_w
    BUFFER_REASON="2xBDP with hardware floor, bounded by RAM/32 and platform cap"
}

sysctl_model_interface() {
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then printf '%s\n' "${NIC_MODEL_INTERFACE:-auto}"
    else printf '%s\n' "${TC_INTERFACE:-auto}"
    fi
}

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(sysctl_model_interface)" || return 1
    cat <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# profile=${SYSCTL_PROFILE} role=${ROLE} bandwidth=${BANDWIDTH_MBIT}Mbps tuning_rtt=${RTT_MS}ms
# buffer_max=${BUFFER_MAX} (${BUFFER_REASON})
# hardware=${HARDWARE_CLASS} cpu=${HARDWARE_CPU_COUNT} ram=${HARDWARE_MEMORY_MB}MiB link=${HARDWARE_LINK_MBIT}Mbit(${HARDWARE_LINK_TRUST}) queues=${HARDWARE_RX_QUEUES}/${HARDWARE_TX_QUEUES}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUFFER_MAX}
net.core.wmem_max = ${BUFFER_MAX}
net.ipv4.tcp_rmem = 4096 ${BUFFER_R_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 ${BUFFER_W_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
EOF
}

explain_sysctl_profile() {
    render_sysctl_profile
    printf '\n# Hardware model: class=%s, effective_bandwidth=%sMbit (%s), buffer_floor=%s, buffer_cap=%s.\n' \
        "$HARDWARE_CLASS" "$EFFECTIVE_BANDWIDTH_MBIT" "$EFFECTIVE_BANDWIDTH_SOURCE" "$(human_bytes "$BUFFER_FLOOR")" "$(human_bytes "$BUFFER_CAP")"
    printf '# Buffer bounds: memory_cap=%s, platform_cap=%s.\n' "$(human_bytes "$BUFFER_MEMORY_CAP")" "$(human_bytes "$BUFFER_PLATFORM_CAP")"
    printf '# Scaling note: %s.\n' "$(hardware_scaling_note)"
    printf '# Deliberately untouched: tcp_mem, tcp_adv_win_scale, TIME_WAIT, VM, file limits, IRQ affinity, NIC offloads and RPS/RFS.\n'
}

normalize_sysctl_words() { awk '{$1=$1; print}'; }

verify_sysctl_profile_runtime() {
    local key expected actual rc=0
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "$(sysctl_model_interface)" || return 1
    while IFS=$'\t' read -r key expected; do
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_sysctl_words || true)
        expected=$(normalize_sysctl_words <<< "$expected")
        if [[ "$actual" != "$expected" ]]; then
            log ERR "sysctl 不一致: $key=${actual:-unavailable}（期望 $expected）"
            rc=1
        fi
    done < <(printf '%s\t%s\n' \
        net.core.default_qdisc fq \
        net.ipv4.tcp_congestion_control bbr \
        net.core.rmem_max "$BUFFER_MAX" \
        net.core.wmem_max "$BUFFER_MAX" \
        net.ipv4.tcp_rmem "4096 $BUFFER_R_DEFAULT $BUFFER_MAX" \
        net.ipv4.tcp_wmem "4096 $BUFFER_W_DEFAULT $BUFFER_MAX" \
        net.ipv4.tcp_mtu_probing 1 \
        net.ipv4.tcp_fastopen 3 \
        net.core.somaxconn "$SOMAXCONN" \
        net.ipv4.tcp_max_syn_backlog "$TCP_MAX_SYN_BACKLOG" \
        net.core.netdev_max_backlog "$NETDEV_BACKLOG")
    return "$rc"
}

normalize_sysctl_profile_for_compare() {
    # The hardware line is diagnostic telemetry, not an applied setting. Link
    # speed, queue counts and driver visibility can change transiently (for
    # example while a virtual NIC is being reconfigured) without changing any
    # managed sysctl value. Keep the line mandatory, but normalize its payload
    # so semantic persistence verification does not produce a false drift.
    awk '/^# hardware=/ { print "# hardware=<runtime-observation>"; next } { print }'
}

verify_sysctl_profile_file() {
    local expected observed
    [[ -f "$SYSCTL_FILE" ]] || { log ERR "sysctl 持久化文件缺失: $SYSCTL_FILE"; return 1; }
    command_exists cmp || { die "缺少命令: cmp"; return 1; }
    expected=$(mktemp) || return 1
    observed=$(mktemp) || { rm -f -- "$expected"; return 1; }
    if ! render_sysctl_profile | normalize_sysctl_profile_for_compare > "$expected"; then
        rm -f -- "$expected" "$observed"
        return 1
    fi
    if ! normalize_sysctl_profile_for_compare < "$SYSCTL_FILE" > "$observed"; then
        rm -f -- "$expected" "$observed"
        return 1
    fi
    if ! cmp -s "$expected" "$observed"; then
        rm -f -- "$expected" "$observed"
        log ERR "sysctl 持久化文件与当前配置不一致: $SYSCTL_FILE"
        return 1
    fi
    rm -f -- "$expected" "$observed"
}

write_sysctl_profile() {
    local temp
    temp=$(mktemp) || return 1
    render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
    atomic_install "$temp" "$SYSCTL_FILE" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

apply_sysctl_profile() {
    local mode="${1:-persistent}" temp=""
    [[ "$mode" == persistent || "$mode" == runtime ]] || { die "sysctl 应用模式只支持 persistent/runtime"; return 1; }
    require_commands sysctl modprobe || return 1
    ensure_bbr_available || return 1
    if [[ "$mode" == runtime ]]; then
        temp=$(mktemp) || return 1
        render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
        sysctl -q -p "$temp" || { rm -f -- "$temp"; die "sysctl 应用失败"; return 1; }
        rm -f -- "$temp"
    else
        write_sysctl_profile || return 1
        sysctl -q -p "$SYSCTL_FILE" || { die "sysctl 应用失败"; return 1; }
    fi
    verify_sysctl_profile_runtime || { die "受管 sysctl 运行时验证失败"; return 1; }
    if [[ "$mode" == runtime ]]; then
        log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效（临时）"
    else
        log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效"
    fi
}

apply_initial_windows() {
    (( INITCWND > 0 || INITRWND > 0 )) || return 0
    local family line token i changed=0
    local -a args=() clean=()
    for family in -4 -6; do
        line=$(ip "$family" route show default 2>/dev/null | sed -n '1p' || true)
        [[ -n "$line" ]] || continue
        read -r -a args <<< "$line"
        clean=()
        for ((i=0; i<${#args[@]}; i++)); do
            token="${args[$i]}"
            if [[ "$token" == initcwnd || "$token" == initrwnd ]]; then ((i+=1)); continue; fi
            clean+=("$token")
        done
        (( INITCWND > 0 )) && clean+=(initcwnd "$INITCWND")
        (( INITRWND > 0 )) && clean+=(initrwnd "$INITRWND")
        if ip "$family" route change "${clean[@]}"; then ((changed+=1)); fi
    done
    (( changed > 0 )) || { die "没有可设置 initcwnd/initrwnd 的默认路由"; return 1; }
}

restore_default_route_windows_snapshot() {
    local directory="$1" family file baseline current token i rc=0
    local -a route=() clean=()
    for family in -4 -6; do
        file="$directory/default-route-v${family#-}.txt"
        [[ -s "$file" ]] || continue
        baseline=$(head -n1 "$file")
        current=$(ip "$family" route show default 2>/dev/null | sed -n '1p' || true)
        [[ "$baseline$current" == *initcwnd* || "$baseline$current" == *initrwnd* ]] || continue
        [[ -n "$current" ]] || { rc=1; continue; }
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

# -----------------------------------------------------------------------------
# Traffic control: HTB aggregate shaper + FQ leaf, full verification and rollback.
# -----------------------------------------------------------------------------

TC_SESSION_HTB_IFACE=""
TC_TRIAL_IFACE=""
TC_TRIAL_SNAPSHOT=""
# Enough for 1 Tbit/s even at CONFIG_HZ=100. The actual value remains rate/HZ,
# so ordinary VPS rates do not inherit a large bucket merely because the cap
# supports modern 25/100/400G NICs.
HTB_BURST_CAP=2147483647

tc_dependencies() { require_commands ip tc awk; }

qdisc_module_hint() {
    local kind="$1" module="sch_$1"
    command_exists modprobe || return 0
    modprobe -q "$module" 2>/dev/null || true
    # A qdisc can be built into the kernel and therefore have no module entry.
    # The real replace operation below remains the authoritative capability
    # check and is always followed by structural verification.
    return 0
}

network_tuning_preflight() {
    local iface="$1" need_shaping="${2:-0}" key
    tc_dependencies || return 1
    [[ -e "${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}/$iface" ]] || { die "网卡不存在: $iface"; return 1; }
    tc qdisc show dev "$iface" >/dev/null 2>&1 || { die "无法读取 $iface 的 qdisc；缺少 NET_ADMIN 或驱动不支持"; return 1; }
    for key in default_qdisc rmem_max wmem_max somaxconn netdev_max_backlog; do
        [[ -e "/proc/sys/net/core/$key" ]] || { die "内核缺少受管 sysctl: net.core.$key"; return 1; }
    done
    [[ -e /proc/sys/net/ipv4/tcp_congestion_control ]] || { die "内核缺少 TCP 拥塞控制 sysctl"; return 1; }
    [[ -e /proc/sys/net/ipv4/tcp_max_syn_backlog ]] || { die "内核缺少 TCP SYN backlog sysctl"; return 1; }
    qdisc_module_hint fq
    (( need_shaping == 0 )) || qdisc_module_hint htb
    hardware_profile_values "$iface" "${BANDWIDTH_MBIT:-0}" || return 1
    log INFO "硬件预检: ${HARDWARE_CLASS}, ${HARDWARE_CPU_COUNT} CPU, ${HARDWARE_MEMORY_MB} MiB RAM, ${HARDWARE_RX_QUEUES}/${HARDWARE_TX_QUEUES} RX/TX queues, link ${HARDWARE_LINK_MBIT} Mbit"
    log INFO "硬件建议: $(hardware_scaling_note)"
}

root_qdisc_kind() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    awk '$1=="qdisc" && $0 ~ / root([[:space:]]|$)/ {print $2; exit}' <<< "$text"
}

qdisc_replay_args_from_stream() {
    awk '
        $1=="qdisc" && $0~/ root([[:space:]]|$)/ {
            seen=0; bands=3;
            for(i=1;i<=NF;i++) {
                if(seen) {
                    if($i=="refcnt") {i++; continue}
                    if($i=="bands") {bands=$(i+1); i++; continue}
                    if($i=="priomap") {i+=16; continue}
                    if($i=="weights") {i+=bands; continue}
                    token=$i; if(token ~ /^[0-9]+p$/) sub(/p$/, "", token)
                    printf "%s%s", (out?" ":""), token; out=1
                }
                if($i=="root") seen=1
            }
            print ""; exit
        }'
}

root_qdisc_replay_args() {
    tc qdisc show dev "$1" 2>/dev/null | qdisc_replay_args_from_stream
}

mq_child_replay_rows_from_stream() {
    awk '
        $1=="qdisc" && $0!~/ root([[:space:]]|$)/ {
            parent=""; start=0; bands=3
            for(i=1;i<=NF;i++) if($i=="parent" && $(i+1) ~ /^:[[:xdigit:]]+$/) {
                parent=$(i+1); start=i+2; break
            }
            if(parent=="") next
            kind=$2; out=""
            for(i=start;i<=NF;i++) {
                if($i=="refcnt") {i++; continue}
                if($i=="bands") {bands=$(i+1); i++; continue}
                if($i=="priomap") {i+=16; continue}
                if($i=="weights") {i+=bands; continue}
                token=$i; if(token ~ /^[0-9]+p$/) sub(/p$/, "", token)
                out=out (out?" ":"") token
            }
            printf "%s\t%s\t%s\n", parent, kind, out
        }'
}

mq_unsupported_child_qdiscs() {
    local iface="$1"
    tc qdisc show dev "$iface" 2>/dev/null | mq_child_replay_rows_from_stream |
        awk -F'\t' '$2!="fq" && $2!="fq_codel" && $2!="pfifo_fast" && $2!="pfifo" && $2!="bfifo" && $2!="noqueue" {print $2 "@" $1}'
}

restore_mq_qdisc_snapshot() {
    local iface="$1" file="$2" parent kind args_string
    local -a args=()
    tc qdisc replace dev "$iface" root mq >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r parent kind args_string; do
        [[ -n "$parent" && -n "$kind" ]] || continue
        case "$kind" in
            fq|fq_codel|pfifo_fast|pfifo|bfifo)
                args=(); [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
                tc qdisc replace dev "$iface" parent "$parent" "$kind" "${args[@]}" >/dev/null 2>&1 || return 1
                ;;
            noqueue) ;;
            *) return 2 ;;
        esac
    done < <(mq_child_replay_rows_from_stream < "$file")
}

managed_htb() {
    local iface="$1" qdisc_text class_text
    qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null) || return 1
    class_text=$(tc class show dev "$iface" 2>/dev/null) || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" &&
        grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" &&
        grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text"
}

managed_htb_interfaces() {
    local net_root="${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}" path iface
    [[ -d "$net_root" ]] || return 0
    for path in "$net_root"/*; do
        [[ -e "$path" ]] || continue
        iface="${path##*/}"
        validate_interface_name "$iface" || continue
        managed_htb "$iface" && printf '%s\n' "$iface"
    done
    return 0
}

# Mutation gates must distinguish "not managed" from "could not be
# inspected". Read every visible interface once and reject the whole operation
# if any qdisc/class query is unavailable.
managed_htb_interfaces_strict() {
    local net_root="${BBRV3_SYS_CLASS_NET_ROOT:-/sys/class/net}" path iface qdisc_text class_text
    [[ -d "$net_root" && ! -L "$net_root" ]] || { die "无法枚举宿主机网卡: $net_root"; return 1; }
    for path in "$net_root"/*; do
        [[ -e "$path" || -L "$path" ]] || continue
        iface="${path##*/}"
        validate_interface_name "$iface" && [[ "$iface" != auto ]] || {
            die "网卡目录包含非法名称，不能完成全接口 qdisc 审计: $iface"
            return 1
        }
        qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null) || {
            die "无法读取 $iface 的 qdisc；不能证明不存在遗留 HTB"
            return 1
        }
        class_text=$(tc class show dev "$iface" 2>/dev/null) || {
            die "无法读取 $iface 的 class；不能证明不存在遗留 HTB"
            return 1
        }
        if grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" &&
           grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" &&
           grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text"; then
            printf '%s\n' "$iface"
        fi
    done
}

shaping_interface_list_text() {
    local interfaces="$1"
    [[ -n "$interfaces" ]] && tr '\n' ' ' <<< "$interfaces" | sed -E 's/[[:space:]]+$//' || printf 'none\n'
}

load_config_for_shaping_preflight() {
    local file="${1:-$CONFIG_FILE}" line key value lineno=0
    local -A seen=()
    # Current configurations use the full strict parser. A legacy configuration
    # still has to be inspected before capture_baseline/migrate_legacy_config,
    # but this preflight must remain read-only. Parse only the three shaping
    # fields needed to prevent a cross-NIC migration; never rewrite the file here.
    if load_config "$file" 2>/dev/null; then return 0; fi
    [[ -f "$file" ]] || return 0
    if grep -Fxq 'SCHEMA_VERSION=1' "$file" && ! grep -Fxq 'SYSCTL_PROFILE=balanced-minimal' "$file"; then
        die "当前 schema 配置未通过严格校验，拒绝把损坏配置当作旧版迁移: $file"
        return 1
    fi
    check_config_permissions "$file" || return 1
    reset_config
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno+=1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=([a-zA-Z0-9_.:-]+)$ ]]; then
            die "旧配置含非法格式，无法执行只读整形预检: ${file}:${lineno}"
            return 1
        fi
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]+x}" ]] || { die "旧配置字段重复，无法安全预检: ${file}:${lineno}: $key"; return 1; }
        seen[$key]=1
        case "$key" in
            TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT)
                validate_config_value "$key" "$value" || {
                    die "旧配置含非法整形字段: ${file}:${lineno}: $key"
                    return 1
                }
                printf -v "$key" '%s' "$value"
                ;;
            # These are known current/legacy data fields. They are deliberately
            # ignored here and will be handled by migrate_legacy_config inside
            # the surrounding action transaction.
            SCHEMA_VERSION|BBR_ENABLED|SYSCTL_PROFILE|ROLE|BANDWIDTH_MBIT|RTT_MS|TC_KNEE_MBIT|TC_MARGIN_PERCENT|INITCWND|INITRWND|MULTI_NIC_ENABLED|TC_BASELINE_MBIT|TC_PERCENT) ;;
            *)
                die "旧配置含未知字段，拒绝在迁移前猜测整形归属: ${file}:${lineno}: $key"
                return 1
                ;;
        esac
    done < "$file"
}

# The configuration schema owns one shaping interface. Refuse an implicit
# migration while another managed HTB remains active: otherwise a default-route
# change can leave an orphan shaper on the old NIC and commit a second one on the
# new NIC. Disabling is deliberately explicit so recovery remains deterministic.
shaping_target_preflight() {
    local target="$1" action="$2" requested="${3:-$1}" interfaces other configured
    validate_interface_name "$target" || { die "整形目标网卡非法: $target"; return 1; }
    [[ "$action" == enable || "$action" == trial || "$action" == install || "$action" == auto || "$action" == disable ]] || {
        die "未知整形操作: $action"
        return 1
    }
    load_config_for_shaping_preflight || return 1
    if (( ${MULTI_NIC_ENABLED:-0} == 1 )); then
        declare -F nic_policy_ownership_preflight >/dev/null || { die "多网卡策略模块未加载"; return 1; }
        nic_policy_ownership_preflight "$target" || return 1
        if [[ "$action" == disable ]] && ! nic_policy_exists "$target"; then
            die "网卡没有受管策略: $target"
            return 1
        fi
        return 0
    fi
    configured="$TC_INTERFACE"
    interfaces=$(managed_htb_interfaces_strict) || return 1

    if [[ "$action" == disable ]]; then
        if (( TC_ENABLED == 1 )) && [[ "$configured" == auto && "$requested" == auto ]]; then
            die "检测到旧版 TC_INTERFACE=auto；不能猜测应关闭哪张网卡。受管 HTB: $(shaping_interface_list_text "$interfaces")。请显式执行 ${0##*/} tc disable --interface DEV"
            return 1
        fi
        if (( TC_ENABLED == 1 )) && [[ "$configured" != auto && "$target" != "$configured" ]]; then
            die "配置中的整形绑定 $configured，拒绝改为关闭 $target；请先对 $configured 执行 tc disable"
            return 1
        fi
        if (( TC_ENABLED == 1 )) && [[ "$configured" == auto ]] && ! grep -Fqx -- "$target" <<< "$interfaces"; then
            die "旧版 auto 配置无法证明 $target 是原受管接口；当前受管 HTB: $(shaping_interface_list_text "$interfaces")"
            return 1
        fi
        if [[ -n "$interfaces" ]] && ! grep -Fqx -- "$target" <<< "$interfaces"; then
            die "发现的受管 HTB 位于 $(shaping_interface_list_text "$interfaces")，拒绝把关闭操作应用到 $target"
            return 1
        fi
        return 0
    fi

    while IFS= read -r other; do
        [[ -n "$other" ]] || continue
        if [[ "$other" != "$target" ]]; then
            die "检测到另一张网卡 $other 上仍有受管 HTB；当前版本只允许一个持久化整形接口。请先执行 ${0##*/} tc disable --interface $other"
            return 1
        fi
    done <<< "$interfaces"

    if (( TC_ENABLED == 1 )); then
        if [[ "$configured" == auto ]]; then
            die "检测到旧版 TC_INTERFACE=auto，拒绝把旧速率隐式迁移到 $target。受管 HTB: $(shaping_interface_list_text "$interfaces")；请先显式关闭旧接口整形"
            return 1
        fi
        if [[ "$configured" != "$target" ]]; then
            die "现有整形绑定 $configured，当前目标为 $target；请先执行 ${0##*/} tc disable --interface $configured"
            return 1
        fi
    fi
}

managed_htb_root() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$text"
}

managed_fq_leaf() {
    local text
    text=$(tc qdisc show dev "$1" 2>/dev/null) || return 1
    grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$text"
}

managed_rate_mbit() {
    local iface="$1" text token
    text=$(tc class show dev "$iface" 2>/dev/null) || return 1
    token=$(awk '$1=="class" && $2=="htb" && $3=="1:10" {for(i=1;i<=NF;i++) if($i=="rate") {print $(i+1); exit}}' <<< "$text")
    awk -v r="$token" 'BEGIN {
        if (r ~ /Tbit$/) {sub(/Tbit$/, "", r); printf "%.0f\n", r*1000000}
        else if (r ~ /Gbit$/) {sub(/Gbit$/, "", r); printf "%.0f\n", r*1000}
        else if (r ~ /Mbit$/) {sub(/Mbit$/, "", r); printf "%.0f\n", r}
        else if (r ~ /Kbit$/) {sub(/Kbit$/, "", r); printf "%.0f\n", r/1000}
    }'
}

session_owned_htb() {
    local iface="$1" rate
    [[ -n "$TC_SESSION_HTB_IFACE" && "$TC_SESSION_HTB_IFACE" == "$iface" ]] || return 1
    managed_htb_root "$iface" || return 1
    rate=$(managed_rate_mbit "$iface") || return 1
    is_uint "$rate" && (( rate > 0 ))
}

managed_htb_diagnostic() {
    local iface="$1" qdisc_text class_text root=no class=no leaf=no rate
    qdisc_text=$(tc qdisc show dev "$iface" 2>/dev/null || true)
    class_text=$(tc class show dev "$iface" 2>/dev/null || true)
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_text" && root=yes
    grep -Eq '^class htb 1:10 (root|parent 1:)' <<< "$class_text" && class=yes
    grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)' <<< "$qdisc_text" && leaf=yes
    rate=$(managed_rate_mbit "$iface") || rate=""
    rate="${rate:--}"
    printf 'root-1=%s class-1:10=%s fq-10=%s rate=%sMbit' "$root" "$class" "$leaf" "$rate"
}

qdisc_guard() {
    local iface="$1" kind detail unsupported
    kind=$(root_qdisc_kind "$iface") || { die "无法读取 $iface 的 root qdisc"; return 1; }
    if managed_htb "$iface" || session_owned_htb "$iface"; then return 0; fi
    case "$kind" in
        ""|fq|fq_codel|noqueue|pfifo_fast) return 0 ;;
        mq)
            unsupported=$(mq_unsupported_child_qdiscs "$iface")
            if [[ -n "$unsupported" ]]; then
                die "拒绝覆盖含不可安全重放子队列的 mq（$iface；$unsupported）"
                return 1
            fi
            return 0
            ;;
        htb)
            detail=$(managed_htb_diagnostic "$iface")
            die "拒绝覆盖未管理的 root qdisc 'htb'（$iface；$detail）"
            return 1
            ;;
        *)
            die "拒绝覆盖未管理的 root qdisc '$kind'（$iface）；请先自行恢复或删除"
            return 1
            ;;
    esac
}

action_qdisc_snapshot() {
    local iface="$1" file="$2" kind rate="" replay_args_string=""
    kind=$(root_qdisc_kind "$iface") || return 1
    if managed_htb "$iface" || session_owned_htb "$iface"; then
        kind="managed-htb"
        rate=$(managed_rate_mbit "$iface") || return 1
    fi
    [[ "$kind" == fq || "$kind" == fq_codel ]] && replay_args_string=$(root_qdisc_replay_args "$iface")
    printf 'KIND\t%s\nRATE\t%s\nARGS\t%s\n' "$kind" "$rate" "$replay_args_string" > "$file" || return 1
    tc qdisc show dev "$iface" >> "$file" 2>/dev/null || true
    tc class show dev "$iface" >> "$file" 2>/dev/null || true
}

snapshot_field() { awk -F'\t' -v key="$2" '$1==key {print $2; exit}' "$1"; }

action_qdisc_snapshot_validate() {
    local file="$1" kind rate args extra
    local -a snapshot_header=()
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mapfile -t snapshot_header < <(head -n 3 "$file") || return 1
    (( ${#snapshot_header[@]} == 3 )) || return 1
    [[ "${snapshot_header[0]}" == KIND$'\t'* && "${snapshot_header[0]#*$'\t'}" != *$'\t'* ]] || return 1
    [[ "${snapshot_header[1]}" == RATE$'\t'* && "${snapshot_header[1]#*$'\t'}" != *$'\t'* ]] || return 1
    [[ "${snapshot_header[2]}" == ARGS$'\t'* && "${snapshot_header[2]#*$'\t'}" != *$'\t'* ]] || return 1
    kind="${snapshot_header[0]#*$'\t'}"; rate="${snapshot_header[1]#*$'\t'}"; args="${snapshot_header[2]#*$'\t'}"
    case "$kind" in
        managed-htb)
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) && [[ -z "$args" ]] || return 1
            ;;
        fq|fq_codel) [[ -z "$rate" ]] || return 1 ;;
        ""|mq|noqueue|pfifo_fast) [[ -z "$rate" && -z "$args" ]] || return 1 ;;
        *) return 1 ;;
    esac
    extra=$(awk -F'\t' '$1=="KIND" || $1=="RATE" || $1=="ARGS" {count++} END {print count+0}' "$file") || return 1
    (( extra == 3 ))
}

restore_action_qdisc() {
    local iface="$1" file="$2" kind rate args_string
    local -a args=()
    action_qdisc_snapshot_validate "$file" || { die "qdisc 操作快照格式非法: $file"; return 1; }
    kind=$(snapshot_field "$file" KIND)
    rate=$(snapshot_field "$file" RATE)
    args_string=$(snapshot_field "$file" ARGS)
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        managed-htb) _apply_shaping_raw "$iface" "$rate" ;;
        fq|fq_codel)
            if tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null 2>&1 || tc qdisc replace dev "$iface" root "$kind" >/dev/null; then
                if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            else return 1
            fi
            ;;
        mq)
            restore_mq_qdisc_snapshot "$iface" "$file" || return 1
            if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            ;;
        ""|noqueue|pfifo_fast)
            tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
            if [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]]; then TC_SESSION_HTB_IFACE=""; fi
            ;;
        *) die "无法安全恢复 qdisc 类型: $kind" ;;
    esac
}

restore_qdisc_text_snapshot() {
    local iface="$1" file="$2" kind args_string
    local -a args=()
    kind=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {print $2; exit}' "$file" 2>/dev/null)
    args_string=$(qdisc_replay_args_from_stream < "$file")
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        fq|fq_codel) tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null 2>&1 || tc qdisc replace dev "$iface" root "$kind" ;;
        mq) restore_mq_qdisc_snapshot "$iface" "$file" ;;
        ""|noqueue|pfifo_fast) tc qdisc del dev "$iface" root 2>/dev/null || true ;;
        *) return 2 ;;
    esac
}

detect_kernel_hz() {
    local file value
    for file in "/boot/config-$(uname -r)" /proc/config; do
        [[ -r "$file" ]] || continue
        value=$(awk -F= '$1=="CONFIG_HZ" {print $2; exit}' "$file" 2>/dev/null || true)
        if is_uint "${value:-}" && (( value >= 100 && value <= 2000 )); then printf '%s\n' "$value"; return 0; fi
    done
    if [[ -r /proc/config.gz ]] && command_exists zcat; then
        value=$(zcat /proc/config.gz 2>/dev/null | awk -F= '$1=="CONFIG_HZ" {print $2; exit}' || true)
        if is_uint "${value:-}" && (( value >= 100 && value <= 2000 )); then printf '%s\n' "$value"; return 0; fi
    fi
    # Debian/Ubuntu generic cloud kernels commonly use 250 Hz. USER_HZ from
    # getconf CLK_TCK is deliberately not used because it is a different clock.
    printf '250\n'
}

calc_htb_burst() {
    local rate="$1" hz mtu="$2" bytes
    hz=$(detect_kernel_hz)
    bytes=$(( (rate * 1000000 + 8 * hz - 1) / (8 * hz) ))
    (( bytes < 32768 )) && bytes=32768
    (( bytes < mtu * 10 )) && bytes=$((mtu * 10))
    (( bytes > HTB_BURST_CAP )) && bytes=$HTB_BURST_CAP
    printf '%s\n' "$bytes"
}

calc_htb_quantum() {
    local mtu="$1" quantum
    quantum=$((mtu * 10))
    (( quantum > 60000 )) && quantum=60000
    printf '%s\n' "$quantum"
}

verify_shaping() {
    local iface="$1"
    managed_htb "$iface" || { die "HTB -> FQ 层级验证失败: $iface"; return 1; }
}

_apply_shaping_raw() {
    local iface="$1" rate="$2" mtu burst quantum cburst hierarchy_exists=0 kind
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    qdisc_module_hint htb; qdisc_module_hint fq
    mtu=$(detect_mtu "$iface"); is_uint "$mtu" || mtu=1500
    burst=$(calc_htb_burst "$rate" "$mtu")
    quantum=$(calc_htb_quantum "$mtu")
    cburst=$((mtu * 2))
    if managed_htb "$iface" || session_owned_htb "$iface"; then
        hierarchy_exists=1
    else
        kind=$(root_qdisc_kind "$iface")
        [[ "$kind" != htb ]] || { die "拒绝修改来源不明的 HTB root（$iface）"; return 1; }
    fi
    if (( ! hierarchy_exists )); then
        tc qdisc replace dev "$iface" root handle 1: htb default 10 || return 1
    fi
    tc class replace dev "$iface" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$cburst" quantum "$quantum" || return 1
    if ! managed_fq_leaf "$iface"; then
        tc qdisc replace dev "$iface" parent 1:10 handle 10: fq || return 1
    fi
    verify_shaping "$iface" || return 1
    TC_SESSION_HTB_IFACE="$iface"
}

apply_shaping() {
    local iface="$1" rate="$2" snapshot
    tc_dependencies || return 1; qdisc_guard "$iface" || return 1
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || { rm -f -- "$snapshot"; return 1; }
    if ! _apply_shaping_raw "$iface" "$rate"; then
        log ERR "应用 ${rate} Mbit 整形失败，正在恢复操作前 qdisc"
        restore_action_qdisc "$iface" "$snapshot" || true
        rm -f -- "$snapshot"
        return 1
    fi
    rm -f -- "$snapshot"
}

apply_fq() {
    local iface="$1" snapshot
    tc_dependencies || return 1; qdisc_guard "$iface" || return 1; qdisc_module_hint fq
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || { rm -f -- "$snapshot"; return 1; }
    if ! tc qdisc replace dev "$iface" root fq || [[ "$(root_qdisc_kind "$iface")" != fq ]]; then
        restore_action_qdisc "$iface" "$snapshot" || true
        rm -f -- "$snapshot"
        die "root FQ 应用失败"
        return 1
    fi
    [[ "$TC_SESSION_HTB_IFACE" == "$iface" ]] && TC_SESSION_HTB_IFACE=""
    rm -f -- "$snapshot"
}

tc_trial_transaction_begin() {
    local iface="$1" snapshot
    [[ -z "$TC_TRIAL_IFACE" && -z "$TC_TRIAL_SNAPSHOT" ]] || {
        die "已有未提交的临时 TC 操作"
        return 1
    }
    snapshot=$(mktemp) || return 1
    if ! action_qdisc_snapshot "$iface" "$snapshot"; then
        rm -f -- "$snapshot"
        return 1
    fi
    chmod 0600 "$snapshot" 2>/dev/null || true
    TC_TRIAL_IFACE="$iface"
    TC_TRIAL_SNAPSHOT="$snapshot"
}

tc_trial_transaction_commit() {
    local snapshot="$TC_TRIAL_SNAPSHOT"
    TC_TRIAL_IFACE=""
    TC_TRIAL_SNAPSHOT=""
    [[ -z "$snapshot" ]] || rm -f -- "$snapshot"
}

tc_trial_transaction_rollback() {
    local iface="$TC_TRIAL_IFACE" snapshot="$TC_TRIAL_SNAPSHOT" rc=0
    [[ -n "$iface" && -n "$snapshot" && -f "$snapshot" ]] || {
        TC_TRIAL_IFACE=""; TC_TRIAL_SNAPSHOT=""
        return 0
    }
    restore_action_qdisc "$iface" "$snapshot" || rc=1
    if (( rc == 0 )); then
        rm -f -- "$snapshot"
        TC_TRIAL_IFACE=""
        TC_TRIAL_SNAPSHOT=""
    else
        log ERR "临时 TC 回滚失败；qdisc 快照保留在 $snapshot"
    fi
    return "$rc"
}

tc_trial() {
    require_root || return 1; require_host_network_control || return 1; acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" iface rc=0 rollback_rc=0
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    [[ "$requested" != auto ]] || auto_tune_route_guard "$iface" "" || return 1
    shaping_target_preflight "$iface" trial "$requested" || return 1
    BANDWIDTH_MBIT="$rate"; network_tuning_preflight "$iface" 1 || return 1
    capture_baseline "$iface" || return 1
    tc_trial_transaction_begin "$iface" || return 1
    if apply_shaping "$iface" "$rate"; then
        tc_trial_transaction_commit || return 1
    else
        rc=$?
        tc_trial_transaction_rollback || rollback_rc=$?
        (( rollback_rc == 0 )) || return "$rollback_rc"
        return "$rc"
    fi
    log OK "临时整形已生效: $iface ${rate} Mbit（未写配置，重启后失效）"
}

tc_enable() {
    local rate="$1" requested="${2:-auto}" knee="${3:-0}" margin="${4:-3}" iface profile role bandwidth rtt
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    is_uint "$knee" && (( knee <= 1000000 )) || { die "非法拐点速率: $knee"; return 1; }
    is_uint "$margin" && (( margin <= 25 )) || { die "非法退让比例: $margin"; return 1; }
    (( knee == 0 || knee >= rate )) || { die "拐点速率不能低于最终整形速率"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    [[ "$requested" != auto ]] || auto_tune_route_guard "$iface" "" || return 1
    load_config || return 1
    profile="$SYSCTL_PROFILE"; role="$ROLE"; bandwidth="$BANDWIDTH_MBIT"; rtt="$RTT_MS"
    if (( MULTI_NIC_ENABLED == 1 )); then
        # The global model may belong to a completely different, higher-BDP
        # interface.  A qdisc-only compatibility command must never copy that
        # aggregate metadata into a newly managed NIC.
        profile=balanced; role=mixed; bandwidth=0; rtt=0
        if nic_policy_exists "$iface"; then
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            profile="$NIC_POLICY_PROFILE"; role="$NIC_POLICY_ROLE"; bandwidth="$NIC_POLICY_BANDWIDTH_MBIT"; rtt="$NIC_POLICY_RTT_MS"
        fi
    fi
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; fi
    nic_manage "$iface" shape "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
}

tc_disable() {
    local requested="${1:-auto}" iface interfaces count profile role bandwidth rtt margin=3
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )) && [[ "$requested" == auto ]]; then
        interfaces=""
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            [[ "$NIC_POLICY_MODE" == shape ]] && interfaces+="${interfaces:+$'\n'}$iface"
        done < <(nic_policy_interface_list)
        count=$(grep -c . <<< "$interfaces" || true)
        (( count == 1 )) || { die "多网卡模式下 tc disable 必须显式指定 --interface（当前整形接口: $(shaping_interface_list_text "$interfaces")）"; return 1; }
        requested="$interfaces"
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto && "$requested" == auto ]]; then
        interfaces=$(managed_htb_interfaces)
        count=$(grep -c . <<< "$interfaces" || true)
        die "检测到旧版 TC_INTERFACE=auto；拒绝根据当前默认路由猜测旧整形接口。发现 ${count} 个受管 HTB: $(shaping_interface_list_text "$interfaces")。请显式指定 --interface DEV"
        return 1
    fi
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    profile="$SYSCTL_PROFILE"; role="$ROLE"; bandwidth="$BANDWIDTH_MBIT"; rtt="$RTT_MS"
    if (( MULTI_NIC_ENABLED == 1 )); then
        nic_policy_exists "$iface" || { die "网卡没有受管策略: $iface"; return 1; }
        nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
        profile="$NIC_POLICY_PROFILE"; role="$NIC_POLICY_ROLE"; bandwidth="$NIC_POLICY_BANDWIDTH_MBIT"; rtt="$NIC_POLICY_RTT_MS"; margin="$NIC_POLICY_MARGIN_PERCENT"
    fi
    if [[ "$profile" == balanced ]] && (( bandwidth == 0 )); then rtt=0; fi
    nic_manage "$iface" fq 0 0 "$margin" "$profile" "$role" "$bandwidth" "$rtt"
}

tc_status() {
    local requested="${1:-auto}" iface interfaces count
    load_config || return 1
    if (( MULTI_NIC_ENABLED == 1 )) && [[ "$requested" == auto ]]; then
        nic_inventory
        return
    fi
    if (( MULTI_NIC_ENABLED == 1 )); then
        iface=$(detect_interface "$requested") || return 1
        printf 'Interface: %s\n' "$iface"
        if nic_policy_exists "$iface"; then
            nic_policy_load_file "$(nic_policy_path "$iface")" || return 1
            printf 'Configured: mode=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$NIC_POLICY_MODE" "$NIC_POLICY_RATE_MBIT" "$NIC_POLICY_KNEE_MBIT" "$NIC_POLICY_MARGIN_PERCENT"
        else printf 'Configured: unmanaged\n'; fi
        tc -s -d qdisc show dev "$iface"
        tc -s -d class show dev "$iface"
        return
    fi
    if (( TC_ENABLED == 1 )) && [[ "$TC_INTERFACE" == auto && "$requested" == auto ]]; then
        interfaces=$(managed_htb_interfaces)
        count=$(grep -c . <<< "$interfaces" || true)
        if (( count == 1 )); then
            requested="$interfaces"
            log WARN "旧版 auto 配置未固化接口；只读状态暂按唯一受管 HTB $requested 展示"
        elif (( count > 1 )); then
            die "旧版 auto 配置对应多个受管 HTB ($(shaping_interface_list_text "$interfaces"))；请显式指定 --interface"
            return 1
        fi
    fi
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    printf 'Interface: %s\n' "$iface"
    printf 'Configured: enabled=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$TC_ENABLED" "$TC_RATE_MBIT" "$TC_KNEE_MBIT" "$TC_MARGIN_PERCENT"
    tc -s -d qdisc show dev "$iface"
    tc -s -d class show dev "$iface"
}

# -----------------------------------------------------------------------------
# Multi-NIC policy: one global TCP model plus independently managed qdiscs.
# -----------------------------------------------------------------------------

NIC_POLICY_SCHEMA="1"
NIC_POLICY_FORMAT="bbrv3-lite-nic-policy"
NIC_BASELINE_SCHEMA="1"
NIC_BASELINE_FORMAT="bbrv3-lite-nic-baseline"

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
    local entry name
    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        case "$name" in
            .manifest) [[ -f "$entry" && ! -L "$entry" ]] || { die "网卡策略清单类型非法: $entry"; return 1; } ;;
            *.conf) [[ -f "$entry" && ! -L "$entry" ]] || { die "网卡策略必须是非符号链接常规文件: $entry"; return 1; } ;;
            *) die "多网卡策略目录含未知条目: $entry"; return 1 ;;
        esac
    done < <(find "$NIC_POLICY_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
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

nic_policy_set_validate() {
    local state file count=0
    state=$(nic_policy_layout_state)
    [[ "$state" == managed ]] || { die "多网卡模式需要有效策略目录，当前: $state"; return 1; }
    nic_policy_directory_entries_validate || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || return 1
        ((count+=1))
    done < <(nic_policy_files)
    return 0
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
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" >/dev/null || return 1
        printf '%s\n' "$NIC_POLICY_INTERFACE"
    done < <(nic_policy_files)
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

nic_policy_model_rows() {
    local excluded="${1:-}" file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" >/dev/null || return 1
        [[ -z "$excluded" || "$NIC_POLICY_INTERFACE" != "$excluded" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$NIC_POLICY_PROFILE" "$NIC_POLICY_ROLE" "$NIC_POLICY_BANDWIDTH_MBIT" "$NIC_POLICY_RTT_MS" "$NIC_POLICY_INTERFACE"
    done < <(nic_policy_files)
}

nic_policy_global_model() {
    local rows
    nic_policy_set_validate || return 1
    rows=$(nic_policy_model_rows) || return 1
    nic_aggregate_model_rows <<< "$rows"
}

nic_policy_candidate_global_model() {
    local target="$1" profile="$2" role="$3" bandwidth="$4" rtt="$5" rows legacy_rtt
    case "$(nic_policy_layout_state)" in managed) nic_policy_set_validate || return 1 ;; absent) ;; *) return 1 ;; esac
    rows=$(nic_policy_model_rows "$target") || return 1
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

nic_global_model_verify() {
    local values expected_profile expected_role expected_bandwidth expected_rtt expected_iface
    values=$(nic_policy_global_model) || return 1
    IFS=$'\t' read -r expected_profile expected_role expected_bandwidth expected_rtt expected_iface <<< "$values"
    NIC_MODEL_INTERFACE="$expected_iface"
    [[ "$SYSCTL_PROFILE" == "$expected_profile" && "$ROLE" == "$expected_role" &&
       "$BANDWIDTH_MBIT" == "$expected_bandwidth" && "$RTT_MS" == "$expected_rtt" ]] || {
        die "全局 TCP 模型与多网卡策略不一致：当前 $SYSCTL_PROFILE/$ROLE/$BANDWIDTH_MBIT/$RTT_MS，期望 $expected_profile/$expected_role/$expected_bandwidth/$expected_rtt"
        return 1
    }
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
    ensure_state_layout || return 1
    if [[ -e "$NIC_STATE_DIR" || -L "$NIC_STATE_DIR" ]]; then
        [[ -d "$NIC_STATE_DIR" && ! -L "$NIC_STATE_DIR" ]] || { die "网卡基线根目录类型不安全: $NIC_STATE_DIR"; return 1; }
    else
        mkdir -p -- "$NIC_STATE_DIR" || return 1
    fi
    chmod 0700 "$NIC_STATE_DIR" 2>/dev/null || true
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
    local iface source rc=0
    [[ "$(nic_policy_layout_state)" == managed ]] || return 0
    nic_policy_set_validate || return 1
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        nic_baseline_validate "$iface" || { rc=1; continue; }
        source=$(awk -F'\t' '$1=="SOURCE" {print $2}' "$(nic_baseline_dir "$iface")/manifest")
        [[ "$source" == snapshot ]] || continue
        nic_baseline_restore "$iface" || rc=1
    done < <(nic_policy_interface_list)
    return "$rc"
}

nic_restore_preflight() {
    local state iface dir
    state=$(nic_policy_layout_state)
    case "$state" in absent) return 0 ;; managed) nic_policy_set_validate || return 1 ;; *) die "多网卡策略目录损坏，恢复尚未开始"; return 1 ;; esac
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
    done < <(nic_policy_interface_list)
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

nic_policy_ownership_preflight() {
    local target="${1:-}" file iface managed policies=""
    case "$(nic_policy_layout_state)" in
        absent) ;;
        managed)
            while IFS= read -r file; do
                [[ -n "$file" ]] || continue
                nic_policy_load_file "$file" || return 1
                nic_policy_validate_identity || return 1
                qdisc_guard "$NIC_POLICY_INTERFACE" || return 1
                policies+="${policies:+$'\n'}$NIC_POLICY_INTERFACE"
            done < <(nic_policy_files)
            ;;
        *) die "多网卡策略目录损坏或不属于本项目"; return 1 ;;
    esac
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

nic_restore_runtime_snapshot() {
    local directory="$1" rc=0
    [[ -f "$directory/sysctl.tsv" ]] || return 1
    restore_tcp_sysctl_snapshot_file "$directory/sysctl.tsv" || rc=1
    restore_default_route_windows_snapshot "$directory" || rc=1
    return "$rc"
}

nic_verify_runtime_policies() {
    local only="${1:-}" file iface managed policies="" rc=0 found=0
    (( MULTI_NIC_ENABLED == 1 )) || { die "当前不是多网卡配置"; return 1; }
    nic_policy_set_validate || return 1
    nic_global_model_verify || rc=1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || { rc=1; continue; }
        iface="$NIC_POLICY_INTERFACE"; policies+="${policies:+$'\n'}$iface"
        [[ -z "$only" || "$only" == "$iface" ]] || continue
        found=1
        nic_policy_validate_identity || { rc=1; continue; }
        if [[ "$NIC_POLICY_MODE" == shape ]]; then
            verify_shaping "$iface" || rc=1
            [[ "$(managed_rate_mbit "$iface" 2>/dev/null || true)" == "$NIC_POLICY_RATE_MBIT" ]] || { log ERR "$iface 整形速率漂移"; rc=1; }
        else
            [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "$iface root qdisc 不是 fq"; rc=1; }
        fi
    done < <(nic_policy_files)
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

nic_apply_runtime_policies() {
    local file iface rc=0 mutated=0 snapshot_dir="" snapshot_parent
    nic_policy_set_validate || return 1
    nic_global_model_verify || return 1
    nic_policy_ownership_preflight || return 1
    snapshot_parent="${TMPDIR:-/tmp}"
    snapshot_dir=$(mktemp -d "$snapshot_parent/${SCRIPT_NAME}.multi-nic.XXXXXX") || return 1
    if ! capture_runtime_sysctls > "$snapshot_dir/sysctl.tsv"; then
        remove_tree_within "$snapshot_dir" "$snapshot_parent" || true
        return 1
    fi
    ip -4 route show default > "$snapshot_dir/default-route-v4.txt" 2>/dev/null || true
    ip -6 route show default > "$snapshot_dir/default-route-v6.txt" 2>/dev/null || true
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        nic_policy_load_file "$file" || { rc=1; break; }
        action_qdisc_snapshot "$NIC_POLICY_INTERFACE" "$snapshot_dir/$NIC_POLICY_INTERFACE.snapshot" || { rc=1; break; }
    done < <(nic_policy_files)
    if (( rc == 0 )); then mutated=1; apply_sysctl_profile runtime || rc=1; fi
    if (( rc == 0 )); then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            nic_policy_load_file "$file" || { rc=1; break; }
            iface="$NIC_POLICY_INTERFACE"
            if [[ "$NIC_POLICY_MODE" == shape ]]; then apply_shaping "$iface" "$NIC_POLICY_RATE_MBIT" || { rc=1; break; }
            else apply_fq "$iface" || { rc=1; break; }
            fi
        done < <(nic_policy_files)
    fi
    if (( rc == 0 )); then apply_initial_windows || rc=1; fi
    if (( rc == 0 )); then nic_verify_runtime_policies || rc=1; fi
    if (( rc != 0 )); then
        if (( mutated )); then
            nic_restore_runtime_snapshot "$snapshot_dir" || true
            for file in "$snapshot_dir"/*.snapshot; do
                [[ -f "$file" ]] || continue
                iface="${file##*/}"; iface="${iface%.snapshot}"
                restore_action_qdisc "$iface" "$file" || true
            done
        fi
        remove_tree_within "$snapshot_dir" "$snapshot_parent" || true
        if (( mutated )); then die "多网卡持久化应用失败，已恢复本轮 qdisc、sysctl 与路由窗口快照"
        else die "多网卡持久化应用在只读快照阶段失败；未修改运行时状态"
        fi
        return 1
    fi
    remove_tree_within "$snapshot_dir" "$snapshot_parent"
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
    local root path iface state mac driver mtu speed rx tx qdisc policy mode rate role layout file rc=0
    layout=$(nic_policy_layout_state)
    case "$layout" in
        managed) nic_policy_set_validate || return 1 ;;
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
    done < <(nic_policy_files)
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

nic_apply_command() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands ip tc sysctl systemctl modprobe || return 1
    load_config || return 1
    (( MULTI_NIC_ENABLED == 1 )) || { die "当前不是多网卡配置"; return 1; }
    nic_apply_runtime_policies
}

nic_policy_reset_record
nic_auto_policy_reset

# -----------------------------------------------------------------------------
# Measurement: iperf3 JSON probe and policer-knee sweep with automatic restore.
# -----------------------------------------------------------------------------

MEASURE_IFACE=""
MEASURE_SNAPSHOT=""
MEASURE_TX_START=0
MEASURE_RX_START=0
MEASURE_RESULT_FILE=""
MEASURE_RUN_DIR=""
MEASURE_IDLE_RTT_MS="na"
MEASURE_PEER_HOST=""
MEASURE_PEER_ADDRESS=""
MEASURE_PEER_SOURCE=""
MEASURE_PEER_FAMILY=""
MEASURE_PEER_IFACE=""
MEASURE_PEER_PORT=""
IPERF_DATA_RC=65
IPERF_CONTAMINATED_RC=66
IPERF_UNSTABLE_RC=67
IPERF_UNAVAILABLE_RC=75
PUBLIC_PEER_CANDIDATES=()

# Public endpoints are opt-in and used only by the interactive auto-tune wizard.
# Providers and test traffic are disclosed before execution; a private iperf3 peer is preferred.
PUBLIC_PEER_POOL=$(cat <<'EOF'
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
lon.speedtest.clouvider.net|伦敦|Clouvider
EOF
)

parse_peer_spec() {
    local spec="$1" default_port="${2:-5201}"
    PEER_HOST=""; PEER_PORT="$default_port"
    if [[ "$spec" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^([^:]+):([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    else
        PEER_HOST="$spec"
    fi
    validate_peer "$PEER_HOST" "$PEER_PORT"
}

public_peer_ports() {
    local host="$1" limit="${2:-1}" requested_iface="${3:-auto}" port found=0 rtt
    is_uint "$limit" && (( limit >= 1 && limit <= 4 )) || limit=1
    for port in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200; do
        if measure_lock_peer "$host" "$requested_iface" "$port" "" "" 1; then
            rtt=$(median_ping_ms "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_FAMILY" 2>/dev/null || true)
            [[ -n "$rtt" ]] || rtt=9999
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$port" "$MEASURE_PEER_ADDRESS" \
                "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE" "$rtt"
            measure_clear_peer_lock
            ((found+=1))
            (( found < limit )) || return 0
        fi
    done
    (( found > 0 ))
}

peer_route_rtt() {
    local host="$1" requested_iface="${2:-auto}" addresses ordered v6_records family address rtt
    addresses=$(resolve_route_target_addresses "$host") || return 1
    [[ -n "$addresses" ]] || return 1
    ordered=$(awk -F'\t' '$1==4 {print}' <<< "$addresses")
    v6_records=$(awk -F'\t' '$1==6 {print}' <<< "$addresses")
    if [[ -n "$v6_records" ]]; then
        if [[ -n "$ordered" ]]; then ordered+=$'\n'; fi
        ordered+="$v6_records"
    fi
    while IFS=$'\t' read -r family address; do
        [[ "$family" == 4 || "$family" == 6 ]] || continue
        if measure_lock_peer "$host" "$requested_iface" "" "$address" "" 1 2>/dev/null; then
            rtt=$(median_ping_ms "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_FAMILY" 2>/dev/null || true)
            measure_clear_peer_lock
            if [[ -n "$rtt" ]]; then
                printf '%s\n' "$rtt"
                return 0
            fi
        fi
    done <<< "$ordered"
    measure_clear_peer_lock
    return 1
}

auto_pick_peer() {
    require_commands ip getent ping timeout iperf3 jq || return 1
    local requested_iface="${1:-auto}" temp host region provider rtt port address family source iface endpoint_rtt
    local max_rtt="${BBRV3_PEER_MAX_RTT:-120}"
    local limit="${BBRV3_PUBLIC_PEER_CANDIDATES:-4}" per_host="${BBRV3_PUBLIC_PORTS_PER_HOST:-2}" candidate found rank
    local primary_host="" preferred_extra="" primary_take index
    local -a primary_candidates=() extra_candidates=() ordered_candidates=()
    is_uint "$max_rtt" && (( max_rtt >= 1 && max_rtt <= 10000 )) || max_rtt=120
    is_uint "$limit" && (( limit >= 2 && limit <= 8 )) || limit=4
    is_uint "$per_host" && (( per_host >= 1 && per_host <= 4 )) || per_host=2
    PUBLIC_PEER_CANDIDATES=()
    temp=$(mktemp -d) || return 1
    log INFO "正在按 RTT 筛选公共 iperf3 节点（Leaseweb / OVH / Clouvider）"
    while IFS='|' read -r host region provider; do
        [[ -n "$host" ]] || continue
        (
            rtt=$(peer_route_rtt "$host" "$requested_iface")
            [[ -n "$rtt" ]] && printf '%s\t%s\t%s\t%s\n' "$rtt" "$host" "$region" "$provider" > "$temp/${host//[^a-zA-Z0-9]/_}"
        ) &
    done <<< "$PUBLIC_PEER_POOL"
    wait || true
    while IFS=$'\t' read -r rtt host region provider; do
        (( rtt <= max_rtt )) || { log INFO "$host ($region/$provider) RTT ${rtt}ms，过远跳过"; continue; }
        found=0; rank=0
        while IFS=$'\t' read -r port address family source iface endpoint_rtt; do
            [[ -n "$port" && -n "$address" && -n "$source" && -n "$iface" ]] || continue
            if ! is_uint "$endpoint_rtt" || (( endpoint_rtt > max_rtt )); then
                log INFO "$host:$port -> $address (IPv${family:-?}) RTT ${endpoint_rtt:-unknown}ms，过远或不可测，跳过"
                continue
            fi
            candidate="$host|$address|$family|$source|$iface|$port|$endpoint_rtt|$region|$provider"
            if (( rank == 0 )); then primary_candidates+=("$candidate"); else extra_candidates+=("$candidate"); fi
            ((found+=1)); ((rank+=1))
        done < <(public_peer_ports "$host" "$per_host" "$requested_iface")
        (( found > 0 )) || log INFO "$host ($region/$provider) 当前无可用测试端口"
        # Prefer distinct hosts before reserving a second port on the same host.
        (( ${#primary_candidates[@]} < limit )) || break
    done < <(cat "$temp"/* 2>/dev/null | sort -n)
    rm -rf -- "$temp"
    if ((${#primary_candidates[@]} > 0)); then
        primary_host="${primary_candidates[0]%%|*}"
        for candidate in "${extra_candidates[@]}"; do
            if [[ "${candidate%%|*}" == "$primary_host" ]]; then preferred_extra="$candidate"; break; fi
        done
        primary_take=$limit
        [[ -z "$preferred_extra" ]] || primary_take=$((limit - 1))
        for ((index=0; index<${#primary_candidates[@]} && index<primary_take; index++)); do
            ordered_candidates+=("${primary_candidates[$index]}")
        done
        [[ -z "$preferred_extra" ]] || ordered_candidates+=("$preferred_extra")
        for ((; index<${#primary_candidates[@]}; index++)); do ordered_candidates+=("${primary_candidates[$index]}"); done
        for candidate in "${extra_candidates[@]}"; do
            [[ "$candidate" == "$preferred_extra" ]] || ordered_candidates+=("$candidate")
        done
    fi
    for candidate in "${ordered_candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        PUBLIC_PEER_CANDIDATES+=("$candidate")
        IFS='|' read -r host address family source iface port rtt region provider <<< "$candidate"
        if (( ${#PUBLIC_PEER_CANDIDATES[@]} == 1 )); then
            log OK "公共对端已通过 IPv${family} iperf3 预检: $host:$port -> $address ($region/$provider, RTT ${rtt}ms)"
        else
            log INFO "已保留备用公共对端: $host:$port -> $address (IPv${family}, $region/$provider, RTT ${rtt}ms)"
        fi
        (( ${#PUBLIC_PEER_CANDIDATES[@]} < limit )) || break
    done
    ((${#PUBLIC_PEER_CANDIDATES[@]} > 0)) || { die "${max_rtt}ms 内没有可用公共 iperf3 节点；请使用自有对端"; return 1; }
}

interface_counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || printf '0\n'; }

measure_set_latency_baseline() {
    local peer="$1" path_samples="${2:-${BBRV3_PATH_SAMPLES:-7}}" path_pmtu="${3:-${BBRV3_PATH_PMTU:-1}}"
    local value="" target family="auto" guarded=0
    target="$peer"
    MEASURE_IDLE_RTT_MS="na"
    [[ "$(uname -s 2>/dev/null || true)" == Linux ]] || return 0
    command_exists ping || return 0
    if [[ -n "$MEASURE_PEER_ADDRESS" && ( "$peer" == "$MEASURE_PEER_HOST" || "$peer" == "$MEASURE_PEER_ADDRESS" ) ]]; then
        target="$MEASURE_PEER_ADDRESS"
        family="$MEASURE_PEER_FAMILY"
        measure_peer_route_guard || return 1
        guarded=1
    elif [[ "$peer" == *:* ]]; then
        family=6
    elif [[ "$peer" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        family=4
    fi
    if (( guarded )); then
        path_profile_capture "$path_samples" "$path_pmtu" || return 1
        value="$PATH_RTT_MEDIAN_MS"
    else
        value=$(median_ping_ms "$target" "$family" 2>/dev/null || true)
    fi
    (( guarded == 0 )) || measure_peer_route_guard || return 1
    if is_decimal "$value"; then
        MEASURE_IDLE_RTT_MS="$value"
        log INFO "空闲 RTT 基线: ${value} ms"
    else
        log WARN "未取得空闲 RTT；吞吐和重传仍会测量，但负载延迟与置信度会降级"
    fi
}

measure_begin() {
    local iface="$1" snapshot
    [[ -z "$MEASURE_SNAPSHOT" ]] || {
        die "已有未恢复的测量 qdisc 快照: $MEASURE_SNAPSHOT"
        return 1
    }
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot" || {
        rm -f -- "$snapshot"
        return 1
    }
    MEASURE_IFACE="$iface"
    MEASURE_SNAPSHOT="$snapshot"
    MEASURE_TX_START=$(interface_counter "$iface" tx_bytes)
    MEASURE_RX_START=$(interface_counter "$iface" rx_bytes)
    trap 'measure_abort 130' INT TERM HUP
}

measure_restore() {
    local rc=0 iface="$MEASURE_IFACE" snapshot="$MEASURE_SNAPSHOT"
    if [[ -z "$iface" && -z "$snapshot" ]]; then
        trap - INT TERM HUP
        measure_clear_peer_lock
        return 0
    fi
    if [[ -z "$iface" || -z "$snapshot" || ! -f "$snapshot" ]]; then
        log ERR "测量 qdisc 回滚状态不完整；保留现场以便人工恢复（iface=${iface:-missing}, snapshot=${snapshot:-missing}）"
        return 1
    fi
    restore_action_qdisc "$iface" "$snapshot" || rc=$?
    if (( rc != 0 )); then
        log ERR "测量 qdisc 回滚失败；快照保留在 $snapshot，退出清理将再次尝试"
        return "$rc"
    fi
    rm -f -- "$snapshot"
    trap - INT TERM HUP
    MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
    measure_clear_peer_lock
    return "$rc"
}

measure_abort() {
    local rc="${1:-130}"
    log WARN "测试被中断，正在恢复操作前 qdisc"
    measure_restore || true
    release_lock
    exit "$rc"
}

traffic_report() {
    local tx_now rx_now tx rx
    tx_now=$(interface_counter "$1" tx_bytes); rx_now=$(interface_counter "$1" rx_bytes)
    tx=$((tx_now - MEASURE_TX_START)); rx=$((rx_now - MEASURE_RX_START))
    (( tx < 0 )) && tx=0; (( rx < 0 )) && rx=0
    log INFO "本轮接口流量: TX $(human_bytes "$tx"), RX $(human_bytes "$rx")"
}

validate_peer() {
    [[ "$1" != -* && "$1" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法 peer: $1"; return 1; }
    is_uint "$2" && (( $2 >= 1 && $2 <= 65535 )) || { die "非法端口: $2"; return 1; }
}

measure_clear_peer_lock() {
    MEASURE_PEER_HOST=""
    MEASURE_PEER_ADDRESS=""
    MEASURE_PEER_SOURCE=""
    MEASURE_PEER_FAMILY=""
    MEASURE_PEER_IFACE=""
    MEASURE_PEER_PORT=""
    path_state_reset
}

measure_route_output_sources() {
    awk '{for (i=1; i<NF; i++) if ($i=="src") print $(i+1)}' | awk '!seen[$0]++'
}

measure_source_address_is_valid() {
    local family="$1" source="$2" octet
    local -a octets=()
    [[ -n "$source" && "$source" != -* && "$source" != *[[:space:]]* ]] || return 1
    case "$family" in
        4)
            [[ "$source" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
            IFS=. read -r -a octets <<< "$source"
            ((${#octets[@]} == 4)) || return 1
            for octet in "${octets[@]}"; do
                [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( 10#$octet <= 255 )) || return 1
            done
            [[ "$source" != 0.0.0.0 ]]
            ;;
        6)
            [[ "$source" == *:* && "$source" =~ ^[0-9A-Fa-f:.]+$ && "$source" != :: ]]
            ;;
        *) return 1 ;;
    esac
}

measure_unique_route_iface() {
    local output="$1" context="$2" iface count
    if route_output_has_unresolved_nhid "$output"; then
        die "$context 包含未解析的 nexthop object (nhid)；测速路径不再唯一"
        return 1
    fi
    if route_output_has_multipath "$output"; then
        die "$context 包含 ECMP/nexthop；测速路径不再唯一"
        return 1
    fi
    count=$(route_output_interfaces <<< "$output" | awk 'END {print NR+0}')
    if ! is_uint "${count:-}" || (( count != 1 )); then
        die "$context 无法确定唯一出口网卡"
        return 1
    fi
    iface=$(route_output_interfaces <<< "$output" | sed -n '1p')
    validate_interface_name "$iface" || { die "$context 返回非法出口网卡: $iface"; return 1; }
    printf '%s\n' "$iface"
}

# Revalidate one already-resolved literal through the platform's strict
# route-get/fibmatch gate, then prove that binding the selected source address
# does not select another policy-routing path.
measure_capture_route_state() {
    local family="$1" address="$2" expected_iface="$3" expected_source="${4:-}"
    local records record_count record_family record_address record_iface output iface sources source source_count
    local bound_output bound_iface bound_fibmatch bound_fib_iface
    records=$(target_route_records "$address") || return 1
    record_count=$(awk 'NF {count++} END {print count+0}' <<< "$records")
    if ! is_uint "${record_count:-}" || (( record_count != 1 )); then
        die "测速地址 $address 的严格路由核验没有返回唯一记录"
        return 1
    fi
    IFS=$'\t' read -r record_family record_address record_iface <<< "$records"
    [[ "$record_family" == "$family" && "$record_address" == "$address" && "$record_iface" == "$expected_iface" ]] || {
        die "测速地址 $address 的冻结路由与预期不一致（IPv${record_family:-?}/${record_iface:-?}，预期 IPv${family}/$expected_iface）"
        return 1
    }

    if ! output=$(ip "-$family" route get "$address" 2>/dev/null) || [[ -z "$output" ]]; then
        die "测速地址 $address 无法取得 route-get 来源地址"
        return 1
    fi
    iface=$(measure_unique_route_iface "$output" "测速地址 $address 的 route-get") || return 1
    [[ "$iface" == "$expected_iface" ]] || {
        die "测速地址 $address 的出口已从 $expected_iface 漂移到 $iface"
        return 1
    }
    sources=$(measure_route_output_sources <<< "$output")
    source_count=$(awk 'NF {count++} END {print count+0}' <<< "$sources")
    if ! is_uint "${source_count:-}" || (( source_count != 1 )); then
        die "测速地址 $address 的 route-get 无法确定唯一来源地址"
        return 1
    fi
    source=$(head -n1 <<< "$sources")
    measure_source_address_is_valid "$family" "$source" || {
        die "测速地址 $address 返回非法 IPv${family} 来源地址: $source"
        return 1
    }
    if [[ -n "$expected_source" && "$source" != "$expected_source" ]]; then
        die "测速地址 $address 的来源地址已从 $expected_source 漂移到 $source"
        return 1
    fi

    if ! bound_output=$(ip "-$family" route get "$address" from "$source" 2>/dev/null) || [[ -z "$bound_output" ]]; then
        die "测速地址 $address 无法用冻结来源地址 $source 完成 route-get"
        return 1
    fi
    bound_iface=$(measure_unique_route_iface "$bound_output" "测速地址 $address 的来源绑定 route-get") || return 1
    [[ "$bound_iface" == "$expected_iface" ]] || {
        die "绑定来源地址 $source 后，测速出口从 $expected_iface 变为 $bound_iface"
        return 1
    }
    if ! bound_fibmatch=$(ip "-$family" route get fibmatch "$address" from "$source" 2>/dev/null) || [[ -z "$bound_fibmatch" ]]; then
        die "无法用 fibmatch 核验测速地址 $address 的来源绑定路径"
        return 1
    fi
    bound_fib_iface=$(measure_unique_route_iface "$bound_fibmatch" "测速地址 $address 的来源绑定 fibmatch") || return 1
    [[ "$bound_fib_iface" == "$expected_iface" ]] || {
        die "绑定来源地址 $source 后，测速 fibmatch 出口从 $expected_iface 变为 $bound_fib_iface"
        return 1
    }
    printf '%s\t%s\n' "$iface" "$source"
}

# Resolve a hostname once, prefer IPv4 for broad public-server compatibility,
# and fall back to IPv6 only when the exact IPv4 endpoint is not route-safe or
# cannot complete a low-traffic iperf3 preflight. Explicit literals never
# change family. A preferred address/source comes from the interactive public
# preflight and deliberately bypasses DNS so the formal run uses that tuple.
measure_lock_peer() {
    local peer="$1" requested_iface="$2" port="${3:-}" preferred_address="${4:-}" preferred_source="${5:-}" quiet="${6:-0}"
    local addresses ordered family address state iface source record record_family record_address record_iface
    local is_literal=0 exact_candidate=0 resolved_count=0 route_candidates=0 service_candidates=0

    # A failed re-lock must never leave a previous endpoint looking current.
    measure_clear_peer_lock
    [[ "$requested_iface" == auto ]] || validate_interface_name "$requested_iface" || {
        die "非法测速出口网卡: $requested_iface"
        return 1
    }
    [[ -z "$port" ]] || { is_uint "$port" && (( port >= 1 && port <= 65535 )); } || {
        die "非法测速端口: $port"
        return 1
    }
    [[ "$quiet" == 0 || "$quiet" == 1 ]] || return 1
    if [[ "$peer" == *:* ]]; then
        is_literal=1
    elif [[ "$peer" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        is_literal=1
    fi

    if [[ -n "$preferred_address" ]]; then
        exact_candidate=1
        if measure_source_address_is_valid 4 "$preferred_address"; then family=4
        elif measure_source_address_is_valid 6 "$preferred_address"; then family=6
        else
            die "预选测速地址无效: $preferred_address"
            return 1
        fi
        if (( is_literal )) && [[ "$peer" != "$preferred_address" ]]; then
            die "显式测速地址 $peer 与预选地址 $preferred_address 不一致"
            return 1
        fi
        addresses=$(printf '%s\t%s\n' "$family" "$preferred_address")
    else
        addresses=$(resolve_route_target_addresses "$peer") || return 1
        [[ -n "$addresses" ]] || {
            (( quiet )) || die "无法解析测速对端 $peer"
            return "$IPERF_UNAVAILABLE_RC"
        }
    fi

    if (( is_literal || exact_candidate )); then
        ordered="$addresses"
    else
        # Do not inherit libc/getent family order. Public iperf3 coverage is
        # substantially broader over IPv4, while IPv6 remains a real fallback.
        ordered=$(awk -F'\t' '$1==4 {print}' <<< "$addresses")
        record=$(awk -F'\t' '$1==6 {print}' <<< "$addresses")
        if [[ -n "$record" ]]; then
            if [[ -n "$ordered" ]]; then ordered+=$'\n'; fi
            ordered+="$record"
        fi
    fi

    while IFS=$'\t' read -r family address; do
        [[ "$family" == 4 || "$family" == 6 ]] || {
            measure_clear_peer_lock
            die "测速对端 $peer 返回非法地址族"
            return 1
        }
        measure_source_address_is_valid "$family" "$address" || {
            measure_clear_peer_lock
            die "测速对端 $peer 返回非法 IPv${family} 地址: $address"
            return 1
        }
        ((resolved_count+=1))

        if [[ "$requested_iface" == auto ]]; then
            if (( is_literal || exact_candidate )); then
                record=$(target_route_records "$address") || { measure_clear_peer_lock; return 1; }
            else
                record=$(target_route_records "$address" 2>/dev/null) || {
                    (( quiet )) || log WARN "跳过 $address（IPv${family}）：没有可严格核验的唯一出口"
                    continue
                }
            fi
            IFS=$'\t' read -r record_family record_address record_iface <<< "$record"
            [[ "$record_family" == "$family" && "$record_address" == "$address" ]] || {
                measure_clear_peer_lock
                die "测速地址 $address 的路由记录与解析结果不一致"
                return 1
            }
            iface="$record_iface"
            validate_interface_name "$iface" || { measure_clear_peer_lock; return 1; }
            interface_is_excluded "$iface" && {
                (( quiet )) || log WARN "跳过 $address（IPv${family}）：出口 $iface 是受保护的虚拟接口"
                continue
            }
        else
            iface="$requested_iface"
        fi

        if (( is_literal || exact_candidate )); then
            state=$(measure_capture_route_state "$family" "$address" "$iface" "$preferred_source") || {
                measure_clear_peer_lock
                return 1
            }
        else
            state=$(measure_capture_route_state "$family" "$address" "$iface" 2>/dev/null) || {
                (( quiet )) || log WARN "跳过 $address（IPv${family}）：路由、来源地址或出口 $iface 核验未通过"
                continue
            }
        fi
        IFS=$'\t' read -r record_iface source <<< "$state"
        [[ "$record_iface" == "$iface" ]] || { measure_clear_peer_lock; return 1; }
        ((route_candidates+=1))

        if [[ -n "$port" ]]; then
            if ! peer_port_open "$address" "$port" || ! iperf_peer_usable "$address" "$port" "$family" "$source"; then
                (( quiet )) || log WARN "跳过 $address:$port（IPv${family}）：TCP/iperf3 预检不可用"
                if (( is_literal || exact_candidate )); then
                    measure_clear_peer_lock
                    return "$IPERF_UNAVAILABLE_RC"
                fi
                continue
            fi
            ((service_candidates+=1))
        fi

        MEASURE_PEER_HOST="$peer"
        MEASURE_PEER_ADDRESS="$address"
        MEASURE_PEER_SOURCE="$source"
        MEASURE_PEER_FAMILY="$family"
        MEASURE_PEER_IFACE="$iface"
        MEASURE_PEER_PORT="$port"
        if ! path_lock_route_identity; then
            measure_clear_peer_lock
            return 1
        fi
        (( quiet )) || log INFO "已冻结测速路径: $peer -> $MEASURE_PEER_ADDRESS（IPv${MEASURE_PEER_FAMILY}, src $MEASURE_PEER_SOURCE, dev $MEASURE_PEER_IFACE${port:+, port $port}, path ${PATH_ROUTE_FINGERPRINT:0:12}）"
        return 0
    done <<< "$ordered"

    measure_clear_peer_lock
    (( quiet )) || {
        if [[ -n "$port" && $route_candidates -gt 0 && $service_candidates -eq 0 ]]; then
            die "测速对端 $peer:$port 没有可用的 IPv4/IPv6 iperf3 端点"
        else
            die "测速对端 $peer 没有能通过严格路由与来源地址核验的候选端点"
        fi
    }
    (( resolved_count > 0 )) || return "$IPERF_UNAVAILABLE_RC"
    return "$IPERF_UNAVAILABLE_RC"
}

measure_lock_requested_peer() {
    local peer="$1" port="$2" requested="$3" preferred_address="${4:-}" preferred_source="${5:-}"
    local expected_iface="$requested"
    # The wrapper may fail before measure_lock_peer is reached (for example an
    # invalid explicit interface); stale state must not survive that failure.
    measure_clear_peer_lock
    if [[ "$requested" != auto ]]; then
        expected_iface=$(detect_interface "$requested") || return 1
    fi
    measure_lock_peer "$peer" "$expected_iface" "$port" "$preferred_address" "$preferred_source"
}

measure_peer_route_guard() {
    local state iface source
    [[ -n "$MEASURE_PEER_ADDRESS" && -n "$MEASURE_PEER_SOURCE" &&
       ( "$MEASURE_PEER_FAMILY" == 4 || "$MEASURE_PEER_FAMILY" == 6 ) && -n "$MEASURE_PEER_IFACE" ]] || {
        die "正式测速尚未冻结对端地址、来源地址和出口网卡"
        return 1
    }
    if [[ -n "$MEASURE_IFACE" && "$MEASURE_IFACE" != "$MEASURE_PEER_IFACE" ]]; then
        die "测量网卡 $MEASURE_IFACE 与冻结出口 $MEASURE_PEER_IFACE 不一致"
        return 1
    fi
    state=$(measure_capture_route_state "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_IFACE" "$MEASURE_PEER_SOURCE") || {
        die "测速路径已漂移；拒绝继续并恢复操作前 qdisc"
        return 1
    }
    IFS=$'\t' read -r iface source <<< "$state"
    [[ "$iface" == "$MEASURE_PEER_IFACE" && "$source" == "$MEASURE_PEER_SOURCE" ]] || {
        die "测速路径已漂移；拒绝使用本次样本"
        return 1
    }
    path_verify_route_identity || {
        die "测速路由、网关、路由表、MTU 或 FIB 指纹已经漂移"
        return 1
    }
}

measure_require_sample_lock() {
    local peer="$1" port="${2:-}" iface
    if [[ -z "$MEASURE_PEER_ADDRESS" ]]; then
        iface="${MEASURE_IFACE:-auto}"
        measure_lock_peer "$peer" "$iface" "$port" || return $?
    elif [[ "$peer" != "$MEASURE_PEER_HOST" && "$peer" != "$MEASURE_PEER_ADDRESS" ]]; then
        die "样本对端 $peer 与冻结对端 $MEASURE_PEER_HOST/$MEASURE_PEER_ADDRESS 不一致"
        return 1
    fi
    if [[ -n "$port" && -z "$MEASURE_PEER_PORT" ]]; then
        measure_require_locked_port "$peer" "$port" || return $?
    elif [[ -n "$port" && -n "$MEASURE_PEER_PORT" && "$port" != "$MEASURE_PEER_PORT" ]]; then
        die "样本端口 $port 与冻结端口 $MEASURE_PEER_PORT 不一致"
        return 1
    fi
    measure_peer_route_guard
}

measure_require_locked_port() {
    local peer="$1" port="$2"
    measure_peer_route_guard || return 1
    if [[ -n "$MEASURE_PEER_PORT" && "$MEASURE_PEER_PORT" != "$port" ]]; then
        die "请求端口 $port 与冻结端口 $MEASURE_PEER_PORT 不一致"
        return 1
    fi
    if [[ -z "$MEASURE_PEER_PORT" ]] &&
       { ! peer_port_open "$MEASURE_PEER_ADDRESS" "$port" ||
         ! iperf_peer_usable "$MEASURE_PEER_ADDRESS" "$port" "$MEASURE_PEER_FAMILY" "$MEASURE_PEER_SOURCE"; }; then
        die "无法连接 $peer:$port（冻结地址 $MEASURE_PEER_ADDRESS / IPv${MEASURE_PEER_FAMILY}）"
        measure_clear_peer_lock
        return "$IPERF_UNAVAILABLE_RC"
    fi
    MEASURE_PEER_PORT="$port"
    measure_peer_route_guard
}

measure_append_locked_peer_summary() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    printf 'LOCKED_ADDRESS\t%s\nLOCKED_SOURCE\t%s\nLOCKED_INTERFACE\t%s\nLOCKED_FAMILY\t%s\nLOCKED_PORT\t%s\n' \
        "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_IFACE" "$MEASURE_PEER_FAMILY" "${MEASURE_PEER_PORT:-none}" >> "$file"
    path_profile_append_summary "$file"
}

peer_port_open() {
    local peer="$1" port="$2"
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$peer" "$port" >/dev/null 2>&1
}

iperf_peer_usable() {
    local peer="$1" port="$2" family="${3:-}" source="${4:-}" json rc=0 error bps
    local -a family_arg=() bind_arg=()
    [[ -z "$family" || "$family" == 4 || "$family" == 6 ]] || return 1
    [[ -z "$family" ]] || family_arg=("-$family")
    [[ -z "$source" ]] || bind_arg=(-B "$source")
    json=$(mktemp) || return 1
    if timeout 8 iperf3 "${family_arg[@]}" -c "$peer" "${bind_arg[@]}" -p "$port" -t 1 -P 1 -b 1M -J > "$json" 2>/dev/null; then
        error=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
        bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json" 2>/dev/null || printf '0\n')
        [[ -z "$error" ]] && is_decimal "$bps" && awk -v b="$bps" 'BEGIN {exit !(b>0)}' || rc=1
    else
        rc=$?
    fi
    rm -f -- "$json"
    return "$rc"
}

iperf_failure_is_unavailable() {
    local reason="${1,,}"
    case "$reason" in
        *server*busy*|*busy*running*a*test*|*unable*to*connect*|*connection*refused*|*connection*timed*out*|*connection*reset*|*control*socket*closed*|*network*is*unreachable*|*no*route*to*host*|*broken*pipe*|*temporarily*unavailable*) return 0 ;;
        *) return 1 ;;
    esac
}

percentile_95_numbers() {
    sort -n | awk '{a[NR]=$1} END {if(NR) {i=int((NR*95+99)/100); if(i<1)i=1; if(i>NR)i=NR; print a[i]}}'
}

max_numbers() { sort -n | tail -n 1; }

median_or_na() {
    if (($#)); then printf '%s\n' "$@" | median_numbers; else printf 'na\n'; fi
}

max_or_na() {
    if (($#)); then printf '%s\n' "$@" | max_numbers; else printf 'na\n'; fi
}

latency_stats_from_file() {
    local file="$1" values median p95
    values=$(sed -n -E 's/.*time[=<]([0-9]+([.][0-9]+)?)[[:space:]]*ms.*/\1/p' "$file" 2>/dev/null || true)
    if [[ -z "$values" ]]; then
        printf 'na\tna\n'
        return 0
    fi
    median=$(median_numbers <<< "$values")
    p95=$(percentile_95_numbers <<< "$values")
    printf '%s\t%s\n' "$median" "$p95"
}

cpu_snapshot() {
    local _ user nice system idle iowait irq softirq steal total idle_all value
    [[ -r /proc/stat ]] || { printf 'na\tna\tna\n'; return 0; }
    read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat || {
        printf 'na\tna\tna\n'
        return 0
    }
    for value in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "${steal:-0}"; do
        is_uint "$value" || { printf 'na\tna\tna\n'; return 0; }
    done
    total=$((user + nice + system + idle + iowait + irq + softirq + ${steal:-0}))
    idle_all=$((idle + iowait))
    printf '%s\t%s\t%s\n' "$total" "$idle_all" "${steal:-0}"
}

cpu_delta_metrics() {
    local before="$1" after="$2" total_before idle_before steal_before total_after idle_after steal_after
    local total_delta idle_delta steal_delta
    IFS=$'\t' read -r total_before idle_before steal_before <<< "$before"
    IFS=$'\t' read -r total_after idle_after steal_after <<< "$after"
    if ! is_uint "$total_before" || ! is_uint "$idle_before" || ! is_uint "$steal_before" ||
       ! is_uint "$total_after" || ! is_uint "$idle_after" || ! is_uint "$steal_after" ||
       (( total_after <= total_before )); then
        printf 'na\tna\n'
        return 0
    fi
    total_delta=$((total_after - total_before)); idle_delta=$((idle_after - idle_before)); steal_delta=$((steal_after - steal_before))
    (( idle_delta < 0 )) && idle_delta=0; (( steal_delta < 0 )) && steal_delta=0
    awk -v t="$total_delta" -v i="$idle_delta" -v s="$steal_delta" 'BEGIN {
        busy=(t-i)*100/t; if(busy<0)busy=0; if(busy>100)busy=100;
        steal=s*100/t; if(steal<0)steal=0; if(steal>100)steal=100;
        printf "%.2f\t%.2f\n", busy, steal
    }'
}

cpu_core_snapshot() {
    awk '/^cpu[0-9]+[[:space:]]/ {
        total=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; steal=$9;
        printf "%s\t%.0f\t%.0f\t%.0f\n", $1, total, idle, steal
    }' /proc/stat 2>/dev/null || true
}

cpu_core_delta_metrics() {
    local before="$1" after="$2"
    awk -v before="$before" -v after="$after" 'BEGIN {
        nb=split(before, b, "\n"); na=split(after, a, "\n"); found=0; peak_busy=0; peak_steal=0;
        for(i=1;i<=nb;i++) {n=split(b[i], f, "\t"); if(n==4) {bt[f[1]]=f[2]; bi[f[1]]=f[3]; bs[f[1]]=f[4]}}
        for(i=1;i<=na;i++) {
            n=split(a[i], f, "\t"); key=f[1]; if(n!=4 || !(key in bt)) continue;
            total=f[2]-bt[key]; idle=f[3]-bi[key]; steal=f[4]-bs[key]; if(total<=0) continue;
            busy=(total-idle)*100/total; if(busy<0)busy=0; if(busy>100)busy=100;
            stealp=steal*100/total; if(stealp<0)stealp=0; if(stealp>100)stealp=100;
            if(!found || busy>peak_busy)peak_busy=busy; if(!found || stealp>peak_steal)peak_steal=stealp; found=1;
        }
        if(found) printf "%.2f\t%.2f\n", peak_busy, peak_steal; else print "na\tna"
    }'
}

background_tx_percent() {
    local before="$1" after="$2" payload="$3"
    if ! is_uint "$before" || ! is_uint "$after" || ! is_uint "$payload" || (( after < before )); then
        printf 'na\n'
        return 0
    fi
    awk -v tx="$((after-before))" -v payload="$payload" 'BEGIN {
        # Permit link/IP/TCP overhead plus a small fixed control-traffic allowance.
        allowed=payload*1.12+65536;
        if(tx<=allowed || tx<=0) {printf "0.00\n"; exit}
        printf "%.2f\n", (tx-allowed)*100/tx
    }'
}

sample_is_contaminated() {
    local background="$1" steal="$2" busy="${3:-na}"
    local max_background="${BBRV3_MAX_BACKGROUND_TX_PERCENT:-15}" max_steal="${BBRV3_MAX_CPU_STEAL_PERCENT:-15}"
    local max_busy="${BBRV3_MAX_CPU_BUSY_PERCENT:-98}"
    is_decimal "$max_background" || max_background=15
    is_decimal "$max_steal" || max_steal=15
    is_decimal "$max_busy" || max_busy=98
    if is_decimal "$background" && awk -v v="$background" -v m="$max_background" 'BEGIN {exit !(v>m)}'; then return 0; fi
    if is_decimal "$steal" && awk -v v="$steal" -v m="$max_steal" 'BEGIN {exit !(v>m)}'; then return 0; fi
    if is_decimal "$busy" && awk -v v="$busy" -v m="$max_busy" 'BEGIN {exit !(v>m)}'; then return 0; fi
    return 1
}

iperf_sample() {
    local peer="$1" port="$2" duration="$3" parallel="$4" json error_file latency_file latency_pid=""
    local rc=0 reason="" bps bytes retrans goodput ratio retrans_per_gib loaded_median="na" loaded_p95="na"
    local tx_before=0 tx_after=0 background="na" cpu_before cpu_after cpu_busy="na" cpu_steal="na" contaminated=0
    local core_before core_after core_busy="na" core_steal="na" reason_parse_rc=0 cpu_metrics core_metrics latency_metrics
    local route_guard_rc=0
    local -a family_arg=()
    validate_peer "$peer" "$port" || return 1
    measure_require_sample_lock "$peer" "$port" || return $?
    family_arg=("-$MEASURE_PEER_FAMILY")
    json=$(mktemp) || return 1
    error_file=$(mktemp) || { rm -f -- "$json"; return 1; }
    latency_file=$(mktemp) || { rm -f -- "$json" "$error_file"; return 1; }
    if [[ "$(uname -s 2>/dev/null || true)" == Linux ]] && command_exists ping; then
        ping "${family_arg[@]}" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE" \
            -n -i 0.2 -W 1 -c "$((duration * 5))" -- "$MEASURE_PEER_ADDRESS" > "$latency_file" 2>/dev/null &
        latency_pid=$!
    fi
    if [[ -n "$MEASURE_IFACE" ]]; then tx_before=$(interface_counter "$MEASURE_IFACE" tx_bytes); fi
    cpu_before=$(cpu_snapshot)
    core_before=$(cpu_core_snapshot)
    if timeout "$((duration + 20))" iperf3 "${family_arg[@]}" -c "$MEASURE_PEER_ADDRESS" -B "$MEASURE_PEER_SOURCE" \
        -p "$port" -t "$duration" -P "$parallel" -J > "$json" 2> "$error_file"; then
        if [[ -s "$json" ]]; then reason=$(jq -r '.error // empty' "$json" 2>/dev/null) || reason_parse_rc=$?; fi
        [[ -z "$reason" ]] || rc=1
    else
        rc=$?
        if [[ -s "$json" ]]; then reason=$(jq -r '.error // empty' "$json" 2>/dev/null) || reason_parse_rc=$?; fi
        [[ -n "$reason" ]] || reason=$(<"$error_file")
        [[ -n "$reason" ]] || { if (( rc == 124 )); then reason="连接或测试超时"; else reason="iperf3 退出码 $rc"; fi; }
    fi
    cpu_after=$(cpu_snapshot)
    core_after=$(cpu_core_snapshot)
    if [[ -n "$MEASURE_IFACE" ]]; then tx_after=$(interface_counter "$MEASURE_IFACE" tx_bytes); fi
    if [[ -n "$latency_pid" ]]; then
        if (( rc != 0 )); then kill "$latency_pid" 2>/dev/null || true; fi
        wait "$latency_pid" 2>/dev/null || true
    fi
    measure_peer_route_guard || route_guard_rc=$?
    if (( route_guard_rc != 0 )); then
        rm -f -- "$json" "$error_file" "$latency_file"
        log ERR "iperf3 $peer:$port 完成后检测到路径漂移；本样本无效"
        return 1
    fi
    rm -f -- "$error_file"
    if (( rc != 0 )); then
        reason=${reason//$'\n'/ }
        reason=${reason//$'\r'/}
        reason=${reason:0:240}
        log WARN "iperf3 $peer:$port（$MEASURE_PEER_ADDRESS）测试失败: $reason"
        rm -f -- "$json" "$latency_file"
        if (( rc == 124 )) || iperf_failure_is_unavailable "$reason"; then return "$IPERF_UNAVAILABLE_RC"; fi
        return 1
    fi
    if (( reason_parse_rc != 0 )); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    if ! bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json") ||
       ! bytes=$(jq -r '.end.sum_sent.bytes // .end.sum.bytes // 0' "$json") ||
       ! retrans=$(jq -r '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0' "$json"); then
        log WARN "iperf3 $peer:$port 返回的 JSON 无法解析"
        rm -f -- "$json" "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    rm -f -- "$json"
    if ! is_decimal "$bps" || ! is_uint "$bytes" || ! is_uint "$retrans" || (( bytes == 0 )) || ! awk -v b="$bps" 'BEGIN {exit !(b>0)}'; then
        log WARN "iperf3 $peer:$port 返回的 JSON 结果不完整"
        rm -f -- "$latency_file"
        return "$IPERF_DATA_RC"
    fi
    goodput=$(awk -v b="$bps" 'BEGIN {printf "%.2f", b/1000000}')
    # An estimate, not packet loss: iperf retransmits / estimated MSS-sized segments.
    ratio=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {n=b/1448; if(n<1)n=1; printf "%.5f", r*100/n}')
    retrans_per_gib=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {printf "%.3f", r*1073741824/b}')
    latency_metrics=$(latency_stats_from_file "$latency_file"); rm -f -- "$latency_file"
    IFS=$'\t' read -r loaded_median loaded_p95 <<< "$latency_metrics"
    cpu_metrics=$(cpu_delta_metrics "$cpu_before" "$cpu_after")
    IFS=$'\t' read -r cpu_busy cpu_steal <<< "$cpu_metrics"
    core_metrics=$(cpu_core_delta_metrics "$core_before" "$core_after")
    IFS=$'\t' read -r core_busy core_steal <<< "$core_metrics"
    if is_decimal "$core_busy"; then
        if is_decimal "$cpu_busy"; then cpu_busy=$(printf '%s\n%s\n' "$cpu_busy" "$core_busy" | max_numbers); else cpu_busy="$core_busy"; fi
    fi
    if is_decimal "$core_steal"; then
        if is_decimal "$cpu_steal"; then cpu_steal=$(printf '%s\n%s\n' "$cpu_steal" "$core_steal" | max_numbers); else cpu_steal="$core_steal"; fi
    fi
    if [[ -n "$MEASURE_IFACE" ]]; then background=$(background_tx_percent "$tx_before" "$tx_after" "$bytes"); fi
    sample_is_contaminated "$background" "$cpu_steal" "$cpu_busy" && contaminated=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$goodput" "$retrans" "$bytes" "$ratio" "$retrans_per_gib" "$loaded_median" "$loaded_p95" \
        "$background" "$cpu_busy" "$cpu_steal" "$contaminated"
}

median_numbers() { sort -n | awk '{a[NR]=$1} END {if(NR) {if(NR%2) print a[(NR+1)/2]; else printf "%.5f\n", (a[NR/2]+a[NR/2+1])/2}}'; }

relative_spread_percent() {
    local count values median deviations
    values=$(printf '%s\n' "$@" | sort -n); count=$#
    median=$(median_numbers <<< "$values")
    if (( count < 3 )); then
        awk -v lo="$(head -n 1 <<< "$values")" -v hi="$(tail -n 1 <<< "$values")" -v m="$median" \
            'BEGIN {if(m<=0) print "999.00"; else printf "%.2f\n", (hi-lo)*100/m}'
        return 0
    fi
    deviations=$(awk -v m="$median" '{d=$1-m; if(d<0)d=-d; print d}' <<< "$values")
    awk -v mad="$(median_numbers <<< "$deviations")" -v m="$median" \
        'BEGIN {if(m<=0) print "999.00"; else printf "%.2f\n", mad*1.4826*100/m}'
}

bufferbloat_delta_ms() {
    local idle="$1" loaded="$2"
    if ! is_decimal "$idle" || ! is_decimal "$loaded"; then printf 'na\n'; return 0; fi
    awk -v i="$idle" -v l="$loaded" 'BEGIN {d=l-i; if(d<0)d=0; printf "%.2f\n", d}'
}

measurement_confidence() {
    local sample_count="$1" spread="$2" loaded_p95="$3" contaminated="$4" failovers="${5:-0}" path_score="${6:-na}"
    local score=100 grade reason path_penalty=0
    local -a reasons=()
    is_uint "$sample_count" || sample_count=0
    if ! is_uint "$contaminated"; then
        contaminated=0; score=$((score - 15)); reasons+=(contamination-unknown)
    fi
    is_uint "$failovers" || failovers=0
    if (( sample_count < 2 )); then score=$((score - 25)); reasons+=(single-sample); fi
    if ! is_decimal "$spread"; then
        score=$((score - 20)); reasons+=(spread-unknown)
    elif awk -v s="$spread" 'BEGIN {exit !(s>10)}'; then
        score=$((score - 40)); reasons+=(very-unstable)
    elif awk -v s="$spread" 'BEGIN {exit !(s>6)}'; then
        score=$((score - 20)); reasons+=(unstable)
    fi
    if ! is_decimal "$loaded_p95"; then score=$((score - 15)); reasons+=(loaded-rtt-unavailable); fi
    if (( contaminated )); then score=$((score - 50)); reasons+=(contaminated); fi
    if (( failovers > 0 )); then score=$((score - 10)); reasons+=(peer-failover); fi
    if is_uint "$path_score" && (( path_score <= 100 )); then
        if (( path_score < 40 )); then path_penalty=35; reasons+=(path-unsafe)
        elif (( path_score < 65 )); then path_penalty=20; reasons+=(path-low-confidence)
        elif (( path_score < 90 )); then path_penalty=10; reasons+=(path-variable)
        fi
        score=$((score - path_penalty))
    fi
    (( score < 0 )) && score=0
    if (( score >= 90 )); then grade=high; elif (( score >= 65 )); then grade=medium; else grade=low; fi
    if ((${#reasons[@]})); then
        local IFS=,
        reason="${reasons[*]}"
    else
        reason=clean
    fi
    printf '%s\t%s\t%s\n' "$score" "$grade" "$reason"
}

compare_verdict() {
    local fq_goodput="$1" shaped_goodput="$2" fq_bloat="$3" shaped_bloat="$4" fq_retrans_gib="$5" shaped_retrans_gib="$6"
    if awk -v f="$fq_goodput" -v s="$shaped_goodput" 'BEGIN {exit !(f>0 && s<f*0.90)}'; then
        printf 'regressed\n'
    elif is_decimal "$fq_bloat" && is_decimal "$shaped_bloat" &&
         awk -v f="$fq_bloat" -v s="$shaped_bloat" -v fg="$fq_goodput" -v sg="$shaped_goodput" \
             'BEGIN {exit !(fg>0 && sg>=fg*0.90 && ((f>=5 && s<=f*0.80) || (f<5 && s<f)))}'; then
        printf 'improved\n'
    elif is_decimal "$fq_retrans_gib" && is_decimal "$shaped_retrans_gib" &&
         awk -v f="$fq_retrans_gib" -v s="$shaped_retrans_gib" -v fg="$fq_goodput" -v sg="$shaped_goodput" \
             'BEGIN {exit !(fg>0 && sg>=fg*0.90 && f>0 && s<=f*0.70)}'; then
        printf 'improved\n'
    else
        printf 'neutral\n'
    fi
}

sample_repeated() {
    local peer="$1" port="$2" duration="$3" parallel="$4" count="$5" label="$6"
    local max_count="${7:-$count}" stability_threshold="${8:-0}"
    local -a goodputs=() retrans=() bytes=() ratios=() retrans_gib=() loaded_medians=() loaded_p95s=()
    local -a backgrounds=() cpu_busies=() cpu_steals=() contaminations=()
    local row i attempt sample_rc=0 attempts="${BBRV3_IPERF_ATTEMPTS:-3}" target_count="$count" contamination_retry
    local contamination_retries="${BBRV3_CONTAMINATION_RETRIES:-1}"
    local g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated spread="0.00" bloat
    is_uint "$attempts" && (( attempts >= 1 && attempts <= 5 )) || attempts=3
    is_uint "$contamination_retries" && (( contamination_retries <= 3 )) || contamination_retries=1
    is_uint "$max_count" && (( max_count >= count && max_count <= 5 )) || max_count="$count"
    is_decimal "$stability_threshold" || stability_threshold=0
    for ((i=1; i<=target_count; i++)); do
        log INFO "$label: ${duration}s × ${parallel} flow(s), sample ${i}/${target_count}"
        contamination_retry=0
        while true; do
            row=""
            for ((attempt=1; attempt<=attempts; attempt++)); do
                if row=$(iperf_sample "$peer" "$port" "$duration" "$parallel"); then
                    sample_rc=0
                    break
                else
                    sample_rc=$?
                fi
                if (( sample_rc != IPERF_UNAVAILABLE_RC )); then
                    die "iperf3 本地执行或结果解析失败（exit $sample_rc），不会切换公共对端"
                    return "$sample_rc"
                fi
                (( attempt < attempts )) && { log WARN "2 秒后重试（${attempt}/${attempts}）"; sleep 2; }
            done
            [[ -n "$row" ]] || {
                if (( sample_rc == 0 )); then
                    die "iperf3 成功退出但没有产生样本"
                    return "$IPERF_DATA_RC"
                fi
                die "当前 iperf3 对端连续 ${attempts} 次不可用"
                return "$sample_rc"
            }
            IFS=$'\t' read -r g r b l rpg loaded_med loaded_tail background cpu_busy cpu_steal contaminated <<< "$row"
            rpg="${rpg:-$(awk -v rv="$r" -v bv="$b" 'BEGIN {if(bv>0) printf "%.3f", rv*1073741824/bv; else print "0.000"}')}"
            loaded_med="${loaded_med:-na}"; loaded_tail="${loaded_tail:-na}"; background="${background:-na}"
            cpu_busy="${cpu_busy:-na}"; cpu_steal="${cpu_steal:-na}"; contaminated="${contaminated:-0}"
            bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$loaded_tail")
            [[ -n "$MEASURE_RESULT_FILE" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(utc_now)" "$label" "$g" "$r" "$b" "$l" "$rpg" "$MEASURE_IDLE_RTT_MS" "$loaded_med" "$loaded_tail" \
                "$bloat" "$background" "$cpu_busy" "$cpu_steal" "$contaminated" >> "$MEASURE_RESULT_FILE"
            if [[ "$contaminated" == 1 && "$contamination_retry" -lt "$contamination_retries" ]]; then
                ((contamination_retry+=1))
                log WARN "样本受到后台流量、CPU 饱和或 steal 污染，2 秒后重采（${contamination_retry}/${contamination_retries}）"
                sleep 2
                continue
            fi
            break
        done
        if [[ "$contaminated" == 1 ]]; then
            die "连续样本受到后台流量、CPU 饱和或 steal 污染；停止测量以避免误判拐点"
            return "$IPERF_CONTAMINATED_RC"
        fi
        goodputs+=("$g"); retrans+=("$r"); bytes+=("$b"); ratios+=("$l"); retrans_gib+=("$rpg")
        is_decimal "$loaded_med" && loaded_medians+=("$loaded_med")
        is_decimal "$loaded_tail" && loaded_p95s+=("$loaded_tail")
        is_decimal "$background" && backgrounds+=("$background")
        is_decimal "$cpu_busy" && cpu_busies+=("$cpu_busy")
        is_decimal "$cpu_steal" && cpu_steals+=("$cpu_steal")
        contaminations+=("$contaminated")
        spread=$(relative_spread_percent "${goodputs[@]}")
        if (( i >= count && i < max_count )) && awk -v s="$spread" -v t="$stability_threshold" 'BEGIN {exit !(t>0 && s>t)}'; then
            target_count=$((i + 1))
            log WARN "吞吐离散度 ${spread}% 超过 ${stability_threshold}%，追加第 ${target_count} 个样本"
        fi
        (( i < target_count )) && sleep 2
    done
    if awk -v s="$spread" -v t="$stability_threshold" 'BEGIN {exit !(t>0 && s>t)}'; then
        die "${target_count} 个样本后吞吐离散度仍为 ${spread}%（上限 ${stability_threshold}%）；停止测量以避免使用不稳定结果"
        return "$IPERF_UNSTABLE_RC"
    fi
    bloat=$(bufferbloat_delta_ms "$MEASURE_IDLE_RTT_MS" "$(median_or_na "${loaded_p95s[@]}")")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(printf '%s\n' "${goodputs[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans[@]}" | median_numbers)" \
        "$(printf '%s\n' "${bytes[@]}" | median_numbers)" \
        "$(printf '%s\n' "${ratios[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans_gib[@]}" | median_numbers)" \
        "$(median_or_na "${loaded_medians[@]}")" "$(median_or_na "${loaded_p95s[@]}")" \
        "$(max_or_na "${backgrounds[@]}")" "$(max_or_na "${cpu_busies[@]}")" "$(max_or_na "${cpu_steals[@]}")" \
        "$(printf '%s\n' "${contaminations[@]}" | max_numbers)" "$spread" "$target_count" "$bloat"
}

loss_spike() {
    local value="$1" threshold="$2" base="$3"
    awk -v v="$value" -v t="$threshold" -v b="$base" 'BEGIN {
        if (v <= t) exit 1;
        if (b > 0 && v < b*5) exit 1;
        exit 0
    }'
}

minimum_efficiency_ratio() {
    local goodput="$1" rate="$2"
    awk -v g="$goodput" -v r="$rate" 'BEGIN {
        if (r <= 0) {print "0.90"; exit}
        e=(g/r)*0.98;
        if (e < 0.75) e=0.75;
        if (e > 0.98) e=0.98;
        printf "%.5f\n", e
    }'
}

throughput_stalled() {
    local goodput="$1" previous_goodput="$2" rate="$3" previous_rate="$4" min_efficiency="$5"
    awk -v g="$goodput" -v p="$previous_goodput" -v r="$rate" -v pr="$previous_rate" -v e="$min_efficiency" 'BEGIN {
        delta=r-pr; gain=g-p;
        exit !(delta>=1 && gain<delta*0.25 && g<r*e)
    }'
}

measurement_sample_acceptable() {
    local goodput="$1" loss="$2" rate="$3" min_efficiency="$4" threshold="$5" baseline_loss="$6"
    loss_spike "$loss" "$threshold" "$baseline_loss" && return 1
    awk -v g="$goodput" -v r="$rate" -v e="$min_efficiency" 'BEGIN {exit !(r<=0 || g>=r*e)}'
}

estimate_sweep_bytes() {
    local high="$1" duration="$2" tests="$3"
    awk -v r="$high" -v d="$duration" -v n="$tests" 'BEGIN {printf "%.0f", r*1000000/8*d*n*1.08}'
}

new_measure_run() {
    local kind="$1" dir base suffix=0
    ensure_state_layout || return 1
    base="$HISTORY_DIR/$(history_stamp)-${kind}"
    dir="$base"
    while [[ -e "$dir" ]]; do
        ((suffix+=1))
        dir="${base}-${suffix}"
    done
    mkdir "$dir" || return 1
    chmod 0700 "$dir"
    MEASURE_RESULT_FILE="$dir/samples.tsv"
    MEASURE_RUN_DIR="$dir"
    printf 'TIME\tLABEL\tGOODPUT_MBIT\tRETRANSMITS\tBYTES\tRETRANS_RATIO_EST_PERCENT\tRETRANS_PER_GIB\tIDLE_RTT_MS\tLOADED_RTT_MEDIAN_MS\tLOADED_RTT_P95_MS\tBUFFERBLOAT_P95_MS\tBACKGROUND_TX_PERCENT\tCPU_BUSY_PERCENT\tCPU_STEAL_PERCENT\tCONTAMINATED\n' > "$MEASURE_RESULT_FILE"
}

measure_path_profile() {
    require_root || return 1; acquire_lock || return 1
    require_commands ip ping find sort awk || return 1
    local peer="$1" requested="${2:-auto}" samples="${3:-7}" pmtu_enabled="${4:-1}"
    local iface dir rc=0
    validate_peer "$peer" 5201 || return 1
    is_uint "$samples" && (( samples >= 3 && samples <= 20 )) || { die "路径画像样本数必须是 3–20"; return 1; }
    [[ "$pmtu_enabled" == 0 || "$pmtu_enabled" == 1 ]] || { die "PMTU 开关只能是 0/1"; return 1; }
    measure_lock_requested_peer "$peer" "" "$requested" || return $?
    iface="$MEASURE_PEER_IFACE"
    new_measure_run path || { measure_clear_peer_lock; return 1; }
    dir="$MEASURE_RUN_DIR"
    rm -f -- "$MEASURE_RESULT_FILE"; MEASURE_RESULT_FILE=""
    if measure_set_latency_baseline "$peer" "$samples" "$pmtu_enabled"; then
        printf 'TYPE\tpath\nPEER\t%s\nINTERFACE\t%s\n' "$peer" "$iface" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if (( rc == 0 )); then
            path_profile_report
            log INFO "路径画像: $dir"
        fi
    else
        rc=$?
    fi
    measure_clear_peer_lock
    return "$rc"
}

measure_probe() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" preferred_address="${6:-}" preferred_source="${7:-}"
    local iface dir row rc=0 speed estimate
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    fi
    new_measure_run probe || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    measure_begin "$iface" || return 1
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 unshaped 3 6); then
        confidence=$(measurement_confidence "$(cut -f13 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f7 <<< "$row")" "$(cut -f11 <<< "$row")" 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nRETRANS_PER_GIB\t%s\nIDLE_RTT_MS\t%s\nLOADED_RTT_P95_MS\t%s\nBUFFERBLOAT_P95_MS\t%s\nGOODPUT_SPREAD_PERCENT\t%s\nSAMPLE_COUNT\t%s\nBACKGROUND_TX_PERCENT_MAX\t%s\nCPU_BUSY_PERCENT_MAX\t%s\nCPU_STEAL_PERCENT_MAX\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" "$(cut -f5 <<< "$row")" \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f7 <<< "$row")" "$(cut -f14 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f13 <<< "$row")" \
            "$(cut -f8 <<< "$row")" "$(cut -f9 <<< "$row")" "$(cut -f10 <<< "$row")" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "可用带宽中位数: $(cut -f1 <<< "$row") Mbit/s，重传 $(cut -f5 <<< "$row") 次/GiB，负载 RTT p95 $(cut -f7 <<< "$row") ms"
        log INFO "测量置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})"
        log INFO "结果: $dir"
    else rc=$?; fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_sweep() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" nominal="$4" low="$5" high="$6" step="$7"
    local duration="$8" parallel="$9" margin="${10}" threshold="${11}" force_scan="${12}" cap="${13}"
    local result_mode="${14:-manual}"
    local preferred_address="${15:-}" preferred_source="${16:-}"
    local iface dir baseline_row baseline_gp baseline_loss base_row base_gp base_loss rate row gp loss
    local last_ok="" last_ok_gp="" broke_at="" fine_start fine_step recommend="" candidate="" confirm_row confirm_gp="" confirm_loss=""
    local min_efficiency="0.90" confirmed=0 reject_reason="" estimated tests rc=0 no_knee=0 above_cap=0 baseline_duration
    local auto_cap=0 nominal_was_auto=0 observed_cap
    local confidence_row confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    [[ "$result_mode" == manual || "$result_mode" == auto ]] || { die "扫描结果模式只支持 manual/auto"; return 1; }
    for value in "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$force_scan" "$cap"; do is_uint "$value" || { die "扫描参数必须为非负整数"; return 1; }; done
    is_decimal "$threshold" || { die "loss threshold 必须是数字"; return 1; }
    (( duration >= 3 && duration <= 120 && parallel >= 1 && parallel <= 32 && margin <= 25 && force_scan <= 1 &&
       (cap == 0 || (cap >= 100 && cap <= 1000000)) )) || { die "扫描参数超出安全范围"; return 1; }
    (( nominal == 0 )) && nominal_was_auto=1
    if (( cap == 0 )) || [[ "$result_mode" == auto ]]; then auto_cap=1; fi
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    if (( cap == 0 )); then cap=$(recommended_scan_cap "$iface" "$nominal") || return 1; fi
    qdisc_guard "$iface" || return 1
    hardware_profile_values "$iface" "$nominal" || return 1
    new_measure_run sweep || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate "$force_scan" || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1

    baseline_duration="$duration"; ((baseline_duration>5)) && baseline_duration=5
    if ! apply_fq "$iface"; then
        rc=1
    elif baseline_row=$(sample_repeated "$peer" "$port" "$baseline_duration" 1 2 unshaped 3 6); then
        baseline_gp=$(cut -f1 <<< "$baseline_row"); baseline_loss=$(cut -f4 <<< "$baseline_row")
        if (( auto_cap )); then
            if observed_cap=$(expanded_scan_cap "$cap" "$baseline_gp"); then
                if (( observed_cap > cap )); then
                    log INFO "根据不限速基准将扫描上限从 ${cap} 调整为 ${observed_cap} Mbit/s"
                    cap="$observed_cap"
                fi
            else
                rc=$?
            fi
        fi
        if (( rc == 0 )); then
            if awk -v g="$baseline_gp" -v c="$cap" 'BEGIN {exit !(g>c)}'; then
                above_cap=1; no_knee=1
                log WARN "不限速单流达到 ${baseline_gp} Mbit/s，超过扫描上限 ${cap} Mbit/s；跳过整形扫描"
            fi
            (( nominal > 0 )) || nominal=$(awk -v g="$baseline_gp" 'BEGIN {printf "%d", g+0.5}')
            if (( nominal_was_auto )) && [[ "$result_mode" == auto ]]; then
                if duration=$(recommended_measure_duration "$iface" "$nominal"); then :; else rc=$?; fi
            fi
        fi
        if (( rc == 0 )); then
            (( low > 0 )) || low=$(awk -v g="$baseline_gp" 'BEGIN {v=g*0.80; if(v<1)v=1; printf "%d", v}')
            (( high > 0 )) || high=$(awk -v g="$baseline_gp" 'BEGIN {v=g*1.30; if(v<2)v=2; printf "%d", v}')
            (( step > 0 )) || { step=$((nominal / 20)); ((step < 5)) && step=5; }
            if (( ! above_cap && high > cap )); then
                log WARN "扫描上界 ${high} Mbit/s 超过硬上限 ${cap} Mbit/s，已收敛到硬上限"
                high="$cap"
            fi
            if (( ! above_cap && low >= cap )); then
                die "扫描下界 ${low} Mbit/s 必须低于硬上限 ${cap} Mbit/s"
                rc=1
            elif (( high <= low )); then
                die "扫描上界必须大于下界"
                rc=1
            fi
        fi
    else
        rc=$?
    fi

    if (( rc == 0 && (step <= 0 || high <= low) )); then
        die "无法根据基准样本生成有效扫描区间"
        rc=1
    fi

    if (( rc == 0 )); then
        # Baseline, low-rate reference and confirmation may each add a third
        # sample when the first pair is unstable.
        tests=$((3 + 3 + (high-low)/step + 4 + 3))
        estimated=$(estimate_sweep_bytes "$high" "$duration" "$tests")
        log INFO "计划最多采集 $tests 个样本、产生约 $(human_bytes "$estimated") 出站流量（不含失败重试）"

        if (( above_cap )); then
            :
        elif (( ! force_scan )) && awk -v v="$baseline_loss" -v t="$threshold" 'BEGIN {limit=t*10; if(limit<1)limit=1; exit !(v>limit)}'; then
            no_knee=1
            log WARN "不限速路径重传估算 ${baseline_loss}% 过高，无法可靠定位 policer；更换对端或使用 --force-scan"
        else
            apply_shaping "$iface" "$low" || rc=$?
            if (( rc == 0 )); then
                base_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "rate-${low}" 3 6) || rc=$?
                base_gp=$(cut -f1 <<< "${base_row:-$'0\t0\t0\t0'}")
                base_loss=$(cut -f4 <<< "${base_row:-$'0\t0\t0\t0'}")
                min_efficiency=$(minimum_efficiency_ratio "$base_gp" "$low")
                log INFO "低速档效率基准: ${base_gp}/${low}，后续最低可接受效率比 ${min_efficiency}"
            fi
            if (( rc == 0 )) && loss_spike "$base_loss" "$threshold" 0; then
                die "扫描下界 ${low} Mbit 已有明显重传，无法建立干净本底；请降低 --low 或更换 peer"
                rc=2
            fi
            if (( rc == 0 )); then
                local previous_gp previous_rate stall_count=0 stalled_rate=""
                last_ok="$low"
                last_ok_gp="$base_gp"; previous_gp="$base_gp"; previous_rate="$low"
                for ((rate=low+step; rate<=high; rate+=step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "rate-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%%\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    if throughput_stalled "$gp" "$previous_gp" "$rate" "$previous_rate" "$min_efficiency"; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; last_ok_gp="$gp"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$broke_at" ]]; then
                fine_step=$((step / 5)); ((fine_step < 1)) && fine_step=1
                fine_start=$((last_ok + fine_step))
                previous_gp="$last_ok_gp"; previous_rate="$last_ok"; stall_count=0; stalled_rate=""
                for ((rate=fine_start; rate<broke_at; rate+=fine_step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "refine-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%% (refine)\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    if throughput_stalled "$gp" "$previous_gp" "$rate" "$previous_rate" "$min_efficiency"; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; last_ok_gp="$gp"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$last_ok" && -n "$broke_at" ]]; then
                candidate=$(( last_ok * (100-margin) / 100 )); ((candidate < 1)) && candidate=1
                apply_shaping "$iface" "$candidate" || rc=$?
                if (( rc == 0 )); then
                    confirm_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "confirm-${candidate}" 3 6) || rc=$?
                    confirm_gp=$(cut -f1 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    confirm_loss=$(cut -f4 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    if (( rc == 0 )) && measurement_sample_acceptable "$confirm_gp" "$confirm_loss" "$candidate" "$min_efficiency" "$threshold" "$base_loss"; then
                        recommend="$candidate"; confirmed=1
                    elif (( rc == 0 )); then
                        reject_reason="confirmation-failed"
                        log WARN "候选档 ${candidate} Mbit 复测未通过吞吐/重传门槛，不生成推荐值"
                    fi
                fi
            elif (( rc == 0 )); then
                no_knee=1
                log WARN "扫描到上界仍未发现拐点，不建议基于本次结果启用整形"
            fi
        fi
    fi

    if (( rc == 0 )); then
        printf 'TYPE\tsweep\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nHARDWARE_CLASS\t%s\nLINK_MBIT\t%s\nRX_QUEUES\t%s\nTX_QUEUES\t%s\nSCAN_CAP_MBIT\t%s\nSAMPLE_DURATION_SECONDS\t%s\nUNSHAPED_MBIT\t%s\nBASE_RETRANS_RATIO_EST_PERCENT\t%s\nCLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t%s\nLOW\t%s\nHIGH\t%s\nSTEP\t%s\nMIN_EFFICIENCY_RATIO\t%s\nLAST_OK\t%s\nBROKE_AT\t%s\nCANDIDATE\t%s\nCONFIRM_MBIT\t%s\nCONFIRM_RETRANS_RATIO_EST_PERCENT\t%s\nCONFIRMED\t%s\nREJECT_REASON\t%s\nRECOMMEND\t%s\nMARGIN_PERCENT\t%s\nNO_KNEE\t%s\nABOVE_CAP\t%s\n' \
            "$peer" "$port" "$iface" "$HARDWARE_CLASS" "$HARDWARE_LINK_MBIT" "$HARDWARE_RX_QUEUES" "$HARDWARE_TX_QUEUES" "$cap" "$duration" \
            "${baseline_gp:-}" "${baseline_loss:-}" "${base_loss:-0}" "$low" "$high" "$step" "$min_efficiency" "${last_ok:-}" "${broke_at:-}" "${candidate:-}" "${confirm_gp:-}" "${confirm_loss:-}" "$confirmed" "${reject_reason:-}" "${recommend:-}" "$margin" "$no_knee" "$above_cap" > "$dir/summary.tsv"
        confidence_row="${confirm_row:-${baseline_row:-}}"
        if [[ -n "$confidence_row" ]]; then
            confidence=$(measurement_confidence "$(cut -f13 <<< "$confidence_row")" "$(cut -f12 <<< "$confidence_row")" "$(cut -f7 <<< "$confidence_row")" "$(cut -f11 <<< "$confidence_row")" 0 "$PATH_PROFILE_SCORE")
            IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        else
            confidence_score=0; confidence_grade=low; confidence_reasons=no-usable-sample
        fi
        printf 'IDLE_RTT_MS\t%s\nUNSHAPED_RETRANS_PER_GIB\t%s\nUNSHAPED_LOADED_RTT_P95_MS\t%s\nUNSHAPED_BUFFERBLOAT_P95_MS\t%s\nUNSHAPED_BACKGROUND_TX_PERCENT_MAX\t%s\nUNSHAPED_CPU_BUSY_PERCENT_MAX\t%s\nUNSHAPED_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_RETRANS_PER_GIB\t%s\nCONFIRM_LOADED_RTT_P95_MS\t%s\nCONFIRM_BUFFERBLOAT_P95_MS\t%s\nCONFIRM_BACKGROUND_TX_PERCENT_MAX\t%s\nCONFIRM_CPU_BUSY_PERCENT_MAX\t%s\nCONFIRM_CPU_STEAL_PERCENT_MAX\t%s\nCONFIRM_GOODPUT_SPREAD_PERCENT\t%s\nCONFIRM_SAMPLE_COUNT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f5 <<< "${baseline_row:-}")" "$(cut -f7 <<< "${baseline_row:-}")" "$(cut -f14 <<< "${baseline_row:-}")" \
            "$(cut -f8 <<< "${baseline_row:-}")" "$(cut -f9 <<< "${baseline_row:-}")" "$(cut -f10 <<< "${baseline_row:-}")" \
            "$(cut -f5 <<< "${confirm_row:-}")" "$(cut -f7 <<< "${confirm_row:-}")" "$(cut -f14 <<< "${confirm_row:-}")" \
            "$(cut -f8 <<< "${confirm_row:-}")" "$(cut -f9 <<< "${confirm_row:-}")" "$(cut -f10 <<< "${confirm_row:-}")" \
            "$(cut -f12 <<< "${confirm_row:-}")" "$(cut -f13 <<< "${confirm_row:-}")" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" >> "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if [[ -n "${recommend:-}" ]]; then
            log OK "扫描完成: last clean=${last_ok} Mbit, break=${broke_at:-above-range} Mbit, 推荐=${recommend} Mbit"
            if [[ "$result_mode" == auto ]]; then
                log INFO "候选档已通过扫描确认；最终单双流复验通过后才会持久化"
            else
                log INFO "确认业务表现后执行: ${0##*/} tc enable ${recommend} --knee ${broke_at:-0} --margin ${margin} --interface ${requested}"
            fi
        fi
        log INFO "扫描置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})"
        log INFO "完整结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

measure_path_check() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" preferred_address="${5:-}" preferred_source="${6:-}"
    local iface dir row="" gp="" loss="" rc=0 accepted=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate > 0 )) || { die "路径检查速率无效"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    new_measure_run path-check || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate 0 || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1
    log INFO "路径预检: 临时整形 ${rate} Mbit/s，检查对端是否足以承载测量"
    if ! apply_shaping "$iface" "$rate"; then
        rc=1
    elif row=$(sample_repeated "$peer" "$port" 5 1 1 path-check); then
        gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
        if awk -v g="$gp" -v r="$rate" 'BEGIN {exit !(g < r*0.60)}'; then
            log ERR "路径预检仅达到 ${gp} Mbit/s，明显低于 ${rate} Mbit/s；更换更近对端后重试"
            rc=2
        elif loss_spike "$loss" 0.5 0; then
            log ERR "路径预检重传比例过高 (${loss}%)；本次对端不适合寻找 policer 拐点"
            rc=2
        else
            accepted=1
            log OK "路径预检通过: ${gp} Mbit/s，重传估算 ${loss}%"
        fi
    else
        rc=$?
    fi
    if [[ -n "$row" ]]; then
        printf 'TYPE\tpath-check\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nACCEPTED\t%s\n' \
            "$peer" "$port" "$iface" "$rate" "$gp" "$loss" "$accepted" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log INFO "路径预检结果: $dir"
    fi
    measure_restore || rc=$?
    return "$rc"
}

measure_verify() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="${4:-8}" expected_rate="${5:-0}" min_efficiency="${6:-0.90}"
    local baseline_loss="${7:-0}" threshold="${8:-0.1}" iface dir one multi one_gp one_loss multi_gp multi_loss rc=0 accepted=1 reject_reason=""
    local preferred_address="${9:-}" preferred_source="${10:-}"
    local multi_parallel
    local one_count multi_count combined_count one_spread multi_spread combined_spread combined_loaded combined_contaminated
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && (( duration >= 3 && duration <= 120 )) || { die "verify duration 超出安全范围"; return 1; }
    is_uint "$expected_rate" && (( expected_rate <= 1000000 )) || { die "verify 期望速率无效"; return 1; }
    is_decimal "$min_efficiency" && is_decimal "$baseline_loss" && is_decimal "$threshold" || { die "verify 验收参数无效"; return 1; }
    awk -v e="$min_efficiency" -v b="$baseline_loss" -v t="$threshold" 'BEGIN {exit !(e>0 && e<=1 && b>=0 && b<=100 && t>=0 && t<=100)}' || {
        die "verify 验收参数超出安全范围"
        return 1
    }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    multi_parallel=$(recommended_verify_flows "$iface" "$expected_rate") || return 1
    new_measure_run verify || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    path_profile_tuning_gate 0 || {
        rc=$?
        measure_clear_peer_lock
        return "$rc"
    }
    measure_begin "$iface" || return 1
    one=$(sample_repeated "$peer" "$port" "$duration" 1 2 verify-single 3 6) || rc=$?
    if (( rc == 0 )); then multi=$(sample_repeated "$peer" "$port" "$duration" "$multi_parallel" 2 "verify-multi-${multi_parallel}" 3 6) || rc=$?; fi
    if (( rc == 0 )); then
        one_gp=$(cut -f1 <<< "$one"); one_loss=$(cut -f4 <<< "$one")
        multi_gp=$(cut -f1 <<< "$multi"); multi_loss=$(cut -f4 <<< "$multi")
        if (( expected_rate > 0 )); then
            if ! measurement_sample_acceptable "$one_gp" "$one_loss" "$expected_rate" "$min_efficiency" "$threshold" "$baseline_loss"; then
                accepted=0; reject_reason="single-flow-below-threshold"
            elif ! measurement_sample_acceptable "$multi_gp" "$multi_loss" "$expected_rate" "$min_efficiency" "$threshold" "$baseline_loss"; then
                accepted=0; reject_reason="multi-flow-below-threshold"
            fi
        fi
        one_count=$(cut -f13 <<< "$one"); multi_count=$(cut -f13 <<< "$multi")
        is_uint "$one_count" || one_count=0; is_uint "$multi_count" || multi_count=0
        if (( one_count < multi_count )); then combined_count="$one_count"; else combined_count="$multi_count"; fi
        one_spread=$(cut -f12 <<< "$one"); multi_spread=$(cut -f12 <<< "$multi")
        if is_decimal "$one_spread" && is_decimal "$multi_spread"; then
            combined_spread=$(printf '%s\n%s\n' "$one_spread" "$multi_spread" | max_numbers)
        else
            combined_spread=na
        fi
        if is_decimal "$(cut -f7 <<< "$one")" && is_decimal "$(cut -f7 <<< "$multi")"; then
            combined_loaded=$(printf '%s\n%s\n' "$(cut -f7 <<< "$one")" "$(cut -f7 <<< "$multi")" | max_numbers)
        else
            combined_loaded=na
        fi
        combined_contaminated=$(printf '%s\n%s\n' "$(cut -f11 <<< "$one")" "$(cut -f11 <<< "$multi")" | max_numbers)
        confidence=$(measurement_confidence "$combined_count" "$combined_spread" "$combined_loaded" "$combined_contaminated" 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tverify\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nEXPECTED_RATE_MBIT\t%s\nMIN_EFFICIENCY_RATIO\t%s\nIDLE_RTT_MS\t%s\nSINGLE_MBIT\t%s\nSINGLE_RETRANS_EST_PERCENT\t%s\nSINGLE_RETRANS_PER_GIB\t%s\nSINGLE_LOADED_RTT_P95_MS\t%s\nSINGLE_BUFFERBLOAT_P95_MS\t%s\nSINGLE_GOODPUT_SPREAD_PERCENT\t%s\nSINGLE_SAMPLE_COUNT\t%s\nMULTI_FLOWS\t%s\nMULTI_MBIT\t%s\nMULTI_RETRANS_EST_PERCENT\t%s\nMULTI_RETRANS_PER_GIB\t%s\nMULTI_LOADED_RTT_P95_MS\t%s\nMULTI_BUFFERBLOAT_P95_MS\t%s\nMULTI_GOODPUT_SPREAD_PERCENT\t%s\nMULTI_SAMPLE_COUNT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nACCEPTED\t%s\nREJECT_REASON\t%s\n' \
            "$peer" "$port" "$iface" "$expected_rate" "$min_efficiency" "$MEASURE_IDLE_RTT_MS" \
            "$one_gp" "$one_loss" "$(cut -f5 <<< "$one")" "$(cut -f7 <<< "$one")" "$(cut -f14 <<< "$one")" "$one_spread" "$one_count" \
            "$multi_parallel" "$multi_gp" "$multi_loss" "$(cut -f5 <<< "$multi")" "$(cut -f7 <<< "$multi")" "$(cut -f14 <<< "$multi")" "$multi_spread" "$multi_count" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" "$accepted" "$reject_reason" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        if (( accepted )); then
            log OK "验证完成: 单流 ${one_gp} Mbit/s，多流(${multi_parallel}) ${multi_gp} Mbit/s"
            log INFO "负载 RTT p95: 单流 $(cut -f7 <<< "$one") ms，多流 $(cut -f7 <<< "$multi") ms；置信度 ${confidence_grade} (${confidence_score}/100)"
        else
            log ERR "最终复验未通过（$reject_reason）：单流 ${one_gp} Mbit/s，多流 ${multi_gp} Mbit/s"
            rc=2
        fi
        log INFO "验证结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_compare() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" duration="${5:-6}" rounds="${6:-2}"
    local preferred_address="${7:-}" preferred_source="${8:-}"
    local iface dir speed estimate_rate estimate rc=0 round mode row verdict confidence
    local fq_gp shaped_gp fq_rpg shaped_rpg fq_bloat shaped_bloat fq_spread shaped_spread combined_spread combined_loaded
    local confidence_score confidence_grade confidence_reasons throughput_delta
    local -a fq_goodputs=() shaped_goodputs=() fq_retrans_gib=() shaped_retrans_gib=() fq_bloats=() shaped_bloats=()
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "compare rate 必须是 1–1000000 的整数"; return 1; }
    is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "compare duration 必须是 3–30 秒"; return 1; }
    is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "compare rounds 必须是 2–5"; return 1; }
    measure_lock_requested_peer "$peer" "$port" "$requested" "$preferred_address" "$preferred_source" || return $?
    iface="$MEASURE_PEER_IFACE"
    measure_require_locked_port "$peer" "$port" || return $?
    qdisc_guard "$iface" || return 1
    new_measure_run compare || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer" || return 1
    speed=$(detect_link_speed "$iface"); estimate_rate="$rate"
    if is_uint "$speed" && (( speed > estimate_rate )); then estimate_rate="$speed"; fi
    estimate=$(estimate_sweep_bytes "$estimate_rate" "$duration" "$((rounds * 2))")
    log INFO "A/B 对照将交错执行 FQ 与 ${rate} Mbit HTB/FQ，各 ${rounds} 轮；最多约 $(human_bytes "$estimate") 出站流量"
    measure_begin "$iface" || return 1
    for ((round=1; round<=rounds; round++)); do
        if (( round % 2 )); then local -a modes=(fq shaped); else local -a modes=(shaped fq); fi
        for mode in "${modes[@]}"; do
            if [[ "$mode" == fq ]]; then
                apply_fq "$iface" || { rc=$?; break 2; }
            else
                apply_shaping "$iface" "$rate" || { rc=$?; break 2; }
            fi
            row=$(sample_repeated "$peer" "$port" "$duration" 1 1 "compare-${mode}-r${round}") || { rc=$?; break 2; }
            if [[ "$mode" == fq ]]; then
                fq_goodputs+=("$(cut -f1 <<< "$row")"); fq_retrans_gib+=("$(cut -f5 <<< "$row")")
                is_decimal "$(cut -f14 <<< "$row")" && fq_bloats+=("$(cut -f14 <<< "$row")")
            else
                shaped_goodputs+=("$(cut -f1 <<< "$row")"); shaped_retrans_gib+=("$(cut -f5 <<< "$row")")
                is_decimal "$(cut -f14 <<< "$row")" && shaped_bloats+=("$(cut -f14 <<< "$row")")
            fi
            sleep 2
        done
    done
    if (( rc == 0 )); then
        fq_gp=$(median_numbers < <(printf '%s\n' "${fq_goodputs[@]}")); shaped_gp=$(median_numbers < <(printf '%s\n' "${shaped_goodputs[@]}"))
        fq_rpg=$(median_numbers < <(printf '%s\n' "${fq_retrans_gib[@]}")); shaped_rpg=$(median_numbers < <(printf '%s\n' "${shaped_retrans_gib[@]}"))
        fq_bloat=$(median_or_na "${fq_bloats[@]}"); shaped_bloat=$(median_or_na "${shaped_bloats[@]}")
        fq_spread=$(relative_spread_percent "${fq_goodputs[@]}"); shaped_spread=$(relative_spread_percent "${shaped_goodputs[@]}")
        combined_spread=$(printf '%s\n%s\n' "$fq_spread" "$shaped_spread" | max_numbers)
        if is_decimal "$fq_bloat" && is_decimal "$shaped_bloat"; then
            combined_loaded=$(printf '%s\n%s\n' "$fq_bloat" "$shaped_bloat" | max_numbers)
        else
            combined_loaded=na
        fi
        verdict=$(compare_verdict "$fq_gp" "$shaped_gp" "$fq_bloat" "$shaped_bloat" "$fq_rpg" "$shaped_rpg")
        confidence=$(measurement_confidence "$rounds" "$combined_spread" "$combined_loaded" 0 0 "$PATH_PROFILE_SCORE")
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        throughput_delta=$(awk -v f="$fq_gp" -v s="$shaped_gp" 'BEGIN {if(f<=0) print "na"; else printf "%.2f", (s-f)*100/f}')
        printf 'TYPE\tcompare\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nDURATION_SECONDS\t%s\nROUNDS\t%s\nORDER\tinterleaved\nIDLE_RTT_MS\t%s\nFQ_GOODPUT_MBIT\t%s\nFQ_RETRANS_PER_GIB\t%s\nFQ_BUFFERBLOAT_P95_MS\t%s\nFQ_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_GOODPUT_MBIT\t%s\nSHAPED_RETRANS_PER_GIB\t%s\nSHAPED_BUFFERBLOAT_P95_MS\t%s\nSHAPED_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_THROUGHPUT_DELTA_PERCENT\t%s\nVERDICT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nPERSISTED\t0\n' \
            "$peer" "$port" "$iface" "$rate" "$duration" "$rounds" "$MEASURE_IDLE_RTT_MS" \
            "$fq_gp" "$fq_rpg" "$fq_bloat" "$fq_spread" "$shaped_gp" "$shaped_rpg" "$shaped_bloat" "$shaped_spread" \
            "$throughput_delta" "$verdict" "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
        measure_append_locked_peer_summary "$dir/summary.tsv" || rc=$?
        log OK "A/B 完成: FQ ${fq_gp} Mbit/s / ${fq_bloat} ms，整形 ${shaped_gp} Mbit/s / ${shaped_bloat} ms，结论 ${verdict}"
        log INFO "对照置信度: ${confidence_grade} (${confidence_score}/100, ${confidence_reasons})；未写入配置或服务"
        log INFO "结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

# -----------------------------------------------------------------------------
# Persistence, legacy migration, restore and uninstall.
# -----------------------------------------------------------------------------

ACTION_TRANSACTION_DIR=""
ACTION_TRANSACTION_IFACE=""
ACTION_TRANSACTION_INTERFACES=""
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
    if command_exists systemctl; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$SERVICE_FILE" "$PERSIST_SCRIPT"
    rmdir "$PERSIST_DIR" 2>/dev/null || true
    command_exists systemctl && systemctl daemon-reload || true
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

restore_unit_state() {
    local unit="$1" file="$2" line enabled active current_enabled current_active
    local actual_enabled actual_active rc=0 remask=0
    local -a state_lines=()
    [[ -f "$file" ]] || return 0
    mapfile -t state_lines < "$file" || return 1
    if (( ${#state_lines[@]} != 1 )); then
        log ERR "systemd unit 状态快照格式损坏: $file"
        return 1
    fi
    line="${state_lines[0]}"
    if [[ "$line" != *$'\t'* || "${line#*$'\t'}" == *$'\t'* ]]; then
        log ERR "systemd unit 状态快照字段无效: $file"
        return 1
    fi
    enabled="${line%%$'\t'*}"
    active="${line#*$'\t'}"
    case "$enabled" in
        enabled|enabled-runtime|disabled|masked|masked-runtime|linked|linked-runtime|alias|static|indirect|generated|transient|not-found) ;;
        *) log ERR "systemd unit 状态快照包含未知 unit-file 状态: ${enabled:-empty}"; return 1 ;;
    esac
    case "$active" in
        active|inactive) ;;
        *) log ERR "systemd unit 状态快照包含不可恢复的 active 状态: ${active:-empty}"; return 1 ;;
    esac
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
    mkdir -p "$dir/files" "$dir/qdiscs" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; return 1; }
    action_qdisc_snapshot "$iface" "$dir/qdisc.snapshot" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; return 1; }
    cp -- "$dir/qdisc.snapshot" "$dir/qdiscs/$iface.snapshot" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; return 1; }
    capture_runtime_sysctls > "$dir/sysctl.tsv" || { remove_tree_within "$dir" "$STATE_DIR"; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; return 1; }
    ip -4 route show default > "$dir/default-route-v4.txt" 2>/dev/null || true
    ip -6 route show default > "$dir/default-route-v6.txt" 2>/dev/null || true
    if ! action_transaction_snapshot_path "$CONFIG_FILE" config ||
       ! action_transaction_snapshot_path "$SYSCTL_FILE" sysctl ||
       ! action_transaction_snapshot_path "$LEGACY_SYSCTL_FILE" legacy-sysctl ||
       ! action_transaction_snapshot_path "$SERVICE_FILE" service ||
       ! action_transaction_snapshot_path "$LEGACY_SERVICE_FILE" legacy-service ||
       ! action_transaction_snapshot_path "$PERSIST_SCRIPT" persist-script ||
       ! action_transaction_snapshot_tree "$NIC_POLICY_DIR" nic-policy-dir; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
        return 1
    fi
    if ! action_transaction_capture_unit "$SERVICE_NAME" service ||
       ! action_transaction_capture_unit bbr-optimize-persist.service legacy-service ||
       ! chmod -R go-rwx "$dir"; then
        remove_tree_within "$dir" "$STATE_DIR" || true
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
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
    [[ -z "$dir" ]] || remove_tree_within "$dir" "$STATE_DIR"
}

action_transaction_begin_multi() {
    local primary="$1" iface
    action_transaction_begin "$primary" || return 1
    if [[ "$(nic_policy_layout_state 2>/dev/null || true)" == managed ]]; then
        if ! nic_policy_set_validate; then action_transaction_discard_snapshot || true; return 1; fi
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            if ! action_transaction_add_interface "$iface"; then action_transaction_discard_snapshot || true; return 1; fi
        done < <(nic_policy_interface_list)
    fi
    if (( ${MULTI_NIC_ENABLED:-0} == 0 )) && [[ "${TC_INTERFACE:-auto}" != auto ]]; then
        if ! action_transaction_add_interface "$TC_INTERFACE"; then action_transaction_discard_snapshot || true; return 1; fi
    fi
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
    remove_tree_within "$dir" "$STATE_DIR" || log WARN "操作已提交，但无法删除临时事务快照: $dir"
}

action_transaction_rollback() {
    local dir="$ACTION_TRANSACTION_DIR" iface="$ACTION_TRANSACTION_IFACE" file rc=0 had_lock="$LOCK_HELD"
    [[ -n "$dir" ]] || return 0
    (( ACTION_TRANSACTION_ROLLING_BACK == 0 )) || return 1
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
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl modprobe || return 1; acquire_lock 30 || return 1
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
    apply_sysctl_profile || return 1
    if (( TC_ENABLED == 1 )); then
        apply_shaping "$iface" "$TC_RATE_MBIT" || return 1
    else
        apply_fq "$iface" || return 1
    fi
    apply_initial_windows
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
    if (( TC_ENABLED )); then verify_shaping "$iface" || rc=1
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
        remove_persistence
        nic_restore_secondary_baselines || { die "旧版委托恢复前，逐网卡 qdisc 恢复失败；策略和基线均已保留"; return 1; }
        release_lock
        log INFO "将恢复操作交给迁移时保存的旧版本工具"
        bash "$BASELINE_DIR/legacy-tool.sh" restore || { die "旧版本恢复失败；旧备份仍在 $LEGACY_BACKUP_DIR"; return 1; }
        acquire_lock 30 || { die "旧版恢复完成，但无法重新取得管理锁"; return 1; }
        nic_policy_remove_tree || { die "旧版基线已恢复，但无法删除 v8 多网卡策略目录"; return 1; }
        log OK "旧版可信基线恢复完成"
        return 0
    fi
    remove_persistence
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

uninstall_managed() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    require_commands ip tc sysctl systemctl readlink grep cut sed mktemp mv rm chmod chown || return 1
    local purge="${1:-0}" resolved_state restored_tcp=0 restored_dns=0 restored_ipv6=0 interfaces other

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
        remove_persistence
        rm -f -- "$CONFIG_FILE" "$SYSCTL_FILE"
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

    remove_cli_command || return 1
    if (( purge )); then
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
    if (( TC_ENABLED )); then verify_shaping "$iface" || rc=1
    else [[ "$(root_qdisc_kind "$iface")" == fq ]] || { log ERR "root qdisc 不是 fq"; rc=1; }
    fi
    if (( rc == 0 )); then log OK "运行时与持久化状态一致"; else die "验证发现不一致"; fi
}

# -----------------------------------------------------------------------------
# XanMod kernel lifecycle: official repository, conservative CPU level choice.
# -----------------------------------------------------------------------------

secure_boot_enabled() {
    command_exists mokutil || return 1
    # Do not use grep -q in a pipe while pipefail is active: an early match can
    # close the pipe, give mokutil SIGPIPE, and turn a true result into false.
    mokutil --sb-state 2>/dev/null | grep -i 'SecureBoot enabled' >/dev/null
}

cpu_flags_line() {
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true
}

cpu_has_any_flag() {
    local flags="$1" flag; shift
    for flag in "$@"; do grep -qw "$flag" <<< "$flags" && return 0; done
    return 1
}

detect_x86_level() {
    local flags
    [[ "$(uname -m)" == x86_64 ]] || { printf 'unknown\n'; return 1; }
    flags=$(cpu_flags_line)
    # x86-64-v3 additionally requires F16C and LZCNT. Linux commonly exposes
    # BMI1 as bmi/bmi1, LZCNT as abm/lzcnt, and SSE3 as pni. AVX is hidden by
    # Linux when the OS has not enabled the XSAVE state, so avx+xsave is the
    # practical /proc/cpuinfo proxy for the psABI OSXSAVE requirement.
    if all_cpu_flags "$flags" avx avx2 bmi2 f16c fma movbe xsave &&
        cpu_has_any_flag "$flags" bmi bmi1 && cpu_has_any_flag "$flags" abm lzcnt; then
        printf '3\n'
    elif all_cpu_flags "$flags" cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 &&
        cpu_has_any_flag "$flags" pni sse3; then
        printf '2\n'
    else printf '1\n'; fi
}

all_cpu_flags() {
    local flags="$1" flag; shift
    for flag in "$@"; do grep -qw "$flag" <<< "$flags" || return 1; done
}

xanmod_candidates() {
    local level="$1" track="$2"
    if [[ "$track" == lts ]]; then
        case "$level" in
            3) printf '%s\n' linux-xanmod-lts-x64v3 linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1 ;;
            2) printf '%s\n' linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1 ;;
            *) printf '%s\n' linux-xanmod-lts-x64v1 ;;
        esac
    else
        # XanMod Main currently has x64v2/x64v3 packages only. Never satisfy a
        # Main request with an LTS package: that silently changes the lifecycle
        # track the operator explicitly selected.
        case "$level" in
            3) printf '%s\n' linux-xanmod-x64v3 linux-xanmod-x64v2 ;;
            2) printf '%s\n' linux-xanmod-x64v2 ;;
            *) return 0 ;;
        esac
    fi
}

select_xanmod_package() {
    local level="$1" track="$2" candidate
    while IFS= read -r candidate; do
        apt-cache show "$candidate" >/dev/null 2>&1 && { printf '%s\n' "$candidate"; return 0; }
    done < <(xanmod_candidates "$level" "$track")
    die "XanMod 仓库中没有适合 x86-64-v${level} / ${track} 的包"
}

apt_network_guard() {
    local package="$1" simulation
    simulation=$(apt-get -s install "$package" 2>/dev/null) || return 1
    if grep -E '^Remv (ifupdown|network-manager|systemd|systemd-resolved|iproute2|openssh-server)( |$)' <<< "$simulation"; then
        die "APT 模拟显示会移除关键网络组件，已中止"
        return 1
    fi
}

kernel_status() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    printf '%-18s %s\n' "Running kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "x86-64 level" "$(detect_x86_level 2>/dev/null || echo n/a)"
    printf '%-18s %s\n' "Secure Boot" "$(secure_boot_enabled && echo enabled || echo disabled/unknown)"
    printf '%-18s %s\n' "BBR support" "$(bbr_kernel_support_status)"
    printf '%-18s %s\n' "BBR compatibility" "$(bbr_compatibility_status "$cc")"
    printf '%-18s %s\n' "BBR generation" "$(bbr_generation_status "$cc")"
    dpkg-query -W -f='${Package}\t${Version}\n' 'linux-*xanmod*' 2>/dev/null || true
}

kernel_install() {
    require_root || return 1; acquire_lock || return 1
    local track="${1:-lts}" codename level package key_tmp keyring_tmp source_tmp
    [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
    [[ "$(os_id)" == debian || "$(os_id)" == ubuntu ]] || { die "XanMod 自动安装只支持 Debian/Ubuntu"; return 1; }
    [[ "$(uname -m)" == x86_64 ]] || { die "XanMod 官方 APT 仅支持 amd64；ARM64 请使用发行版内核或审计后的社区构建"; return 1; }
    is_container && { die "容器中不能更换宿主机内核"; return 1; }
    secure_boot_enabled && { die "检测到 Secure Boot 已启用；请先准备签名/MOK 或关闭后再安装"; return 1; }
    require_commands apt-get apt-cache curl gpg || return 1
    codename=$(os_codename); [[ -n "$codename" ]] || { die "无法读取 VERSION_CODENAME"; return 1; }
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    install -d -m 0755 /etc/apt/keyrings
    key_tmp=$(mktemp) || return 1
    curl -fsSL --connect-timeout 15 --max-time 60 https://dl.xanmod.org/archive.key -o "$key_tmp"
    gpg --show-keys "$key_tmp" >/dev/null 2>&1 || { rm -f "$key_tmp"; die "XanMod 公钥格式验证失败"; return 1; }
    keyring_tmp=$(mktemp) || { rm -f "$key_tmp"; return 1; }
    gpg --dearmor --yes -o "$keyring_tmp" "$key_tmp"
    rm -f "$key_tmp"
    atomic_install "$keyring_tmp" /etc/apt/keyrings/xanmod-archive-keyring.gpg 0644 || { rm -f "$keyring_tmp"; return 1; }
    rm -f "$keyring_tmp"
    source_tmp=$(mktemp) || return 1
    printf 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org %s main\n' "$codename" > "$source_tmp"
    atomic_install "$source_tmp" /etc/apt/sources.list.d/xanmod-release.list 0644 || { rm -f "$source_tmp"; return 1; }
    rm -f "$source_tmp"
    apt-get update
    level=$(detect_x86_level); package=$(select_xanmod_package "$level" "$track") || return 1
    apt_network_guard "$package" || return 1
    log INFO "系统=$codename CPU=x86-64-v$level 选择包=$package"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    command_exists update-grub && update-grub
    log OK "XanMod 已安装；当前内核未被删除。请自行安排重启后执行 status 验证"
}

kernel_remove() {
    require_root || return 1; acquire_lock || return 1
    local -a packages=() safe=() package
    mapfile -t packages < <(dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | sort -u)
    ((${#packages[@]})) || { log INFO "没有已安装的 XanMod 包"; return 0; }
    for package in "${packages[@]}"; do
        if [[ "$(uname -r)" == *xanmod* ]] && dpkg-query -L "$package" 2>/dev/null | grep -F "/boot/vmlinuz-$(uname -r)" >/dev/null; then
            log WARN "跳过当前正在运行的内核包: $package"
        else safe+=("$package"); fi
    done
    ((${#safe[@]})) || { die "没有可安全卸载的非运行中 XanMod 包"; return 1; }
    confirm "将卸载: ${safe[*]}，继续？" || { log INFO "已取消"; return 0; }
    apt-get remove -y "${safe[@]}"
    command_exists update-grub && update-grub
}

# -----------------------------------------------------------------------------
# DNS: scoped systemd-resolved policy with immutable backup and action rollback.
# -----------------------------------------------------------------------------

DNS_DROPIN="${BBRV3_DNS_DROPIN:-/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf}"
DNS_RESOLV_CONF="${BBRV3_RESOLV_CONF:-/etc/resolv.conf}"
DNS_STUB_RESOLV="${BBRV3_DNS_STUB_RESOLV:-/run/systemd/resolve/stub-resolv.conf}"
DNS_FULL_RESOLV="${BBRV3_DNS_FULL_RESOLV:-/run/systemd/resolve/resolv.conf}"
DNS_TRANSACTION_DIR=""

dns_snapshot_path() {
    local source="$1" name="$2" state_name="$3" directory="$4"
    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$directory/$name" || return 1
        printf 'present\n' > "$directory/${state_name}.state" || return 1
    else
        printf 'absent\n' > "$directory/${state_name}.state" || return 1
    fi
}

dns_unit_enabled_state() {
    local state
    state=$(systemctl is-enabled systemd-resolved 2>/dev/null || true)
    case "$state" in
        enabled|enabled-runtime|linked|linked-runtime|alias|masked|masked-runtime|static|indirect|disabled|generated|transient|bad|not-found)
            printf '%s\n' "$state"
            ;;
        *) return 1 ;;
    esac
}

dns_unit_active_state() {
    local state
    state=$(systemctl is-active systemd-resolved 2>/dev/null || true)
    case "$state" in
        active|reloading|inactive|failed|activating|deactivating|maintenance|refreshing)
            printf '%s\n' "$state"
            ;;
        *) return 1 ;;
    esac
}

dns_unit_load_state() {
    local state
    state=$(systemctl show systemd-resolved --property=LoadState --value 2>/dev/null) || return 1
    case "$state" in
        loaded|error|masked|not-found|bad-setting|transient|stub|merged) printf '%s\n' "$state" ;;
        *) return 1 ;;
    esac
}

dns_snapshot_unit_state() {
    local directory="$1" enabled active load
    enabled=$(dns_unit_enabled_state) || return 1
    active=$(dns_unit_active_state) || return 1
    load=$(dns_unit_load_state) || return 1
    case "$enabled" in bad|not-found) return 1 ;; esac
    # A transient service state cannot be faithfully reconstructed during a
    # later rollback. Wait for it to settle instead of recording a lie.
    case "$active" in active|inactive) ;; *) return 1 ;; esac
    case "$load" in loaded|masked) ;; *) return 1 ;; esac
    case "$enabled" in
        masked|masked-runtime)
            [[ "$load" == masked ]] || return 1
            ;;
        *)
            [[ "$load" == loaded ]] || return 1
            ;;
    esac
    printf '%s\t%s\t%s\n' "$enabled" "$active" "$load" > "$directory/service.unit" || return 1
    # Retain the old file so older executables can still consume this baseline.
    printf '%s\n' "$active" > "$directory/service.active" || return 1
}

dns_snapshot_current() {
    local directory="$1"
    mkdir -p -- "$directory" || return 1
    dns_snapshot_path "$DNS_RESOLV_CONF" resolv.conf resolv "$directory" || return 1
    dns_snapshot_path "$DNS_DROPIN" dropin.conf dropin "$directory" || return 1
    dns_snapshot_unit_state "$directory" || return 1
}

dns_valid_unit_enabled_value() {
    case "$1" in
        enabled|enabled-runtime|linked|linked-runtime|alias|masked|masked-runtime|static|indirect|disabled|generated|transient) return 0 ;;
        *) return 1 ;;
    esac
}

dns_validate_snapshot() {
    local directory="$1" require_manifest="${2:-0}" name state enabled active load extra legacy_active
    local line key value require_unit=0 unit_lines snapshot_schema
    local -A manifest_fields=()
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    if (( require_manifest )); then
        [[ -f "$directory/manifest" && ! -L "$directory/manifest" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || return 1
            key="${line%%$'\t'*}"; value="${line#*$'\t'}"
            [[ -n "$key" && -n "$value" ]] || return 1
            [[ -z "${manifest_fields[$key]+x}" ]] || return 1
            case "$key" in CREATED_AT|CREATED_BY|SCHEMA|DNS_UNIT_LIFECYCLE) ;; *) return 1 ;; esac
            manifest_fields[$key]="$value"
        done < "$directory/manifest"
        [[ "${manifest_fields[CREATED_AT]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
        [[ "${manifest_fields[CREATED_BY]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || return 1
        if [[ -n "${manifest_fields[SCHEMA]:-}" || -n "${manifest_fields[DNS_UNIT_LIFECYCLE]:-}" ]]; then
            [[ "${manifest_fields[SCHEMA]:-}" == 2 && "${manifest_fields[DNS_UNIT_LIFECYCLE]:-}" == 1 ]] || return 1
            (( ${#manifest_fields[@]} == 4 )) || return 1
            require_unit=1
        else
            # v7.2.0 and earlier baselines only carried their creation fields.
            (( ${#manifest_fields[@]} == 2 )) || return 1
        fi
    fi
    if [[ -e "$directory/.snapshot.schema" || -L "$directory/.snapshot.schema" ]]; then
        [[ -f "$directory/.snapshot.schema" && ! -L "$directory/.snapshot.schema" ]] || return 1
        snapshot_schema=$(<"$directory/.snapshot.schema") || return 1
        [[ "$snapshot_schema" == 2 ]] || return 1
        require_unit=1
    fi
    for name in resolv dropin; do
        [[ -f "$directory/${name}.state" && ! -L "$directory/${name}.state" ]] || return 1
        state=$(<"$directory/${name}.state") || return 1
        case "$state" in
            present) [[ -f "$directory/${name}.conf" || -L "$directory/${name}.conf" ]] || return 1 ;;
            absent) [[ ! -e "$directory/${name}.conf" && ! -L "$directory/${name}.conf" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    [[ ! -L "$directory/service.unit" ]] || return 1
    if [[ -f "$directory/service.unit" ]]; then
        unit_lines=$(wc -l < "$directory/service.unit") || return 1
        (( unit_lines == 1 )) || return 1
        IFS=$'\t' read -r enabled active load extra < "$directory/service.unit" || return 1
        [[ -z "$extra" ]] || return 1
        dns_valid_unit_enabled_value "$enabled" || return 1
        [[ "$active" == active || "$active" == inactive ]] || return 1
        [[ "$load" == loaded || "$load" == masked ]] || return 1
        case "$enabled" in
            masked|masked-runtime) [[ "$load" == masked ]] || return 1 ;;
            *) [[ "$load" == loaded ]] || return 1 ;;
        esac
        [[ -f "$directory/service.active" && ! -L "$directory/service.active" ]] || return 1
        legacy_active=$(<"$directory/service.active") || return 1
        [[ "$legacy_active" == "$active" ]] || return 1
    else
        (( require_unit == 0 )) || return 1
        [[ -f "$directory/service.active" && ! -L "$directory/service.active" ]] || return 1
        legacy_active=$(<"$directory/service.active") || return 1
        [[ "$legacy_active" == active || "$legacy_active" == inactive ]] || return 1
    fi
}

dns_require_legacy_baseline_lifecycle_safety() {
    local base="$DNS_BACKUP_DIR/baseline" enabled
    [[ -e "$base" || -L "$base" ]] || return 0
    dns_validate_snapshot "$base" 1 || {
        die "现有 DNS 基线损坏或不完整，拒绝覆盖: $base"
        return 1
    }
    [[ ! -f "$base/service.unit" ]] || return 0
    enabled=$(dns_unit_enabled_state) || {
        die "无法读取 systemd-resolved unit-file 状态，旧 DNS 基线不具备安全恢复能力"
        return 1
    }
    case "$enabled" in
        disabled|enabled-runtime)
            die "旧 DNS 基线没有 unit-file 状态；本次操作需要把 systemd-resolved 从 $enabled 改为 enabled，拒绝修改"
            return 1
            ;;
    esac
}

dns_pending_transaction() {
    local candidate quality
    for candidate in "$DNS_BACKUP_DIR"/.transaction.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        if dns_validate_snapshot "$candidate" 0 >/dev/null 2>&1; then quality=valid; else quality=corrupt; fi
        printf '%s\t%s\n' "$quality" "$candidate"
        return 0
    done
    return 1
}

dns_refuse_pending_transaction() {
    local pending quality path
    if pending=$(dns_pending_transaction); then
        IFS=$'\t' read -r quality path <<< "$pending"
        die "发现未完成的 DNS 事务快照 ($quality): $path；拒绝叠加新操作，请先人工核对并恢复"
        return 1
    fi
}

dns_restore_unit_state() {
    local enabled="$1" active="$2" current_enabled current_active actual_enabled actual_active rc=0 active_handled=0

    current_enabled=$(dns_unit_enabled_state) || {
        log ERR "无法读取恢复前的 systemd-resolved unit-file 状态"
        return 1
    }
    current_active=$(dns_unit_active_state) || {
        log ERR "无法读取恢复前的 systemd-resolved active 状态"
        return 1
    }
    [[ "$current_active" == active || "$current_active" == inactive ]] || {
        log ERR "恢复前的 systemd-resolved active 状态尚未稳定: $current_active"
        return 1
    }

    case "$enabled" in
        masked|masked-runtime)
            if [[ "$current_enabled" == "$enabled" && "$active" == inactive ]]; then
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                active_handled=1
            else
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
                if [[ "$active" == active ]]; then
                    if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                elif ! systemctl stop systemd-resolved >/dev/null 2>&1; then
                    rc=1
                fi
                if [[ "$enabled" == masked-runtime ]]; then
                    if ! systemctl mask --runtime systemd-resolved >/dev/null 2>&1; then rc=1; fi
                elif ! systemctl mask systemd-resolved >/dev/null 2>&1; then
                    rc=1
                fi
                active_handled=1
            fi
            ;;
        enabled)
            if [[ "$current_enabled" != enabled ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl enable systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        enabled-runtime)
            if [[ "$current_enabled" != enabled-runtime ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
                if ! systemctl enable --runtime systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        disabled)
            if [[ "$current_enabled" != disabled ]]; then
                case "$current_enabled" in
                    masked|masked-runtime)
                        if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                        ;;
                esac
                if ! systemctl disable systemd-resolved >/dev/null 2>&1; then rc=1; fi
            fi
            ;;
        linked|linked-runtime|alias|static|indirect|generated|transient)
            # Apply refuses these states, so a normal transaction never has to
            # synthesize them. Unmasking can reveal an inherent static/alias
            # state; the exact postcondition check below catches anything else.
            case "$current_enabled" in
                masked|masked-runtime)
                    if ! systemctl unmask systemd-resolved >/dev/null 2>&1; then rc=1; fi
                    ;;
            esac
            ;;
        *)
            log ERR "DNS 快照包含无效 unit-file 状态: $enabled"
            return 1
            ;;
    esac

    if (( active_handled == 0 )); then
        case "$active" in
            active)
                if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            inactive)
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            *)
                log ERR "DNS 快照包含不可恢复的 active 状态: $active"
                return 1
                ;;
        esac
    fi

    actual_enabled=$(dns_unit_enabled_state 2>/dev/null) || actual_enabled='query-failed'
    actual_active=$(dns_unit_active_state 2>/dev/null) || actual_active='query-failed'
    if [[ "$actual_enabled" != "$enabled" ]]; then
        log ERR "systemd-resolved unit-file 恢复验证失败: expected=$enabled actual=$actual_enabled"
        rc=1
    fi
    if [[ "$actual_active" != "$active" ]]; then
        log ERR "systemd-resolved active 恢复验证失败: expected=$active actual=$actual_active"
        rc=1
    fi
    return "$rc"
}

dns_restore_snapshot() {
    local directory="$1" state enabled active load actual_active rc=0
    dns_validate_snapshot "$directory" 0 || {
        die "DNS 快照不完整: $directory"
        return 1
    }
    rm -f -- "$DNS_DROPIN" || rc=1
    state=$(<"$directory/dropin.state") || return 1
    if [[ "$state" == present ]]; then
        mkdir -p -- "$(dirname "$DNS_DROPIN")" || rc=1
        cp -a -- "$directory/dropin.conf" "$DNS_DROPIN" || rc=1
    fi
    rm -f -- "$DNS_RESOLV_CONF" || rc=1
    state=$(<"$directory/resolv.state") || return 1
    if [[ "$state" == present ]]; then cp -a -- "$directory/resolv.conf" "$DNS_RESOLV_CONF" || rc=1; fi

    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    if [[ -f "$directory/service.unit" ]]; then
        IFS=$'\t' read -r enabled active load < "$directory/service.unit" || return 1
        dns_restore_unit_state "$enabled" "$active" || rc=1
    else
        # Legacy baselines only captured whether the service was active.
        active=$(<"$directory/service.active") || return 1
        case "$active" in
            active)
                if ! systemctl restart systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
            inactive)
                if ! systemctl stop systemd-resolved >/dev/null 2>&1; then rc=1; fi
                ;;
        esac
        actual_active=$(dns_unit_active_state 2>/dev/null) || actual_active='query-failed'
        if [[ "$actual_active" != "$active" ]]; then
            log ERR "旧 DNS 基线 active 恢复验证失败: expected=$active actual=$actual_active"
            rc=1
        fi
    fi
    return "$rc"
}

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" temp_dir
    if [[ -e "$base" || -L "$base" ]]; then
        dns_validate_snapshot "$base" 1 || {
            die "现有 DNS 基线损坏或不完整，拒绝覆盖: $base"
            return 1
        }
        return 0
    fi
    ensure_state_layout || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    chmod 0700 "$DNS_BACKUP_DIR" 2>/dev/null || true
    temp_dir=$(mktemp -d "${DNS_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! dns_snapshot_current "$temp_dir" ||
       ! dns_validate_snapshot "$temp_dir" 0 ||
       ! printf 'CREATED_AT\t%s\nCREATED_BY\t%s\nSCHEMA\t2\nDNS_UNIT_LIFECYCLE\t1\n' "$(utc_now)" "$SCRIPT_VERSION" > "$temp_dir/manifest" ||
       ! dns_validate_snapshot "$temp_dir" 1 ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$DNS_BACKUP_DIR" || true
        return 1
    fi
}

dns_transaction_begin() {
    [[ -z "$DNS_TRANSACTION_DIR" ]] || { die "已有未提交的 DNS 事务"; return 1; }
    dns_refuse_pending_transaction || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    DNS_TRANSACTION_DIR=$(mktemp -d "${DNS_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! dns_snapshot_current "$DNS_TRANSACTION_DIR" ||
       ! printf '2\n' > "$DNS_TRANSACTION_DIR/.snapshot.schema" ||
       ! dns_validate_snapshot "$DNS_TRANSACTION_DIR" 0 ||
       ! chmod -R go-rwx "$DNS_TRANSACTION_DIR"; then
        remove_tree_within "$DNS_TRANSACTION_DIR" "$DNS_BACKUP_DIR" || true
        DNS_TRANSACTION_DIR=""
        return 1
    fi
}

dns_transaction_commit() {
    local directory="$DNS_TRANSACTION_DIR"
    [[ -n "$directory" ]] || return 0
    DNS_TRANSACTION_DIR=""
    remove_tree_within "$directory" "$DNS_BACKUP_DIR" || log WARN "DNS 已提交，但无法删除临时事务快照: $directory"
}

dns_transaction_rollback() {
    local directory="$DNS_TRANSACTION_DIR" rc=0
    [[ -n "$directory" ]] || return 0
    dns_restore_snapshot "$directory" || rc=1
    if (( rc == 0 )); then
        remove_tree_within "$directory" "$DNS_BACKUP_DIR" || rc=1
    fi
    if (( rc == 0 )); then
        DNS_TRANSACTION_DIR=""
        log OK "已恢复本次 DNS 操作前状态"
    else
        log ERR "DNS 自动回滚未完全成功；事务快照保留在 $directory"
    fi
    return "$rc"
}

dns_normalized_link_target() {
    local target
    target=$(readlink "$DNS_RESOLV_CONF" 2>/dev/null) || return 1
    if [[ "$target" == /* ]]; then
        readlink -m -- "$target"
    else
        readlink -m -- "$(dirname "$DNS_RESOLV_CONF")/$target"
    fi
}

dns_project_dropin_signature_valid() {
    local content old_dot old_plain new_dot new_plain
    [[ -f "$DNS_DROPIN" && ! -L "$DNS_DROPIN" ]] || return 1
    content=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$DNS_DROPIN") || return 1
    old_dot=$'[Resolve]\nDNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net\nFallbackDNS=8.8.8.8#dns.google\nDomains=~.\nDNSOverTLS=yes\nDNSSEC=allow-downgrade'
    old_plain=$'[Resolve]\nDNS=1.1.1.1 9.9.9.9\nFallbackDNS=8.8.8.8\nDomains=~.\nDNSOverTLS=no\nDNSSEC=allow-downgrade'
    new_dot=$'[Resolve]\nDNS=\nFallbackDNS=\nDomains=\nDNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net\nFallbackDNS=8.8.8.8#dns.google 2001:4860:4860::8888#dns.google\nDomains=~.\nDNSOverTLS=yes\nDNSSEC=allow-downgrade'
    new_plain=$'[Resolve]\nDNS=\nFallbackDNS=\nDomains=\nDNS=1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe\nFallbackDNS=8.8.8.8 2001:4860:4860::8888\nDomains=~.\nDNSOverTLS=no\nDNSSEC=allow-downgrade'
    [[ "$content" == "$old_dot" || "$content" == "$old_plain" || "$content" == "$new_dot" || "$content" == "$new_plain" ]]
}

dns_resolver_owner() {
    local target stub full
    if [[ ! -e "$DNS_RESOLV_CONF" && ! -L "$DNS_RESOLV_CONF" ]]; then
        printf 'absent\n'
        return 0
    fi
    if [[ -L "$DNS_RESOLV_CONF" ]]; then
        target=$(dns_normalized_link_target 2>/dev/null || true)
        stub=$(readlink -m -- "$DNS_STUB_RESOLV")
        full=$(readlink -m -- "$DNS_FULL_RESOLV")
        case "$target" in
            "$stub"|"$full") printf 'systemd-resolved\n' ;;
            */run/NetworkManager/*) printf 'NetworkManager\n' ;;
            */run/resolvconf/*) printf 'resolvconf\n' ;;
            *) printf 'symlink:%s\n' "${target:-unknown}" ;;
        esac
        return 0
    fi
    if grep -Eiq 'NetworkManager' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'NetworkManager\n'
    elif grep -Eiq 'resolvconf|openresolv' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'resolvconf\n'
    elif grep -Eiq 'cloud-init' "$DNS_RESOLV_CONF" 2>/dev/null; then
        printf 'cloud-init\n'
    elif grep -Eiq 'systemd-resolved|stub-resolv[.]conf' "$DNS_RESOLV_CONF" 2>/dev/null; then
        # A copied stub is still a regular file: it is not updated atomically by
        # systemd-resolved and therefore does not prove resolver ownership.
        printf 'regular-file:systemd-marker\n'
    else
        printf 'regular-file\n'
    fi
}

dns_complex_routing_reason_from_domains() {
    local output="$1" line payload token section saw_global=0 saw_unknown=0 trimmed
    while IFS= read -r line; do
        trimmed=${line#"${line%%[![:space:]]*}"}
        [[ -n "$trimmed" ]] || continue
        case "$line" in
            Link\ *:*) section='link' ;;
            Global:*) section='global'; (( saw_global += 1 )) ;;
            *) saw_unknown=1; continue ;;
        esac
        payload=${line#*:}
        payload=${payload#"${payload%%[![:space:]]*}"}
        [[ -n "$payload" && "$payload" != none ]] || continue
        if [[ "$section" == link ]]; then
            printf '检测到 per-link DNS 域: %s' "$line"
            return 0
        fi
        for token in $payload; do
            # Empty assignments in the project drop-in deliberately replace
            # the global list with only ~. Any other global search or route-only
            # domain may be private and must block takeover.
            if [[ "$token" == '~.' ]] && dns_project_dropin_signature_valid; then continue; fi
            printf '检测到全局 DNS 域: %s' "$token"
            return 0
        done
    done <<< "$output"
    (( saw_global == 1 && saw_unknown == 0 )) || return 2
    return 1
}

dns_complex_routing_reason_from_status() {
    local output="$1" line context=unknown payload token saw_global=0 domain_continuation=0 trimmed
    while IFS= read -r line; do
        case "$line" in
            Global) context='global'; (( saw_global += 1 )); domain_continuation=0; continue ;;
            Link\ *) context='link'; domain_continuation=0; continue ;;
        esac
        trimmed=${line#"${line%%[![:space:]]*}"}
        if [[ "$trimmed" =~ ^DNS[[:space:]]+Domains?([[:space:]]*:[[:space:]]*|[[:space:]]+)(.*)$ ]]; then
            payload=${BASH_REMATCH[2]}
            domain_continuation=1
        elif (( domain_continuation )); then
            [[ -n "$trimmed" ]] || continue
            if [[ "$trimmed" =~ ^(Protocols|Current[[:space:]]+DNS[[:space:]]+Server|DNS[[:space:]]+Servers?|Fallback[[:space:]]+DNS[[:space:]]+Servers?|DNSSEC|DNSOverTLS|DefaultRoute|Current[[:space:]]+Scopes|LLMNR|MulticastDNS)([[:space:]:]|$) ]]; then
                domain_continuation=0
                continue
            fi
            payload=$trimmed
        else
            continue
        fi
        payload=${payload#"${payload%%[![:space:]]*}"}
        [[ -n "$payload" && "$payload" != none ]] || continue
        if [[ "$context" == unknown ]]; then
            return 2
        elif [[ "$context" == link ]]; then
            printf '检测到 per-link DNS 域: %s' "$payload"
            return 0
        fi
        for token in $payload; do
            if [[ "$token" == '~.' ]] && dns_project_dropin_signature_valid; then continue; fi
            printf '检测到全局 DNS 域: %s' "$token"
            return 0
        done
    done <<< "$output"
    (( saw_global == 1 )) || return 2
    return 1
}

dns_complex_routing_reason() {
    local output rc
    if output=$(LC_ALL=C resolvectl domain 2>/dev/null); then
        if dns_complex_routing_reason_from_domains "$output"; then return 0; else rc=$?; fi
        (( rc == 1 )) && return 1
    fi
    if output=$(LC_ALL=C resolvectl status 2>/dev/null); then
        if dns_complex_routing_reason_from_status "$output"; then return 0; else rc=$?; fi
        (( rc == 1 )) && return 1
    fi
    # First takeover fails closed when split-DNS cannot be inspected. Existing
    # project policy may enter its transaction path for repair/rollback.
    dns_project_dropin_signature_valid && return 2
    printf '无法读取 systemd-resolved 的 routing domains'
    return 0
}

dns_preflight_takeover() {
    local owner enabled active load reason routing_rc
    owner=$(dns_resolver_owner) || return 1
    enabled=$(dns_unit_enabled_state) || { die "无法读取 systemd-resolved unit-file 状态"; return 1; }
    active=$(dns_unit_active_state) || { die "无法读取 systemd-resolved active 状态"; return 1; }
    load=$(dns_unit_load_state) || { die "无法读取 systemd-resolved LoadState"; return 1; }

    case "$load" in
        loaded) ;;
        *) die "systemd-resolved 不可用（LoadState=$load）"; return 1 ;;
    esac
    case "$active" in
        active) ;;
        inactive)
            die "systemd-resolved 当前未运行；为避免 resolvectl 通过 D-Bus 自动激活并污染修改前基线，拒绝接管 DNS"
            return 1
            ;;
        *) die "systemd-resolved 状态尚未稳定: $active"; return 1 ;;
    esac
    case "$enabled" in
        masked|masked-runtime) die "systemd-resolved 已被屏蔽；拒绝自动解除屏蔽并接管 DNS"; return 1 ;;
        not-found|bad) die "无法确认 systemd-resolved 的持久化状态: $enabled"; return 1 ;;
        generated|transient) die "systemd-resolved unit 状态为 $enabled，不适合持久 DNS 接管"; return 1 ;;
        linked|linked-runtime|alias|static|indirect)
            die "systemd-resolved unit 状态为 $enabled，无法证明重启后会自动运行；拒绝把 resolv.conf 指向运行时 stub"
            return 1
            ;;
    esac
    case "$owner" in
        systemd-resolved|absent) ;;
        *)
            die "当前 resolv.conf 由 '$owner' 管理；仅支持接管 systemd-resolved，未作任何修改"
            return 1
            ;;
    esac
    if reason=$(dns_complex_routing_reason); then
        die "$reason；为保护 VPN/私有域/split DNS，拒绝设置全局 Domains=~."
        return 1
    else
        routing_rc=$?
        if (( routing_rc == 2 )); then
            log WARN "旧版项目 DNS 策略存在，但无法读取 routing domains；仅允许事务性修复，应用后仍会严格验证"
        fi
    fi
}

dns_prepare_resolved_service() {
    local enabled actual_enabled actual_active
    enabled=$(dns_unit_enabled_state) || { die "无法读取 systemd-resolved unit-file 状态"; return 1; }
    case "$enabled" in
        disabled|enabled-runtime)
            systemctl enable systemd-resolved >/dev/null || {
                die "无法持久启用 systemd-resolved；DNS 配置不会在重启后可靠生效"
                return 1
            }
            ;;
        enabled) ;;
        *) die "不支持的 systemd-resolved unit 状态: $enabled"; return 1 ;;
    esac
    systemctl restart systemd-resolved || { die "systemd-resolved 重启失败"; return 1; }
    actual_enabled=$(dns_unit_enabled_state) || { die "无法验证 systemd-resolved unit-file 状态"; return 1; }
    actual_active=$(dns_unit_active_state) || { die "无法验证 systemd-resolved active 状态"; return 1; }
    [[ "$actual_enabled" == enabled && "$actual_active" == active ]] || {
        die "systemd-resolved 生命周期验证失败: unit=$actual_enabled active=$actual_active"
        return 1
    }
}

dns_resolvectl_query() {
    local name="$1"
    if [[ $(type -t resolvectl) == function ]]; then
        LC_ALL=C resolvectl query "$name"
    else
        LC_ALL=C timeout 15 resolvectl query "$name"
    fi
}

dns_global_status_section() {
    awk '
        /^Global$/ { count++; in_global=(count == 1); next }
        /^Link [0-9]+/ { in_global=0; next }
        in_global { print }
        END { if (count != 1) exit 1 }
    '
}

dns_verify_applied_routing_domains() {
    local output reason global_line global_domains routing_rc
    output=$(LC_ALL=C resolvectl domain 2>/dev/null) || {
        die "应用后无法读取 routing domains；拒绝提交 DNS 策略"
        return 1
    }
    if reason=$(dns_complex_routing_reason_from_domains "$output"); then
        die "$reason；应用后 routing-domain 验证失败"
        return 1
    else
        routing_rc=$?
        if (( routing_rc != 1 )); then
            die "应用后的 routing-domain 输出无法可靠解析；拒绝提交 DNS 策略"
            return 1
        fi
    fi
    global_line=$(awk '/^Global:/ { print; exit }' <<< "$output")
    [[ -n "$global_line" ]] || { die "应用后缺少 Global DNS domain 状态"; return 1; }
    global_domains=${global_line#*:}
    global_domains=${global_domains#"${global_domains%%[![:space:]]*}"}
    [[ "$global_domains" == '~.' ]] || {
        die "应用后的 Global DNS domains 不是项目唯一的 ~.: ${global_domains:-empty}"
        return 1
    }
}

dns_verify_effective_global_servers() {
    local mode="$1" dns_output servers server global_count seen_cloudflare=0 seen_quad9=0
    dns_output=$(LC_ALL=C resolvectl dns 2>/dev/null) || {
        die "无法读取 effective Global DNS servers"
        return 1
    }
    global_count=$(grep -Ec '^Global:' <<< "$dns_output" || true)
    (( global_count == 1 )) || { die "effective DNS 状态必须且只能包含一个 Global 段"; return 1; }
    servers=$(awk '
        /^Global:/ {
            if (found) exit 2
            found=1
            sub(/^Global:[[:space:]]*/, "")
            if (length) printf "%s ", $0
            next
        }
        /^Link [0-9]+/ { if (found) exit; next }
        found && /^[[:space:]]+/ {
            sub(/^[[:space:]]+/, "")
            if (length) printf "%s ", $0
            next
        }
        found { exit }
        END { if (!found) exit 1 }
    ' <<< "$dns_output") || { die "effective DNS 状态缺少或无法解析 Global servers"; return 1; }
    servers=${servers% }
    [[ -n "$servers" ]] || { die "effective Global DNS servers 为空"; return 1; }
    for server in $servers; do
        if [[ "$mode" == dot ]]; then
            case "$server" in
                1.1.1.1#cloudflare-dns.com|1.1.1.1:53#cloudflare-dns.com|1.1.1.1:853#cloudflare-dns.com|2606:4700:4700::1111#cloudflare-dns.com|'[2606:4700:4700::1111]'#cloudflare-dns.com|'[2606:4700:4700::1111]':53#cloudflare-dns.com|'[2606:4700:4700::1111]':853#cloudflare-dns.com) seen_cloudflare=1 ;;
                9.9.9.9#dns.quad9.net|9.9.9.9:53#dns.quad9.net|9.9.9.9:853#dns.quad9.net|2620:fe::fe#dns.quad9.net|'[2620:fe::fe]'#dns.quad9.net|'[2620:fe::fe]':53#dns.quad9.net|'[2620:fe::fe]':853#dns.quad9.net) seen_quad9=1 ;;
                *) die "effective Global DoT servers 含有非项目上游: $server"; return 1 ;;
            esac
        else
            case "$server" in
                1.1.1.1|1.1.1.1:53|2606:4700:4700::1111|'[2606:4700:4700::1111]'|'[2606:4700:4700::1111]':53) seen_cloudflare=1 ;;
                9.9.9.9|9.9.9.9:53|2620:fe::fe|'[2620:fe::fe]'|'[2620:fe::fe]':53) seen_quad9=1 ;;
                *) die "effective Global DNS servers 含有非项目上游: $server"; return 1 ;;
            esac
        fi
    done
    (( seen_cloudflare == 1 && seen_quad9 == 1 )) || {
        die "effective Global DNS servers 缺少 Cloudflare 或 Quad9 上游: $servers"
        return 1
    }
}

dns_verify_effective_global_fallbacks() {
    local mode="$1" status global fallbacks server seen_google=0
    status=$(LC_ALL=C resolvectl status 2>/dev/null) || {
        die "无法读取 effective Global fallback DNS servers"
        return 1
    }
    global=$(dns_global_status_section <<< "$status") || {
        die "systemd-resolved 状态缺少 Global 段"
        return 1
    }
    fallbacks=$(awk '
        /^[[:space:]]*Fallback DNS Servers?([[:space:]]*:[[:space:]]*|[[:space:]]+)/ {
            if (found) exit 2
            found=1
            line=$0
            sub(/^[[:space:]]*Fallback DNS Servers?([[:space:]]*:[[:space:]]*|[[:space:]]+)/, "", line)
            if (length(line)) {
                if (line !~ /^([0-9]|\[)/) exit 2
                printf "%s ", line
            }
            collecting=1
            next
        }
        collecting {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (length(line) && line ~ /^([0-9]|\[)/) {
                printf "%s ", line
                next
            }
            exit
        }
        END { if (!found) exit 1 }
    ' <<< "$global") || {
        die "effective Global fallback DNS 状态缺失或无法解析"
        return 1
    }
    fallbacks=${fallbacks% }
    [[ -n "$fallbacks" ]] || { die "effective Global fallback DNS servers 为空"; return 1; }
    for server in $fallbacks; do
        if [[ "$mode" == dot ]]; then
            case "$server" in
                8.8.8.8#dns.google|8.8.8.8:53#dns.google|8.8.8.8:853#dns.google|2001:4860:4860::8888#dns.google|'[2001:4860:4860::8888]'#dns.google|'[2001:4860:4860::8888]':53#dns.google|'[2001:4860:4860::8888]':853#dns.google) seen_google=1 ;;
                *) die "effective Global DoT fallback 含有非项目上游: $server"; return 1 ;;
            esac
        else
            case "$server" in
                8.8.8.8|8.8.8.8:53|2001:4860:4860::8888|'[2001:4860:4860::8888]'|'[2001:4860:4860::8888]':53) seen_google=1 ;;
                *) die "effective Global DNS fallback 含有非项目上游: $server"; return 1 ;;
            esac
        fi
    done
    (( seen_google == 1 )) || { die "effective Global DNS fallback 缺少 Google 上游"; return 1; }
}

dns_verify_dot_global_status() {
    local status global
    status=$(LC_ALL=C resolvectl status 2>/dev/null) || {
        die "无法读取 systemd-resolved 状态，不能确认 DoT 已启用"
        return 1
    }
    global=$(dns_global_status_section <<< "$status") || {
        die "systemd-resolved 状态缺少 Global 段"
        return 1
    }
    grep -Eq '(^|[[:space:]])[+]DNSOverTLS([[:space:]]|$)|DNSOverTLS setting:[[:space:]]*yes' <<< "$global" || {
        die "systemd-resolved Global 段未报告 DNSOverTLS=yes"
        return 1
    }
    grep -Eq '(1[.]1[.]1[.]1(:53|:853)?|2606:4700:4700::1111|\[2606:4700:4700::1111\](:53|:853)?)#cloudflare-dns[.]com' <<< "$global" &&
        grep -Eq '(9[.]9[.]9[.]9(:53|:853)?|2620:fe::fe|\[2620:fe::fe\](:53|:853)?)#dns[.]quad9[.]net' <<< "$global" &&
        grep -Eq '(8[.]8[.]8[.]8(:53|:853)?|2001:4860:4860::8888|\[2001:4860:4860::8888\](:53|:853)?)#dns[.]google' <<< "$global" || {
        die "systemd-resolved Global 段未加载本项目的 DoT servers"
        return 1
    }
    grep -Eq 'DNS Domains?([[:space:]]*:[[:space:]]*|[[:space:]]+)~[.]([[:space:]]|$)' <<< "$global" || {
        die "systemd-resolved Global 段未加载项目的 Domains=~."
        return 1
    }

}

dns_verify_runtime() {
    local mode="$1" name query_output
    resolvectl flush-caches >/dev/null 2>&1 || true
    dns_verify_applied_routing_domains || return 1
    dns_verify_effective_global_servers "$mode" || return 1
    dns_verify_effective_global_fallbacks "$mode" || return 1
    if [[ "$mode" == dot ]]; then
        dns_verify_dot_global_status || return 1
    fi
    for name in example.com iana.org; do
        query_output=$(dns_resolvectl_query "$name" 2>/dev/null) || {
            if [[ "$mode" == dot ]]; then
                die "DoT 查询验证失败 ($name)；不会降级为普通公共 DNS"
            else
                die "DNS 查询验证失败 ($name)"
            fi
            return 1
        }
        if [[ "$mode" == dot ]] &&
           ! grep -Eiq 'Data was acquired via local or encrypted transport:[[:space:]]*yes' <<< "$query_output"; then
            die "DoT 查询缺少加密传输证据 ($name)；不会提交 DNS 策略"
            return 1
        fi
    done
}

dns_apply_steps() {
    local mode="$1" temp
    temp=$(mktemp) || return 1
    if [[ "$mode" == dot ]]; then
        cat > "$temp" <<'EOF' || { rm -f -- "$temp"; return 1; }
# Policy: strict-dot
[Resolve]
DNS=
FallbackDNS=
Domains=
DNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google 2001:4860:4860::8888#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
    else
        cat > "$temp" <<'EOF' || { rm -f -- "$temp"; return 1; }
# Policy: plain
[Resolve]
DNS=
FallbackDNS=
Domains=
DNS=1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe
FallbackDNS=8.8.8.8 2001:4860:4860::8888
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
    fi
    atomic_install "$temp" "$DNS_DROPIN" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    ln -sfn "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF" || { die "无法切换 resolv.conf"; return 1; }
    systemctl daemon-reload >/dev/null || { die "systemd 配置重载失败"; return 1; }
    dns_prepare_resolved_service || return 1
    dns_verify_runtime "$mode"
}

dns_apply() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl resolvectl timeout || return 1
    local mode="${1:-auto}" rc rollback_rc=0
    [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
    dns_refuse_pending_transaction || return 1
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_preflight_takeover || return 1
    dns_require_legacy_baseline_lifecycle_safety || return 1
    dns_capture_baseline || return 1
    if [[ "$mode" == auto ]]; then
        mode='dot'
        log INFO "自动模式将尝试经认证的 DoT；验证失败会完整回滚，不会降级为普通公共 DNS"
    fi
    dns_transaction_begin || return 1
    if dns_apply_steps "$mode"; then
        dns_transaction_commit
        if [[ "$mode" == dot ]]; then
            log OK "DNS 策略已应用: strict-dot"
        else
            log OK "DNS 策略已应用: plain"
        fi
        return 0
    else
        rc=$?
    fi
    log WARN "DNS 应用失败，正在恢复操作前状态"
    dns_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

dns_restore() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl || return 1
    local base="$DNS_BACKUP_DIR/baseline" rc rollback_rc=0
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_validate_snapshot "$base" 1 || { die "DNS 基线损坏或不完整: $base"; return 1; }
    dns_transaction_begin || return 1
    if dns_restore_snapshot "$base"; then
        dns_transaction_commit
        if [[ -f "$base/service.unit" ]]; then
            log OK "DNS 已恢复到首次修改前状态"
        else
            log WARN "DNS 文件与服务 active 状态已按旧基线恢复；旧基线未记录 unit-file 生命周期，enabled/masked 状态只能尽力保留"
        fi
        return 0
    else
        rc=$?
    fi
    log WARN "DNS 基线恢复失败，正在恢复本次操作前状态"
    dns_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

dns_status() {
    local owner enabled active routing="unavailable" reason routing_rc pending transaction="none"
    owner=$(dns_resolver_owner 2>/dev/null || printf 'unknown\n')
    if command_exists systemctl; then
        enabled=$(dns_unit_enabled_state 2>/dev/null) || enabled=unavailable
        active=$(dns_unit_active_state 2>/dev/null) || active=unavailable
    else
        enabled=unavailable
        active=unavailable
    fi
    if command_exists resolvectl; then
        if reason=$(dns_complex_routing_reason); then
            routing="complex ($reason)"
        else
            routing_rc=$?
            if (( routing_rc == 1 )); then routing=simple; else routing=unavailable; fi
        fi
    fi
    if pending=$(dns_pending_transaction); then transaction=${pending//$'\t'/': '}; fi
    printf 'Resolver owner: %s\n' "$owner"
    printf 'systemd-resolved: %s / %s\n' "$enabled" "$active"
    printf 'Routing domains: %s\n' "$routing"
    printf 'Pending transaction: %s\n' "$transaction"
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}

# shellcheck shell=bash
# -----------------------------------------------------------------------------
# DNS policy engine: read-only planning, canonical policy names and verification.
# The executor in dns.sh remains the only code allowed to mutate resolver state.
# -----------------------------------------------------------------------------

DNS_POLICY_SCHEMA=1
DNS_POLICY_REQUESTED=""
DNS_POLICY_CURRENT=""
DNS_POLICY_DECISION=""
DNS_POLICY_ACTION=""
DNS_POLICY_REASON=""
DNS_POLICY_RISKS=""
DNS_POLICY_OWNER=""
DNS_POLICY_UNIT=""
DNS_POLICY_ROUTING=""

dns_policy_normalize() {
    case "${1:-}" in
        native) printf 'native\n' ;;
        strict-dot|dot|auto) printf 'strict-dot\n' ;;
        plain) printf 'plain\n' ;;
        *)
            die "DNS policy 只支持 native/strict-dot/plain（兼容别名: auto/dot）"
            return 1
            ;;
    esac
}

dns_policy_detect_current() {
    local dot_value
    if [[ ! -e "$DNS_DROPIN" && ! -L "$DNS_DROPIN" ]]; then
        printf 'native\n'
        return 0
    fi
    dns_project_dropin_signature_valid || {
        printf 'foreign\n'
        return 0
    }
    dot_value=$(awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*DNSOverTLS[[:space:]]*=/ {
            value=$2
            gsub(/[[:space:]]/, "", value)
            print tolower(value)
            exit
        }
    ' "$DNS_DROPIN" 2>/dev/null) || return 1
    case "$dot_value" in
        yes) printf 'strict-dot\n' ;;
        no) printf 'plain\n' ;;
        *) printf 'foreign\n' ;;
    esac
}

dns_policy_compact_reason() {
    awk '
        NF {
            gsub(/\033\[[0-9;]*m/, "")
            gsub(/[[:space:]]+/, " ")
            sub(/^ /, ""); sub(/ $/, "")
            if (length($0)) {
                if (seen) printf "; "
                printf "%s", $0
                seen=1
            }
        }
        END { if (seen) printf "\n" }
    '
}

dns_policy_add_risk() {
    local risk="$1"
    [[ -n "$DNS_POLICY_RISKS" ]] && DNS_POLICY_RISKS+=","
    DNS_POLICY_RISKS+="$risk"
}

dns_policy_block() {
    DNS_POLICY_DECISION=blocked
    DNS_POLICY_ACTION=none
    DNS_POLICY_REASON="$1"
    return 1
}

dns_policy_collect() {
    local requested="${1:-strict-dot}" target output pending enabled active routing_reason routing_rc
    DNS_POLICY_REQUESTED=""; DNS_POLICY_CURRENT=""; DNS_POLICY_DECISION=""
    DNS_POLICY_ACTION=""; DNS_POLICY_REASON=""; DNS_POLICY_RISKS=""
    DNS_POLICY_OWNER=unavailable; DNS_POLICY_UNIT=unavailable; DNS_POLICY_ROUTING=unavailable

    target=$(dns_policy_normalize "$requested") || return 1
    DNS_POLICY_REQUESTED="$target"
    DNS_POLICY_CURRENT=$(dns_policy_detect_current) || DNS_POLICY_CURRENT=unknown
    DNS_POLICY_OWNER=$(dns_resolver_owner 2>/dev/null || printf 'unavailable\n')

    if command_exists systemctl; then
        enabled=$(dns_unit_enabled_state 2>/dev/null || printf 'unavailable\n')
        active=$(dns_unit_active_state 2>/dev/null || printf 'unavailable\n')
        DNS_POLICY_UNIT="$enabled/$active"
    fi
    if command_exists resolvectl; then
        if routing_reason=$(dns_complex_routing_reason 2>/dev/null); then
            DNS_POLICY_ROUTING="complex: $routing_reason"
        else
            routing_rc=$?
            if (( routing_rc == 1 )); then DNS_POLICY_ROUTING=simple; else DNS_POLICY_ROUTING=unavailable; fi
        fi
    fi

    if pending=$(dns_pending_transaction 2>/dev/null); then
        dns_policy_block "存在未完成 DNS 事务: ${pending//$'\t'/ }"
        return 1
    fi

    if [[ "$target" == native ]]; then
        if [[ -e "$DNS_BACKUP_DIR/baseline" || -L "$DNS_BACKUP_DIR/baseline" ]]; then
            dns_validate_snapshot "$DNS_BACKUP_DIR/baseline" 1 || {
                dns_policy_block "DNS 基线损坏或不完整，不能安全恢复"
                return 1
            }
            DNS_POLICY_DECISION=ready
            DNS_POLICY_ACTION=restore-baseline
            DNS_POLICY_REASON="恢复首次可信 DNS 基线；不推测或重建原解析器配置"
            return 0
        fi
        if [[ "$DNS_POLICY_CURRENT" == strict-dot || "$DNS_POLICY_CURRENT" == plain ]]; then
            dns_policy_block "检测到项目 DNS 策略，但没有可验证基线；拒绝猜测原始 DNS 状态"
            return 1
        fi
        DNS_POLICY_DECISION=noop
        DNS_POLICY_ACTION=preserve-native
        DNS_POLICY_REASON="没有项目基线或已管理策略；保持现有解析器不变"
        return 0
    fi
    if [[ "$DNS_POLICY_CURRENT" == foreign ]]; then
        dns_policy_block "策略文件路径已被非本项目内容占用: $DNS_DROPIN"
        return 1
    fi
    command_exists systemctl && command_exists resolvectl || {
        dns_policy_block "缺少 systemctl/resolvectl，不能管理 systemd-resolved"
        return 1
    }
    if ! output=$(systemctl cat systemd-resolved 2>&1); then
        dns_policy_block "系统未提供 systemd-resolved"
        return 1
    fi
    if ! output=$(dns_preflight_takeover 2>&1); then
        output=$(dns_policy_compact_reason <<< "$output")
        dns_policy_block "${output:-DNS 接管安全检查失败}"
        return 1
    fi
    if ! output=$(dns_require_legacy_baseline_lifecycle_safety 2>&1); then
        output=$(dns_policy_compact_reason <<< "$output")
        dns_policy_block "${output:-旧 DNS 基线缺少安全生命周期信息}"
        return 1
    fi

    DNS_POLICY_DECISION=ready
    if [[ "$DNS_POLICY_CURRENT" == "$target" ]]; then
        DNS_POLICY_ACTION=verify-and-repair
        DNS_POLICY_REASON="策略文件已匹配；仍将事务性重载并执行真实查询验证"
    elif [[ "$target" == strict-dot ]]; then
        DNS_POLICY_ACTION=install-strict-dot
        DNS_POLICY_REASON="配置经认证 DoT；任何验证失败都会恢复操作前状态，不降级"
    else
        DNS_POLICY_ACTION=install-plain
        DNS_POLICY_REASON="显式配置普通公共 DNS；不会由 strict-dot 自动降级到该策略"
        dns_policy_add_risk plaintext-dns
    fi
    [[ "$DNS_POLICY_OWNER" == absent ]] && dns_policy_add_risk create-resolver-owner
    [[ "$DNS_POLICY_UNIT" == disabled/active || "$DNS_POLICY_UNIT" == enabled-runtime/active ]] &&
        dns_policy_add_risk persist-systemd-resolved
    return 0
}

dns_policy_print_plan() {
    printf '%-20s %s\n' 'Policy module' 'DNS'
    printf '%-20s %s\n' 'Requested policy' "${DNS_POLICY_REQUESTED:-unknown}"
    printf '%-20s %s\n' 'Current policy' "${DNS_POLICY_CURRENT:-unknown}"
    printf '%-20s %s\n' 'Decision' "${DNS_POLICY_DECISION:-unknown}"
    printf '%-20s %s\n' 'Action' "${DNS_POLICY_ACTION:-none}"
    printf '%-20s %s\n' 'Resolver owner' "${DNS_POLICY_OWNER:-unavailable}"
    printf '%-20s %s\n' 'Resolved lifecycle' "${DNS_POLICY_UNIT:-unavailable}"
    printf '%-20s %s\n' 'Routing domains' "${DNS_POLICY_ROUTING:-unavailable}"
    printf '%-20s %s\n' 'Risks' "${DNS_POLICY_RISKS:-none}"
    printf '%-20s %s\n' 'Reason' "${DNS_POLICY_REASON:-none}"
    printf '%-20s %s\n' 'Plan mutation' 'none (read-only)'
}

dns_policy_plan() {
    local rc=0
    dns_policy_collect "${1:-strict-dot}" || rc=$?
    dns_policy_print_plan
    return "$rc"
}

dns_policy_snapshot_object_matches() {
    local left="$1" right="$2"
    if [[ -L "$left" || -L "$right" ]]; then
        [[ -L "$left" && -L "$right" ]] || return 1
        [[ "$(readlink "$left")" == "$(readlink "$right")" ]]
    else
        [[ -f "$left" && -f "$right" ]] || return 1
        cmp -s -- "$left" "$right"
    fi
}

dns_policy_native_matches_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" state name temp rc=0
    dns_validate_snapshot "$base" 1 || return 1
    temp=$(mktemp -d) || return 1
    if ! dns_snapshot_current "$temp" || ! dns_validate_snapshot "$temp" 0; then
        rm -rf -- "$temp"
        return 1
    fi
    for name in resolv dropin; do
        cmp -s -- "$base/${name}.state" "$temp/${name}.state" || { rc=1; continue; }
        state=$(<"$base/${name}.state") || { rc=1; continue; }
        if [[ "$state" == present ]]; then
            dns_policy_snapshot_object_matches "$base/${name}.conf" "$temp/${name}.conf" || rc=1
        fi
    done
    if [[ -f "$base/service.unit" ]]; then
        cmp -s -- "$base/service.unit" "$temp/service.unit" || rc=1
    else
        cmp -s -- "$base/service.active" "$temp/service.active" || rc=1
    fi
    rm -rf -- "$temp"
    return "$rc"
}

dns_policy_verify() {
    local requested="${1:-}" target current owner enabled active base="$DNS_BACKUP_DIR/baseline"
    if [[ -n "$requested" ]]; then
        target=$(dns_policy_normalize "$requested") || return 1
    else
        target=$(dns_policy_detect_current) || return 1
    fi
    current=$(dns_policy_detect_current) || return 1
    if [[ "$target" == native ]]; then
        if [[ -e "$base" || -L "$base" ]]; then
            dns_policy_native_matches_baseline || {
                die "DNS native 策略与首次可信文件/服务生命周期基线不一致"
                return 1
            }
        elif [[ "$current" != native ]]; then
            die "DNS native 策略无法验证: observed=$current 且没有可信基线"
            return 1
        fi
        log OK "DNS native 策略验证通过：项目未接管当前解析器"
        return 0
    fi
    [[ "$target" == strict-dot || "$target" == plain ]] || {
        die "当前 DNS 状态不是可验证的规范策略: $target"
        return 1
    }
    [[ "$current" == "$target" ]] || {
        die "DNS 策略漂移: expected=$target observed=$current"
        return 1
    }

    require_commands systemctl resolvectl timeout || return 1
    owner=$(dns_resolver_owner) || return 1
    enabled=$(dns_unit_enabled_state) || return 1
    active=$(dns_unit_active_state) || return 1
    [[ "$owner" == systemd-resolved && "$enabled" == enabled && "$active" == active ]] || {
        die "DNS 运行时漂移: owner=$owner unit=$enabled/$active"
        return 1
    }
    if [[ "$target" == strict-dot ]]; then
        dns_verify_runtime dot || return 1
    else
        dns_verify_runtime plain || return 1
    fi
    log OK "DNS 策略与运行时一致: $target"
}

dns_policy_apply() {
    local requested="${1:-strict-dot}" target rc=0
    target=$(dns_policy_normalize "$requested") || return 1
    dns_policy_collect "$target" || rc=$?
    dns_policy_print_plan
    (( rc == 0 )) || return "$rc"
    if [[ "$DNS_POLICY_DECISION" == noop ]]; then
        log OK "DNS native 策略无需修改"
        return 0
    fi
    if [[ "$target" == native ]]; then
        dns_restore || return 1
        dns_policy_verify native
    elif [[ "$target" == strict-dot ]]; then
        dns_apply dot || return 1
        [[ "$(dns_policy_detect_current)" == strict-dot ]] || {
            die "DNS 提交后策略识别失败"
            return 1
        }
    else
        dns_apply plain || return 1
        [[ "$(dns_policy_detect_current)" == plain ]] || {
            die "DNS 提交后策略识别失败"
            return 1
        }
    fi
}

dns_policy_status() {
    local current owner enabled active health=unmanaged
    current=$(dns_policy_detect_current 2>/dev/null || printf 'unknown\n')
    owner=$(dns_resolver_owner 2>/dev/null || printf 'unavailable\n')
    enabled=$(dns_unit_enabled_state 2>/dev/null || printf 'unavailable\n')
    active=$(dns_unit_active_state 2>/dev/null || printf 'unavailable\n')
    if [[ "$current" == strict-dot || "$current" == plain ]]; then
        if [[ "$owner" == systemd-resolved && "$enabled" == enabled && "$active" == active ]]; then
            health='structurally-consistent; run dns verify for live-query proof'
        else
            health="drift ($owner, $enabled/$active)"
        fi
    elif [[ "$current" == foreign ]]; then
        health='foreign policy file; not managed'
    fi
    printf '%-24s %s\n' 'DNS policy schema' "$DNS_POLICY_SCHEMA"
    printf '%-24s %s\n' 'DNS inferred policy' "$current"
    printf '%-24s %s\n' 'DNS policy health' "$health"
    dns_status
}

# -----------------------------------------------------------------------------
# IPv6: explicit, interface-aware policy with immutable baseline and rollback.
# -----------------------------------------------------------------------------

IPV6_SYSCTL_FILE="${BBRV3_IPV6_SYSCTL_FILE:-/etc/sysctl.d/99-bbrv3-lite-ipv6.conf}"
if [[ ${BBRV3_IPV6_PROC_CONF_ROOT+x} == x ]]; then
    IPV6_PROC_CONF_ROOT_EXPLICIT=1
else
    IPV6_PROC_CONF_ROOT_EXPLICIT=0
fi
IPV6_PROC_CONF_ROOT="${BBRV3_IPV6_PROC_CONF_ROOT:-/proc/sys/net/ipv6/conf}"
IPV6_CMDLINE_FILE="${BBRV3_IPV6_CMDLINE_FILE:-/proc/cmdline}"
IPV6_MODULE_DISABLE_FILE="${BBRV3_IPV6_MODULE_DISABLE_FILE:-/sys/module/ipv6/parameters/disable}"
IPV6_SNAPSHOT_SCHEMA=2
IPV6_TRANSACTION_DIR=""
IPV6_LAST_RESTORE_QUALITY=""
IPV6_TOPOLOGY_REASON=""
IPV6_RESTORE_DISABLE_TARGETS=""
IPV6_RESTORE_DISABLES_LOOPBACK=0
IPV6_SNAPSHOT_VALIDATION_ERROR=""
IPV6_SNAPSHOT_CAPTURE=""

ipv6_valid_interface_name() {
    local iface="$1"
    [[ -n "$iface" && "$iface" != . && "$iface" != .. && "$iface" =~ ^[-[:alnum:]_.:@+]+$ ]]
}

ipv6_proc_backend_available() {
    # A shell function named sysctl normally means a unit-test or an embedding
    # shim. Do not bypass such a shim and write to the host's real /proc tree.
    if (( IPV6_PROC_CONF_ROOT_EXPLICIT == 0 )) && declare -F sysctl >/dev/null; then
        return 1
    fi
    [[ -d "$IPV6_PROC_CONF_ROOT" ]]
}

ipv6_conf_path() {
    local iface="$1"
    ipv6_valid_interface_name "$iface" || { die "无效的 IPv6 接口名: $iface"; return 1; }
    printf '%s/%s/disable_ipv6\n' "${IPV6_PROC_CONF_ROOT%/}" "$iface"
}

ipv6_list_runtime_interfaces() {
    local path iface nullglob_was_set=0
    local -a paths=()
    if ! ipv6_proc_backend_available; then
        # Compatibility-only fallback. It deliberately reports a partial view;
        # mutating transactions refuse to proceed without the /proc interface map.
        printf '%s\n' all default lo
        return 2
    fi
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    paths=( "${IPV6_PROC_CONF_ROOT%/}"/*/disable_ipv6 )
    (( nullglob_was_set )) || shopt -u nullglob
    ((${#paths[@]})) || return 1
    for path in "${paths[@]}"; do
        iface=${path%/disable_ipv6}
        iface=${iface##*/}
        ipv6_valid_interface_name "$iface" || {
            die "IPv6 接口名无法安全写入快照: $iface"
            return 1
        }
        printf '%s\n' "$iface"
    done
}

ipv6_sysctl_key() {
    local iface="$1"
    ipv6_valid_interface_name "$iface" || return 1
    printf 'net.ipv6.conf.%s.disable_ipv6\n' "$iface"
}

ipv6_read_interface_value() {
    local iface="$1" path value key
    if ipv6_proc_backend_available; then
        path=$(ipv6_conf_path "$iface") || return 1
        [[ -r "$path" ]] || return 1
        IFS= read -r value < "$path" || return 1
    else
        key=$(ipv6_sysctl_key "$iface") || return 1
        value=$(sysctl -n "$key" 2>/dev/null) || return 1
    fi
    [[ "$value" == 0 || "$value" == 1 ]] || return 1
    printf '%s\n' "$value"
}

ipv6_write_interface_value() {
    local iface="$1" value="$2" path key
    [[ "$value" == 0 || "$value" == 1 ]] || { die "无效的 IPv6 sysctl 值: $value"; return 1; }
    if ipv6_proc_backend_available; then
        path=$(ipv6_conf_path "$iface") || return 1
        [[ -e "$path" ]] || { log WARN "IPv6 接口已消失，无法恢复: $iface"; return 1; }
        if ! printf '%s\n' "$value" > "$path"; then
            log WARN "无法写入 IPv6 接口状态: $iface=$value"
            return 1
        fi
    else
        key=$(ipv6_sysctl_key "$iface") || return 1
        sysctl -q -w "$key=$value"
    fi
}

ipv6_boot_disable_source() {
    local cmdline="" module_value=""
    [[ ! -r "$IPV6_CMDLINE_FILE" ]] || cmdline=$(<"$IPV6_CMDLINE_FILE")
    if [[ " $cmdline " =~ [[:space:]]ipv6\.disable=(1|y|Y|yes|YES)[[:space:]] ]]; then
        printf 'kernel-command-line\n'
        return 0
    fi
    [[ ! -r "$IPV6_MODULE_DISABLE_FILE" ]] || module_value=$(<"$IPV6_MODULE_DISABLE_FILE")
    case "$module_value" in
        1|y|Y|yes|YES) printf 'module-parameter\n'; return 0 ;;
    esac
    printf 'none\n'
    return 1
}

ipv6_boot_disabled() {
    [[ "$(ipv6_boot_disable_source || true)" != none ]]
}

ipv6_ssh_family() {
    local client="" server="" _ignored=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client _ignored server _ignored <<< "$SSH_CONNECTION"
        if [[ "$client" == *:* || "$server" == *:* ]]; then printf 'IPv6\n'; else printf 'IPv4\n'; fi
    else
        printf 'not-ssh/unknown\n'
    fi
}

ipv6_default_route_mode() {
    local v4="" v6=""
    if command_exists ip; then
        v4=$(ip -4 route show default 2>/dev/null || true)
        v6=$(ip -6 route show default 2>/dev/null || true)
    fi
    if [[ -n "$v4" && -n "$v6" ]]; then printf 'dual-stack\n'
    elif [[ -n "$v4" ]]; then printf 'IPv4-only\n'
    elif [[ -n "$v6" ]]; then printf 'IPv6-only\n'
    else printf 'none/unknown\n'
    fi
}

ipv6_address_output_has_routable_topology() {
    local input="$1" line iface family address scope field previous=""
    local -a fields=()
    IPV6_TOPOLOGY_REASON=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r -a fields <<< "$line"
        ((${#fields[@]} >= 4)) || continue
        iface=${fields[1]%%@*}
        family=${fields[2]}
        address=${fields[3],,}
        [[ "$family" == inet6 && "$iface" != lo ]] || continue
        scope=""; previous=""
        for field in "${fields[@]}"; do
            if [[ "$previous" == scope ]]; then scope="$field"; break; fi
            previous="$field"
        done
        if [[ "$scope" == global || "${address%%/*}" =~ ^f[cd] ]]; then
            IPV6_TOPOLOGY_REASON="address $address on $iface (scope ${scope:-unknown})"
            return 0
        fi
    done <<< "$input"
    return 1
}

ipv6_address_output_has_loopback_address() {
    local input="$1" line iface family address
    local -a fields=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r -a fields <<< "$line"
        ((${#fields[@]} >= 4)) || continue
        iface=${fields[1]%%@*}
        family=${fields[2]}
        address=${fields[3],,}
        [[ "$iface" == lo && "$family" == inet6 && "${address%%/*}" == ::1 ]] || continue
        return 0
    done <<< "$input"
    return 1
}

ipv6_route_output_has_business_topology() {
    local input="$1" line first second destination="" route_type="" normalized
    IPV6_TOPOLOGY_REASON=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        first=""; second=""; destination=""; route_type=""
        read -r first second _ <<< "$line"
        route_type=""
        case "$first" in
            unreachable|blackhole|prohibit|throw)
                # These are negative policy entries, not a usable IPv6 path.
                continue
                ;;
            local|broadcast|multicast|anycast|nat)
                route_type="$first"
                destination="$second"
                ;;
            *)
                destination="$first"
                ;;
        esac
        [[ -n "$destination" ]] || continue
        if [[ "$destination" == default ]]; then
            IPV6_TOPOLOGY_REASON="default route: $line"
            return 0
        fi
        normalized=${destination,,}
        normalized=${normalized%%/*}
        case "$normalized" in
            ::1|fe[89ab]*|ff*) continue ;;
        esac
        IPV6_TOPOLOGY_REASON="${route_type:+$route_type }route $destination"
        return 0
    done <<< "$input"
    return 1
}

ipv6_read_topology_diagnostics() {
    local addresses_file="$1" routes_file="$2"
    if ! ip -6 -o addr show > "$addresses_file" 2>/dev/null; then
        die "无法读取 IPv6 地址拓扑；为避免不可恢复地删除地址，拒绝继续"
        return 1
    fi
    if ! ip -6 route show table all > "$routes_file" 2>/dev/null; then
        die "无法读取 IPv6 路由拓扑；为避免不可恢复地删除路由，拒绝继续"
        return 1
    fi
}

ipv6_disable_topology_preflight() {
    local addresses_file routes_file addresses routes reason
    addresses_file=$(mktemp) || return 1
    routes_file=$(mktemp) || { rm -f -- "$addresses_file"; return 1; }
    if ! ipv6_read_topology_diagnostics "$addresses_file" "$routes_file"; then
        rm -f -- "$addresses_file" "$routes_file"
        return 1
    fi
    addresses=$(<"$addresses_file")
    routes=$(<"$routes_file")
    rm -f -- "$addresses_file" "$routes_file"
    if ipv6_address_output_has_routable_topology "$addresses"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "检测到可路由 IPv6 地址（$reason）；禁用会删除地址且仅恢复 flag 无法重建，拒绝操作"
        return 1
    fi
    if ipv6_route_output_has_business_topology "$routes"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "检测到 IPv6 业务路由（$reason）；禁用会删除路由且仅恢复 flag 无法重建，拒绝操作"
        return 1
    fi
}

ipv6_capture_topology_diagnostics() {
    local directory="$1"
    ipv6_read_topology_diagnostics "$directory/addresses-v6.txt" "$directory/routes-v6.txt"
}

ipv6_snapshot_has_routable_topology() {
    local directory="$1" addresses="" routes=""
    [[ ! -f "$directory/addresses-v6.txt" ]] || addresses=$(<"$directory/addresses-v6.txt")
    [[ ! -f "$directory/routes-v6.txt" ]] || routes=$(<"$directory/routes-v6.txt")
    ipv6_address_output_has_routable_topology "$addresses" ||
        ipv6_route_output_has_business_topology "$routes"
}

ipv6_restore_collect_disable_targets() {
    local directory="$1" record iface value key current targets=""
    IPV6_RESTORE_DISABLE_TARGETS=""
    IPV6_RESTORE_DISABLES_LOOPBACK=0
    if ipv6_snapshot_is_v2 "$directory"; then
        while IFS=$'\t' read -r record iface value; do
            [[ "$record" == INTERFACE ]] || continue
            [[ "$value" == 0 || "$value" == 1 ]] || {
                die "IPv6 v2 快照包含无效 disable flag: $iface=$value"
                return 1
            }
            [[ "$value" == 1 && "$iface" != default ]] || continue
            current=$(ipv6_read_interface_value "$iface" 2>/dev/null) || continue
            [[ "$current" == 0 || "$current" == 1 ]] || continue
            targets+="${targets:+,}$iface"
            [[ "$iface" != lo ]] || IPV6_RESTORE_DISABLES_LOOPBACK=1
        done < "$directory/sysctl.tsv"
    else
        while IFS=$'\t' read -r key value; do
            [[ -n "$key" ]] || continue
            [[ "$value" == 0 || "$value" == 1 ]] || {
                die "旧 IPv6 快照包含无效 disable flag: $key=$value"
                return 1
            }
            [[ "$value" == 1 ]] || continue
            case "$key" in
                net.ipv6.conf.default.disable_ipv6) continue ;;
                net.ipv6.conf.all.disable_ipv6)
                    targets+="${targets:+,}all(write-trigger)"
                    IPV6_RESTORE_DISABLES_LOOPBACK=1
                    ;;
                net.ipv6.conf.*.disable_ipv6)
                    iface=${key#net.ipv6.conf.}
                    iface=${iface%.disable_ipv6}
                    if current=$(ipv6_read_interface_value "$iface" 2>/dev/null); then
                        targets+="${targets:+,}$iface"
                        [[ "$iface" != lo ]] || IPV6_RESTORE_DISABLES_LOOPBACK=1
                    fi
                    ;;
                *)
                    # The legacy restorer writes every recorded key. Unknown
                    # target=1 records therefore receive the same fail-closed gate.
                    targets+="${targets:+,}$key"
                    ;;
            esac
        done < "$directory/sysctl.tsv"
    fi
    IPV6_RESTORE_DISABLE_TARGETS="$targets"
}

ipv6_restore_target_preflight() {
    local directory="$1" addresses_file routes_file addresses routes reason
    ipv6_restore_collect_disable_targets "$directory" || return 1
    [[ -n "$IPV6_RESTORE_DISABLE_TARGETS" ]] || return 0

    addresses_file=$(mktemp) || return 1
    routes_file=$(mktemp) || { rm -f -- "$addresses_file"; return 1; }
    if ! ipv6_read_topology_diagnostics "$addresses_file" "$routes_file"; then
        rm -f -- "$addresses_file" "$routes_file"
        return 1
    fi
    addresses=$(<"$addresses_file")
    routes=$(<"$routes_file")
    rm -f -- "$addresses_file" "$routes_file"

    if (( IPV6_RESTORE_DISABLES_LOOPBACK )) && ipv6_address_output_has_loopback_address "$addresses"; then
        die "目标 IPv6 快照会禁用 lo，但当前存在 ::1；写入会删除回环地址且无法重建，拒绝恢复"
        return 1
    fi
    if ipv6_address_output_has_routable_topology "$addresses"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "目标 IPv6 快照会把现有接口置为禁用（$IPV6_RESTORE_DISABLE_TARGETS），且当前存在可路由地址（$reason）；拒绝恢复"
        return 1
    fi
    if ipv6_route_output_has_business_topology "$routes"; then
        reason="$IPV6_TOPOLOGY_REASON"
        die "目标 IPv6 快照会把现有接口置为禁用（$IPV6_RESTORE_DISABLE_TARGETS），且当前存在业务路由（$reason）；拒绝恢复"
        return 1
    fi
}

ipv6_disable_preflight() {
    local boot_source ssh_family route_mode
    boot_source=$(ipv6_boot_disable_source || true)
    [[ "$boot_source" == none ]] || {
        die "IPv6 已由启动级策略禁用（$boot_source）；运行时 sysctl 无法安全管理，需修改启动配置并重启"
        return 1
    }
    ssh_family=$(ipv6_ssh_family)
    [[ "$ssh_family" != IPv6 ]] || {
        die "当前 SSH 管理会话使用 IPv6；拒绝禁用以避免立即断开连接"
        return 1
    }
    route_mode=$(ipv6_default_route_mode)
    [[ "$route_mode" == IPv4-only ]] || {
        die "IPv6 禁用仅允许有 IPv4 默认出口且没有 IPv6 默认出口的主机；当前为 $route_mode"
        return 1
    }
    ipv6_disable_topology_preflight
}

ipv6_snapshot_is_v2() {
    local directory="$1"
    [[ -e "$directory/snapshot.meta" || -L "$directory/snapshot.meta" ]] ||
        grep -Fqx $'FORMAT\tinterface-values-v2' "$directory/manifest" 2>/dev/null ||
        awk -F'\t' '$1=="AGGREGATE" || $1=="INTERFACE" {found=1; exit} END {exit !found}' \
            "$directory/sysctl.tsv" 2>/dev/null
}

ipv6_snapshot_validation_fail() {
    IPV6_SNAPSHOT_VALIDATION_ERROR="$1"
    return 1
}

ipv6_validate_snapshot_persistent() {
    local directory="$1" state
    local -a state_lines=()
    [[ -f "$directory/persistent.state" && ! -L "$directory/persistent.state" ]] ||
        ipv6_snapshot_validation_fail "缺少常规文件 persistent.state" || return 1
    mapfile -t state_lines < "$directory/persistent.state" ||
        ipv6_snapshot_validation_fail "无法读取 persistent.state" || return 1
    ((${#state_lines[@]} == 1)) ||
        ipv6_snapshot_validation_fail "persistent.state 必须且只能包含一行" || return 1
    state=${state_lines[0]}
    [[ "$state" == present || "$state" == absent ]] ||
        ipv6_snapshot_validation_fail "persistent.state 非法: $state" || return 1
    if [[ "$state" == present && ! -f "$directory/persistent.conf" && ! -L "$directory/persistent.conf" ]]; then
        ipv6_snapshot_validation_fail "persistent.state=present 但缺少 persistent.conf"
        return 1
    fi
    if [[ "$state" == absent && ( -e "$directory/persistent.conf" || -L "$directory/persistent.conf" ) ]]; then
        ipv6_snapshot_validation_fail "persistent.state=absent 但存在多余 persistent.conf"
        return 1
    fi
}

ipv6_validate_manifest() {
    local directory="$1" is_v2="$2" line key value metadata_value
    local -A fields=()
    [[ -f "$directory/manifest" && ! -L "$directory/manifest" ]] ||
        ipv6_snapshot_validation_fail "基线缺少常规文件 manifest" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* && "${line#*$'\t'}" != *$'\t'* ]] || {
            ipv6_snapshot_validation_fail "manifest 行格式非法"
            return 1
        }
        key="${line%%$'\t'*}"; value="${line#*$'\t'}"
        [[ -n "$key" && -n "$value" ]] || { ipv6_snapshot_validation_fail "manifest 含空字段"; return 1; }
        [[ -z "${fields[$key]+x}" ]] || { ipv6_snapshot_validation_fail "manifest 键重复: $key"; return 1; }
        case "$key" in
            CREATED_AT|CREATED_BY|FORMAT|SCHEMA|CAPTURE|RESTORE_SCOPE|AGGREGATE_ALL|TOPOLOGY_DIAGNOSTICS) ;;
            *) ipv6_snapshot_validation_fail "manifest 含未知键: $key"; return 1 ;;
        esac
        fields[$key]="$value"
    done < "$directory/manifest"
    [[ "${fields[CREATED_AT]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        ipv6_snapshot_validation_fail "manifest CREATED_AT 非法"
        return 1
    }
    [[ "${fields[CREATED_BY]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || {
        ipv6_snapshot_validation_fail "manifest CREATED_BY 非法"
        return 1
    }
    if (( is_v2 )); then
        (( ${#fields[@]} == 8 )) || { ipv6_snapshot_validation_fail "v2 manifest 字段集合不完整"; return 1; }
        for key in FORMAT SCHEMA CAPTURE RESTORE_SCOPE AGGREGATE_ALL TOPOLOGY_DIAGNOSTICS; do
            metadata_value=$(awk -F'\t' -v wanted="$key" '$1==wanted {print $2; exit}' "$directory/snapshot.meta") || return 1
            [[ "${fields[$key]:-}" == "$metadata_value" ]] || {
                ipv6_snapshot_validation_fail "manifest 与 snapshot.meta 不一致: $key"
                return 1
            }
        done
    else
        (( ${#fields[@]} == 2 )) || { ipv6_snapshot_validation_fail "旧版 manifest 含不受支持字段"; return 1; }
    fi
}

ipv6_validate_v2_metadata() {
    local directory="$1" key value extra capture=""
    local -A seen=()
    IPV6_SNAPSHOT_CAPTURE=""
    [[ -f "$directory/snapshot.meta" && ! -L "$directory/snapshot.meta" ]] ||
        ipv6_snapshot_validation_fail "v2 快照缺少常规文件 snapshot.meta" || return 1
    while IFS=$'\t' read -r key value extra || [[ -n "$key$value$extra" ]]; do
        [[ -n "$key" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 行格式非法"
            return 1
        }
        [[ -z "${seen[$key]+x}" ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 键重复: $key"
            return 1
        }
        seen["$key"]=1
        case "$key:$value" in
            FORMAT:interface-values-v2|SCHEMA:"$IPV6_SNAPSHOT_SCHEMA"|RESTORE_SCOPE:disable-flags-only|AGGREGATE_ALL:audit-only/write-trigger/not-replayed|TOPOLOGY_DIAGNOSTICS:diagnostic-only/not-replayable) ;;
            CAPTURE:per-interface|CAPTURE:boot-disabled|CAPTURE:partial) capture="$value" ;;
            *)
                ipv6_snapshot_validation_fail "snapshot.meta 键值非法: $key=$value"
                return 1
                ;;
        esac
    done < "$directory/snapshot.meta"
    for key in FORMAT SCHEMA CAPTURE RESTORE_SCOPE AGGREGATE_ALL TOPOLOGY_DIAGNOSTICS; do
        [[ "${seen[$key]:-0}" == 1 ]] || {
            ipv6_snapshot_validation_fail "snapshot.meta 缺少键: $key"
            return 1
        }
    done
    IPV6_SNAPSHOT_CAPTURE="$capture"
}

ipv6_validate_v2_records() {
    local directory="$1" capture="$2" record iface value extra rows=0 aggregate=0 default_seen=0 lo_seen=0
    local -A interfaces=()
    [[ -f "$directory/sysctl.tsv" && ! -L "$directory/sysctl.tsv" ]] ||
        ipv6_snapshot_validation_fail "v2 快照缺少常规文件 sysctl.tsv" || return 1
    while IFS=$'\t' read -r record iface value extra || [[ -n "$record$iface$value$extra" ]]; do
        [[ -n "$record" && -n "$iface" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "sysctl.tsv 行格式非法"
            return 1
        }
        ipv6_valid_interface_name "$iface" || {
            ipv6_snapshot_validation_fail "sysctl.tsv 接口名非法: $iface"
            return 1
        }
        [[ "$value" == 0 || "$value" == 1 ]] || {
            ipv6_snapshot_validation_fail "sysctl.tsv disable flag 非法: $iface=$value"
            return 1
        }
        rows=$((rows + 1))
        case "$record:$iface" in
            AGGREGATE:all)
                aggregate=$((aggregate + 1))
                (( aggregate == 1 )) || {
                    ipv6_snapshot_validation_fail "AGGREGATE all 重复"
                    return 1
                }
                ;;
            INTERFACE:all)
                ipv6_snapshot_validation_fail "all 只能作为 AGGREGATE 审计记录"
                return 1
                ;;
            INTERFACE:*)
                [[ -z "${interfaces[$iface]+x}" ]] || {
                    ipv6_snapshot_validation_fail "INTERFACE 记录重复: $iface"
                    return 1
                }
                interfaces["$iface"]=1
                [[ "$iface" != default ]] || default_seen=1
                [[ "$iface" != lo ]] || lo_seen=1
                ;;
            *)
                ipv6_snapshot_validation_fail "sysctl.tsv 记录类型非法: $record/$iface"
                return 1
                ;;
        esac
    done < "$directory/sysctl.tsv"

    if [[ "$capture" == boot-disabled ]]; then
        (( rows == 0 )) || {
            ipv6_snapshot_validation_fail "boot-disabled 快照不得伪造运行时接口值"
            return 1
        }
    else
        (( aggregate == 1 && default_seen == 1 && lo_seen == 1 )) || {
            ipv6_snapshot_validation_fail "逐接口快照必须恰有 AGGREGATE all、INTERFACE default 和 INTERFACE lo"
            return 1
        }
    fi
}

ipv6_validate_legacy_records() {
    local directory="$1" key value extra iface rows=0
    local -A seen=()
    [[ -f "$directory/sysctl.tsv" && ! -L "$directory/sysctl.tsv" ]] ||
        ipv6_snapshot_validation_fail "旧快照缺少常规文件 sysctl.tsv" || return 1
    while IFS=$'\t' read -r key value extra || [[ -n "$key$value$extra" ]]; do
        [[ -n "$key" && -n "$value" && -z "$extra" ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl.tsv 行格式非法"
            return 1
        }
        case "$key" in
            net.ipv6.conf.*.disable_ipv6)
                iface=${key#net.ipv6.conf.}
                iface=${iface%.disable_ipv6}
                ipv6_valid_interface_name "$iface" || {
                    ipv6_snapshot_validation_fail "旧 sysctl 接口名非法: $iface"
                    return 1
                }
                ;;
            *)
                ipv6_snapshot_validation_fail "旧 sysctl key 非法: $key"
                return 1
                ;;
        esac
        [[ "$value" == 0 || "$value" == 1 ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl disable flag 非法: $key=$value"
            return 1
        }
        [[ -z "${seen[$key]+x}" ]] || {
            ipv6_snapshot_validation_fail "旧 sysctl key 重复: $key"
            return 1
        }
        seen["$key"]=1
        rows=$((rows + 1))
    done < "$directory/sysctl.tsv"
    (( rows > 0 )) || {
        ipv6_snapshot_validation_fail "旧 sysctl.tsv 为空"
        return 1
    }
}

ipv6_validate_snapshot() {
    local directory="$1" require_manifest="${2:-0}" capture is_v2=0
    IPV6_SNAPSHOT_VALIDATION_ERROR=""
    [[ -d "$directory" && ! -L "$directory" ]] ||
        ipv6_snapshot_validation_fail "快照目录不存在或不是常规目录" || return 1
    ipv6_validate_snapshot_persistent "$directory" || return 1
    if ipv6_snapshot_is_v2 "$directory"; then
        is_v2=1
        ipv6_validate_v2_metadata "$directory" || return 1
        capture="$IPV6_SNAPSHOT_CAPTURE"
        ipv6_validate_v2_records "$directory" "$capture" || return 1
        [[ -f "$directory/addresses-v6.txt" && ! -L "$directory/addresses-v6.txt" ]] ||
            ipv6_snapshot_validation_fail "v2 快照缺少地址诊断文件" || return 1
        [[ -f "$directory/routes-v6.txt" && ! -L "$directory/routes-v6.txt" ]] ||
            ipv6_snapshot_validation_fail "v2 快照缺少路由诊断文件" || return 1
    else
        ipv6_validate_legacy_records "$directory" || return 1
    fi
    if (( require_manifest )) || [[ -e "$directory/manifest" || -L "$directory/manifest" ]]; then
        ipv6_validate_manifest "$directory" "$is_v2" || return 1
    fi
}

ipv6_snapshot_quality() {
    local directory="$1" require_manifest="${2:-0}" capture=""
    if ! ipv6_validate_snapshot "$directory" "$require_manifest"; then
        printf 'malformed/invalid\n'
        return 0
    fi
    if ipv6_snapshot_is_v2 "$directory"; then
        capture=$(awk -F'\t' '$1=="CAPTURE" {print $2}' "$directory/snapshot.meta")
    fi
    case "$capture" in
        per-interface) printf 'disable-flags-exact\n' ;;
        boot-disabled) printf 'persistent-only\n' ;;
        *) printf 'legacy/partial-best-effort\n' ;;
    esac
}

ipv6_snapshot_current() {
    local directory="$1" iface value capture=per-interface list_rc=0
    local saw_all=0 saw_default=0 saw_lo=0
    local interfaces_file
    mkdir -p -- "$directory" || return 1
    : > "$directory/sysctl.tsv" || return 1
    interfaces_file="$directory/.interfaces"
    if ipv6_boot_disabled; then
        capture=boot-disabled
        : > "$interfaces_file"
    else
        if ipv6_list_runtime_interfaces > "$interfaces_file"; then
            capture=per-interface
        else
            list_rc=$?
            (( list_rc == 2 )) || { rm -f -- "$interfaces_file"; return 1; }
            capture=partial
        fi
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            value=$(ipv6_read_interface_value "$iface") || {
                die "无法读取 IPv6 运行时状态: $iface"
                rm -f -- "$interfaces_file"
                return 1
            }
            case "$iface" in all) saw_all=1 ;; default) saw_default=1 ;; lo) saw_lo=1 ;; esac
            if [[ "$iface" == all ]]; then
                printf 'AGGREGATE\tall\t%s\n' "$value" >> "$directory/sysctl.tsv" || return 1
            else
                printf 'INTERFACE\t%s\t%s\n' "$iface" "$value" >> "$directory/sysctl.tsv" || return 1
            fi
        done < "$interfaces_file"
        if [[ "$capture" == per-interface ]] && (( saw_all == 0 || saw_default == 0 || saw_lo == 0 )); then
            die "IPv6 /proc 视图缺少 all/default/lo，无法建立逐接口 disable flags 快照"
            rm -f -- "$interfaces_file"
            return 1
        fi
    fi
    rm -f -- "$interfaces_file"

    ipv6_capture_topology_diagnostics "$directory" || return 1

    printf 'FORMAT\tinterface-values-v2\nSCHEMA\t%s\nCAPTURE\t%s\nRESTORE_SCOPE\tdisable-flags-only\nAGGREGATE_ALL\taudit-only/write-trigger/not-replayed\nTOPOLOGY_DIAGNOSTICS\tdiagnostic-only/not-replayable\n' \
        "$IPV6_SNAPSHOT_SCHEMA" "$capture" > "$directory/snapshot.meta" || return 1

    if [[ -e "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]]; then
        cp -a -- "$IPV6_SYSCTL_FILE" "$directory/persistent.conf" || return 1
        printf 'present\n' > "$directory/persistent.state" || return 1
    else
        printf 'absent\n' > "$directory/persistent.state" || return 1
    fi
    ipv6_validate_snapshot "$directory" || {
        die "刚创建的 IPv6 快照校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    }
}

ipv6_restore_persistent_snapshot() {
    local directory="$1" state=absent rc=0
    rm -f -- "$IPV6_SYSCTL_FILE" || rc=1
    [[ ! -f "$directory/persistent.state" ]] || state=$(<"$directory/persistent.state")
    if [[ "$state" == present ]]; then
        [[ -e "$directory/persistent.conf" || -L "$directory/persistent.conf" ]] || return 1
        mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")" || rc=1
        cp -a -- "$directory/persistent.conf" "$IPV6_SYSCTL_FILE" || rc=1
    fi
    return "$rc"
}

ipv6_snapshot_interface_set_matches_current() {
    local directory="$1" captured_file current_file list_rc=0 captured current
    captured_file=$(mktemp) || return 1
    current_file=$(mktemp) || { rm -f -- "$captured_file"; return 1; }
    awk -F'\t' '$1=="INTERFACE" && $2!="default" {print $2}' "$directory/sysctl.tsv" | LC_ALL=C sort -u > "$captured_file"
    if ipv6_list_runtime_interfaces | awk '$0!="all" && $0!="default"' | LC_ALL=C sort -u > "$current_file"; then
        :
    else
        list_rc=${PIPESTATUS[0]}
    fi
    if (( list_rc != 0 )); then
        rm -f -- "$captured_file" "$current_file"
        log WARN "无法枚举当前全部 IPv6 接口；拒绝声称 disable flags 精确恢复"
        return 1
    fi
    if cmp -s -- "$captured_file" "$current_file"; then
        rm -f -- "$captured_file" "$current_file"
        return 0
    fi
    captured=$(paste -sd, "$captured_file" 2>/dev/null || true)
    current=$(paste -sd, "$current_file" 2>/dev/null || true)
    rm -f -- "$captured_file" "$current_file"
    log WARN "IPv6 接口集合已变化；无法声称 disable flags 精确恢复（快照: ${captured:-none}；当前: ${current:-none}）"
    return 1
}

ipv6_restore_v2_runtime() {
    local directory="$1" record iface value default_value="" rc=0
    while IFS=$'\t' read -r record iface value; do
        case "$record:$iface" in
            INTERFACE:default) default_value="$value" ;;
        esac
    done < "$directory/sysctl.tsv"

    # all is a write trigger, not a safely replayable aggregate state. Replaying
    # even a historically observed value can delete IPv6 topology added after
    # capture. It remains in the snapshot for audit only and is never written.
    if [[ -n "$default_value" ]]; then ipv6_write_interface_value default "$default_value" || rc=1; fi
    while IFS=$'\t' read -r record iface value; do
        [[ "$record" == INTERFACE && "$iface" != default ]] || continue
        ipv6_write_interface_value "$iface" "$value" || rc=1
    done < "$directory/sysctl.tsv"
    return "$rc"
}

ipv6_restore_legacy_runtime() {
    local directory="$1" key value aggregate_key="" aggregate_value="" rc=0
    while IFS=$'\t' read -r key value; do
        [[ "$key" == net.ipv6.conf.all.disable_ipv6 ]] || continue
        aggregate_key="$key"; aggregate_value="$value"; break
    done < "$directory/sysctl.tsv"
    if [[ -n "$aggregate_key" ]] && ! sysctl -q -w "$aggregate_key=$aggregate_value"; then rc=1; fi
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" && "$key" != net.ipv6.conf.all.disable_ipv6 ]] || continue
        if ! sysctl -q -w "$key=$value"; then rc=1; fi
    done < "$directory/sysctl.tsv"
    return "$rc"
}

ipv6_restore_snapshot() {
    local directory="$1" context="${2:-baseline}" quality rc=0 interface_drift=0
    [[ "$context" == baseline || "$context" == transaction ]] || {
        die "无效的 IPv6 快照恢复上下文: $context"
        return 1
    }
    if ! ipv6_validate_snapshot "$directory"; then
        IPV6_LAST_RESTORE_QUALITY="malformed/invalid"
        die "IPv6 快照校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    fi
    quality=$(ipv6_snapshot_quality "$directory")
    IPV6_LAST_RESTORE_QUALITY="$quality"
    ipv6_restore_target_preflight "$directory" || return 1
    if ipv6_boot_disabled; then
        ipv6_restore_persistent_snapshot "$directory" || rc=1
        IPV6_LAST_RESTORE_QUALITY="persistent-only/reboot-required"
        log WARN "启动级 IPv6 禁用仍然生效；已恢复持久化文件，但运行时状态只能在修改启动配置并重启后恢复"
        return "$rc"
    fi
    if [[ "$quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$directory" &&
       ! ipv6_snapshot_interface_set_matches_current "$directory"; then
        IPV6_LAST_RESTORE_QUALITY="partial/interface-set-changed"
        if [[ "$context" == baseline ]]; then
            return 1
        fi
        interface_drift=1
    fi
    ipv6_restore_persistent_snapshot "$directory" || rc=1
    if ipv6_snapshot_is_v2 "$directory"; then
        ipv6_restore_v2_runtime "$directory" || rc=1
    else
        log WARN "旧 IPv6 基线没有逐接口原值；仅执行 best-effort 恢复，无法证明每张网卡都回到首次状态"
        ipv6_restore_legacy_runtime "$directory" || rc=1
        IPV6_LAST_RESTORE_QUALITY="legacy/partial-best-effort"
    fi
    (( interface_drift == 0 )) || rc=1
    return "$rc"
}

ipv6_capture_baseline() {
    local base="$IPV6_BACKUP_DIR/baseline" temp_dir
    # Existing baselines are immutable, including legacy/partial baselines. Their
    # reduced restore capability is reported, never hidden by recapturing current state.
    if [[ -e "$base" || -L "$base" ]]; then
        if ! ipv6_validate_snapshot "$base" 1; then
            die "现有 IPv6 基线损坏（${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}）；为避免覆盖首次基线，拒绝继续"
            return 1
        fi
        return 0
    fi
    ensure_state_layout || return 1
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    chmod 0700 "$IPV6_BACKUP_DIR" 2>/dev/null || true
    temp_dir=$(mktemp -d "${IPV6_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$temp_dir"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
    if ipv6_snapshot_has_routable_topology "$temp_dir"; then
        log ERR "IPv6 拓扑在基线捕获期间变为可路由状态；拒绝保存可能诱导不可恢复操作的基线"
        remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
    if
       ! { printf 'CREATED_AT\t%s\nCREATED_BY\t%s\n' "$(utc_now)" "$SCRIPT_VERSION"; cat "$temp_dir/snapshot.meta"; } > "$temp_dir/manifest" ||
       ! ipv6_validate_snapshot "$temp_dir" 1 ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$IPV6_BACKUP_DIR" || true
        return 1
    fi
}

ipv6_pending_transaction() {
    local candidate
    for candidate in "$IPV6_BACKUP_DIR"/.transaction.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

ipv6_refuse_pending_transaction() {
    local pending
    if pending=$(ipv6_pending_transaction); then
        die "发现上次未完成的 IPv6 事务: $pending；为避免覆盖可审计的回滚现场，拒绝继续。请先人工核验并恢复或移走该目录"
        return 1
    fi
}

ipv6_transaction_begin() {
    local quality
    [[ -z "$IPV6_TRANSACTION_DIR" ]] || { die "已有未提交的 IPv6 事务"; return 1; }
    ipv6_refuse_pending_transaction || return 1
    mkdir -p -- "$IPV6_BACKUP_DIR" || return 1
    IPV6_TRANSACTION_DIR=$(mktemp -d "${IPV6_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! ipv6_snapshot_current "$IPV6_TRANSACTION_DIR" || ! chmod -R go-rwx "$IPV6_TRANSACTION_DIR"; then
        remove_tree_within "$IPV6_TRANSACTION_DIR" "$IPV6_BACKUP_DIR" || true
        IPV6_TRANSACTION_DIR=""
        return 1
    fi
    quality=$(ipv6_snapshot_quality "$IPV6_TRANSACTION_DIR")
    if [[ "$quality" == legacy/partial-best-effort || "$quality" == malformed/invalid ]]; then
        die "IPv6 事务快照质量为 $quality；拒绝开始无法可靠回滚的修改"
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
    ipv6_restore_snapshot "$directory" transaction || rc=1
    if (( rc == 0 )); then remove_tree_within "$directory" "$IPV6_BACKUP_DIR" || rc=1; fi
    if (( rc == 0 )); then
        IPV6_TRANSACTION_DIR=""
        log OK "已恢复本次 IPv6 操作前的逐接口 disable flags；地址和路由未作重放"
    else
        if [[ "$IPV6_LAST_RESTORE_QUALITY" == partial/interface-set-changed ]]; then
            log WARN "接口集合已变化：已尽力恢复持久策略、default 和仍存在的已捕获接口；新增接口保持当前值"
        fi
        log ERR "IPv6 自动回滚未完全成功；事务快照保留在 $directory"
    fi
    return "$rc"
}

ipv6_snapshot_interface_value() {
    local directory="$1" wanted="$2" record iface value
    while IFS=$'\t' read -r record iface value; do
        [[ "$record" == INTERFACE && "$iface" == "$wanted" ]] || continue
        printf '%s\n' "$value"
        return 0
    done < "$directory/sysctl.tsv"
    return 1
}

ipv6_disable_runtime_from_snapshot() {
    local directory="$1" record iface lo_before rc=0
    lo_before=$(ipv6_snapshot_interface_value "$directory" lo) || {
        die "IPv6 事务缺少 lo 原值"
        return 1
    }
    ipv6_write_interface_value default 1 || rc=1
    while IFS=$'\t' read -r record iface _; do
        [[ "$record" == INTERFACE ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        ipv6_write_interface_value "$iface" 1 || rc=1
    done < "$directory/sysctl.tsv"
    (( rc == 0 )) || return "$rc"

    [[ "$(ipv6_read_interface_value default 2>/dev/null || true)" == 1 ]] || {
        die "IPv6 默认接口策略禁用验证失败"
        return 1
    }
    while IFS=$'\t' read -r record iface _; do
        [[ "$record" == INTERFACE ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        [[ "$(ipv6_read_interface_value "$iface" 2>/dev/null || true)" == 1 ]] || {
            die "IPv6 禁用验证失败: $iface"
            return 1
        }
    done < "$directory/sysctl.tsv"
    [[ "$(ipv6_read_interface_value lo 2>/dev/null || true)" == "$lo_before" ]] || {
        die "IPv6 回环接口状态发生意外变化；拒绝提交"
        return 1
    }
}

ipv6_write_persistent_policy() {
    local snapshot="$1" temp record iface
    temp=$(mktemp) || return 1
    {
        printf '%s\n' '# Managed by bbrv3-lite' '# Policy: disabled-persistent' '# IPv6 is disabled per interface; lo/::1 is intentionally not modified.'
        printf '%s\n' 'net/ipv6/conf/default/disable_ipv6 = 1'
        while IFS=$'\t' read -r record iface _; do
            [[ "$record" == INTERFACE ]] || continue
            case "$iface" in all|default|lo) continue ;; esac
            printf 'net/ipv6/conf/%s/disable_ipv6 = 1\n' "$iface"
        done < "$snapshot/sysctl.tsv"
    } > "$temp"
    atomic_install "$temp" "$IPV6_SYSCTL_FILE" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
}

ipv6_disable_steps() {
    local mode="$1" snapshot="$2"
    ipv6_disable_runtime_from_snapshot "$snapshot" || { die "部分 IPv6 运行时值修改失败"; return 1; }
    if [[ "$mode" == permanent ]]; then
        ipv6_write_persistent_policy "$snapshot" || return 1
    else
        rm -f -- "$IPV6_SYSCTL_FILE" || return 1
    fi
}

ipv6_disable() {
    require_root || return 1; require_host_network_control || return 1
    acquire_lock || return 1; require_commands sysctl ip || return 1
    local mode="${1:-temporary}" rc rollback_rc=0 baseline_quality mode_label
    [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
    ipv6_refuse_pending_transaction || return 1
    ipv6_disable_preflight || return 1
    ipv6_capture_baseline || return 1
    baseline_quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
    if [[ "$baseline_quality" != disable-flags-exact ]]; then
        log WARN "现有 IPv6 基线为 $baseline_quality；disable flags 只能尽力恢复，地址和路由从不伪装可重放"
    fi
    ipv6_transaction_begin || return 1
    if ! ipv6_disable_topology_preflight; then
        # No runtime or persistent mutation has happened yet. Discarding the
        # transaction snapshot is safer than replaying flags over a topology that
        # may have appeared between the first preflight and this final gate.
        ipv6_transaction_commit
        return 1
    fi
    if ipv6_disable_steps "$mode" "$IPV6_TRANSACTION_DIR"; then
        ipv6_transaction_commit
        if [[ "$mode" == permanent ]]; then mode_label=永久; else mode_label=临时; fi
        log OK "IPv6 已${mode_label}禁用（保留 lo/::1）"
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
    require_root || return 1; require_host_network_control || return 1
    acquire_lock || return 1; require_commands sysctl ip || return 1
    local base="$IPV6_BACKUP_DIR/baseline" rc rollback_rc=0 baseline_quality failed_quality
    ipv6_refuse_pending_transaction || return 1
    [[ -e "$base" && -d "$base" && ! -L "$base" ]] || { die "没有 IPv6 基线"; return 1; }
    if ! ipv6_validate_snapshot "$base" 1; then
        IPV6_LAST_RESTORE_QUALITY="malformed/invalid"
        die "IPv6 基线校验失败: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
        return 1
    fi
    baseline_quality=$(ipv6_snapshot_quality "$base" 1)
    # Run before creating the transaction snapshot or writing persistent/runtime
    # state. Any target=1 that could destroy current topology must fail closed.
    ipv6_restore_target_preflight "$base" || return 1
    if ! ipv6_boot_disabled && [[ "$baseline_quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$base" &&
       ! ipv6_snapshot_interface_set_matches_current "$base"; then
        IPV6_LAST_RESTORE_QUALITY="partial/interface-set-changed"
        return 1
    fi
    ipv6_transaction_begin || return 1
    if ! ipv6_restore_target_preflight "$base"; then
        # The first gate runs before any transaction/state mutation. Repeat
        # immediately before replay to catch topology appearing in that window;
        # no target state has been written, so discard rather than replay rollback.
        ipv6_transaction_commit
        return 1
    fi
    if ipv6_restore_snapshot "$base"; then
        ipv6_transaction_commit
        if [[ "$baseline_quality" == disable-flags-exact && "$IPV6_LAST_RESTORE_QUALITY" == disable-flags-exact ]]; then
            log OK "IPv6 disable flags 已按逐接口基线精确恢复；地址和路由仅保留诊断快照，不作重放"
        else
            log WARN "IPv6 disable flags 已按 $IPV6_LAST_RESTORE_QUALITY 恢复；无法宣称地址或路由已还原"
        fi
        return 0
    else
        rc=$?
        failed_quality="$IPV6_LAST_RESTORE_QUALITY"
    fi
    log WARN "IPv6 基线恢复失败（${failed_quality:-unknown}），正在恢复本次操作前状态"
    ipv6_transaction_rollback || rollback_rc=$?
    IPV6_LAST_RESTORE_QUALITY="${failed_quality:-unknown}"
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

ipv6_status() {
    local iface value boot_source ssh_family route_mode baseline_quality=absent list_file list_rc=0
    boot_source=$(ipv6_boot_disable_source || true)
    ssh_family=$(ipv6_ssh_family)
    route_mode=$(ipv6_default_route_mode)
    if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
        baseline_quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
    fi

    printf '%-48s %s\n' 'IPv6 boot-level disable' "$boot_source"
    printf '%-48s %s\n' 'Current SSH management path' "$ssh_family"
    printf '%-48s %s\n' 'Default-route families' "$route_mode"
    list_file=$(mktemp) || return 1
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else list_rc=$?; fi
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null || printf 'unavailable\n')
        case "$iface" in
            all) printf '%-48s %s\n' 'all write-trigger (observed; not aggregate state)' "$value" ;;
            default) printf '%-48s %s\n' 'new-interface default disable_ipv6' "$value" ;;
            lo) printf '%-48s %s\n' 'interface lo disable_ipv6' "$value" ;;
            *) printf '%-48s %s\n' "interface $iface disable_ipv6" "$value" ;;
        esac
    done < "$list_file"
    rm -f -- "$list_file"
    (( list_rc == 0 )) || printf '%-48s %s\n' 'Per-interface enumeration' 'partial/unavailable'
    printf '%-48s %s\n' 'bbrv3-lite persistent policy' "$([[ -f "$IPV6_SYSCTL_FILE" ]] && echo present || echo absent)"
    printf '%-48s %s\n' 'bbrv3-lite IPv6 baseline' "$baseline_quality"
}

# shellcheck shell=bash
# -----------------------------------------------------------------------------
# IPv6 policy engine: topology-aware planning and independently verifiable state.
# The executor in ipv6.sh owns all runtime/persistent mutations and transactions.
# -----------------------------------------------------------------------------

IPV6_POLICY_SCHEMA=1
IPV6_POLICY_REQUESTED=""
IPV6_POLICY_CURRENT=""
IPV6_POLICY_DECISION=""
IPV6_POLICY_ACTION=""
IPV6_POLICY_REASON=""
IPV6_POLICY_RISKS=""
IPV6_POLICY_BOOT=""
IPV6_POLICY_SSH=""
IPV6_POLICY_ROUTES=""
IPV6_POLICY_TOPOLOGY=""

ipv6_policy_normalize() {
    case "${1:-}" in
        native) printf 'native\n' ;;
        disabled-temporary|temporary) printf 'disabled-temporary\n' ;;
        disabled-persistent|permanent) printf 'disabled-persistent\n' ;;
        *)
            die "IPv6 policy 只支持 native/disabled-temporary/disabled-persistent（兼容别名: temporary/permanent）"
            return 1
            ;;
    esac
}

ipv6_project_policy_signature_kind() {
    local line normalized iface header=0 default_seen=0 non_lo=0 legacy_all=0 legacy_default=0 legacy_lo=0
    local -A seen=()
    [[ -f "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        normalized=${line%$'\r'}
        [[ -n "${normalized//[[:space:]]/}" ]] || continue
        if [[ "$normalized" =~ ^[[:space:]]*# ]]; then
            [[ "$normalized" == *"Managed by bbrv3-lite"* ]] && header=1
            continue
        fi
        if [[ "$normalized" =~ ^[[:space:]]*net/ipv6/conf/([-[:alnum:]_.:@+]+)/disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            ipv6_valid_interface_name "$iface" || return 1
            [[ -z "${seen[$iface]+x}" ]] || return 1
            seen["$iface"]=1
            case "$iface" in
                default) default_seen=1 ;;
                all|lo) return 1 ;;
                *) non_lo=$((non_lo + 1)) ;;
            esac
            continue
        fi
        if [[ "$normalized" =~ ^[[:space:]]*net[.]ipv6[.]conf[.](all|default|lo)[.]disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            case "$iface" in
                all) legacy_all=$((legacy_all + 1)) ;;
                default) legacy_default=$((legacy_default + 1)) ;;
                lo) legacy_lo=$((legacy_lo + 1)) ;;
            esac
            continue
        fi
        return 1
    done < "$IPV6_SYSCTL_FILE"
    (( header == 1 )) || return 1
    if (( default_seen == 1 && non_lo >= 1 && legacy_all == 0 && legacy_default == 0 && legacy_lo == 0 )); then
        printf 'interface-policy\n'
        return 0
    fi
    if (( default_seen == 0 && non_lo == 0 && legacy_all == 1 && legacy_default == 1 && legacy_lo == 1 )); then
        printf 'legacy-all-policy\n'
        return 0
    fi
    return 1
}

ipv6_policy_runtime_disabled() {
    local iface value list_file rc=0 non_lo=0
    list_file=$(mktemp) || return 2
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else rc=$?; fi
    (( rc == 0 )) || { rm -f -- "$list_file"; return 2; }
    value=$(ipv6_read_interface_value default 2>/dev/null) || { rm -f -- "$list_file"; return 2; }
    [[ "$value" == 1 ]] || { rm -f -- "$list_file"; return 1; }
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        case "$iface" in all|default|lo) continue ;; esac
        non_lo=$((non_lo + 1))
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || { rm -f -- "$list_file"; return 2; }
        [[ "$value" == 1 ]] || { rm -f -- "$list_file"; return 1; }
    done < "$list_file"
    rm -f -- "$list_file"
    (( non_lo >= 1 )) || return 2
    return 0
}

ipv6_policy_persistent_interface_set_matches_current() {
    local line iface list_file rc=0 expected_count=0 current_count=0
    local -A expected=() current=()
    [[ -f "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*net/ipv6/conf/([-[:alnum:]_.:@+]+)/disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$ ]]; then
            iface=${BASH_REMATCH[1]}
            case "$iface" in all|default|lo) continue ;; esac
            expected["$iface"]=1
            expected_count=$((expected_count + 1))
        fi
    done < "$IPV6_SYSCTL_FILE"
    list_file=$(mktemp) || return 1
    if ipv6_list_runtime_interfaces > "$list_file"; then :; else rc=$?; fi
    (( rc == 0 )) || { rm -f -- "$list_file"; return 1; }
    while IFS= read -r iface; do
        case "$iface" in ''|all|default|lo) continue ;; esac
        current["$iface"]=1
        current_count=$((current_count + 1))
    done < "$list_file"
    rm -f -- "$list_file"
    (( expected_count == current_count )) || return 1
    for iface in "${!expected[@]}"; do [[ "${current[$iface]:-0}" == 1 ]] || return 1; done
}

ipv6_policy_detect_current() {
    local kind="" runtime_rc=0 baseline=0
    [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]] && baseline=1
    if [[ -e "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]]; then
        kind=$(ipv6_project_policy_signature_kind 2>/dev/null) || {
            printf 'foreign\n'
            return 0
        }
    fi
    if ipv6_policy_runtime_disabled; then runtime_rc=0; else runtime_rc=$?; fi
    case "$kind:$runtime_rc" in
        interface-policy:0)
            if ipv6_policy_persistent_interface_set_matches_current; then
                printf 'disabled-persistent\n'
            else
                printf 'disabled-persistent-drift\n'
            fi
            ;;
        interface-policy:*) printf 'disabled-persistent-drift\n' ;;
        legacy-all-policy:0) printf 'legacy-disabled-persistent\n' ;;
        legacy-all-policy:*) printf 'legacy-disabled-drift\n' ;;
        :0)
            if (( baseline )); then printf 'disabled-temporary\n'; else printf 'external-disabled\n'; fi
            ;;
        :1) printf 'native\n' ;;
        :2) printf 'unknown\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

ipv6_policy_compact_reason() {
    awk '
        NF {
            gsub(/\033\[[0-9;]*m/, "")
            gsub(/[[:space:]]+/, " ")
            sub(/^ /, ""); sub(/ $/, "")
            if (length($0)) {
                if (seen) printf "; "
                printf "%s", $0
                seen=1
            }
        }
        END { if (seen) printf "\n" }
    '
}

ipv6_policy_add_risk() {
    local risk="$1"
    [[ -n "$IPV6_POLICY_RISKS" ]] && IPV6_POLICY_RISKS+=","
    IPV6_POLICY_RISKS+="$risk"
}

ipv6_policy_block() {
    IPV6_POLICY_DECISION=blocked
    IPV6_POLICY_ACTION=none
    IPV6_POLICY_REASON="$1"
    return 1
}

ipv6_policy_collect() {
    local requested="${1:-disabled-temporary}" target output pending quality list_rc=0
    IPV6_POLICY_REQUESTED=""; IPV6_POLICY_CURRENT=""; IPV6_POLICY_DECISION=""
    IPV6_POLICY_ACTION=""; IPV6_POLICY_REASON=""; IPV6_POLICY_RISKS=""
    IPV6_POLICY_BOOT=$(ipv6_boot_disable_source 2>/dev/null || true); IPV6_POLICY_BOOT=${IPV6_POLICY_BOOT:-none}
    IPV6_POLICY_SSH=$(ipv6_ssh_family)
    IPV6_POLICY_ROUTES=$(ipv6_default_route_mode)
    IPV6_POLICY_TOPOLOGY=not-inspected

    target=$(ipv6_policy_normalize "$requested") || return 1
    IPV6_POLICY_REQUESTED="$target"
    IPV6_POLICY_CURRENT=$(ipv6_policy_detect_current) || IPV6_POLICY_CURRENT=unknown

    if pending=$(ipv6_pending_transaction 2>/dev/null); then
        ipv6_policy_block "存在未完成 IPv6 事务: ${pending//$'\t'/ }"
        return 1
    fi

    if [[ "$target" == native ]]; then
        if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
            ipv6_validate_snapshot "$IPV6_BACKUP_DIR/baseline" 1 || {
                ipv6_policy_block "IPv6 基线损坏或不完整: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
                return 1
            }
            quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
            if ! output=$(ipv6_restore_target_preflight "$IPV6_BACKUP_DIR/baseline" 2>&1); then
                output=$(ipv6_policy_compact_reason <<< "$output")
                IPV6_POLICY_TOPOLOGY=unsafe
                ipv6_policy_block "${output:-IPv6 基线恢复拓扑检查失败}"
                return 1
            fi
            if [[ "$IPV6_POLICY_BOOT" == none && "$quality" == disable-flags-exact ]] &&
               ipv6_snapshot_is_v2 "$IPV6_BACKUP_DIR/baseline" &&
               ! ipv6_snapshot_interface_set_matches_current "$IPV6_BACKUP_DIR/baseline" >/dev/null 2>&1; then
                IPV6_POLICY_TOPOLOGY='interface-set-drift'
                ipv6_policy_block "当前接口集合与首次可信 IPv6 基线不同；拒绝声称可精确恢复"
                return 1
            fi
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_TOPOLOGY='safe-for-restore'
            if [[ "$IPV6_POLICY_BOOT" != none ]]; then
                IPV6_POLICY_ACTION=restore-persistence-reboot-required
                IPV6_POLICY_REASON="启动级 IPv6 禁用仍生效；只恢复持久文件（质量: $quality），运行时需修改启动配置并重启"
                ipv6_policy_add_risk reboot-required
            else
                IPV6_POLICY_ACTION=restore-baseline
                IPV6_POLICY_REASON="恢复首次可信 disable flags 与持久文件（质量: $quality）；地址和路由只作诊断，不伪装可重放"
            fi
            [[ "$quality" == disable-flags-exact ]] || ipv6_policy_add_risk partial-legacy-baseline
            return 0
        fi
        case "$IPV6_POLICY_CURRENT" in
            disabled-persistent|disabled-persistent-drift|legacy-disabled-persistent|legacy-disabled-drift|disabled-temporary)
                ipv6_policy_block "检测到项目 IPv6 策略，但没有可验证基线；拒绝猜测原始 IPv6 状态"
                return 1
                ;;
        esac
        IPV6_POLICY_DECISION=noop
        IPV6_POLICY_ACTION=preserve-native
        IPV6_POLICY_REASON="没有项目基线或已管理策略；保持当前 IPv6 状态不变"
        return 0
    fi

    case "$IPV6_POLICY_CURRENT" in
        foreign)
            ipv6_policy_block "策略文件路径已被非本项目内容占用: $IPV6_SYSCTL_FILE"
            return 1
            ;;
        legacy-disabled-persistent|legacy-disabled-drift)
            ipv6_policy_block "检测到会修改 all/lo 的旧版 IPv6 策略；请先应用 native 恢复基线，再选择新的逐接口策略"
            return 1
            ;;
    esac
    command_exists ip || {
        ipv6_policy_block "缺少 ip 命令，不能审计 IPv6 地址和路由拓扑"
        return 1
    }
    if ipv6_list_runtime_interfaces >/dev/null 2>&1; then :; else list_rc=$?; fi
    (( list_rc == 0 )) || {
        ipv6_policy_block "无法获得完整的逐接口 IPv6 disable flags，拒绝生成不可精确恢复的策略"
        return 1
    }
    if [[ -e "$IPV6_BACKUP_DIR/baseline" || -L "$IPV6_BACKUP_DIR/baseline" ]]; then
        ipv6_validate_snapshot "$IPV6_BACKUP_DIR/baseline" 1 || {
            ipv6_policy_block "现有 IPv6 基线损坏或不完整: ${IPV6_SNAPSHOT_VALIDATION_ERROR:-unknown}"
            return 1
        }
        quality=$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline" 1)
        [[ "$quality" == disable-flags-exact ]] || ipv6_policy_add_risk partial-legacy-baseline
    fi
    if ! output=$(ipv6_disable_preflight 2>&1); then
        output=$(ipv6_policy_compact_reason <<< "$output")
        IPV6_POLICY_TOPOLOGY=unsafe
        ipv6_policy_block "${output:-IPv6 拓扑安全检查失败}"
        return 1
    fi
    IPV6_POLICY_TOPOLOGY='safe-no-routable-ipv6'

    case "$target:$IPV6_POLICY_CURRENT" in
        disabled-temporary:disabled-temporary|disabled-persistent:disabled-persistent)
            IPV6_POLICY_DECISION=noop
            IPV6_POLICY_ACTION=verify-current
            IPV6_POLICY_REASON="当前策略已匹配；只执行独立一致性验证"
            ;;
        disabled-temporary:*)
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_ACTION=disable-runtime-remove-persistence
            IPV6_POLICY_REASON="逐接口临时禁用，保留 lo/::1；重启后由系统原生配置决定"
            ;;
        disabled-persistent:*)
            IPV6_POLICY_DECISION=ready
            IPV6_POLICY_ACTION=disable-runtime-install-persistence
            IPV6_POLICY_REASON="逐接口禁用并写入持久策略，保留 lo/::1"
            ipv6_policy_add_risk persistent-ipv6-disable
            ;;
    esac
    ipv6_policy_add_risk address-autoconfiguration-stops
    return 0
}

ipv6_policy_print_plan() {
    printf '%-22s %s\n' 'Policy module' 'IPv6'
    printf '%-22s %s\n' 'Requested policy' "${IPV6_POLICY_REQUESTED:-unknown}"
    printf '%-22s %s\n' 'Current policy' "${IPV6_POLICY_CURRENT:-unknown}"
    printf '%-22s %s\n' 'Decision' "${IPV6_POLICY_DECISION:-unknown}"
    printf '%-22s %s\n' 'Action' "${IPV6_POLICY_ACTION:-none}"
    printf '%-22s %s\n' 'Boot-level disable' "${IPV6_POLICY_BOOT:-unknown}"
    printf '%-22s %s\n' 'SSH path' "${IPV6_POLICY_SSH:-unknown}"
    printf '%-22s %s\n' 'Default routes' "${IPV6_POLICY_ROUTES:-unknown}"
    printf '%-22s %s\n' 'Topology gate' "${IPV6_POLICY_TOPOLOGY:-not-inspected}"
    printf '%-22s %s\n' 'Risks' "${IPV6_POLICY_RISKS:-none}"
    printf '%-22s %s\n' 'Reason' "${IPV6_POLICY_REASON:-none}"
    printf '%-22s %s\n' 'Plan mutation' 'none (read-only)'
}

ipv6_policy_plan() {
    local rc=0
    ipv6_policy_collect "${1:-disabled-temporary}" || rc=$?
    ipv6_policy_print_plan
    return "$rc"
}

ipv6_policy_persistent_matches_snapshot() {
    local directory="$1" state
    state=$(<"$directory/persistent.state") || return 1
    case "$state" in
        absent) [[ ! -e "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] ;;
        present)
            [[ -f "$IPV6_SYSCTL_FILE" || -L "$IPV6_SYSCTL_FILE" ]] || return 1
            cmp -s -- "$directory/persistent.conf" "$IPV6_SYSCTL_FILE"
            ;;
        *) return 1 ;;
    esac
}

ipv6_policy_runtime_matches_snapshot() {
    local directory="$1" quality record iface expected key value
    ipv6_validate_snapshot "$directory" 1 || return 1
    quality=$(ipv6_snapshot_quality "$directory" 1)
    if [[ "$quality" == disable-flags-exact ]] && ipv6_snapshot_is_v2 "$directory"; then
        ipv6_snapshot_interface_set_matches_current "$directory" || return 1
        while IFS=$'\t' read -r record iface expected; do
            [[ "$record" == INTERFACE ]] || continue
            value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || return 1
            [[ "$value" == "$expected" ]] || return 1
        done < "$directory/sysctl.tsv"
        return 0
    fi
    while IFS=$'\t' read -r key expected; do
        [[ "$key" == net.ipv6.conf.*.disable_ipv6 ]] || continue
        iface=${key#net.ipv6.conf.}; iface=${iface%.disable_ipv6}
        value=$(ipv6_read_interface_value "$iface" 2>/dev/null) || return 1
        [[ "$value" == "$expected" ]] || return 1
    done < "$directory/sysctl.tsv"
}

ipv6_policy_verify() {
    local requested="${1:-}" target current base="$IPV6_BACKUP_DIR/baseline"
    if [[ -n "$requested" ]]; then
        target=$(ipv6_policy_normalize "$requested") || return 1
    else
        target=$(ipv6_policy_detect_current) || return 1
    fi
    current=$(ipv6_policy_detect_current) || return 1
    if [[ "$target" == native ]]; then
        if [[ -e "$base" || -L "$base" ]]; then
            ipv6_validate_snapshot "$base" 1 || {
                die "IPv6 native 验证失败：基线损坏"
                return 1
            }
            ipv6_policy_persistent_matches_snapshot "$base" || {
                die "IPv6 native 策略与首次可信 disable flags/持久文件不一致"
                return 1
            }
            if ipv6_boot_disabled; then
                log WARN "IPv6 native 持久状态已验证；启动级禁用仍生效，运行时需修改启动配置并重启后才能验证"
                return 0
            fi
            ipv6_policy_runtime_matches_snapshot "$base" || {
                die "IPv6 native 策略与首次可信 disable flags/持久文件不一致"
                return 1
            }
        else
            case "$current" in
                disabled-persistent|disabled-persistent-drift|legacy-disabled-persistent|legacy-disabled-drift|disabled-temporary)
                    die "IPv6 native 验证失败：存在项目策略但没有基线"
                    return 1
                    ;;
            esac
        fi
        log OK "IPv6 native 策略验证通过"
        return 0
    fi
    [[ "$target" == disabled-temporary || "$target" == disabled-persistent ]] || {
        die "当前 IPv6 状态不是可验证的规范策略: $target"
        return 1
    }

    [[ -e "$base" && -d "$base" && ! -L "$base" ]] && ipv6_validate_snapshot "$base" 1 || {
        die "IPv6 禁用策略缺少可验证基线"
        return 1
    }
    ipv6_policy_runtime_disabled || {
        die "IPv6 策略漂移：至少一个非回环接口或 default 未处于禁用状态"
        return 1
    }
    if [[ "$target" == disabled-persistent ]]; then
        [[ "$current" == disabled-persistent ]] || {
            die "IPv6 持久策略漂移: observed=$current"
            return 1
        }
    else
        [[ "$current" == disabled-temporary ]] || {
            die "IPv6 临时策略漂移: observed=$current"
            return 1
        }
        [[ ! -e "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]] || {
            die "IPv6 临时策略不应存在持久文件"
            return 1
        }
    fi
    log OK "IPv6 策略与运行时一致: $target"
}

ipv6_policy_apply() {
    local requested="${1:-disabled-temporary}" target mode rc=0
    target=$(ipv6_policy_normalize "$requested") || return 1
    ipv6_policy_collect "$target" || rc=$?
    ipv6_policy_print_plan
    (( rc == 0 )) || return "$rc"
    if [[ "$IPV6_POLICY_DECISION" == noop ]]; then
        if [[ "$target" == native ]]; then
            log OK "IPv6 native 策略无需修改"
            return 0
        fi
        ipv6_policy_verify "$target"
        return
    fi
    if [[ "$target" == native ]]; then
        ipv6_restore || return 1
        ipv6_policy_verify native
        return
    fi
    if [[ "$target" == disabled-persistent ]]; then mode=permanent; else mode=temporary; fi
    ipv6_disable "$mode" || return 1
    ipv6_policy_verify "$target"
}

ipv6_policy_status() {
    local current health
    current=$(ipv6_policy_detect_current 2>/dev/null || printf 'unknown\n')
    case "$current" in
        native|external-disabled) health='unmanaged/native' ;;
        disabled-temporary|disabled-persistent) health='structurally-consistent' ;;
        legacy-*) health='migration-required: restore native first' ;;
        *-drift) health='drift' ;;
        foreign) health='foreign policy file; not managed' ;;
        *) health='unavailable/unknown' ;;
    esac
    printf '%-48s %s\n' 'IPv6 policy schema' "$IPV6_POLICY_SCHEMA"
    printf '%-48s %s\n' 'IPv6 inferred policy' "$current"
    printf '%-48s %s\n' 'IPv6 policy health' "$health"
    ipv6_status
}

# -----------------------------------------------------------------------------
# Self-update: release-only download, SHA256 verification and atomic replacement.
# -----------------------------------------------------------------------------

self_update() {
    require_root || return 1; acquire_lock || return 1; require_commands curl awk sha256sum sort install grep || return 1
    local latest latest_version current target tmp base expected actual backup newest persist_distinct=0
    current=$(current_script_path 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        current=$(command -v bbr 2>/dev/null || true)
        [[ -f "$current" ]] || { die "当前从临时流运行且没有已安装的 bbr 命令；请先运行 install-alias.sh"; return 1; }
    fi
    managed_bbr_script_signature "$current" || { die "当前 bbr 命令缺少完整项目签名；拒绝自更新未知文件"; return 1; }
    latest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${PROJECT_REPO}/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4; exit}' || true)
    if [[ -z "$latest" ]]; then
        latest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${PROJECT_REPO}/tags?per_page=100" |
            awk -F'"' '/"name"[[:space:]]*:/ && $4 ~ /^v[0-9]+[.][0-9]+[.][0-9]+$/ {print $4}' | sort -V | tail -n1)
    fi
    [[ "$latest" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { die "无法取得合法 release 版本"; return 1; }
    [[ "$latest" != "v${SCRIPT_VERSION}" ]] || { log OK "已经是最新版本 $latest"; return 0; }
    latest_version="${latest#v}"
    newest=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$latest_version" | sort -V | tail -n1)
    if [[ "$newest" == "$SCRIPT_VERSION" ]]; then log WARN "当前 v${SCRIPT_VERSION} 比最新 release $latest 更新，不执行降级"; return 0; fi
    tmp=$(mktemp -d) || return 1
    base="https://github.com/${PROJECT_REPO}/releases/download/${latest}"
    if ! curl -fsSL --max-time 120 "$base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" ||
       ! curl -fsSL --max-time 30 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
        base="https://raw.githubusercontent.com/${PROJECT_REPO}/${latest}"
        curl -fsSL --max-time 120 "$base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; return 1; }
        curl -fsSL --max-time 30 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || { rm -rf "$tmp"; die "tag 缺少 SHA256SUMS"; return 1; }
        log WARN "GitHub Release 资产缺失，已从不可变 tag 更新"
    fi
    expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "$tmp/SHA256SUMS")
    actual=$(sha256sum "$tmp/net-tcp-tune.sh" | awk '{print $1}')
    [[ -n "$expected" && "$actual" == "$expected" ]] || { rm -rf "$tmp"; die "SHA256 校验失败"; return 1; }
    bash -n "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本语法检查失败"; return 1; }
    managed_bbr_script_signature "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本缺少完整项目签名或签名有歧义"; return 1; }
    grep -Fxc "SCRIPT_VERSION=\"${latest#v}\"" "$tmp/net-tcp-tune.sh" >/dev/null || { rm -rf "$tmp"; die "新脚本版本标记不匹配"; return 1; }
    target="$current"; backup="${current}.previous"
    cp -a -- "$current" "$tmp/current.before" || { rm -rf "$tmp"; die "无法备份当前脚本"; return 1; }
    atomic_install "$tmp/current.before" "$backup" 0755 || { rm -rf "$tmp"; die "无法写入上一版本备份: $backup"; return 1; }
    if [[ -e "$PERSIST_SCRIPT" && "$(readlink -f "$PERSIST_SCRIPT")" != "$(readlink -f "$target")" ]]; then
        persist_distinct=1
    fi
    if ! atomic_install "$tmp/net-tcp-tune.sh" "$target" 0755; then
        rm -rf "$tmp"
        die "更新当前 bbr 命令失败；原文件未替换"
        return 1
    fi
    if (( persist_distinct )) && ! atomic_install "$tmp/net-tcp-tune.sh" "$PERSIST_SCRIPT" 0755; then
        if ! atomic_install "$tmp/current.before" "$target" 0755; then
            rm -rf "$tmp"
            die "持久化副本更新失败，且当前命令自动回滚失败；上一版本仍保存在 $backup"
            return 1
        fi
        rm -rf "$tmp"
        die "持久化副本更新失败；当前 bbr 命令已回滚到更新前版本"
        return 1
    fi
    rm -rf "$tmp"
    log OK "已更新到 $latest；上一版本保存在 $backup"
}

# -----------------------------------------------------------------------------
# CLI and compact interactive menu.
# -----------------------------------------------------------------------------

show_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - measured BBR/HTB/FQ tuning

Usage:
  ${0##*/} auto
  ${0##*/} detect [--interface DEV] [--target HOST]
  ${0##*/} install [--profile balanced|adaptive] [--role proxy|mixed|bulk]
                     [--bandwidth MBIT --rtt MS] [--interface DEV]
  ${0##*/} explain [same profile options as install]
  ${0##*/} status
  ${0##*/} tc trial RATE [--interface DEV]
  ${0##*/} tc enable RATE [--interface DEV] [--knee RATE] [--margin PERCENT]
  ${0##*/} tc disable|status|stats [--interface DEV]
  ${0##*/} nic list|status
  ${0##*/} nic plan --interface DEV [--mode fq|shape --rate MBIT]
  ${0##*/} nic manage --interface DEV --mode fq|shape [--rate MBIT]
                    [--knee MBIT --margin PERCENT]
                    [--profile balanced|adaptive --role proxy|mixed|bulk]
                    [--bandwidth MBIT --rtt MS]
  ${0##*/} nic unmanage --interface DEV
  ${0##*/} nic verify [--interface DEV]
  ${0##*/} measure deps
  ${0##*/} measure path --peer HOST [--interface DEV] [--samples 7] [--no-pmtu]
  ${0##*/} measure probe --peer HOST [--port 5201] [--duration 10] [--parallel 4]
  ${0##*/} measure verify --peer HOST [--port 5201] [--duration 10]
  ${0##*/} measure compare --peer HOST --rate MBIT [--port 5201] [--duration 6] [--rounds 2]
  ${0##*/} measure sweep --peer HOST [--nominal MBIT] [--low MBIT --high MBIT]
                         [--step MBIT] [--duration 8] [--parallel 1]
                         [--margin 3] [--loss-threshold 0.1] [--cap MBIT] [--force-scan]
  ${0##*/} kernel status|install [--track lts|main]|remove
  ${0##*/} dns status|plan POLICY|apply POLICY|verify|restore
             POLICY: native|strict-dot|plain (aliases: auto|dot)
  ${0##*/} ipv6 status|plan POLICY|apply POLICY|verify|restore
             POLICY: native|disabled-temporary|disabled-persistent
             compatibility: ipv6 disable [temporary|permanent]
  ${0##*/} baseline info|adopt [--interface DEV]
  ${0##*/} verify
  ${0##*/} restore
  ${0##*/} uninstall [--purge-state]
  ${0##*/} update | version | help

Internal systemd command: apply
EOF
}

require_option_value() {
    local option="${1:-}"
    (($# >= 2)) && [[ -n "${2:-}" && "${2:-}" != --* ]] || {
        die "${option:-选项} 需要参数"
        return 1
    }
}

require_no_arguments() {
    local context="$1"; shift
    (($# == 0)) || {
        die "$context 不接受额外参数: $*"
        return 1
    }
}

parse_common_profile_options() {
    CLI_PROFILE=balanced; CLI_ROLE=mixed; CLI_BANDWIDTH=0; CLI_RTT=0; CLI_INTERFACE=auto
    while (($#)); do
        case "$1" in
            --profile) require_option_value "$@" || return 1; CLI_PROFILE="$2"; shift 2 ;;
            --role) require_option_value "$@" || return 1; CLI_ROLE="$2"; shift 2 ;;
            --bandwidth) require_option_value "$@" || return 1; CLI_BANDWIDTH="$2"; shift 2 ;;
            --rtt) require_option_value "$@" || return 1; CLI_RTT="$2"; shift 2 ;;
            --interface) require_option_value "$@" || return 1; CLI_INTERFACE="$2"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    if ! validate_config_value SYSCTL_PROFILE "$CLI_PROFILE" ||
       ! validate_config_value ROLE "$CLI_ROLE" ||
       ! validate_config_value BANDWIDTH_MBIT "$CLI_BANDWIDTH" ||
       ! validate_config_value RTT_MS "$CLI_RTT" ||
       ! validate_interface_name "$CLI_INTERFACE"; then
        die "profile/role/bandwidth/rtt/interface 参数无效"
        return 1
    fi
    if [[ "$CLI_PROFILE" == adaptive ]] && (( CLI_BANDWIDTH == 0 || CLI_RTT == 0 )); then
        die "adaptive profile 必须同时提供非零 --bandwidth 和 --rtt"
        return 1
    fi
    (( CLI_BANDWIDTH == 0 && CLI_RTT == 0 )) || (( CLI_BANDWIDTH > 0 && CLI_RTT > 0 )) || {
        die "--bandwidth 与 --rtt 必须成对提供"
        return 1
    }
}

cmd_detect() {
    local iface=auto target=""
    while (($#)); do
        case "$1" in
            --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
            --target) require_option_value "$@" || return 1; target="$2"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    detect_profile "$iface" "$target"
}

cmd_install() { parse_common_profile_options "$@" || return 1; install_base_tuning "$CLI_INTERFACE" "$CLI_PROFILE" "$CLI_ROLE" "$CLI_BANDWIDTH" "$CLI_RTT"; }
cmd_explain() {
    parse_common_profile_options "$@" || return 1
    reset_config; SYSCTL_PROFILE="$CLI_PROFILE"; ROLE="$CLI_ROLE"; BANDWIDTH_MBIT="$CLI_BANDWIDTH"; RTT_MS="$CLI_RTT"; TC_INTERFACE="$CLI_INTERFACE"
    explain_sysctl_profile
}

cmd_tc() {
    local action="${1:-}"; shift || true
    local rate="" iface=auto knee=0 margin=3
    case "$action" in
        trial)
            rate="${1:-}"; shift || true
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "需要 1–1000000 的合法 RATE"; return 1; }
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    *) die "tc trial 不支持参数: $1"; return 1 ;;
                esac
            done
            tc_trial "$rate" "$iface"
            ;;
        enable)
            rate="${1:-}"; shift || true
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "需要 1–1000000 的合法 RATE"; return 1; }
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    --knee) require_option_value "$@" || return 1; knee="$2"; shift 2 ;;
                    --margin) require_option_value "$@" || return 1; margin="$2"; shift 2 ;;
                    *) die "未知参数: $1"; return 1 ;;
                esac
            done
            is_uint "$knee" && (( knee <= 1000000 )) || { die "--knee 必须是 0–1000000 的整数"; return 1; }
            is_uint "$margin" && (( margin <= 25 )) || { die "--margin 必须是 0–25 的整数"; return 1; }
            (( knee == 0 || knee >= rate )) || { die "--knee 不能低于最终整形 RATE"; return 1; }
            tc_enable "$rate" "$iface" "$knee" "$margin"
            ;;
        disable|status|stats)
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    *) die "未知参数: $1"; return 1 ;;
                esac
            done
            case "$action" in disable) tc_disable "$iface" ;; status|stats) tc_status "$iface" ;; esac
            ;;
        *) die "tc 子命令应为 trial/enable/disable/status/stats" ;;
    esac
}

cmd_nic() {
    local action="${1:-list}"; (($#)) && shift || true
    local iface="" mode=fq rate=0 knee=0 margin=3 profile=balanced role=mixed bandwidth=0 rtt=0
    case "$action" in
        list|status)
            require_no_arguments "nic $action" "$@" || return 1
            nic_inventory
            ;;
        plan|manage)
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    --mode) require_option_value "$@" || return 1; mode="$2"; shift 2 ;;
                    --rate) require_option_value "$@" || return 1; rate="$2"; shift 2 ;;
                    --knee) require_option_value "$@" || return 1; knee="$2"; shift 2 ;;
                    --margin) require_option_value "$@" || return 1; margin="$2"; shift 2 ;;
                    --profile) require_option_value "$@" || return 1; profile="$2"; shift 2 ;;
                    --role) require_option_value "$@" || return 1; role="$2"; shift 2 ;;
                    --bandwidth) require_option_value "$@" || return 1; bandwidth="$2"; shift 2 ;;
                    --rtt) require_option_value "$@" || return 1; rtt="$2"; shift 2 ;;
                    *) die "nic $action 不支持参数: $1"; return 1 ;;
                esac
            done
            validate_interface_name "$iface" && [[ -n "$iface" && "$iface" != auto ]] || { die "nic $action 需要具体 --interface DEV"; return 1; }
            [[ "$mode" == fq || "$mode" == shape ]] || { die "--mode 只支持 fq/shape"; return 1; }
            is_uint "$rate" && is_uint "$knee" && is_uint "$margin" || { die "rate/knee/margin 必须是非负整数"; return 1; }
            (( rate <= 1000000 && knee <= 1000000 && margin <= 25 )) || { die "rate/knee/margin 超出范围"; return 1; }
            if [[ "$mode" == shape ]]; then (( rate > 0 && ( knee == 0 || knee >= rate ) )) || { die "shape 需要非零 --rate，且 knee 不能低于 rate"; return 1; }
            else (( rate == 0 && knee == 0 )) || { die "fq 模式不接受 rate/knee"; return 1; }
            fi
            validate_config_value SYSCTL_PROFILE "$profile" && validate_config_value ROLE "$role" &&
                validate_config_value BANDWIDTH_MBIT "$bandwidth" && validate_config_value RTT_MS "$rtt" || { die "profile/role/bandwidth/rtt 非法"; return 1; }
            (( bandwidth == 0 && rtt == 0 )) || (( bandwidth > 0 && rtt > 0 )) || { die "--bandwidth 与 --rtt 必须成对提供"; return 1; }
            [[ "$profile" != adaptive || ( "$bandwidth" -gt 0 && "$rtt" -gt 0 ) ]] || { die "adaptive 需要非零 --bandwidth 和 --rtt"; return 1; }
            if [[ "$action" == plan ]]; then load_config || return 1; nic_plan "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
            else nic_manage "$iface" "$mode" "$rate" "$knee" "$margin" "$profile" "$role" "$bandwidth" "$rtt"
            fi
            ;;
        unmanage)
            while (($#)); do case "$1" in --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;; *) die "nic unmanage 不支持参数: $1"; return 1 ;; esac; done
            validate_interface_name "$iface" && [[ -n "$iface" && "$iface" != auto ]] || { die "nic unmanage 需要具体 --interface DEV"; return 1; }
            nic_unmanage "$iface"
            ;;
        verify)
            while (($#)); do case "$1" in --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;; *) die "nic verify 不支持参数: $1"; return 1 ;; esac; done
            [[ -z "$iface" ]] || { validate_interface_name "$iface" && [[ "$iface" != auto ]]; } || { die "非法 --interface"; return 1; }
            load_config || return 1
            nic_verify_runtime_policies "$iface"
            ;;
        apply) require_no_arguments "nic apply" "$@" || return 1; nic_apply_command ;;
        *) die "nic 子命令应为 list/status/plan/manage/unmanage/verify/apply" ;;
    esac
}

cmd_measure() {
    local action="${1:-}"; shift || true
    local peer="" port=5201 iface=auto duration=10 parallel=4 nominal=0 low=0 high=0 step=0 margin=3 threshold=0.1 force=0 cap=0
    local rate=0 rounds=2 samples=7 pmtu=1
    if [[ "$action" == deps ]]; then
        require_no_arguments "measure deps" "$@" || return 1
        install_measure_dependencies
        return
    fi
    [[ "$action" == path || "$action" == probe || "$action" == sweep || "$action" == verify || "$action" == compare ]] || { die "measure 子命令应为 deps/path/probe/sweep/verify/compare"; return 1; }
    [[ "$action" == sweep ]] && { duration=8; parallel=1; }
    [[ "$action" == compare ]] && { duration=6; parallel=1; }
    while (($#)); do
        case "$1" in
            --peer) require_option_value "$@" || return 1; peer="$2"; shift 2 ;;
            --port)
                [[ "$action" != path ]] || { die "measure path 不使用 --port"; return 1; }
                require_option_value "$@" || return 1; port="$2"; shift 2
                ;;
            --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
            --duration)
                [[ "$action" != path ]] || { die "measure path 使用 --samples，不接受 --duration"; return 1; }
                require_option_value "$@" || return 1; duration="$2"; shift 2
                ;;
            --samples)
                [[ "$action" == path ]] || { die "measure $action 不支持 --samples"; return 1; }
                require_option_value "$@" || return 1; samples="$2"; shift 2
                ;;
            --no-pmtu)
                [[ "$action" == path ]] || { die "measure $action 不支持 --no-pmtu"; return 1; }
                pmtu=0; shift
                ;;
            --parallel)
                [[ "$action" == probe || "$action" == sweep ]] || { die "measure $action 不接受 --parallel"; return 1; }
                require_option_value "$@" || return 1; parallel="$2"; shift 2
                ;;
            --rate|--rounds)
                [[ "$action" == compare ]] || { die "measure $action 不支持参数: $1"; return 1; }
                require_option_value "$@" || return 1
                case "$1" in --rate) rate="$2" ;; --rounds) rounds="$2" ;; esac
                shift 2
                ;;
            --nominal|--low|--high|--step|--margin|--loss-threshold|--cap)
                [[ "$action" == sweep ]] || { die "measure $action 不支持参数: $1"; return 1; }
                require_option_value "$@" || return 1
                case "$1" in
                    --nominal) nominal="$2" ;; --low) low="$2" ;; --high) high="$2" ;; --step) step="$2" ;;
                    --margin) margin="$2" ;; --loss-threshold) threshold="$2" ;; --cap) cap="$2" ;;
                esac
                shift 2
                ;;
            --force-scan)
                [[ "$action" == sweep ]] || { die "measure $action 不支持参数: $1"; return 1; }
                force=1; shift
                ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    [[ -n "$peer" ]] || { die "需要 --peer HOST"; return 1; }
    if [[ "$action" == path ]]; then
        is_uint "$samples" && (( samples >= 3 && samples <= 20 )) || { die "measure path --samples 必须是 3–20"; return 1; }
    fi
    if [[ "$action" == compare ]]; then
        is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "measure compare 需要 --rate 1–1000000"; return 1; }
        is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "measure compare --rounds 必须是 2–5"; return 1; }
        is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "measure compare --duration 必须是 3–30 秒"; return 1; }
    fi
    if [[ "$action" == path ]]; then measure_path_profile "$peer" "$iface" "$samples" "$pmtu"
    elif [[ "$action" == probe ]]; then measure_probe "$peer" "$port" "$iface" "$duration" "$parallel"
    elif [[ "$action" == verify ]]; then measure_verify "$peer" "$port" "$iface" "$duration"
    elif [[ "$action" == compare ]]; then measure_compare "$peer" "$port" "$iface" "$rate" "$duration" "$rounds"
    else measure_sweep "$peer" "$port" "$iface" "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$threshold" "$force" "$cap"; fi
}

cmd_kernel() {
    local action="${1:-status}" track=lts; shift || true
    case "$action" in
        status) require_no_arguments "kernel status" "$@" || return 1; kernel_status ;;
        install)
            while (($#)); do
                case "$1" in --track) require_option_value "$@" || return 1; track="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac
            done
            [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
            kernel_install "$track"
            ;;
        remove) require_no_arguments "kernel remove" "$@" || return 1; kernel_remove ;;
        *) die "kernel 子命令应为 status/install/remove" ;;
    esac
}

cmd_dns() {
    local action="${1:-status}" policy; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "dns status" "$@" || return 1; dns_policy_status ;;
        plan)
            (($# <= 1)) || { die "dns plan 最多接受一个 policy"; return 1; }
            policy="${1:-strict-dot}"; dns_policy_normalize "$policy" >/dev/null || return 1
            dns_policy_plan "$policy"
            ;;
        apply)
            (($# <= 1)) || { die "dns apply 最多接受一个 policy"; return 1; }
            policy="${1:-strict-dot}"; dns_policy_normalize "$policy" >/dev/null || return 1
            dns_policy_apply "$policy"
            ;;
        verify)
            (($# <= 1)) || { die "dns verify 最多接受一个 policy"; return 1; }
            [[ -z "${1:-}" ]] || dns_policy_normalize "$1" >/dev/null || return 1
            dns_policy_verify "${1:-}"
            ;;
        restore) require_no_arguments "dns restore" "$@" || return 1; dns_policy_apply native ;;
        *) die "dns 子命令应为 status/plan/apply/verify/restore" ;;
    esac
}

cmd_ipv6() {
    local action="${1:-status}" policy; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "ipv6 status" "$@" || return 1; ipv6_policy_status ;;
        plan)
            (($# <= 1)) || { die "ipv6 plan 最多接受一个 policy"; return 1; }
            policy="${1:-disabled-temporary}"; ipv6_policy_normalize "$policy" >/dev/null || return 1
            ipv6_policy_plan "$policy"
            ;;
        apply)
            (($# <= 1)) || { die "ipv6 apply 最多接受一个 policy"; return 1; }
            policy="${1:-disabled-temporary}"; ipv6_policy_normalize "$policy" >/dev/null || return 1
            ipv6_policy_apply "$policy"
            ;;
        verify)
            (($# <= 1)) || { die "ipv6 verify 最多接受一个 policy"; return 1; }
            [[ -z "${1:-}" ]] || ipv6_policy_normalize "$1" >/dev/null || return 1
            ipv6_policy_verify "${1:-}"
            ;;
        disable)
            (($# <= 1)) || { die "ipv6 disable 最多接受一个 mode"; return 1; }
            policy="${1:-temporary}"; [[ "$policy" == temporary || "$policy" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
            ipv6_policy_apply "$policy"
            ;;
        restore) require_no_arguments "ipv6 restore" "$@" || return 1; ipv6_policy_apply native ;;
        *) die "ipv6 子命令应为 status/plan/apply/verify/disable/restore" ;;
    esac
}

cmd_baseline() {
    local action="${1:-info}" iface=auto; shift || true
    case "$action" in
        info) require_no_arguments "baseline info" "$@" || return 1; baseline_info ;;
        adopt)
            while (($#)); do case "$1" in --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            baseline_adopt "$iface"
            ;;
        *) die "baseline 子命令应为 info/adopt" ;;
    esac
}

ensure_interactive_measure_dependencies() {
    local -a missing=() command
    for command in iperf3 jq ping; do command_exists "$command" || missing+=("$command"); done
    ((${#missing[@]} == 0)) && return 0
    log WARN "自动调优需要: ${missing[*]}"
    confirm "现在安装测量依赖？" y || { die "缺少测量依赖，已取消"; return 1; }
    install_measure_dependencies || return 1
    require_commands iperf3 jq ping timeout || return 1
}

activate_public_peer_candidate() {
    local index="$1" candidate host address family source iface port rtt region provider
    is_uint "$index" && (( index < ${#PUBLIC_PEER_CANDIDATES[@]} )) || return 1
    candidate="${PUBLIC_PEER_CANDIDATES[$index]}"
    IFS='|' read -r host address family source iface port rtt region provider <<< "$candidate"
    validate_peer "$host" "$port" || return 1
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    measure_source_address_is_valid "$family" "$address" || return 1
    measure_source_address_is_valid "$family" "$source" || return 1
    validate_interface_name "$iface" || return 1
    WIZARD_PEER="$host"; WIZARD_PORT="$port"; WIZARD_PEER_RTT="$rtt"
    WIZARD_PEER_REGION="$region"; WIZARD_PEER_PROVIDER="$provider"; WIZARD_PUBLIC_INDEX="$index"
    WIZARD_PEER_ADDRESS="$address"; WIZARD_PEER_FAMILY="$family"; WIZARD_PEER_SOURCE="$source"; WIZARD_PEER_IFACE="$iface"
}

interactive_select_peer() {
    local choice spec rtt
    printf '%s\n' '测速对端：' '  1) 自动选择公共节点（Leaseweb / OVH / Clouvider）' '  2) 自有 iperf3 服务器（推荐）'
    read -r -p '选择 [1]: ' choice || return 1
    case "${choice:-1}" in
        1)
            auto_pick_peer auto || return 1
            WIZARD_PUBLIC_PEER=1; WIZARD_FAILOVERS=0
            activate_public_peer_candidate 0 || return 1
            return 0
            ;;
        2)
            read -r -p '对端 HOST[:PORT]（IPv6 用 [ADDR]:PORT）: ' spec || return 1
            ;;
        *) die "无效对端选择"; return 1 ;;
    esac
    parse_peer_spec "$spec" || return 1
    measure_lock_peer "$PEER_HOST" auto "$PEER_PORT" || return $?
    WIZARD_PUBLIC_PEER=0; WIZARD_PEER="$PEER_HOST"; WIZARD_PORT="$PEER_PORT"
    WIZARD_PEER_ADDRESS="$MEASURE_PEER_ADDRESS"; WIZARD_PEER_FAMILY="$MEASURE_PEER_FAMILY"
    WIZARD_PEER_SOURCE="$MEASURE_PEER_SOURCE"; WIZARD_PEER_IFACE="$MEASURE_PEER_IFACE"
    rtt=$(median_ping_ms "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_FAMILY" 2>/dev/null || true)
    WIZARD_PEER_RTT="${rtt:-0}"; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0
    measure_clear_peer_lock
}

auto_measure_with_peer_failover() {
    local iface="$1" nominal="$2" index=0 count=1 rc path_rate
    local duration="${WIZARD_SAMPLE_DURATION:-5}" cap="${WIZARD_SCAN_CAP:-5000}"
    if (( ${WIZARD_PUBLIC_PEER:-0} )); then count=${#PUBLIC_PEER_CANDIDATES[@]}; fi
    for ((index=0; index<count; index++)); do
        if (( ${WIZARD_PUBLIC_PEER:-0} )); then
            activate_public_peer_candidate "$index" || return 1
        fi
        if [[ "${WIZARD_PEER_IFACE:-$iface}" != "$iface" ]]; then
            if (( ${WIZARD_PUBLIC_PEER:-0} )); then
                log WARN "跳过备用公共端点 $WIZARD_PEER:$WIZARD_PORT：其出口 ${WIZARD_PEER_IFACE:-unknown} 与本轮网卡 $iface 不同"
                continue
            fi
            die "测速端点出口 ${WIZARD_PEER_IFACE:-unknown} 与本轮网卡 $iface 不一致"
            return 1
        fi
        if (( ${WIZARD_PUBLIC_PEER:-0} && index > 0 )); then
            ((WIZARD_FAILOVERS+=1))
            log WARN "切换到备用公共对端 $((index + 1))/${count}: $WIZARD_PEER:$WIZARD_PORT（$WIZARD_PEER_REGION/$WIZARD_PEER_PROVIDER，RTT ${WIZARD_PEER_RTT}ms）"
        fi
        if (( ${WIZARD_ROUTE_GUARD_ACTIVE:-0} )); then
            auto_tune_route_guard "$iface" "${WIZARD_PEER_ADDRESS:-$WIZARD_PEER}" || return 1
        fi
        if (( nominal > 0 )); then
            path_rate=$((nominal * 40 / 100)); ((path_rate < 1)) && path_rate=1
            if measure_path_check "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$path_rate" \
                    "${WIZARD_PEER_ADDRESS:-}" "${WIZARD_PEER_SOURCE:-}"; then
                :
            else
                rc=$?
                if (( ${WIZARD_PUBLIC_PEER:-0} && (rc == IPERF_UNAVAILABLE_RC || rc == 2) )); then
                    (( index + 1 < count )) && continue
                    break
                fi
                return "$rc"
            fi
        fi
        if measure_sweep "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$nominal" 0 0 0 "$duration" 1 3 0.1 0 "$cap" auto \
                "${WIZARD_PEER_ADDRESS:-}" "${WIZARD_PEER_SOURCE:-}"; then
            WIZARD_SWEEP_PEER="$WIZARD_PEER"
            WIZARD_SWEEP_PORT="$WIZARD_PORT"
            WIZARD_SWEEP_ADDRESS="${WIZARD_PEER_ADDRESS:-}"
            WIZARD_SWEEP_SOURCE="${WIZARD_PEER_SOURCE:-}"
            WIZARD_SWEEP_IFACE="${WIZARD_PEER_IFACE:-$iface}"
            return 0
        else
            rc=$?
        fi
        if (( ${WIZARD_PUBLIC_PEER:-0} && (rc == IPERF_UNAVAILABLE_RC || rc == 2) )); then
            (( index + 1 < count )) && continue
            break
        fi
        return "$rc"
    done
    die "所有已预检的公共 iperf3 对端都不可用或不适合当前路径；请稍后重试或使用自有服务器"
    return 1
}

auto_verify_with_peer_failover() {
    local iface="$1" duration="$2" expected_rate="$3" min_efficiency="$4" baseline_loss="$5"
    local sweep_peer="${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" sweep_address="${WIZARD_SWEEP_ADDRESS:-${WIZARD_PEER_ADDRESS:-}}"
    local sweep_source="${WIZARD_SWEEP_SOURCE:-${WIZARD_PEER_SOURCE:-}}" sweep_iface="${WIZARD_SWEEP_IFACE:-${WIZARD_PEER_IFACE:-$iface}}"
    local current_index="${WIZARD_PUBLIC_INDEX:-0}" candidate host address family source candidate_iface port rtt region provider index rc
    if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1 \
            "${WIZARD_PEER_ADDRESS:-}" "${WIZARD_PEER_SOURCE:-}"; then
        return 0
    else
        rc=$?
    fi
    (( ${WIZARD_PUBLIC_PEER:-0} && rc == IPERF_UNAVAILABLE_RC )) || return "$rc"

    # The acceptance thresholds come from the sweep path. A different host may
    # have a different bottleneck, so final verification may only change ports
    # on the same host. Cross-host failover must restart the complete sweep.
    for ((index=0; index<${#PUBLIC_PEER_CANDIDATES[@]}; index++)); do
        (( index != current_index )) || continue
        candidate="${PUBLIC_PEER_CANDIDATES[$index]}"
        IFS='|' read -r host address family source candidate_iface port rtt region provider <<< "$candidate"
        [[ "$host" == "$sweep_peer" ]] || continue
        [[ "$address" == "$sweep_address" && "$source" == "$sweep_source" && "$candidate_iface" == "$sweep_iface" ]] || continue
        activate_public_peer_candidate "$index" || return 1
        ((WIZARD_FAILOVERS+=1))
        log WARN "最终复验切换到同主机备用端口: $WIZARD_PEER:$WIZARD_PORT"
        if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1 \
                "${WIZARD_PEER_ADDRESS:-}" "${WIZARD_PEER_SOURCE:-}"; then
            return 0
        else
            rc=$?
        fi
        (( rc == IPERF_UNAVAILABLE_RC )) || return "$rc"
    done
    die "扫描主机 $sweep_peer 的可用端口在最终复验阶段全部不可用；为保持同路径基线，不会切换到其他主机"
    return "$IPERF_UNAVAILABLE_RC"
}

auto_tune_execute() {
    local iface="$1" profile="$2" role="$3" nominal="$4" tuning_rtt="$5" peer_rtt="${6:-0}"
    local summary recommend knee measured no_knee confirmed reject_reason min_efficiency baseline_loss expected_rate=0
    local role_floor rtt_source verify_summary verify_confidence_score verify_confidence_grade verify_confidence_reasons
    local sweep_path_fingerprint verify_path_fingerprint sweep_endpoint_fingerprint verify_endpoint_fingerprint path_rtt
    prepare_auto_tuning_runtime "$iface" "$iface" "$profile" "$role" "$nominal" "$tuning_rtt" || return 1
    if [[ -z "${WIZARD_PEER:-}" ]]; then
        verify_runtime_tuning "$iface" || return 1
        persist_current_tuning || return 1
        printf '\n'
        log OK "BBR + FQ 基础调优和持久化提交完成（未运行测速）"
        show_status
        return 0
    fi
    auto_measure_with_peer_failover "$iface" "$nominal" || return $?
    summary="$MEASURE_RUN_DIR/summary.tsv"
    sweep_path_fingerprint=$(summary_value "$summary" PATH_ROUTE_FINGERPRINT)
    [[ "$sweep_path_fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
        die "扫描结果缺少合法网络路径指纹；不会持久化"
        return 1
    }
    sweep_endpoint_fingerprint=$(summary_value "$summary" PATH_ENDPOINT_FINGERPRINT)
    [[ "$sweep_endpoint_fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
        die "扫描结果缺少合法测速端点指纹；不会持久化"
        return 1
    }
    path_rtt=$(summary_value "$summary" PATH_RTT_P95_MS)
    if is_decimal "$path_rtt"; then
        peer_rtt=$(awk -v r="$path_rtt" 'BEGIN {printf "%d",r+0.5}')
    elif (( ${WIZARD_PUBLIC_PEER:-0} )); then
        peer_rtt="${WIZARD_PEER_RTT:-0}"
    fi
    tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    recommend=$(summary_value "$summary" RECOMMEND)
    knee=$(summary_value "$summary" BROKE_AT); knee="${knee:-0}"
    measured=$(summary_value "$summary" UNSHAPED_MBIT)
    no_knee=$(summary_value "$summary" NO_KNEE)
    confirmed=$(summary_value "$summary" CONFIRMED)
    reject_reason=$(summary_value "$summary" REJECT_REASON)
    min_efficiency=$(summary_value "$summary" MIN_EFFICIENCY_RATIO); min_efficiency="${min_efficiency:-0.90}"
    baseline_loss=$(summary_value "$summary" CLEAN_BASE_RETRANS_RATIO_EST_PERCENT); baseline_loss="${baseline_loss:-0}"
    role_floor=$(role_tuning_rtt_floor "$role") || return 1
    if (( peer_rtt > role_floor )); then rtt_source="path-p95"; else rtt_source="role-floor"; fi
    printf 'SWEEP_PEER\t%s\nSWEEP_PORT\t%s\nPEER_RTT_MS\t%s\nTUNING_RTT_MS\t%s\nTUNING_RTT_SOURCE\t%s\nROLE\t%s\nPUBLIC_PEER_FAILOVERS\t%s\nSWEEP_PATH_FINGERPRINT\t%s\nSWEEP_ENDPOINT_FINGERPRINT\t%s\n' \
        "${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" "${WIZARD_SWEEP_PORT:-$WIZARD_PORT}" "$peer_rtt" "$tuning_rtt" "$rtt_source" "$role" "${WIZARD_FAILOVERS:-0}" "$sweep_path_fingerprint" "$sweep_endpoint_fingerprint" >> "$summary" || return 1

    if [[ -n "$reject_reason" || ( -n "$knee" && "$knee" != 0 && "$confirmed" != 1 ) ]]; then
        die "扫描候选值未通过确认测试（${reject_reason:-unconfirmed}），不会应用或持久化"
        return 2
    fi
    if [[ -n "$measured" && "$tuning_rtt" -gt 0 ]]; then
        nic_stage_candidate_global_model "$iface" adaptive "$role" "$(awk -v g="$measured" 'BEGIN {printf "%d", g+0.5}')" "$tuning_rtt" || return 1
        apply_sysctl_profile runtime || return 1
    fi
    if [[ -n "$recommend" ]]; then
        TC_ENABLED=1; TC_INTERFACE="$iface"; TC_RATE_MBIT="$recommend"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT=3
        apply_shaping "$iface" "$recommend" || return 1
        expected_rate="$recommend"
    else
        TC_ENABLED=0; TC_INTERFACE="$iface"; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
        apply_fq "$iface" || return 1
        log INFO "扫描未发现可信拐点（NO_KNEE=${no_knee:-1}），保持 BBR + FQ，不启用 HTB"
    fi
    verify_runtime_tuning "$iface" || return 1
    auto_verify_with_peer_failover "$iface" 6 "$expected_rate" "$min_efficiency" "$baseline_loss" || return $?
    verify_summary="$MEASURE_RUN_DIR/summary.tsv"
    verify_path_fingerprint=$(summary_value "$verify_summary" PATH_ROUTE_FINGERPRINT)
    [[ "$verify_path_fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
        die "最终复验缺少合法网络路径指纹；不会持久化"
        return 1
    }
    verify_endpoint_fingerprint=$(summary_value "$verify_summary" PATH_ENDPOINT_FINGERPRINT)
    [[ "$verify_endpoint_fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
        die "最终复验缺少合法测速端点指纹；不会持久化"
        return 1
    }
    [[ "$verify_endpoint_fingerprint" == "$sweep_endpoint_fingerprint" ]] || {
        die "扫描与最终复验使用了不同测速端点；拒绝把跨端点结果持久化"
        return 2
    }
    [[ "$verify_path_fingerprint" == "$sweep_path_fingerprint" ]] || {
        die "扫描与最终复验经过不同网络路径；拒绝把跨路径结果持久化"
        return 2
    }
    verify_confidence_score=$(summary_value "$verify_summary" CONFIDENCE_SCORE); verify_confidence_score="${verify_confidence_score:-0}"
    verify_confidence_grade=$(summary_value "$verify_summary" CONFIDENCE_GRADE); verify_confidence_grade="${verify_confidence_grade:-unknown}"
    verify_confidence_reasons=$(summary_value "$verify_summary" CONFIDENCE_REASONS); verify_confidence_reasons="${verify_confidence_reasons:-unavailable}"
    if (( ${WIZARD_FAILOVERS:-0} > 0 )) && is_uint "$verify_confidence_score"; then
        verify_confidence_score=$((verify_confidence_score - 10)); (( verify_confidence_score < 0 )) && verify_confidence_score=0
        if (( verify_confidence_score >= 90 )); then verify_confidence_grade=high
        elif (( verify_confidence_score >= 65 )); then verify_confidence_grade=medium
        else verify_confidence_grade=low
        fi
        if [[ "$verify_confidence_reasons" == clean ]]; then verify_confidence_reasons="peer-failover"
        else verify_confidence_reasons="${verify_confidence_reasons},peer-failover"
        fi
    fi
    printf 'FINAL_VERIFY_PEER\t%s\nFINAL_VERIFY_PORT\t%s\nTOTAL_PUBLIC_PEER_FAILOVERS\t%s\nFINAL_VERIFY_CONFIDENCE_SCORE\t%s\nFINAL_VERIFY_CONFIDENCE_GRADE\t%s\nFINAL_VERIFY_CONFIDENCE_REASONS\t%s\nFINAL_VERIFY_PATH_FINGERPRINT\t%s\nFINAL_VERIFY_ENDPOINT_FINGERPRINT\t%s\n' \
        "$WIZARD_PEER" "$WIZARD_PORT" "${WIZARD_FAILOVERS:-0}" "$verify_confidence_score" "$verify_confidence_grade" "$verify_confidence_reasons" "$verify_path_fingerprint" "$verify_endpoint_fingerprint" >> "$summary" || return 1
    if (( ${WIZARD_ROUTE_GUARD_ACTIVE:-0} )); then
        auto_tune_route_guard "$iface" "${WIZARD_PEER_ADDRESS:-$WIZARD_PEER}" || return 1
    fi
    persist_current_tuning || return 1
    printf '\n'
    log OK "自动调优、复验和持久化提交完成"
    log INFO "最终复验置信度: ${verify_confidence_grade} (${verify_confidence_score}/100, ${verify_confidence_reasons})"
    show_status
    log INFO "扫描记录: $summary"
}

auto_tune_wizard() {
    require_root || return 1
    require_host_network_control || return 1
    require_systemd_runtime || return 1
    [[ -t 0 ]] || { die "auto 向导需要交互终端"; return 1; }
    local bandwidth_input nominal=0 role_choice role=mixed peer_rtt=0 tuning_rtt=0 profile=balanced estimate="动态估算" iface rc rollback_rc=0
    local backup_count=0 candidate_index candidate tmp_iface
    WIZARD_PEER=""; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=0; WIZARD_PUBLIC_INDEX=0; WIZARD_PEER_RTT=0; WIZARD_FAILOVERS=0; WIZARD_ROUTE_GUARD_ACTIVE=0
    WIZARD_PEER_ADDRESS=""; WIZARD_PEER_FAMILY=""; WIZARD_PEER_SOURCE=""; WIZARD_PEER_IFACE=""
    nic_auto_policy_reset
    WIZARD_SWEEP_PEER=""; WIZARD_SWEEP_PORT=0; WIZARD_SWEEP_ADDRESS=""; WIZARD_SWEEP_SOURCE=""; WIZARD_SWEEP_IFACE=""
    WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
    printf '\n%s v%s 自动调优\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '首次修改前会保存不可覆盖的基线：%s\n' "$BASELINE_DIR"
    printf '包含本工具涉及的 sysctl、配置/服务、qdisc/class，以及 IPv4/IPv6 路由快照。\n\n'
    ensure_interactive_measure_dependencies || return 1

    read -r -p '标称带宽 Mbit/s（a=自动测量，0=仅安装 BBR+FQ）[a]: ' bandwidth_input || return 1
    bandwidth_input="${bandwidth_input:-a}"
    if [[ "$bandwidth_input" != a && "$bandwidth_input" != auto ]]; then
        is_uint "$bandwidth_input" && (( bandwidth_input <= 1000000 )) || { die "带宽必须是非负整数或 a"; return 1; }
        nominal="$bandwidth_input"
    fi

    if [[ "$nominal" != 0 || "$bandwidth_input" == a || "$bandwidth_input" == auto ]]; then
        interactive_select_peer || return 1
        peer_rtt="${WIZARD_PEER_RTT:-0}"
        if (( peer_rtt == 0 )); then
            peer_rtt=$(median_ping_ms "$WIZARD_PEER_ADDRESS" "$WIZARD_PEER_FAMILY" 2>/dev/null || true)
            [[ -n "$peer_rtt" ]] || peer_rtt=0
        fi
    fi

    printf '%s\n' '用途：1) 混合业务  2) 代理/转发  3) 大文件吞吐'
    read -r -p '选择 [1]: ' role_choice || return 1
    case "${role_choice:-1}" in 1) role=mixed ;; 2) role=proxy ;; 3) role=bulk ;; *) die "无效用途"; return 1 ;; esac
    tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    iface="${WIZARD_PEER_IFACE:-}"
    [[ -n "$iface" ]] || iface=$(detect_interface auto) || return 1
    auto_tune_route_guard "$iface" "${WIZARD_PEER_ADDRESS:-}" || return 1
    shaping_target_preflight "$iface" auto auto || return 1
    WIZARD_ROUTE_GUARD_ACTIVE=1
    WIZARD_SCAN_CAP=$(recommended_scan_cap "$iface" "$nominal") || return 1
    WIZARD_SAMPLE_DURATION=$(recommended_measure_duration "$iface" "$nominal") || return 1
    if (( nominal > 0 && tuning_rtt > 0 )); then
        profile=adaptive
        estimate="约 $(human_bytes "$(estimate_sweep_bytes "$((nominal * 13 / 10))" "$WIZARD_SAMPLE_DURATION" 20)") 上行"
    elif [[ -n "${WIZARD_PEER:-}" ]]; then
        estimate="将按实测带宽动态计算，扫描上限 ${WIZARD_SCAN_CAP} Mbit/s"
    else
        estimate="不运行测速"
    fi

    printf '\n执行摘要\n'
    hardware_profile_values "$iface" "$nominal" || return 1
    printf '  网卡/用途       %s / %s\n' "$iface" "$role"
    printf '  硬件模型        %s / %s CPU / %s MiB / RX:TX %s:%s\n' "$HARDWARE_CLASS" "$HARDWARE_CPU_COUNT" "$HARDWARE_MEMORY_MB" "$HARDWARE_RX_QUEUES" "$HARDWARE_TX_QUEUES"
    printf '  链路/采样       %s Mbit（%s）/ %ss\n' "$HARDWARE_LINK_MBIT" "$HARDWARE_LINK_TRUST" "$WIZARD_SAMPLE_DURATION"
    printf '  扫描策略        初始上限 %s Mbit；自动测量后可按基准扩展\n' "$WIZARD_SCAN_CAP"
    printf '  标称带宽        %s\n' "$([[ "$bandwidth_input" == a || "$bandwidth_input" == auto ]] && echo 自动测量 || echo "${nominal} Mbit/s")"
    if [[ -n "${WIZARD_PEER:-}" ]]; then
        printf '  iperf3 对端     %s:%s（测速 RTT %sms）\n' "$WIZARD_PEER" "$WIZARD_PORT" "${peer_rtt:-unknown}"
        printf '  冻结测速端点    %s / IPv%s / src %s / %s\n' "$WIZARD_PEER_ADDRESS" "$WIZARD_PEER_FAMILY" "$WIZARD_PEER_SOURCE" "$WIZARD_PEER_IFACE"
        if (( WIZARD_PUBLIC_PEER )); then
            for ((candidate_index=0; candidate_index<${#PUBLIC_PEER_CANDIDATES[@]}; candidate_index++)); do
                (( candidate_index != WIZARD_PUBLIC_INDEX )) || continue
                candidate="${PUBLIC_PEER_CANDIDATES[$candidate_index]}"
                tmp_iface=$(cut -d'|' -f5 <<< "$candidate")
                if [[ "$tmp_iface" == "$WIZARD_PEER_IFACE" ]]; then ((backup_count+=1)); fi
            done
            printf '  公共备用对端    %s 个（同出口候选；正式采样不可用时自动切换）\n' "$backup_count"
        fi
        printf '  缓冲区调优 RTT  %sms（按用途下限与测速 RTT 取较大值）\n' "$tuning_rtt"
    fi
    printf '  预计时间/流量   约 3–8 分钟 / %s\n' "$estimate"
    printf '  持久化位置      %s + %s\n' "$CONFIG_FILE" "$SERVICE_FILE"
    confirm "确认开始？" || { log INFO "已取消，未修改系统"; return 0; }

    qdisc_guard "$iface" || return 1
    BANDWIDTH_MBIT="$nominal"; network_tuning_preflight "$iface" 1 || return 1
    action_transaction_begin_multi "$iface" || return 1
    if auto_tune_execute "$iface" "$profile" "$role" "$nominal" "$tuning_rtt" "$peer_rtt"; then
        action_transaction_commit
        return
    else
        rc=$?
    fi
    log WARN "自动调优未完成，正在恢复开始前状态"
    action_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

menu_run() {
    local rc
    set +e
    # Every menu action runs in its own shell so failed commands cannot poison
    # the menu's errexit state. Transactions also live in that shell, so it
    # must own an EXIT trap; the parent trap cannot see child-only variables
    # after Ctrl-C, SIGTERM or another abrupt exit.
    ( set -Eeuo pipefail; trap cleanup_core EXIT; "$@" )
    rc=$?
    set -e
    (( rc != 90 )) || return 90
    (( rc == 0 )) || log WARN "操作失败（exit $rc）；系统不会把本次操作报告为成功"
    return 0
}

ui_clear() {
    [[ -t 1 && "${TERM:-dumb}" != dumb ]] || return 0
    printf '\033[2J\033[H'
}

ui_pause() {
    [[ -t 0 ]] || return 0
    read -r -p '按 Enter 继续...' || true
}

submenu_run() {
    ui_clear
    if ! menu_run "$@"; then return 90; fi
    ui_pause
}

invalid_menu_choice() {
    log WARN "无效选择"
    ui_pause
}

measurement_action() {
    local choice="$1" rate target
    ensure_interactive_measure_dependencies || return 1
    if [[ "$choice" == 5 ]]; then
        read -r -p '路径画像目标 HOST/IP: ' target || return 1
        [[ -n "$target" ]] || { die "目标不能为空"; return 1; }
        measure_path_profile "$target" auto 7 1
        return
    fi
    interactive_select_peer || return 1
    case "$choice" in
        1) measure_sweep "$WIZARD_PEER" "$WIZARD_PORT" auto 0 0 0 0 5 1 3 0.1 0 0 ;;
        2) measure_probe "$WIZARD_PEER" "$WIZARD_PORT" auto 8 4 ;;
        3) measure_verify "$WIZARD_PEER" "$WIZARD_PORT" auto 8 ;;
        4)
            read -r -p 'A/B 整形速率 Mbit/s: ' rate || return 1
            measure_compare "$WIZARD_PEER" "$WIZARD_PORT" auto "$rate" 6 2
            ;;
    esac
}

measurement_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' '测量与复验' '1) 自动拐点扫描' '2) 单次带宽探测' '3) 单流/硬件自适应多流复验' '4) FQ 与整形 A/B 对照' '5) 网络路径画像' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1|2|3|4|5) submenu_run measurement_action "$choice" || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

tc_menu() {
    local choice rate iface
    while true; do
        ui_clear
        printf '%s\n' '多网卡 / TC 管理' '1) 网卡清单与策略' '2) 验证全部受管网卡' '3) 新增/更新 FQ 策略' \
            '4) 新增/更新独立整形速率' '5) 关闭指定网卡整形并保留 FQ' '6) 解除管理并恢复该网卡原始 qdisc' '7) 临时试跑速率' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run nic_inventory || return 90 ;;
            2) submenu_run cmd_nic verify || return 90 ;;
            3)
                nic_inventory; read -r -p '网卡 DEV: ' iface
                submenu_run cmd_nic manage --interface "$iface" --mode fq || return 90
                ;;
            4)
                nic_inventory; read -r -p '网卡 DEV: ' iface; read -r -p '速率 Mbit/s: ' rate
                submenu_run cmd_nic manage --interface "$iface" --mode shape --rate "$rate" || return 90
                ;;
            5)
                nic_inventory; read -r -p '网卡 DEV: ' iface
                submenu_run tc_disable "$iface" || return 90
                ;;
            6)
                nic_inventory; read -r -p '网卡 DEV: ' iface
                if confirm "解除 $iface 管理并恢复原始 qdisc？"; then submenu_run nic_unmanage "$iface" || return 90; else log INFO "已取消"; ui_pause; fi
                ;;
            7)
                nic_inventory; read -r -p '网卡 DEV: ' iface; read -r -p '速率 Mbit/s: ' rate
                submenu_run tc_trial "$rate" "$iface" || return 90
                ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

kernel_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'XanMod 内核管理' '1) 内核/BBR 状态' '2) 安装 XanMod LTS' '3) 安装 XanMod Main' '4) 卸载非运行中的 XanMod' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run kernel_status || return 90 ;;
            2) if confirm '安装 XanMod LTS？'; then submenu_run kernel_install lts || return 90; else log INFO "已取消"; ui_pause; fi ;;
            3) if confirm '安装 XanMod Main？'; then submenu_run kernel_install main || return 90; else log INFO "已取消"; ui_pause; fi ;;
            4) submenu_run kernel_remove || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

dns_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'DNS 独立策略' '1) 状态' '2) 预览 strict-dot 计划' '3) 应用 strict-dot（失败即回滚）' '4) 应用 plain' '5) 恢复 native 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run dns_policy_status || return 90 ;; 2) submenu_run dns_policy_plan strict-dot || return 90 ;;
            3) if confirm '应用严格 DoT 策略？'; then submenu_run dns_policy_apply strict-dot || return 90; else log INFO "已取消"; ui_pause; fi ;;
            4) if confirm '应用普通 DNS 策略？'; then submenu_run dns_policy_apply plain || return 90; else log INFO "已取消"; ui_pause; fi ;;
            5) if confirm '恢复 DNS native 基线？'; then submenu_run dns_policy_apply native || return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

ipv6_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'IPv6 独立策略' '1) 状态' '2) 预览临时禁用计划' '3) 应用临时禁用' '4) 应用持久禁用' '5) 恢复 native 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run ipv6_policy_status || return 90 ;; 2) submenu_run ipv6_policy_plan disabled-temporary || return 90 ;;
            3) if confirm '临时禁用非回环 IPv6？'; then submenu_run ipv6_policy_apply disabled-temporary || return 90; else log INFO "已取消"; ui_pause; fi ;;
            4) if confirm '持久禁用非回环 IPv6？'; then submenu_run ipv6_policy_apply disabled-persistent || return 90; else log INFO "已取消"; ui_pause; fi ;;
            5) if confirm '恢复 IPv6 native 基线？'; then submenu_run ipv6_policy_apply native || return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

maintenance_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' '恢复 / 更新 / 卸载' '1) 查看基线' '2) 只恢复首次可信基线' '3) 检查更新' \
            '4) 完整卸载（恢复配置、删除 bbr，保留备份）' '5) 完整卸载并永久删除全部状态' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run baseline_info || return 90 ;;
            2) if confirm '恢复首次可信基线？'; then submenu_run restore_baseline || return 90; else log INFO "已取消"; ui_pause; fi ;;
            3) submenu_run self_update || return 90 ;;
            4) if confirm '恢复可恢复配置并删除 bbr 命令？'; then ui_clear; uninstall_managed 0 && return 90; else log INFO "已取消"; ui_pause; fi ;;
            5) if confirm '先恢复可恢复配置，再永久删除 bbr 命令、基线和历史？'; then ui_clear; uninstall_managed 1 && return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

status_and_verify_action() { show_status; verify_system_state; }

interactive_menu() {
    local choice
    while true; do
        ui_clear
        printf '\n%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '%s\n' '1) 自动调优（推荐）' '2) 安装/刷新 BBR + FQ' '3) 测量与复验' '4) 多网卡 / TC 管理' \
            '5) 完整状态与一致性验证' '6) XanMod 内核管理' '7) DNS 管理' '8) IPv6 管理' '9) 恢复/更新/卸载' '0) 退出'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run auto_tune_wizard ;;
            2) submenu_run cmd_install ;;
            3) if ! menu_run measurement_menu; then return 0; fi ;;
            4) if ! menu_run tc_menu; then return 0; fi ;;
            5) submenu_run status_and_verify_action ;;
            6) if ! menu_run kernel_menu; then return 0; fi ;;
            7) if ! menu_run dns_menu; then return 0; fi ;;
            8) if ! menu_run ipv6_menu; then return 0; fi ;;
            9) if ! menu_run maintenance_menu; then return 0; fi ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

main() {
    trap cleanup_core EXIT
    local command="${1:-}"; [[ -n "$command" ]] && shift || true
    if [[ -z "$command" ]]; then
        if [[ -t 0 ]]; then interactive_menu; else show_help; fi
        return
    fi
    case "$command" in
        auto) require_no_arguments "auto" "$@" || return 1; auto_tune_wizard ;;
        detect) cmd_detect "$@" ;;
        install) cmd_install "$@" ;;
        explain) cmd_explain "$@" ;;
        status) require_no_arguments "status" "$@" || return 1; show_status ;;
        tc) cmd_tc "$@" ;;
        nic) cmd_nic "$@" ;;
        measure) cmd_measure "$@" ;;
        kernel) cmd_kernel "$@" ;;
        dns) cmd_dns "$@" ;;
        ipv6) cmd_ipv6 "$@" ;;
        baseline) cmd_baseline "$@" ;;
        verify) require_no_arguments "verify" "$@" || return 1; verify_system_state ;;
        restore) require_no_arguments "restore" "$@" || return 1; restore_baseline ;;
        uninstall)
            case "$#:${1:-}" in 0:) uninstall_managed 0 ;; 1:--purge-state) uninstall_managed 1 ;; *) die "uninstall 只接受一个可选参数 --purge-state" ;; esac
            ;;
        apply) require_no_arguments "apply" "$@" || return 1; apply_configured_state ;;
        update) require_no_arguments "update" "$@" || return 1; self_update ;;
        version|--version|-V) require_no_arguments "version" "$@" || return 1; printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
        help|--help|-h) require_no_arguments "help" "$@" || return 1; show_help ;;
        *) die "未知命令: $command（运行 help 查看用法）" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
