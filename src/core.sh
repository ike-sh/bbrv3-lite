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
STANDARD_NIC_POLICY_DIR="/etc/bbrv3-lite/interfaces.d"
NIC_POLICY_DIR="${BBRV3_NIC_POLICY_DIR:-$STANDARD_NIC_POLICY_DIR}"
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
    local rc="${1:-$?}" cleanup_rc=0
    if (( ${QDISC_DEFAULT_TRANSACTION_ACTIVE:-0} == 1 )) && declare -F qdisc_default_transaction_restore >/dev/null; then
        log WARN "进程退出时 default_qdisc 临时事务仍未提交，正在恢复全局原值"
        qdisc_default_transaction_restore || cleanup_rc=1
    fi
    if [[ -n "${NIC_RUNTIME_TRANSACTION_DIR:-}" ]] && declare -F nic_runtime_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未完成的网络运行时事务，正在恢复全部接口和全局状态"
        nic_runtime_transaction_rollback || cleanup_rc=1
    fi
    if [[ -n "${TC_TRIAL_IFACE:-}" && -n "${TC_TRIAL_SNAPSHOT:-}" ]] && declare -F tc_trial_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交的临时 TC 操作，正在恢复操作前 qdisc"
        tc_trial_transaction_rollback || cleanup_rc=1
    fi
    if [[ -n "${MEASURE_IFACE:-}" && -n "${MEASURE_SNAPSHOT:-}" ]] && declare -F measure_restore >/dev/null; then
        log WARN "进程退出时仍有测量快照，正在恢复操作前 qdisc"
        measure_restore || cleanup_rc=1
    fi
    if [[ -n "${DNS_TRANSACTION_DIR:-}" ]] && declare -F dns_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交 DNS 事务，正在恢复操作前状态"
        dns_transaction_rollback || cleanup_rc=1
    fi
    if [[ -n "${IPV6_TRANSACTION_DIR:-}" ]] && declare -F ipv6_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交 IPv6 事务，正在恢复操作前状态"
        ipv6_transaction_rollback || cleanup_rc=1
    fi
    if [[ -n "${ACTION_TRANSACTION_DIR:-}" ]] && declare -F action_transaction_rollback >/dev/null; then
        log WARN "进程退出时仍有未提交事务，正在恢复操作前状态"
        action_transaction_rollback || cleanup_rc=1
    fi
    release_lock || cleanup_rc=1
    (( rc != 0 )) && return "$rc"
    return "$cleanup_rc"
}

cleanup_core_exit() {
    local original_rc=$? final_rc
    # EXIT trap return values do not replace the process status in Bash. Clear
    # the trap and exit explicitly so a failed emergency rollback can never be
    # reported to systemd or an operator as a successful command.
    trap - EXIT
    if cleanup_core "$original_rc"; then final_rc=0; else final_rc=$?; fi
    exit "$final_rc"
}
