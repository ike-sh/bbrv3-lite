#!/usr/bin/env bash
# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu
# This file is assembled from src/*.sh by scripts/build.sh.
# shellcheck shell=bash

SCRIPT_VERSION="7.0.0"
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
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
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
    (( LOCK_HELD == 0 )) || return 0
    require_commands flock
    mkdir -p -- "$(dirname "$LOCK_FILE")"
    exec {BBRV3_LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$BBRV3_LOCK_FD"; then
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

cleanup_core() { release_lock; }

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
    atomic_install "$temp" "$file" 0600
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
    case "$(virtualization_type)" in docker|lxc|openvz|podman|container-other) return 0 ;; *) return 1 ;; esac
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
    if is_uint "${value:-}" && (( value > 0 )); then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
detect_rx_queues() { find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | awk '{print $1}'; }
detect_driver() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null || printf 'virtual\n'; }
memory_mb() { awk '/MemTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo; }

median_ping_ms() {
    local target="$1" family="${2:-auto}" output
    case "$family" in
        4) output=$(ping -4 -n -c 5 -W 2 "$target" 2>/dev/null || true) ;;
        6) output=$(ping -6 -n -c 5 -W 2 "$target" 2>/dev/null || true) ;;
        *) output=$(ping -n -c 5 -W 2 "$target" 2>/dev/null || true) ;;
    esac
    awk -F'/' '/rtt|round-trip/ {printf "%.0f\n", $5}' <<< "$output"
}

detect_profile() {
    local requested="${1:-auto}" target="${2:-}" iface rtt="not measured"
    require_commands ip awk uname
    iface=$(detect_interface "$requested") || return 1
    if [[ -n "$target" ]]; then rtt=$(median_ping_ms "$target"); [[ -n "$rtt" ]] || rtt="unreachable"; fi
    printf '%-18s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-18s %s\n' "OS" "$(os_id) $(os_codename)"
    printf '%-18s %s\n' "Kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "Virtualization" "$(virtualization_type)"
    printf '%-18s %s\n' "CPU cores" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo '?')"
    printf '%-18s %s MB\n' "Memory" "$(memory_mb)"
    printf '%-18s %s\n' "Interface" "$iface"
    printf '%-18s %s\n' "Driver" "$(detect_driver "$iface")"
    printf '%-18s %s\n' "MTU" "$(detect_mtu "$iface")"
    printf '%-18s %s\n' "Link speed" "$(detect_link_speed "$iface") Mbps"
    printf '%-18s %s\n' "RX queues" "$(detect_rx_queues "$iface")"
    printf '%-18s %s\n' "Target RTT" "$rtt ms"
    printf '%-18s %s\n' "Congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf '%-18s %s\n' "Available CC" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
}

install_measure_dependencies() {
    require_root
    case "$(os_id)" in
        debian|ubuntu)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 jq iproute2 procps util-linux
            ;;
        *) die "自动安装依赖目前只支持 Debian/Ubuntu" ;;
    esac
}

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

# -----------------------------------------------------------------------------
# Sysctl: auditable balanced/adaptive profiles, BBR verification and route IW.
# -----------------------------------------------------------------------------

ensure_bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<< "$available"; then
        die "当前内核不提供 BBR；不会静默回退到 cubic"
        return 1
    fi
}

buffer_profile_values() {
    local profile="$1" role="$2" bandwidth="$3" rtt="$4"
    local ram bdp max cap floor=4194304 absolute_cap=268435456 default_r=131072 default_w=65536
    ram=$(memory_mb)
    if [[ "$profile" == balanced ]]; then
        BUFFER_MAX=16777216
        BUFFER_R_DEFAULT=$default_r
        BUFFER_W_DEFAULT=$default_w
        BUFFER_REASON="balanced fixed 16 MiB ceiling"
        return 0
    fi
    (( bandwidth > 0 && rtt > 0 )) || { die "adaptive profile 需要 --bandwidth 和 --rtt"; return 1; }
    # bytes = Mbps * ms * 125; keep two BDPs, bounded by RAM/32 and 256 MiB.
    bdp=$(( bandwidth * rtt * 125 ))
    max=$(( bdp * 2 ))
    cap=$(( ram * 1024 * 1024 / 32 ))
    (( cap > absolute_cap )) && cap=$absolute_cap
    (( cap < floor )) && cap=$floor
    (( max < floor )) && max=$floor
    (( max > cap )) && max=$cap
    case "$role" in
        proxy) default_r=131072; default_w=65536 ;;
        mixed) default_r=262144; default_w=131072 ;;
        bulk)  default_r=1048576; default_w=1048576 ;;
    esac
    (( default_r > max )) && default_r=$max
    (( default_w > max )) && default_w=$max
    BUFFER_MAX=$max
    BUFFER_R_DEFAULT=$default_r
    BUFFER_W_DEFAULT=$default_w
    BUFFER_REASON="2xBDP bounded by RAM/32 and 256 MiB"
}

render_sysctl_profile() {
    buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS" || return 1
    cat <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# profile=${SYSCTL_PROFILE} role=${ROLE} bandwidth=${BANDWIDTH_MBIT}Mbps rtt=${RTT_MS}ms
# buffer_max=${BUFFER_MAX} (${BUFFER_REASON})
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUFFER_MAX}
net.core.wmem_max = ${BUFFER_MAX}
net.ipv4.tcp_rmem = 4096 ${BUFFER_R_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 ${BUFFER_W_DEFAULT} ${BUFFER_MAX}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
EOF
}

explain_sysctl_profile() {
    render_sysctl_profile
    printf '\n# Deliberately untouched: tcp_mem, tcp_adv_win_scale, TIME_WAIT, VM, file limits, RPS/RFS.\n'
}

write_sysctl_profile() {
    local temp
    temp=$(mktemp) || return 1
    render_sysctl_profile > "$temp" || { rm -f -- "$temp"; return 1; }
    atomic_install "$temp" "$SYSCTL_FILE" 0644
    rm -f -- "$temp"
}

apply_sysctl_profile() {
    require_commands sysctl modprobe
    ensure_bbr_available || return 1
    write_sysctl_profile || return 1
    sysctl -q -p "$SYSCTL_FILE" || { die "sysctl 应用失败"; return 1; }
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] || { die "BBR 验证失败"; return 1; }
    [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == fq ]] || { die "default_qdisc 验证失败"; return 1; }
    log OK "BBR 与 ${SYSCTL_PROFILE} sysctl 已生效"
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

tc_dependencies() { require_commands ip tc awk; }
has_net_admin() { tc qdisc show >/dev/null 2>&1; }

root_qdisc_kind() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc" && $0 ~ / root / {print $2; exit}'
}

root_qdisc_replay_args() {
    tc qdisc show dev "$1" 2>/dev/null | awk '
        $1=="qdisc" && $0~/ root / {
            seen=0;
            for(i=1;i<=NF;i++) {
                if(seen) {
                    if($i=="refcnt") {i++; continue}
                    token=$i; if(token ~ /^[0-9]+p$/) sub(/p$/, "", token)
                    printf "%s%s", (out?" ":""), token; out=1
                }
                if($i=="root") seen=1
            }
            print ""; exit
        }'
}

managed_htb() {
    local iface="$1"
    tc qdisc show dev "$iface" 2>/dev/null | grep -Eq '^qdisc htb 1: root([[:space:]]|$)' &&
        tc class show dev "$iface" 2>/dev/null | grep -Eq '^class htb 1:10 (root|parent 1:)' &&
        tc qdisc show dev "$iface" 2>/dev/null | grep -Eq '^qdisc fq 10: parent 1:10([[:space:]]|$)'
}

managed_rate_mbit() {
    local iface="$1" token
    token=$(tc class show dev "$iface" 2>/dev/null | awk '$1=="class" && $2=="htb" && $3=="1:10" {for(i=1;i<=NF;i++) if($i=="rate") {print $(i+1); exit}}')
    awk -v r="$token" 'BEGIN {
        if (r ~ /Gbit$/) {sub(/Gbit$/, "", r); printf "%.0f\n", r*1000}
        else if (r ~ /Mbit$/) {sub(/Mbit$/, "", r); printf "%.0f\n", r}
        else if (r ~ /Kbit$/) {sub(/Kbit$/, "", r); printf "%.0f\n", r/1000}
    }'
}

qdisc_guard() {
    local iface="$1" kind
    kind=$(root_qdisc_kind "$iface")
    if managed_htb "$iface"; then return 0; fi
    case "$kind" in
        ""|fq|fq_codel|noqueue|mq|pfifo_fast) return 0 ;;
        *)
            die "拒绝覆盖未管理的 root qdisc '$kind'（$iface）；请先自行恢复或删除"
            return 1
            ;;
    esac
}

action_qdisc_snapshot() {
    local iface="$1" file="$2" kind rate="" replay_args_string=""
    kind=$(root_qdisc_kind "$iface")
    managed_htb "$iface" && { kind=managed-htb; rate=$(managed_rate_mbit "$iface"); }
    [[ "$kind" == fq || "$kind" == fq_codel ]] && replay_args_string=$(root_qdisc_replay_args "$iface")
    printf 'KIND\t%s\nRATE\t%s\nARGS\t%s\n' "$kind" "$rate" "$replay_args_string" > "$file"
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
        fq|fq_codel) tc qdisc replace dev "$iface" root "$kind" "${args[@]}" >/dev/null || tc qdisc replace dev "$iface" root "$kind" >/dev/null ;;
        ""|noqueue|mq|pfifo_fast) tc qdisc del dev "$iface" root >/dev/null 2>&1 || true ;;
        *) die "无法安全恢复 qdisc 类型: $kind" ;;
    esac
}

restore_qdisc_text_snapshot() {
    local iface="$1" file="$2" kind args_string
    local -a args=()
    kind=$(awk '$1=="qdisc" && $0~/ root / {print $2; exit}' "$file" 2>/dev/null)
    args_string=$(awk '$1=="qdisc" && $0~/ root / {
        seen=0; out=0;
        for(i=1;i<=NF;i++) {
            if(seen) {if($i=="refcnt"){i++;continue}; token=$i; if(token~/^[0-9]+p$/)sub(/p$/, "", token); printf "%s%s",(out?" ":""),token; out=1}
            if($i=="root")seen=1
        } print ""; exit}' "$file" 2>/dev/null)
    [[ -n "$args_string" ]] && read -r -a args <<< "$args_string"
    case "$kind" in
        fq|fq_codel) tc qdisc replace dev "$iface" root "$kind" "${args[@]}" || tc qdisc replace dev "$iface" root "$kind" ;;
        ""|noqueue|mq|pfifo_fast) tc qdisc del dev "$iface" root 2>/dev/null || true ;;
        *) return 2 ;;
    esac
}

calc_htb_burst() {
    local rate="$1" hz mtu="$2" bytes
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    is_uint "$hz" || hz=100
    bytes=$(( (rate * 1000000 + 8 * hz - 1) / (8 * hz) ))
    (( bytes < 32768 )) && bytes=32768
    (( bytes < mtu * 10 )) && bytes=$((mtu * 10))
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
    local iface="$1" rate="$2" mtu burst quantum cburst
    is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "非法整形速率: $rate"; return 1; }
    mtu=$(detect_mtu "$iface"); is_uint "$mtu" || mtu=1500
    burst=$(calc_htb_burst "$rate" "$mtu")
    quantum=$(calc_htb_quantum "$mtu")
    cburst=$((mtu * 2))
    tc qdisc replace dev "$iface" root handle 1: htb default 10 || return 1
    tc class replace dev "$iface" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$cburst" quantum "$quantum" || return 1
    tc qdisc replace dev "$iface" parent 1:10 handle 10: fq || return 1
    verify_shaping "$iface"
}

apply_shaping() {
    local iface="$1" rate="$2" snapshot
    tc_dependencies; qdisc_guard "$iface" || return 1
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot"
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
    tc_dependencies; qdisc_guard "$iface" || return 1
    snapshot=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$snapshot"
    if ! tc qdisc replace dev "$iface" root fq || [[ "$(root_qdisc_kind "$iface")" != fq ]]; then
        restore_action_qdisc "$iface" "$snapshot" || true
        rm -f -- "$snapshot"
        die "root FQ 应用失败"
        return 1
    fi
    rm -f -- "$snapshot"
}

tc_trial() {
    require_root; acquire_lock; tc_dependencies
    local rate="$1" requested="${2:-auto}" iface
    iface=$(detect_interface "$requested") || return 1
    capture_baseline "$iface" || return 1
    apply_shaping "$iface" "$rate" || return 1
    log OK "临时整形已生效: $iface ${rate} Mbit（未写配置，重启后失效）"
}

tc_enable() {
    require_root; acquire_lock; tc_dependencies
    local rate="$1" requested="${2:-auto}" knee="${3:-0}" margin="${4:-3}" iface
    iface=$(detect_interface "$requested") || return 1
    capture_baseline "$iface" || return 1
    load_config
    TC_ENABLED=1; TC_INTERFACE="$requested"; TC_RATE_MBIT="$rate"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT="$margin"
    apply_sysctl_profile || return 1
    apply_shaping "$iface" "$rate" || return 1
    save_config
    install_persistence
    log OK "整形已持久化: $iface ${rate} Mbit"
}

tc_disable() {
    require_root; acquire_lock; tc_dependencies
    local requested="${1:-auto}" iface
    load_config
    [[ "$requested" == auto && "$TC_INTERFACE" != auto ]] && requested="$TC_INTERFACE"
    iface=$(detect_interface "$requested") || return 1
    if managed_htb "$iface"; then apply_fq "$iface" || return 1
    elif [[ "$(root_qdisc_kind "$iface")" != fq ]]; then qdisc_guard "$iface" && apply_fq "$iface"; fi
    TC_ENABLED=0; TC_RATE_MBIT=0
    save_config
    install_persistence
    log OK "HTB 整形已关闭，BBR + FQ 保持启用"
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

interface_counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || printf '0\n'; }

measure_begin() {
    local iface="$1"
    MEASURE_IFACE="$iface"
    MEASURE_SNAPSHOT=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$MEASURE_SNAPSHOT"
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
    [[ "$1" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法 peer: $1"; return 1; }
    is_uint "$2" && (( $2 >= 1 && $2 <= 65535 )) || { die "非法端口: $2"; return 1; }
}

peer_port_open() {
    local peer="$1" port="$2"
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$peer" "$port" >/dev/null 2>&1
}

iperf_sample() {
    local peer="$1" port="$2" duration="$3" parallel="$4" json bps bytes retrans goodput ratio
    json=$(mktemp) || return 1
    if ! timeout "$((duration + 20))" iperf3 -c "$peer" -p "$port" -t "$duration" -P "$parallel" -J > "$json" 2>/dev/null; then
        rm -f -- "$json"
        return 1
    fi
    bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json")
    bytes=$(jq -r '.end.sum_sent.bytes // .end.sum.bytes // 0' "$json")
    retrans=$(jq -r '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0' "$json")
    rm -f -- "$json"
    is_decimal "$bps" && is_uint "$bytes" && is_uint "$retrans" || return 1
    goodput=$(awk -v b="$bps" 'BEGIN {printf "%.2f", b/1000000}')
    # An estimate, not packet loss: iperf retransmits / estimated MSS-sized segments.
    ratio=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {n=b/1448; if(n<1)n=1; printf "%.5f", r*100/n}')
    printf '%s\t%s\t%s\t%s\n' "$goodput" "$retrans" "$bytes" "$ratio"
}

median_numbers() { sort -n | awk '{a[NR]=$1} END {if(NR) {if(NR%2) print a[(NR+1)/2]; else printf "%.5f\n", (a[NR/2]+a[NR/2+1])/2}}'; }

sample_repeated() {
    local peer="$1" port="$2" duration="$3" parallel="$4" count="$5" label="$6"
    local -a rows=() goodputs=() retrans=() bytes=() ratios=()
    local row i
    for ((i=1; i<=count; i++)); do
        log INFO "$label: ${duration}s × ${parallel} flow(s), sample ${i}/${count}"
        row=$(iperf_sample "$peer" "$port" "$duration" "$parallel") || { die "iperf3 测试失败或对端繁忙"; return 1; }
        rows+=("$row")
        IFS=$'\t' read -r g r b l <<< "$row"
        goodputs+=("$g"); retrans+=("$r"); bytes+=("$b"); ratios+=("$l")
        [[ -n "$MEASURE_RESULT_FILE" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(utc_now)" "$label" "$g" "$r" "$b" "$l" >> "$MEASURE_RESULT_FILE"
        (( i < count )) && sleep 2
    done
    printf '%s\t%s\t%s\t%s\n' \
        "$(printf '%s\n' "${goodputs[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans[@]}" | median_numbers)" \
        "$(printf '%s\n' "${bytes[@]}" | median_numbers)" \
        "$(printf '%s\n' "${ratios[@]}" | median_numbers)"
}

loss_spike() {
    local value="$1" threshold="$2" base="$3"
    awk -v v="$value" -v t="$threshold" -v b="$base" 'BEGIN {
        if (v <= t) exit 1;
        if (b > 0 && v < b*5) exit 1;
        exit 0
    }'
}

estimate_sweep_bytes() {
    local high="$1" duration="$2" tests="$3"
    awk -v r="$high" -v d="$duration" -v n="$tests" 'BEGIN {printf "%.0f", r*1000000/8*d*n*1.08}'
}

new_measure_run() {
    local kind="$1" dir
    ensure_state_layout
    dir="$HISTORY_DIR/$(history_stamp)-${kind}"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    MEASURE_RESULT_FILE="$dir/samples.tsv"
    MEASURE_RUN_DIR="$dir"
    printf 'TIME\tLABEL\tGOODPUT_MBIT\tRETRANSMITS\tBYTES\tRETRANS_RATIO_EST_PERCENT\n' > "$MEASURE_RESULT_FILE"
}

measure_probe() {
    require_root; acquire_lock; tc_dependencies
    require_commands iperf3 jq timeout
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" iface dir row rc=0 speed estimate
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    fi
    new_measure_run probe
    dir="$MEASURE_RUN_DIR"
    measure_begin "$iface" || return 1
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 3 unshaped); then
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" > "$dir/summary.tsv"
        log OK "可用带宽中位数: $(cut -f1 <<< "$row") Mbit/s，重传比例估算: $(cut -f4 <<< "$row")%"
        log INFO "结果: $dir"
    else rc=$?; fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_sweep() {
    require_root; acquire_lock; tc_dependencies
    require_commands iperf3 jq timeout
    local peer="$1" port="$2" requested="$3" nominal="$4" low="$5" high="$6" step="$7"
    local duration="$8" parallel="$9" margin="${10}" threshold="${11}" force_scan="${12}" cap="${13}"
    local iface dir baseline_row baseline_gp baseline_loss base_row base_loss rate row gp loss
    local last_ok="" broke_at="" fine_start fine_step recommend confirm_row estimated tests rc=0 no_knee=0 above_cap=0 baseline_duration
    validate_peer "$peer" "$port" || return 1
    for value in "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$cap"; do is_uint "$value" || { die "扫描参数必须为非负整数"; return 1; }; done
    is_decimal "$threshold" || { die "loss threshold 必须是数字"; return 1; }
    (( duration >= 3 && duration <= 120 && parallel >= 1 && parallel <= 32 && margin <= 25 && cap >= 100 && cap <= 1000000 )) || { die "扫描参数超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    new_measure_run sweep
    dir="$MEASURE_RUN_DIR"
    measure_begin "$iface" || return 1

    baseline_duration="$duration"; ((baseline_duration>5)) && baseline_duration=5
    if ! apply_fq "$iface" || ! baseline_row=$(sample_repeated "$peer" "$port" "$baseline_duration" 1 2 unshaped); then rc=$?; else
        baseline_gp=$(cut -f1 <<< "$baseline_row"); baseline_loss=$(cut -f4 <<< "$baseline_row")
        if awk -v g="$baseline_gp" -v c="$cap" 'BEGIN {exit !(g>c)}'; then
            above_cap=1; no_knee=1
            log WARN "不限速单流达到 ${baseline_gp} Mbit/s，超过扫描上限 ${cap} Mbit/s；跳过整形扫描"
        fi
        (( nominal > 0 )) || nominal=$(awk -v g="$baseline_gp" 'BEGIN {printf "%d", g+0.5}')
        (( low > 0 )) || low=$(awk -v g="$baseline_gp" 'BEGIN {v=g*0.80; if(v<1)v=1; printf "%d", v}')
        (( high > 0 )) || high=$(awk -v g="$baseline_gp" 'BEGIN {v=g*1.30; if(v<2)v=2; printf "%d", v}')
        (( step > 0 )) || { step=$((nominal / 20)); ((step < 5)) && step=5; }
        (( high > low )) || { die "扫描上界必须大于下界"; rc=1; }
    fi

    if (( rc == 0 )); then
        tests=$((2 + (high-low)/step + 6))
        estimated=$(estimate_sweep_bytes "$high" "$duration" "$tests")
        log INFO "预计最多测试 $tests 次、产生约 $(human_bytes "$estimated") 出站流量"

        if (( above_cap )); then
            :
        elif (( ! force_scan )) && ! loss_spike "$baseline_loss" "$threshold" 0; then
            no_knee=1
            log WARN "不限速测试未出现明显重传跳变，不建议启用 HTB"
        else
            apply_shaping "$iface" "$low" || rc=$?
            if (( rc == 0 )); then
                base_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "rate-${low}") || rc=$?
                base_loss=$(cut -f4 <<< "${base_row:-$'0\t0\t0\t0'}")
            fi
            if (( rc == 0 )) && loss_spike "$base_loss" "$threshold" 0; then
                die "扫描下界 ${low} Mbit 已有明显重传，无法建立干净本底；请降低 --low 或更换 peer"
                rc=2
            fi
            if (( rc == 0 )); then
                last_ok="$low"
                for ((rate=low+step; rate<=high; rate+=step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "rate-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%%\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    last_ok="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$broke_at" ]]; then
                fine_step=$((step / 5)); ((fine_step < 1)) && fine_step=1
                fine_start=$((last_ok + fine_step))
                for ((rate=fine_start; rate<broke_at; rate+=fine_step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "refine-${rate}") || { rc=$?; break; }
                    loss=$(cut -f4 <<< "$row")
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    last_ok="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$last_ok" ]]; then
                recommend=$(( last_ok * (100-margin) / 100 )); ((recommend < 1)) && recommend=1
                apply_shaping "$iface" "$recommend" || rc=$?
                if (( rc == 0 )); then
                    confirm_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "confirm-${recommend}") || rc=$?
                    loss=$(cut -f4 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    if (( rc == 0 )) && loss_spike "$loss" "$threshold" "$base_loss"; then
                        log WARN "推荐档复测仍有跳变，请降低速率或更换对端复测"
                    fi
                fi
            elif (( rc == 0 )); then
                no_knee=1
                log WARN "扫描到上界仍未发现拐点，不建议基于本次结果启用整形"
            fi
        fi
    fi

    if (( rc == 0 )); then
        printf 'TYPE\tsweep\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nUNSHAPED_MBIT\t%s\nBASE_RETRANS_RATIO_EST_PERCENT\t%s\nLOW\t%s\nHIGH\t%s\nSTEP\t%s\nLAST_OK\t%s\nBROKE_AT\t%s\nRECOMMEND\t%s\nMARGIN_PERCENT\t%s\nNO_KNEE\t%s\nABOVE_CAP\t%s\n' \
            "$peer" "$port" "$iface" "${baseline_gp:-}" "${baseline_loss:-}" "$low" "$high" "$step" "${last_ok:-}" "${broke_at:-}" "${recommend:-}" "$margin" "$no_knee" "$above_cap" > "$dir/summary.tsv"
        if [[ -n "${recommend:-}" ]]; then
            log OK "扫描完成: last clean=${last_ok} Mbit, break=${broke_at:-above-range} Mbit, 推荐=${recommend} Mbit"
            log INFO "确认业务表现后执行: ${0##*/} tc enable ${recommend} --knee ${broke_at:-0} --margin ${margin} --interface ${requested}"
        fi
        log INFO "完整结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

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

# -----------------------------------------------------------------------------
# XanMod kernel lifecycle: official repository, conservative CPU level choice.
# -----------------------------------------------------------------------------

secure_boot_enabled() {
    command_exists mokutil || return 1
    mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

detect_x86_level() {
    local flags
    [[ "$(uname -m)" == x86_64 ]] || { printf 'unknown\n'; return 1; }
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)
    if all_cpu_flags "$flags" avx avx2 bmi1 bmi2 fma movbe xsave; then printf '3\n'
    elif all_cpu_flags "$flags" cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; then printf '2\n'
    else printf '1\n'; fi
}

all_cpu_flags() {
    local flags="$1" flag; shift
    for flag in "$@"; do grep -qw "$flag" <<< "$flags" || return 1; done
}

xanmod_candidates() {
    local level="$1" track="$2" prefix="linux-xanmod"
    [[ "$track" == lts ]] && prefix="linux-xanmod-lts"
    case "$level" in
        3) printf '%s\n' "${prefix}-x64v3" "${prefix}-x64v2" "linux-xanmod-lts-x64v1" ;;
        2) printf '%s\n' "${prefix}-x64v2" "linux-xanmod-lts-x64v1" ;;
        *) printf '%s\n' "linux-xanmod-lts-x64v1" ;;
    esac
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
    printf '%-18s %s\n' "Running kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "x86-64 level" "$(detect_x86_level 2>/dev/null || echo n/a)"
    printf '%-18s %s\n' "Secure Boot" "$(secure_boot_enabled && echo enabled || echo disabled/unknown)"
    printf '%-18s %s\n' "BBR module" "$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; found=1} END{if(!found)print "available/unknown version"}')"
    dpkg-query -W -f='${Package}\t${Version}\n' 'linux-*xanmod*' 2>/dev/null || true
}

kernel_install() {
    require_root; acquire_lock
    local track="${1:-lts}" codename level package key_tmp keyring_tmp source_tmp
    [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
    [[ "$(os_id)" == debian || "$(os_id)" == ubuntu ]] || { die "XanMod 自动安装只支持 Debian/Ubuntu"; return 1; }
    [[ "$(uname -m)" == x86_64 ]] || { die "XanMod 官方 APT 仅支持 amd64；ARM64 请使用发行版内核或审计后的社区构建"; return 1; }
    is_container && { die "容器中不能更换宿主机内核"; return 1; }
    secure_boot_enabled && { die "检测到 Secure Boot 已启用；请先准备签名/MOK 或关闭后再安装"; return 1; }
    require_commands apt-get apt-cache curl gpg
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
    atomic_install "$keyring_tmp" /etc/apt/keyrings/xanmod-archive-keyring.gpg 0644
    rm -f "$keyring_tmp"
    source_tmp=$(mktemp) || return 1
    printf 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org %s main\n' "$codename" > "$source_tmp"
    atomic_install "$source_tmp" /etc/apt/sources.list.d/xanmod-release.list 0644
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
    require_root; acquire_lock
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
# DNS: scoped systemd-resolved policy with immutable backup and explicit restore.
# -----------------------------------------------------------------------------

DNS_DROPIN="/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf"

dns_capture_baseline() {
    local base="$DNS_BACKUP_DIR/baseline"
    [[ -f "$base/manifest" ]] && return 0
    mkdir -p "$base"
    printf 'CREATED_AT\t%s\n' "$(utc_now)" > "$base/manifest"
    if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then cp -a /etc/resolv.conf "$base/resolv.conf"; printf 'present\n' > "$base/resolv.state"; else printf 'absent\n' > "$base/resolv.state"; fi
    if [[ -e "$DNS_DROPIN" ]]; then cp -a "$DNS_DROPIN" "$base/dropin.conf"; printf 'present\n' > "$base/dropin.state"; else printf 'absent\n' > "$base/dropin.state"; fi
    chmod -R go-rwx "$base"
}

dns_restore_files() {
    local base="$DNS_BACKUP_DIR/baseline" state
    rm -f "$DNS_DROPIN"
    state=$(<"$base/dropin.state")
    [[ "$state" == present ]] && cp -a "$base/dropin.conf" "$DNS_DROPIN"
    rm -f /etc/resolv.conf
    state=$(<"$base/resolv.state")
    [[ "$state" == present ]] && cp -a "$base/resolv.conf" /etc/resolv.conf
    systemctl restart systemd-resolved 2>/dev/null || true
}

dns_apply() {
    require_root; acquire_lock; require_commands systemctl resolvectl timeout
    local mode="${1:-auto}" temp
    [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
    systemctl cat systemd-resolved >/dev/null 2>&1 || { die "系统未提供 systemd-resolved"; return 1; }
    dns_capture_baseline
    if [[ "$mode" == auto ]]; then
        if peer_port_open 1.1.1.1 853; then mode="dot"; else mode="plain"; log WARN "DoT 853 不可达，降级到普通 DNS 53"; fi
    fi
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
    atomic_install "$temp" "$DNS_DROPIN" 0644
    rm -f "$temp"
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    if ! resolvectl query example.com >/dev/null; then
        dns_restore_files
        die "DNS 验证失败，已自动恢复修改前配置"
        return 1
    fi
    log OK "DNS 策略已应用: $mode"
}

dns_restore() {
    require_root; acquire_lock
    local base="$DNS_BACKUP_DIR/baseline"
    [[ -f "$base/manifest" ]] || { die "没有 DNS 基线"; return 1; }
    dns_restore_files
    log OK "DNS 已恢复到首次修改前状态"
}

dns_status() {
    printf 'Drop-in: %s\n' "$([[ -f "$DNS_DROPIN" ]] && echo "$DNS_DROPIN" || echo absent)"
    printf 'resolv.conf: %s\n' "$(readlink /etc/resolv.conf 2>/dev/null || echo regular-file)"
    command_exists resolvectl && resolvectl status || true
}

# -----------------------------------------------------------------------------
# IPv6: explicit temporary/permanent disable with exact sysctl-value restore.
# -----------------------------------------------------------------------------

IPV6_SYSCTL_FILE="/etc/sysctl.d/99-bbrv3-lite-ipv6.conf"

ipv6_capture_baseline() {
    local base="$IPV6_BACKUP_DIR/baseline" key
    [[ -f "$base/sysctl.tsv" ]] && return 0
    mkdir -p "$base"
    for key in all default lo; do
        printf 'net.ipv6.conf.%s.disable_ipv6\t%s\n' "$key" "$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || echo 0)"
    done > "$base/sysctl.tsv"
    chmod -R go-rwx "$base"
}

ipv6_set_disabled() {
    local value="$1" key
    for key in all default lo; do sysctl -q -w "net.ipv6.conf.${key}.disable_ipv6=$value"; done
}

ipv6_disable() {
    require_root; acquire_lock; require_commands sysctl
    local mode="${1:-temporary}" temp
    [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
    ipv6_capture_baseline
    ipv6_set_disabled 1
    if [[ "$mode" == permanent ]]; then
        temp=$(mktemp) || return 1
        printf '%s\n' \
            '# Managed by bbrv3-lite' \
            'net.ipv6.conf.all.disable_ipv6 = 1' \
            'net.ipv6.conf.default.disable_ipv6 = 1' \
            'net.ipv6.conf.lo.disable_ipv6 = 1' > "$temp"
        atomic_install "$temp" "$IPV6_SYSCTL_FILE" 0644
        rm -f "$temp"
    fi
    log OK "IPv6 已${mode/temporary/临时}${mode/permanent/永久}禁用"
}

ipv6_restore() {
    require_root; acquire_lock
    local base="$IPV6_BACKUP_DIR/baseline" key value
    [[ -f "$base/sysctl.tsv" ]] || { die "没有 IPv6 基线"; return 1; }
    rm -f "$IPV6_SYSCTL_FILE"
    while IFS=$'\t' read -r key value; do sysctl -q -w "$key=$value" || true; done < "$base/sysctl.tsv"
    log OK "IPv6 已恢复到首次修改前状态"
}

ipv6_status() {
    local key
    for key in all default lo; do printf '%-42s %s\n' "net.ipv6.conf.${key}.disable_ipv6" "$(sysctl -n "net.ipv6.conf.${key}.disable_ipv6" 2>/dev/null || echo unavailable)"; done
    printf '%-42s %s\n' "persistent file" "$([[ -f "$IPV6_SYSCTL_FILE" ]] && echo present || echo absent)"
}

# -----------------------------------------------------------------------------
# Self-update: release-only download, SHA256 verification and atomic replacement.
# -----------------------------------------------------------------------------

self_update() {
    require_root; acquire_lock; require_commands curl awk sha256sum sort
    local latest latest_version current target tmp base expected actual backup newest
    current=$(current_script_path) || return 1
    latest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${PROJECT_REPO}/releases/latest" | awk -F'"' '/"tag_name"/ {print $4; exit}')
    [[ "$latest" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { die "无法取得合法 release 版本"; return 1; }
    [[ "$latest" != "v${SCRIPT_VERSION}" ]] || { log OK "已经是最新版本 $latest"; return 0; }
    latest_version="${latest#v}"
    newest=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$latest_version" | sort -V | tail -n1)
    if [[ "$newest" == "$SCRIPT_VERSION" ]]; then log WARN "当前 v${SCRIPT_VERSION} 比最新 release $latest 更新，不执行降级"; return 0; fi
    tmp=$(mktemp -d) || return 1
    base="https://github.com/${PROJECT_REPO}/releases/download/${latest}"
    curl -fsSL --max-time 120 "$base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; return 1; }
    curl -fsSL --max-time 30 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || { rm -rf "$tmp"; die "Release 缺少 SHA256SUMS"; return 1; }
    expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "$tmp/SHA256SUMS")
    actual=$(sha256sum "$tmp/net-tcp-tune.sh" | awk '{print $1}')
    [[ -n "$expected" && "$actual" == "$expected" ]] || { rm -rf "$tmp"; die "SHA256 校验失败"; return 1; }
    bash -n "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本语法检查失败"; return 1; }
    grep -q "SCRIPT_VERSION=\"${latest#v}\"" "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本版本标记不匹配"; return 1; }
    target="$current"; backup="${current}.previous"
    cp -a -- "$current" "$backup"
    install -m 0755 "$tmp/net-tcp-tune.sh" "$target"
    if [[ -e "$PERSIST_SCRIPT" && "$(readlink -f "$PERSIST_SCRIPT")" != "$(readlink -f "$target")" ]]; then
        install -m 0755 "$tmp/net-tcp-tune.sh" "$PERSIST_SCRIPT"
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
  ${0##*/} measure sweep --peer HOST [--nominal MBIT] [--low MBIT --high MBIT]
                         [--step MBIT] [--duration 8] [--parallel 1]
                         [--margin 3] [--loss-threshold 0.1] [--cap 5000] [--force-scan]
  ${0##*/} kernel status|install [--track lts|main]|remove
  ${0##*/} dns status|apply [auto|dot|plain]|restore
  ${0##*/} ipv6 status|disable [temporary|permanent]|restore
  ${0##*/} baseline info|adopt [--interface DEV]
  ${0##*/} restore
  ${0##*/} uninstall [--purge-state]
  ${0##*/} update | version | help

Internal systemd command: apply
EOF
}

parse_common_profile_options() {
    CLI_PROFILE=balanced; CLI_ROLE=mixed; CLI_BANDWIDTH=0; CLI_RTT=0; CLI_INTERFACE=auto
    while (($#)); do
        case "$1" in
            --profile) CLI_PROFILE="${2:?missing profile}"; shift 2 ;;
            --role) CLI_ROLE="${2:?missing role}"; shift 2 ;;
            --bandwidth) CLI_BANDWIDTH="${2:?missing bandwidth}"; shift 2 ;;
            --rtt) CLI_RTT="${2:?missing rtt}"; shift 2 ;;
            --interface) CLI_INTERFACE="${2:?missing interface}"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    validate_config_value SYSCTL_PROFILE "$CLI_PROFILE" && validate_config_value ROLE "$CLI_ROLE" &&
        validate_config_value BANDWIDTH_MBIT "$CLI_BANDWIDTH" && validate_config_value RTT_MS "$CLI_RTT" &&
        validate_interface_name "$CLI_INTERFACE"
}

cmd_detect() {
    local iface=auto target=""
    while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; --target) target="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    detect_profile "$iface" "$target"
}

cmd_install() { parse_common_profile_options "$@" || return 1; install_base_tuning "$CLI_INTERFACE" "$CLI_PROFILE" "$CLI_ROLE" "$CLI_BANDWIDTH" "$CLI_RTT"; }
cmd_explain() {
    parse_common_profile_options "$@" || return 1
    reset_config; SYSCTL_PROFILE="$CLI_PROFILE"; ROLE="$CLI_ROLE"; BANDWIDTH_MBIT="$CLI_BANDWIDTH"; RTT_MS="$CLI_RTT"
    explain_sysctl_profile
}

cmd_tc() {
    local action="${1:-}"; shift || true
    local rate="" iface=auto knee=0 margin=3
    case "$action" in
        trial|enable)
            rate="${1:-}"; shift || true
            is_uint "$rate" && ((rate>0)) || { die "需要合法 RATE"; return 1; }
            while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; --knee) knee="$2"; shift 2 ;; --margin) margin="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            if [[ "$action" == trial ]]; then tc_trial "$rate" "$iface"; else tc_enable "$rate" "$iface" "$knee" "$margin"; fi
            ;;
        disable|status|stats)
            while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            case "$action" in disable) tc_disable "$iface" ;; status|stats) tc_status "$iface" ;; esac
            ;;
        *) die "tc 子命令应为 trial/enable/disable/status/stats" ;;
    esac
}

cmd_measure() {
    local action="${1:-}"; shift || true
    local peer="" port=5201 iface=auto duration=10 parallel=4 nominal=0 low=0 high=0 step=0 margin=3 threshold=0.1 force=0 cap=5000
    [[ "$action" == deps ]] && { install_measure_dependencies; return; }
    [[ "$action" == probe || "$action" == sweep ]] || { die "measure 子命令应为 deps/probe/sweep"; return 1; }
    [[ "$action" == sweep ]] && { duration=8; parallel=1; }
    while (($#)); do
        case "$1" in
            --peer) peer="$2"; shift 2 ;; --port) port="$2"; shift 2 ;; --interface) iface="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;; --parallel) parallel="$2"; shift 2 ;; --nominal) nominal="$2"; shift 2 ;;
            --low) low="$2"; force=1; shift 2 ;; --high) high="$2"; force=1; shift 2 ;; --step) step="$2"; shift 2 ;;
            --margin) margin="$2"; shift 2 ;; --loss-threshold) threshold="$2"; shift 2 ;; --cap) cap="$2"; shift 2 ;; --force-scan) force=1; shift ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    [[ -n "$peer" ]] || { die "需要 --peer HOST"; return 1; }
    if [[ "$action" == probe ]]; then measure_probe "$peer" "$port" "$iface" "$duration" "$parallel"
    else measure_sweep "$peer" "$port" "$iface" "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$threshold" "$force" "$cap"; fi
}

cmd_kernel() {
    local action="${1:-status}" track=lts; shift || true
    while (($#)); do case "$1" in --track) track="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    case "$action" in status) kernel_status ;; install) kernel_install "$track" ;; remove) kernel_remove ;; *) die "kernel 子命令应为 status/install/remove" ;; esac
}

cmd_dns() { local action="${1:-status}" mode="${2:-auto}"; case "$action" in status) dns_status ;; apply) dns_apply "$mode" ;; restore) dns_restore ;; *) die "dns 子命令应为 status/apply/restore" ;; esac; }
cmd_ipv6() { local action="${1:-status}" mode="${2:-temporary}"; case "$action" in status) ipv6_status ;; disable) ipv6_disable "$mode" ;; restore) ipv6_restore ;; *) die "ipv6 子命令应为 status/disable/restore" ;; esac; }

cmd_baseline() {
    local action="${1:-info}" iface=auto; shift || true
    while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    case "$action" in info) baseline_info ;; adopt) baseline_adopt "$iface" ;; *) die "baseline 子命令应为 info/adopt" ;; esac
}

interactive_menu() {
    local choice
    while true; do
        printf '\n%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '%s\n' '1) 系统/网卡检测' '2) 安装 BBR + FQ' '3) 自动测量 policer 拐点' '4) TC 状态' \
            '5) 完整状态' '6) XanMod 内核管理' '7) DNS 管理' '8) IPv6 管理' '9) 恢复基线' '0) 退出'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) cmd_detect ;;
            2) cmd_install ;;
            3) read -r -p 'iperf3 peer: ' peer; cmd_measure sweep --peer "$peer" ;;
            4) cmd_tc status ;;
            5) show_status ;;
            6) kernel_status ;;
            7) dns_status ;;
            8) ipv6_status ;;
            9) confirm '恢复首次可信基线？' && restore_baseline ;;
            0) return 0 ;;
            *) log WARN "无效选择" ;;
        esac
    done
}

main() {
    trap cleanup_core EXIT
    local command="${1:-}"; [[ -n "$command" ]] && shift || true
    if [[ -z "$command" ]]; then [[ -t 0 ]] && interactive_menu || show_help; return; fi
    case "$command" in
        detect) cmd_detect "$@" ;;
        install) cmd_install "$@" ;;
        explain) cmd_explain "$@" ;;
        status) show_status ;;
        tc) cmd_tc "$@" ;;
        measure) cmd_measure "$@" ;;
        kernel) cmd_kernel "$@" ;;
        dns) cmd_dns "$@" ;;
        ipv6) cmd_ipv6 "$@" ;;
        baseline) cmd_baseline "$@" ;;
        restore) restore_baseline ;;
        uninstall)
            case "${1:-}" in "") uninstall_managed 0 ;; --purge-state) uninstall_managed 1 ;; *) die "uninstall 只接受 --purge-state" ;; esac
            ;;
        apply) apply_configured_state ;;
        update) self_update ;;
        version|--version|-V) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
        help|--help|-h) show_help ;;
        *) die "未知命令: $command（运行 help 查看用法）" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
