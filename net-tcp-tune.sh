#!/usr/bin/env bash
# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu
# This file is assembled from src/*.sh by scripts/build.sh.
# shellcheck shell=bash

SCRIPT_VERSION="7.2.0"
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
}

config_key_known() {
    case "$1" in
        SCHEMA_VERSION|BBR_ENABLED|SYSCTL_PROFILE|ROLE|BANDWIDTH_MBIT|RTT_MS|TC_ENABLED|TC_INTERFACE|TC_RATE_MBIT|TC_KNEE_MBIT|TC_MARGIN_PERCENT|INITCWND|INITRWND) return 0 ;;
        *) return 1 ;;
    esac
}

validate_interface_name() {
    [[ "$1" == "auto" || "$1" =~ ^[a-zA-Z0-9_.:-]{1,64}$ ]]
}

validate_config_value() {
    local key="$1" value="$2"
    case "$key" in
        SCHEMA_VERSION) [[ "$value" == "$STATE_SCHEMA" ]] ;;
        BBR_ENABLED|TC_ENABLED) [[ "$value" == 0 || "$value" == 1 ]] ;;
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
        "INITRWND=${INITRWND}"
}

save_config() {
    local file="${1:-$CONFIG_FILE}" temp
    for key in SCHEMA_VERSION BBR_ENABLED SYSCTL_PROFILE ROLE BANDWIDTH_MBIT RTT_MS TC_ENABLED TC_INTERFACE TC_RATE_MBIT TC_KNEE_MBIT TC_MARGIN_PERCENT INITCWND INITRWND; do
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

default_route_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '$1=="default" {print $5; exit}')
    [[ -n "$iface" ]] || iface=$(ip -6 route show default 2>/dev/null | awk '$1=="default" {print $5; exit}')
    printf '%s\n' "$iface"
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
# State and baseline: immutable provenance and scoped restoration.
# -----------------------------------------------------------------------------

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
       -e "$SERVICE_FILE" || -e "$LEGACY_SERVICE_FILE" || -e "$PERSIST_SCRIPT" ]]
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
        cp -a -- "$source" "$BASELINE_DIR/$name" || return 1
        printf 'present\n' > "$BASELINE_DIR/${name}.state" || return 1
    else
        printf 'absent\n' > "$BASELINE_DIR/${name}.state" || return 1
    fi
}

capture_runtime_sysctls() {
    local key value
    for key in \
        net.core.default_qdisc net.ipv4.tcp_congestion_control \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog; do
        value=$(sysctl -n "$key" 2>/dev/null || true)
        [[ -n "$value" ]] && printf '%s\t%s\n' "$key" "$value"
    done
    return 0
}

capture_baseline() {
    local iface="$1" provenance="${2:-native}" temp_dir
    ensure_state_layout || return 1
    [[ ! -f "$BASELINE_DIR/manifest" ]] || return 0
    if [[ -d "$BASELINE_DIR" ]]; then
        log WARN "清理上次中断留下的不完整基线目录"
        remove_tree_within "$BASELINE_DIR" "$STATE_DIR" || return 1
    fi
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
    mkdir -p "$temp_dir/files" || { remove_tree_within "$temp_dir" "$STATE_DIR"; return 1; }
    mv "$temp_dir" "$BASELINE_DIR" || { remove_tree_within "$temp_dir" "$STATE_DIR"; return 1; }
    printf 'SCHEMA\t%s\nCREATED_AT\t%s\nCREATED_BY\t%s\nPROVENANCE\t%s\nINTERFACE\t%s\n' \
        "$STATE_SCHEMA" "$(utc_now)" "$SCRIPT_VERSION" "$provenance" "$iface" > "$BASELINE_DIR/manifest.pending" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    capture_runtime_sysctls > "$BASELINE_DIR/sysctl.tsv" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    tc qdisc show dev "$iface" > "$BASELINE_DIR/qdisc.txt" 2>/dev/null || true
    tc class show dev "$iface" > "$BASELINE_DIR/class.txt" 2>/dev/null || true
    ip -4 route show table all > "$BASELINE_DIR/routes-v4.txt" 2>/dev/null || true
    ip -6 route show table all > "$BASELINE_DIR/routes-v6.txt" 2>/dev/null || true
    ip -4 route show default > "$BASELINE_DIR/default-route-v4.txt" 2>/dev/null || true
    ip -6 route show default > "$BASELINE_DIR/default-route-v6.txt" 2>/dev/null || true
    backup_path "$CONFIG_FILE" config || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    backup_path "$SYSCTL_FILE" sysctl || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    backup_path "$LEGACY_SYSCTL_FILE" legacy-sysctl || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    backup_path "$SERVICE_FILE" service || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    backup_path "$LEGACY_SERVICE_FILE" legacy-service || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    backup_path "$PERSIST_SCRIPT" persist-script || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    capture_unit_state "$SERVICE_NAME" "$BASELINE_DIR/service.unit" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    capture_unit_state bbr-optimize-persist.service "$BASELINE_DIR/legacy-service.unit" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    chmod -R go-rwx "$BASELINE_DIR" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    mv "$BASELINE_DIR/manifest.pending" "$BASELINE_DIR/manifest" || { remove_tree_within "$BASELINE_DIR" "$STATE_DIR"; return 1; }
    log OK "已保存不可覆盖的初始基线: $BASELINE_DIR ($provenance)"
}

baseline_adopt() {
    require_root || return 1; acquire_lock || return 1; require_commands ip tc sysctl || return 1
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
    rm -f -- "$target" || return 1
    if [[ "$state" == present ]]; then
        mkdir -p -- "$(dirname "$target")" || return 1
        cp -a -- "$BASELINE_DIR/$name" "$target" || return 1
    fi
}

restore_runtime_sysctls() {
    local key value rc=0
    [[ -f "$BASELINE_DIR/sysctl.tsv" ]] || return 0
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

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "${TC_INTERFACE:-auto}" || return 1
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
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "${TC_INTERFACE:-auto}" || return 1
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

verify_sysctl_profile_file() {
    local expected
    [[ -f "$SYSCTL_FILE" ]] || { log ERR "sysctl 持久化文件缺失: $SYSCTL_FILE"; return 1; }
    command_exists cmp || { die "缺少命令: cmp"; return 1; }
    expected=$(mktemp) || return 1
    if ! render_sysctl_profile > "$expected"; then rm -f -- "$expected"; return 1; fi
    if ! cmp -s "$expected" "$SYSCTL_FILE"; then
        rm -f -- "$expected"
        log ERR "sysctl 持久化文件与当前配置不一致: $SYSCTL_FILE"
        return 1
    fi
    rm -f -- "$expected"
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
        line=$(ip "$family" route show default 2>/dev/null | head -n1 || true)
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

# -----------------------------------------------------------------------------
# Traffic control: HTB aggregate shaper + FQ leaf, full verification and rollback.
# -----------------------------------------------------------------------------

TC_SESSION_HTB_IFACE=""
# Enough for 1 Tbit/s even at CONFIG_HZ=100. The actual value remains rate/HZ,
# so ordinary VPS rates do not inherit a large bucket merely because the cap
# supports modern 25/100/400G NICs.
HTB_BURST_CAP=2147483647

tc_dependencies() { require_commands ip tc awk; }
has_net_admin() { tc qdisc show >/dev/null 2>&1; }

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
    [[ -e "/sys/class/net/$iface" ]] || { die "网卡不存在: $iface"; return 1; }
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
        kind=managed-htb
        rate=$(managed_rate_mbit "$iface") || return 1
    fi
    [[ "$kind" == fq || "$kind" == fq_codel ]] && replay_args_string=$(root_qdisc_replay_args "$iface")
    printf 'KIND\t%s\nRATE\t%s\nARGS\t%s\n' "$kind" "$rate" "$replay_args_string" > "$file" || return 1
    tc qdisc show dev "$iface" >> "$file" 2>/dev/null || true
    tc class show dev "$iface" >> "$file" 2>/dev/null || true
}

snapshot_field() { awk -F'\t' -v key="$2" '$1==key {print $2; exit}' "$1"; }

restore_action_qdisc() {
    local iface="$1" file="$2" kind rate args_string
    local -a args=()
    [[ -f "$file" ]] || return 1
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

tc_trial() {
    require_root || return 1; require_host_network_control || return 1; acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" iface
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    BANDWIDTH_MBIT="$rate"; network_tuning_preflight "$iface" 1 || return 1
    capture_baseline "$iface" || return 1
    apply_shaping "$iface" "$rate" || return 1
    log OK "临时整形已生效: $iface ${rate} Mbit（未写配置，重启后失效）"
}

tc_enable_steps() {
    local iface="$1" rate="$2" requested="$3" knee="$4" margin="$5"
    capture_baseline "$iface" || return 1
    load_config || return 1
    TC_ENABLED=1; TC_INTERFACE="$requested"; TC_RATE_MBIT="$rate"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT="$margin"
    apply_sysctl_profile || return 1
    apply_shaping "$iface" "$rate" || return 1
    save_config || { die "整形已在运行时生效，但配置保存失败"; return 1; }
    install_persistence || { die "整形已在运行时生效，但持久化安装失败"; return 1; }
    restart_and_verify_persistence || return 1
    log OK "整形已持久化: $iface ${rate} Mbit"
}

tc_enable() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; tc_dependencies || return 1
    local rate="$1" requested="${2:-auto}" knee="${3:-0}" margin="${4:-3}" iface
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    is_uint "$knee" && (( knee <= 1000000 )) || { die "非法拐点速率: $knee"; return 1; }
    is_uint "$margin" && (( margin <= 25 )) || { die "非法退让比例: $margin"; return 1; }
    (( knee == 0 || knee >= rate )) || { die "拐点速率不能低于最终整形速率"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    BANDWIDTH_MBIT="$rate"; network_tuning_preflight "$iface" 1 || return 1
    run_action_transaction "$iface" tc_enable_steps "$iface" "$rate" "$requested" "$knee" "$margin"
}

tc_disable_steps() {
    local iface="$1"
    if managed_htb "$iface"; then apply_fq "$iface" || return 1
    elif [[ "$(root_qdisc_kind "$iface")" != fq ]]; then qdisc_guard "$iface" || return 1; apply_fq "$iface" || return 1; fi
    TC_ENABLED=0; TC_RATE_MBIT=0
    save_config || return 1
    install_persistence || return 1
    restart_and_verify_persistence || return 1
    log OK "HTB 整形已关闭，BBR + FQ 保持启用"
}

tc_disable() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; tc_dependencies || return 1
    local requested="${1:-auto}" iface
    load_config || return 1
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    network_tuning_preflight "$iface" 0 || return 1
    run_action_transaction "$iface" tc_disable_steps "$iface"
}

tc_status() {
    local requested="${1:-auto}" iface
    load_config || return 1
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    printf 'Interface: %s\n' "$iface"
    printf 'Configured: enabled=%s rate=%sMbit knee=%sMbit margin=%s%%\n' "$TC_ENABLED" "$TC_RATE_MBIT" "$TC_KNEE_MBIT" "$TC_MARGIN_PERCENT"
    tc -s -d qdisc show dev "$iface"
    tc -s -d class show dev "$iface"
}

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
    local host="$1" limit="${2:-1}" port found=0
    is_uint "$limit" && (( limit >= 1 && limit <= 4 )) || limit=1
    for port in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200; do
        if peer_port_open "$host" "$port" && iperf_peer_usable "$host" "$port"; then
            printf '%s\n' "$port"
            ((found+=1))
            (( found < limit )) || return 0
        fi
    done
    (( found > 0 ))
}

public_peer_port() {
    public_peer_ports "$1" 1
}

auto_pick_peer() {
    require_commands ping timeout iperf3 jq || return 1
    local temp host region provider rtt port max_rtt="${BBRV3_PEER_MAX_RTT:-120}"
    local limit="${BBRV3_PUBLIC_PEER_CANDIDATES:-4}" per_host="${BBRV3_PUBLIC_PORTS_PER_HOST:-2}" candidate found rank
    local primary_host="" preferred_extra="" primary_take index
    local -a primary_candidates=() extra_candidates=() ordered_candidates=()
    is_uint "$limit" && (( limit >= 2 && limit <= 8 )) || limit=4
    is_uint "$per_host" && (( per_host >= 1 && per_host <= 4 )) || per_host=2
    PUBLIC_PEER_CANDIDATES=()
    temp=$(mktemp -d) || return 1
    log INFO "正在按 RTT 筛选公共 iperf3 节点（Leaseweb / OVH / Clouvider）"
    while IFS='|' read -r host region provider; do
        [[ -n "$host" ]] || continue
        (
            rtt=$(median_ping_ms "$host")
            [[ -n "$rtt" ]] && printf '%s\t%s\t%s\t%s\n' "$rtt" "$host" "$region" "$provider" > "$temp/${host//[^a-zA-Z0-9]/_}"
        ) &
    done <<< "$PUBLIC_PEER_POOL"
    wait || true
    while IFS=$'\t' read -r rtt host region provider; do
        (( rtt <= max_rtt )) || { log INFO "$host ($region/$provider) RTT ${rtt}ms，过远跳过"; continue; }
        found=0; rank=0
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            candidate="$host|$port|$rtt|$region|$provider"
            if (( rank == 0 )); then primary_candidates+=("$candidate"); else extra_candidates+=("$candidate"); fi
            ((found+=1)); ((rank+=1))
        done < <(public_peer_ports "$host" "$per_host")
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
        IFS='|' read -r host port rtt region provider <<< "$candidate"
        if (( ${#PUBLIC_PEER_CANDIDATES[@]} == 1 )); then
            log OK "公共对端已通过 iperf3 预检: $host:$port ($region/$provider, RTT ${rtt}ms)"
        else
            log INFO "已保留备用公共对端: $host:$port ($region/$provider, RTT ${rtt}ms)"
        fi
        (( ${#PUBLIC_PEER_CANDIDATES[@]} < limit )) || break
    done
    ((${#PUBLIC_PEER_CANDIDATES[@]} > 0)) || { die "${max_rtt}ms 内没有可用公共 iperf3 节点；请使用自有对端"; return 1; }
}

interface_counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || printf '0\n'; }

measure_set_latency_baseline() {
    local peer="$1" value=""
    MEASURE_IDLE_RTT_MS="na"
    [[ "$(uname -s 2>/dev/null || true)" == Linux ]] || return 0
    command_exists ping || return 0
    value=$(median_ping_ms "$peer" 2>/dev/null || true)
    if is_decimal "$value"; then
        MEASURE_IDLE_RTT_MS="$value"
        log INFO "空闲 RTT 基线: ${value} ms"
    else
        log WARN "未取得空闲 RTT；吞吐和重传仍会测量，但负载延迟与置信度会降级"
    fi
}

measure_begin() {
    local iface="$1"
    MEASURE_IFACE="$iface"
    MEASURE_SNAPSHOT=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$MEASURE_SNAPSHOT" || {
        rm -f -- "$MEASURE_SNAPSHOT"
        MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        return 1
    }
    MEASURE_TX_START=$(interface_counter "$iface" tx_bytes)
    MEASURE_RX_START=$(interface_counter "$iface" rx_bytes)
    trap 'measure_abort 130' INT TERM HUP
}

measure_restore() {
    local rc=0
    if [[ -n "$MEASURE_IFACE" && -n "$MEASURE_SNAPSHOT" && -f "$MEASURE_SNAPSHOT" ]]; then
        restore_action_qdisc "$MEASURE_IFACE" "$MEASURE_SNAPSHOT" || rc=$?
        rm -f -- "$MEASURE_SNAPSHOT"
    fi
    trap - INT TERM HUP
    MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
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

peer_port_open() {
    local peer="$1" port="$2"
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$peer" "$port" >/dev/null 2>&1
}

iperf_peer_usable() {
    local peer="$1" port="$2" json rc=0 error bps
    json=$(mktemp) || return 1
    if timeout 8 iperf3 -c "$peer" -p "$port" -t 1 -P 1 -b 1M -J > "$json" 2>/dev/null; then
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
    json=$(mktemp) || return 1
    error_file=$(mktemp) || { rm -f -- "$json"; return 1; }
    latency_file=$(mktemp) || { rm -f -- "$json" "$error_file"; return 1; }
    if [[ "$(uname -s 2>/dev/null || true)" == Linux ]] && command_exists ping; then
        ping -n -i 0.2 -W 1 -c "$((duration * 5))" -- "$peer" > "$latency_file" 2>/dev/null &
        latency_pid=$!
    fi
    if [[ -n "$MEASURE_IFACE" ]]; then tx_before=$(interface_counter "$MEASURE_IFACE" tx_bytes); fi
    cpu_before=$(cpu_snapshot)
    core_before=$(cpu_core_snapshot)
    if timeout "$((duration + 20))" iperf3 -c "$peer" -p "$port" -t "$duration" -P "$parallel" -J > "$json" 2> "$error_file"; then
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
    rm -f -- "$error_file"
    if (( rc != 0 )); then
        reason=${reason//$'\n'/ }
        reason=${reason//$'\r'/}
        reason=${reason:0:240}
        log WARN "iperf3 $peer:$port 测试失败: $reason"
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
    local sample_count="$1" spread="$2" loaded_p95="$3" contaminated="$4" failovers="${5:-0}"
    local score=100 grade reason
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

measure_probe() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" iface dir row rc=0 speed estimate
    local confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return "$IPERF_UNAVAILABLE_RC"; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    fi
    new_measure_run probe || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer"
    measure_begin "$iface" || return 1
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 unshaped 3 6); then
        confidence=$(measurement_confidence "$(cut -f13 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f7 <<< "$row")" "$(cut -f11 <<< "$row")" 0)
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\nRETRANS_PER_GIB\t%s\nIDLE_RTT_MS\t%s\nLOADED_RTT_P95_MS\t%s\nBUFFERBLOAT_P95_MS\t%s\nGOODPUT_SPREAD_PERCENT\t%s\nSAMPLE_COUNT\t%s\nBACKGROUND_TX_PERCENT_MAX\t%s\nCPU_BUSY_PERCENT_MAX\t%s\nCPU_STEAL_PERCENT_MAX\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" "$(cut -f5 <<< "$row")" \
            "$MEASURE_IDLE_RTT_MS" "$(cut -f7 <<< "$row")" "$(cut -f14 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f13 <<< "$row")" \
            "$(cut -f8 <<< "$row")" "$(cut -f9 <<< "$row")" "$(cut -f10 <<< "$row")" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
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
    local iface dir baseline_row baseline_gp baseline_loss base_row base_gp base_loss rate row gp loss
    local last_ok="" last_ok_gp="" broke_at="" fine_start fine_step recommend="" candidate="" confirm_row confirm_gp="" confirm_loss=""
    local min_efficiency="0.90" confirmed=0 reject_reason="" estimated tests rc=0 no_knee=0 above_cap=0 baseline_duration
    local auto_cap=0 nominal_was_auto=0 observed_cap
    local confidence_row confidence confidence_score confidence_grade confidence_reasons
    validate_peer "$peer" "$port" || return 1
    [[ "$result_mode" == manual || "$result_mode" == auto ]] || { die "扫描结果模式只支持 manual/auto"; return 1; }
    for value in "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$force_scan" "$cap"; do is_uint "$value" || { die "扫描参数必须为非负整数"; return 1; }; done
    is_decimal "$threshold" || { die "loss threshold 必须是数字"; return 1; }
    (( nominal == 0 )) && nominal_was_auto=1
    if (( cap == 0 )) || [[ "$result_mode" == auto ]]; then auto_cap=1; fi
    if (( cap == 0 )); then cap=$(recommended_scan_cap "$requested" "$nominal") || return 1; fi
    (( duration >= 3 && duration <= 120 && parallel >= 1 && parallel <= 32 && margin <= 25 && force_scan <= 1 && cap >= 100 && cap <= 1000000 )) || { die "扫描参数超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return "$IPERF_UNAVAILABLE_RC"; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    hardware_profile_values "$iface" "$nominal" || return 1
    new_measure_run sweep || return 1
    dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer"
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
            confidence=$(measurement_confidence "$(cut -f13 <<< "$confidence_row")" "$(cut -f12 <<< "$confidence_row")" "$(cut -f7 <<< "$confidence_row")" "$(cut -f11 <<< "$confidence_row")" 0)
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
    local peer="$1" port="$2" requested="$3" rate="$4" iface row gp loss rc=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate > 0 )) || { die "路径检查速率无效"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    measure_set_latency_baseline "$peer"
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
            log OK "路径预检通过: ${gp} Mbit/s，重传估算 ${loss}%"
        fi
    else
        rc=$?
    fi
    measure_restore || rc=$?
    return "$rc"
}

measure_verify() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="${4:-8}" expected_rate="${5:-0}" min_efficiency="${6:-0.90}"
    local baseline_loss="${7:-0}" threshold="${8:-0.1}" iface dir one multi one_gp one_loss multi_gp multi_loss rc=0 accepted=1 reject_reason=""
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
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return "$IPERF_UNAVAILABLE_RC"; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    multi_parallel=$(recommended_verify_flows "$iface" "$expected_rate") || return 1
    new_measure_run verify || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer"
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
        confidence=$(measurement_confidence "$combined_count" "$combined_spread" "$combined_loaded" "$combined_contaminated" 0)
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        printf 'TYPE\tverify\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nEXPECTED_RATE_MBIT\t%s\nMIN_EFFICIENCY_RATIO\t%s\nIDLE_RTT_MS\t%s\nSINGLE_MBIT\t%s\nSINGLE_RETRANS_EST_PERCENT\t%s\nSINGLE_RETRANS_PER_GIB\t%s\nSINGLE_LOADED_RTT_P95_MS\t%s\nSINGLE_BUFFERBLOAT_P95_MS\t%s\nSINGLE_GOODPUT_SPREAD_PERCENT\t%s\nSINGLE_SAMPLE_COUNT\t%s\nMULTI_FLOWS\t%s\nMULTI_MBIT\t%s\nMULTI_RETRANS_EST_PERCENT\t%s\nMULTI_RETRANS_PER_GIB\t%s\nMULTI_LOADED_RTT_P95_MS\t%s\nMULTI_BUFFERBLOAT_P95_MS\t%s\nMULTI_GOODPUT_SPREAD_PERCENT\t%s\nMULTI_SAMPLE_COUNT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nACCEPTED\t%s\nREJECT_REASON\t%s\n' \
            "$peer" "$port" "$iface" "$expected_rate" "$min_efficiency" "$MEASURE_IDLE_RTT_MS" \
            "$one_gp" "$one_loss" "$(cut -f5 <<< "$one")" "$(cut -f7 <<< "$one")" "$(cut -f14 <<< "$one")" "$one_spread" "$one_count" \
            "$multi_parallel" "$multi_gp" "$multi_loss" "$(cut -f5 <<< "$multi")" "$(cut -f7 <<< "$multi")" "$(cut -f14 <<< "$multi")" "$multi_spread" "$multi_count" \
            "$confidence_score" "$confidence_grade" "$confidence_reasons" "$accepted" "$reject_reason" > "$dir/summary.tsv"
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
    local iface dir speed estimate_rate estimate rc=0 round mode row verdict confidence
    local fq_gp shaped_gp fq_rpg shaped_rpg fq_bloat shaped_bloat fq_spread shaped_spread combined_spread combined_loaded
    local confidence_score confidence_grade confidence_reasons throughput_delta
    local -a fq_goodputs=() shaped_goodputs=() fq_retrans_gib=() shaped_retrans_gib=() fq_bloats=() shaped_bloats=()
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "compare rate 必须是 1–1000000 的整数"; return 1; }
    is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "compare duration 必须是 3–30 秒"; return 1; }
    is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "compare rounds 必须是 2–5"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return "$IPERF_UNAVAILABLE_RC"; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    new_measure_run compare || return 1; dir="$MEASURE_RUN_DIR"
    measure_set_latency_baseline "$peer"
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
        confidence=$(measurement_confidence "$rounds" "$combined_spread" "$combined_loaded" 0 0)
        IFS=$'\t' read -r confidence_score confidence_grade confidence_reasons <<< "$confidence"
        throughput_delta=$(awk -v f="$fq_gp" -v s="$shaped_gp" 'BEGIN {if(f<=0) print "na"; else printf "%.2f", (s-f)*100/f}')
        printf 'TYPE\tcompare\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nRATE_MBIT\t%s\nDURATION_SECONDS\t%s\nROUNDS\t%s\nORDER\tinterleaved\nIDLE_RTT_MS\t%s\nFQ_GOODPUT_MBIT\t%s\nFQ_RETRANS_PER_GIB\t%s\nFQ_BUFFERBLOAT_P95_MS\t%s\nFQ_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_GOODPUT_MBIT\t%s\nSHAPED_RETRANS_PER_GIB\t%s\nSHAPED_BUFFERBLOAT_P95_MS\t%s\nSHAPED_GOODPUT_SPREAD_PERCENT\t%s\nSHAPED_THROUGHPUT_DELTA_PERCENT\t%s\nVERDICT\t%s\nCONFIDENCE_SCORE\t%s\nCONFIDENCE_GRADE\t%s\nCONFIDENCE_REASONS\t%s\nPERSISTED\t0\n' \
            "$peer" "$port" "$iface" "$rate" "$duration" "$rounds" "$MEASURE_IDLE_RTT_MS" \
            "$fq_gp" "$fq_rpg" "$fq_bloat" "$fq_spread" "$shaped_gp" "$shaped_rpg" "$shaped_bloat" "$shaped_spread" \
            "$throughput_delta" "$verdict" "$confidence_score" "$confidence_grade" "$confidence_reasons" > "$dir/summary.tsv"
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
    BANDWIDTH_MBIT="$bandwidth"; network_tuning_preflight "$iface" 1 || return 1
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
    kind=$(awk '$1=="qdisc" && $0~/ root([[:space:]]|$)/ {print $2; exit}' "$BASELINE_DIR/qdisc.txt" 2>/dev/null)
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
    local hardware_state="unavailable" queue_state="unavailable" backlog_state="unavailable" scaling_state="unavailable"
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
    if buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" "${iface:-${TC_INTERFACE:-auto}}" 2>/dev/null; then
        buffer_state="$(human_bytes "$BUFFER_MAX") ($BUFFER_REASON)"
        hardware_state="$HARDWARE_CLASS / ${HARDWARE_CPU_COUNT} CPU / ${HARDWARE_MEMORY_MB} MiB"
        queue_state="${HARDWARE_DRIVER} / RX ${HARDWARE_RX_QUEUES} / TX ${HARDWARE_TX_QUEUES} / MTU ${HARDWARE_MTU} / link ${HARDWARE_LINK_MBIT} (${HARDWARE_LINK_TRUST})"
        backlog_state="listen/SYN ${SOMAXCONN}/${TCP_MAX_SYN_BACKLOG} / netdev ${NETDEV_BACKLOG}"
        scaling_state=$(hardware_scaling_note)
    fi
    script_state=$(persistence_script_state)
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
    mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
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
        if [[ "$(uname -r)" == *xanmod* ]] && dpkg-query -L "$package" 2>/dev/null | grep -Fq "/boot/vmlinuz-$(uname -r)"; then
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

dns_snapshot_current() {
    local directory="$1" active
    mkdir -p -- "$directory" || return 1
    dns_snapshot_path "$DNS_RESOLV_CONF" resolv.conf resolv "$directory" || return 1
    dns_snapshot_path "$DNS_DROPIN" dropin.conf dropin "$directory" || return 1
    active=$(systemctl is-active systemd-resolved 2>/dev/null || true)
    printf '%s\n' "${active:-inactive}" > "$directory/service.active" || return 1
}

dns_restore_snapshot() {
    local directory="$1" state active rc=0
    [[ -f "$directory/resolv.state" && -f "$directory/dropin.state" ]] || {
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

    if [[ -f "$directory/service.active" ]]; then active=$(<"$directory/service.active"); else active=active; fi
    case "$active" in
        active|activating|reloading) systemctl restart systemd-resolved >/dev/null 2>&1 || rc=1 ;;
        *) systemctl stop systemd-resolved >/dev/null 2>&1 || true ;;
    esac
    return "$rc"
}

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline" temp_dir
    [[ -f "$base/manifest" ]] && return 0
    ensure_state_layout || return 1
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    chmod 0700 "$DNS_BACKUP_DIR" 2>/dev/null || true
    if [[ -d "$base" ]]; then
        log WARN "清理上次中断留下的不完整 DNS 基线"
        remove_tree_within "$base" "$DNS_BACKUP_DIR" || return 1
    fi
    temp_dir=$(mktemp -d "${DNS_BACKUP_DIR}/.baseline.XXXXXX") || return 1
    if ! dns_snapshot_current "$temp_dir" ||
       ! printf 'CREATED_AT\t%s\nCREATED_BY\t%s\n' "$(utc_now)" "$SCRIPT_VERSION" > "$temp_dir/manifest" ||
       ! chmod -R go-rwx "$temp_dir" ||
       ! mv "$temp_dir" "$base"; then
        [[ ! -e "$temp_dir" ]] || remove_tree_within "$temp_dir" "$DNS_BACKUP_DIR" || true
        return 1
    fi
}

dns_transaction_begin() {
    [[ -z "$DNS_TRANSACTION_DIR" ]] || { die "已有未提交的 DNS 事务"; return 1; }
    mkdir -p -- "$DNS_BACKUP_DIR" || return 1
    DNS_TRANSACTION_DIR=$(mktemp -d "${DNS_BACKUP_DIR}/.transaction.XXXXXX") || return 1
    if ! dns_snapshot_current "$DNS_TRANSACTION_DIR" || ! chmod -R go-rwx "$DNS_TRANSACTION_DIR"; then
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

dns_apply_steps() {
    local mode="$1" temp
    temp=$(mktemp) || return 1
    if [[ "$mode" == dot ]]; then
        cat > "$temp" <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
Domains=~.
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
    else
        cat > "$temp" <<'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=8.8.8.8
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
    fi
    atomic_install "$temp" "$DNS_DROPIN" 0644 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    ln -sfn "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF" || { die "无法切换 resolv.conf"; return 1; }
    systemctl restart systemd-resolved || { die "systemd-resolved 重启失败"; return 1; }
    resolvectl query example.com >/dev/null || { die "DNS 查询验证失败"; return 1; }
}

dns_apply() {
    require_root || return 1; require_host_network_control || return 1; require_systemd_runtime || return 1
    acquire_lock || return 1; require_commands systemctl resolvectl timeout || return 1
    local mode="${1:-auto}" rc rollback_rc=0
    [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_capture_baseline || return 1
    if [[ "$mode" == auto ]]; then
        if peer_port_open 1.1.1.1 853 || peer_port_open 9.9.9.9 853; then
            mode="dot"
        else
            mode="plain"
            log WARN "公共 DoT 853 不可达，降级到普通 DNS 53"
        fi
    fi
    dns_transaction_begin || return 1
    if dns_apply_steps "$mode"; then
        dns_transaction_commit
        log OK "DNS 策略已应用: $mode"
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
    require_root || return 1; acquire_lock || return 1; require_commands systemctl || return 1
    local base="$DNS_BACKUP_DIR/baseline" rc rollback_rc=0
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_transaction_begin || return 1
    if dns_restore_snapshot "$base"; then
        dns_transaction_commit
        log OK "DNS 已恢复到首次修改前状态"
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
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}

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
    grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本缺少项目标记"; return 1; }
    grep -q "SCRIPT_VERSION=\"${latest#v}\"" "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本版本标记不匹配"; return 1; }
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
  ${0##*/} measure deps
  ${0##*/} measure probe --peer HOST [--port 5201] [--duration 10] [--parallel 4]
  ${0##*/} measure verify --peer HOST [--port 5201] [--duration 10]
  ${0##*/} measure compare --peer HOST --rate MBIT [--port 5201] [--duration 6] [--rounds 2]
  ${0##*/} measure sweep --peer HOST [--nominal MBIT] [--low MBIT --high MBIT]
                         [--step MBIT] [--duration 8] [--parallel 1]
                         [--margin 3] [--loss-threshold 0.1] [--cap MBIT] [--force-scan]
  ${0##*/} kernel status|install [--track lts|main]|remove
  ${0##*/} dns status|apply [auto|dot|plain]|restore
  ${0##*/} ipv6 status|disable [temporary|permanent]|restore
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

cmd_measure() {
    local action="${1:-}"; shift || true
    local peer="" port=5201 iface=auto duration=10 parallel=4 nominal=0 low=0 high=0 step=0 margin=3 threshold=0.1 force=0 cap=0
    local rate=0 rounds=2
    if [[ "$action" == deps ]]; then
        require_no_arguments "measure deps" "$@" || return 1
        install_measure_dependencies
        return
    fi
    [[ "$action" == probe || "$action" == sweep || "$action" == verify || "$action" == compare ]] || { die "measure 子命令应为 deps/probe/sweep/verify/compare"; return 1; }
    [[ "$action" == sweep ]] && { duration=8; parallel=1; }
    [[ "$action" == compare ]] && { duration=6; parallel=1; }
    while (($#)); do
        case "$1" in
            --peer) require_option_value "$@" || return 1; peer="$2"; shift 2 ;;
            --port) require_option_value "$@" || return 1; port="$2"; shift 2 ;;
            --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
            --duration) require_option_value "$@" || return 1; duration="$2"; shift 2 ;;
            --parallel)
                [[ "$action" != verify && "$action" != compare ]] || { die "measure $action 使用固定流数，不接受 --parallel"; return 1; }
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
    if [[ "$action" == compare ]]; then
        is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "measure compare 需要 --rate 1–1000000"; return 1; }
        is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "measure compare --rounds 必须是 2–5"; return 1; }
        is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "measure compare --duration 必须是 3–30 秒"; return 1; }
    fi
    if [[ "$action" == probe ]]; then measure_probe "$peer" "$port" "$iface" "$duration" "$parallel"
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
    local action="${1:-status}" mode; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "dns status" "$@" || return 1; dns_status ;;
        apply)
            (($# <= 1)) || { die "dns apply 最多接受一个 mode"; return 1; }
            mode="${1:-auto}"; [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
            dns_apply "$mode"
            ;;
        restore) require_no_arguments "dns restore" "$@" || return 1; dns_restore ;;
        *) die "dns 子命令应为 status/apply/restore" ;;
    esac
}

cmd_ipv6() {
    local action="${1:-status}" mode; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "ipv6 status" "$@" || return 1; ipv6_status ;;
        disable)
            (($# <= 1)) || { die "ipv6 disable 最多接受一个 mode"; return 1; }
            mode="${1:-temporary}"; [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
            ipv6_disable "$mode"
            ;;
        restore) require_no_arguments "ipv6 restore" "$@" || return 1; ipv6_restore ;;
        *) die "ipv6 子命令应为 status/disable/restore" ;;
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
    local index="$1" candidate host port rtt region provider
    is_uint "$index" && (( index < ${#PUBLIC_PEER_CANDIDATES[@]} )) || return 1
    candidate="${PUBLIC_PEER_CANDIDATES[$index]}"
    IFS='|' read -r host port rtt region provider <<< "$candidate"
    validate_peer "$host" "$port" || return 1
    WIZARD_PEER="$host"; WIZARD_PORT="$port"; WIZARD_PEER_RTT="$rtt"
    WIZARD_PEER_REGION="$region"; WIZARD_PEER_PROVIDER="$provider"; WIZARD_PUBLIC_INDEX="$index"
}

interactive_select_peer() {
    local choice spec
    printf '%s\n' '测速对端：' '  1) 自动选择公共节点（Leaseweb / OVH / Clouvider）' '  2) 自有 iperf3 服务器（推荐）'
    read -r -p '选择 [1]: ' choice || return 1
    case "${choice:-1}" in
        1)
            auto_pick_peer || return 1
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
    peer_port_open "$PEER_HOST" "$PEER_PORT" || { die "无法连接 $PEER_HOST:$PEER_PORT"; return 1; }
    WIZARD_PUBLIC_PEER=0; WIZARD_PEER="$PEER_HOST"; WIZARD_PORT="$PEER_PORT"
    WIZARD_PEER_RTT=0; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0
}

auto_measure_with_peer_failover() {
    local iface="$1" nominal="$2" index=0 count=1 rc path_rate
    local duration="${WIZARD_SAMPLE_DURATION:-5}" cap="${WIZARD_SCAN_CAP:-5000}"
    if (( ${WIZARD_PUBLIC_PEER:-0} )); then count=${#PUBLIC_PEER_CANDIDATES[@]}; fi
    for ((index=0; index<count; index++)); do
        if (( ${WIZARD_PUBLIC_PEER:-0} )); then
            activate_public_peer_candidate "$index" || return 1
            if (( index > 0 )); then
                ((WIZARD_FAILOVERS+=1))
                log WARN "切换到备用公共对端 $((index + 1))/${count}: $WIZARD_PEER:$WIZARD_PORT（$WIZARD_PEER_REGION/$WIZARD_PEER_PROVIDER，RTT ${WIZARD_PEER_RTT}ms）"
            fi
        fi
        if (( nominal > 0 )); then
            path_rate=$((nominal * 40 / 100)); ((path_rate < 1)) && path_rate=1
            if measure_path_check "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$path_rate"; then
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
        if measure_sweep "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$nominal" 0 0 0 "$duration" 1 3 0.1 0 "$cap" auto; then
            WIZARD_SWEEP_PEER="$WIZARD_PEER"
            WIZARD_SWEEP_PORT="$WIZARD_PORT"
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
    local sweep_peer="${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" current_index="${WIZARD_PUBLIC_INDEX:-0}"
    local candidate host index rc
    if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1; then
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
        host="${candidate%%|*}"
        [[ "$host" == "$sweep_peer" ]] || continue
        activate_public_peer_candidate "$index" || return 1
        ((WIZARD_FAILOVERS+=1))
        log WARN "最终复验切换到同主机备用端口: $WIZARD_PEER:$WIZARD_PORT"
        if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1; then
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
    prepare_auto_tuning_runtime "$iface" auto "$profile" "$role" "$nominal" "$tuning_rtt" || return 1
    if [[ -z "${WIZARD_PEER:-}" ]]; then
        verify_runtime_tuning "$iface" || return 1
        persist_current_tuning || return 1
        printf '\n'
        log OK "BBR + FQ 基础调优和持久化提交完成（未运行测速）"
        show_status
        return 0
    fi
    auto_measure_with_peer_failover "$iface" "$nominal" || return 1
    if (( ${WIZARD_PUBLIC_PEER:-0} )); then
        peer_rtt="${WIZARD_PEER_RTT:-0}"
        tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    fi
    summary="$MEASURE_RUN_DIR/summary.tsv"
    recommend=$(summary_value "$summary" RECOMMEND)
    knee=$(summary_value "$summary" BROKE_AT); knee="${knee:-0}"
    measured=$(summary_value "$summary" UNSHAPED_MBIT)
    no_knee=$(summary_value "$summary" NO_KNEE)
    confirmed=$(summary_value "$summary" CONFIRMED)
    reject_reason=$(summary_value "$summary" REJECT_REASON)
    min_efficiency=$(summary_value "$summary" MIN_EFFICIENCY_RATIO); min_efficiency="${min_efficiency:-0.90}"
    baseline_loss=$(summary_value "$summary" CLEAN_BASE_RETRANS_RATIO_EST_PERCENT); baseline_loss="${baseline_loss:-0}"
    role_floor=$(role_tuning_rtt_floor "$role") || return 1
    if (( peer_rtt > role_floor )); then rtt_source="observed-peer"; else rtt_source="role-floor"; fi
    printf 'SWEEP_PEER\t%s\nSWEEP_PORT\t%s\nPEER_RTT_MS\t%s\nTUNING_RTT_MS\t%s\nTUNING_RTT_SOURCE\t%s\nROLE\t%s\nPUBLIC_PEER_FAILOVERS\t%s\n' \
        "${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" "${WIZARD_SWEEP_PORT:-$WIZARD_PORT}" "$peer_rtt" "$tuning_rtt" "$rtt_source" "$role" "${WIZARD_FAILOVERS:-0}" >> "$summary" || return 1

    if [[ -n "$reject_reason" || ( -n "$knee" && "$knee" != 0 && "$confirmed" != 1 ) ]]; then
        die "扫描候选值未通过确认测试（${reject_reason:-unconfirmed}），不会应用或持久化"
        return 2
    fi
    if [[ -n "$measured" && "$tuning_rtt" -gt 0 ]]; then
        SYSCTL_PROFILE=adaptive; BANDWIDTH_MBIT=$(awk -v g="$measured" 'BEGIN {printf "%d", g+0.5}'); RTT_MS="$tuning_rtt"; ROLE="$role"
        apply_sysctl_profile runtime || return 1
    fi
    if [[ -n "$recommend" ]]; then
        TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT="$recommend"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT=3
        apply_shaping "$iface" "$recommend" || return 1
        expected_rate="$recommend"
    else
        TC_ENABLED=0; TC_INTERFACE=auto; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
        apply_fq "$iface" || return 1
        log INFO "扫描未发现可信拐点（NO_KNEE=${no_knee:-1}），保持 BBR + FQ，不启用 HTB"
    fi
    verify_runtime_tuning "$iface" || return 1
    auto_verify_with_peer_failover "$iface" 6 "$expected_rate" "$min_efficiency" "$baseline_loss" || return 1
    verify_summary="$MEASURE_RUN_DIR/summary.tsv"
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
    printf 'FINAL_VERIFY_PEER\t%s\nFINAL_VERIFY_PORT\t%s\nTOTAL_PUBLIC_PEER_FAILOVERS\t%s\nFINAL_VERIFY_CONFIDENCE_SCORE\t%s\nFINAL_VERIFY_CONFIDENCE_GRADE\t%s\nFINAL_VERIFY_CONFIDENCE_REASONS\t%s\n' \
        "$WIZARD_PEER" "$WIZARD_PORT" "${WIZARD_FAILOVERS:-0}" "$verify_confidence_score" "$verify_confidence_grade" "$verify_confidence_reasons" >> "$summary" || return 1
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
    WIZARD_PEER=""; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=0; WIZARD_PUBLIC_INDEX=0; WIZARD_PEER_RTT=0; WIZARD_FAILOVERS=0
    WIZARD_SWEEP_PEER=""; WIZARD_SWEEP_PORT=0; WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
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
        if (( peer_rtt == 0 )); then peer_rtt=$(median_ping_ms "$WIZARD_PEER"); [[ -n "$peer_rtt" ]] || peer_rtt=0; fi
    fi

    printf '%s\n' '用途：1) 混合业务  2) 代理/转发  3) 大文件吞吐'
    read -r -p '选择 [1]: ' role_choice || return 1
    case "${role_choice:-1}" in 1) role=mixed ;; 2) role=proxy ;; 3) role=bulk ;; *) die "无效用途"; return 1 ;; esac
    tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    iface=$(detect_interface auto) || return 1
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
        if (( WIZARD_PUBLIC_PEER )); then printf '  公共备用对端    %s 个（正式采样不可用时自动切换）\n' "$(( ${#PUBLIC_PEER_CANDIDATES[@]} - 1 ))"; fi
        printf '  缓冲区调优 RTT  %sms（按用途下限与测速 RTT 取较大值）\n' "$tuning_rtt"
    fi
    printf '  预计时间/流量   约 3–8 分钟 / %s\n' "$estimate"
    printf '  持久化位置      %s + %s\n' "$CONFIG_FILE" "$SERVICE_FILE"
    confirm "确认开始？" || { log INFO "已取消，未修改系统"; return 0; }

    qdisc_guard "$iface" || return 1
    BANDWIDTH_MBIT="$nominal"; network_tuning_preflight "$iface" 1 || return 1
    action_transaction_begin "$iface" || return 1
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
    ( set -Eeuo pipefail; "$@" )
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
    local choice="$1" rate
    ensure_interactive_measure_dependencies || return 1
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
        printf '%s\n' '测量与复验' '1) 自动拐点扫描' '2) 单次带宽探测' '3) 单流/硬件自适应多流复验' '4) FQ 与整形 A/B 对照' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1|2|3|4) submenu_run measurement_action "$choice" || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

tc_menu() {
    local choice rate
    while true; do
        ui_clear
        printf '%s\n' 'TC 整形管理' '1) 状态/统计' '2) 临时试跑速率' '3) 持久启用速率' '4) 关闭整形并保留 FQ' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run tc_status auto || return 90 ;;
            2) read -r -p '速率 Mbit/s: ' rate; submenu_run tc_trial "$rate" auto || return 90 ;;
            3) read -r -p '速率 Mbit/s: ' rate; submenu_run tc_enable "$rate" auto 0 3 || return 90 ;;
            4) submenu_run tc_disable auto || return 90 ;;
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
        printf '%s\n' 'DNS 管理' '1) 状态' '2) 自动选择 DoT/普通 DNS' '3) 强制 DoT' '4) 普通 DNS' '5) 恢复 DNS 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run dns_status || return 90 ;; 2) submenu_run dns_apply auto || return 90 ;;
            3) submenu_run dns_apply dot || return 90 ;; 4) submenu_run dns_apply plain || return 90 ;;
            5) if confirm '恢复 DNS 基线？'; then submenu_run dns_restore || return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

ipv6_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'IPv6 管理' '1) 状态' '2) 临时禁用' '3) 永久禁用' '4) 恢复 IPv6 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run ipv6_status || return 90 ;; 2) submenu_run ipv6_disable temporary || return 90 ;;
            3) submenu_run ipv6_disable permanent || return 90 ;;
            4) if confirm '恢复 IPv6 基线？'; then submenu_run ipv6_restore || return 90; else log INFO "已取消"; ui_pause; fi ;;
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
        printf '%s\n' '1) 自动调优（推荐）' '2) 安装/刷新 BBR + FQ' '3) 测量与复验' '4) TC 整形管理' \
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
