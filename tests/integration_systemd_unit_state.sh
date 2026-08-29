#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are consumed by sourced production functions
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d /var/tmp/bbrv3-unit-state.XXXXXX)
TEST_UNIT=bbrv3-lite-v803-missing.service
TEST_UNIT_FILE="/etc/systemd/system/$TEST_UNIT"
TEST_ENABLE_LINK="/etc/systemd/system/multi-user.target.wants/$TEST_UNIT"

cleanup() {
    local rc=$?
    set +e
    systemctl disable --now "$TEST_UNIT" >/dev/null 2>&1
    rm -f -- "$TEST_ENABLE_LINK" "$TEST_UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed "$TEST_UNIT" >/dev/null 2>&1
    rm -rf -- "$TEST_ROOT"
    return "$rc"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ $(cat /proc/1/comm) == systemd ]] || fail 'integration_systemd_unit_state.sh requires systemd as PID 1'

export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_SERVICE_FILE="$TEST_UNIT_FILE"
export BBRV3_LEGACY_SERVICE_FILE="$TEST_ROOT/etc/bbr-optimize-persist.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite.conf"
export BBRV3_LEGACY_SYSCTL_FILE="$TEST_ROOT/etc/99-bbr-ultimate.conf"
export BBRV3_PERSIST_DIR="$TEST_ROOT/lib/bbrv3-lite"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/lib/bbrv3-lite/net-tcp-tune.sh"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"
SERVICE_NAME="$TEST_UNIT"

rm -f -- "$TEST_ENABLE_LINK" "$TEST_UNIT_FILE"
systemctl daemon-reload

raw_missing=$(LC_ALL=C systemctl show "$TEST_UNIT" \
    --property=LoadState --property=UnitFileState --property=ActiveState)
grep -Fxq 'LoadState=not-found' <<< "$raw_missing" || fail 'real systemd did not report LoadState=not-found'
grep -Fxq 'UnitFileState=' <<< "$raw_missing" || fail 'real systemd missing unit returned an unexpected UnitFileState'
grep -Fxq 'ActiveState=inactive' <<< "$raw_missing" || fail 'real systemd missing unit was not inactive'
[[ $(query_unit_state "$TEST_UNIT") == $'not-found\tinactive' ]] || fail 'missing unit was not normalized to not-found/inactive'

missing_snapshot="$TEST_ROOT/missing.unit"
capture_unit_state "$TEST_UNIT" "$missing_snapshot"
[[ $(<"$missing_snapshot") == $'not-found\tinactive' ]] || fail 'capture_unit_state did not preserve the absent lifecycle'
action_transaction_quiesce_unit_for_restore "$TEST_UNIT"
[[ ! -e "$TEST_ENABLE_LINK" && ! -L "$TEST_ENABLE_LINK" ]] || fail 'pure missing quiesce created or retained an enable link'

# Exercise the real first-run capture and transaction entry points against the
# Debian 12 PID-1 manager while both managed units are absent. Docker Desktop's
# kernel does not expose every required TCP sysctl, so network readers are a
# controlled, read-only fixture; all systemctl queries below still reach the
# real PID-1 manager. This gate tests lifecycle/transaction admission, not TCP.
(
    integration_iface=eth0
    network_writes="$TEST_ROOT/network-writes"
    BBRV3_SYS_CLASS_NET_ROOT="$TEST_ROOT/sys/class/net"
    mkdir -p -- "$BBRV3_SYS_CLASS_NET_ROOT/$integration_iface"
    : > "$network_writes"
    fixture_sysctl_value() {
        case "$1" in
            net.core.default_qdisc) printf 'fq\n' ;;
            net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
            net.core.rmem_max|net.core.wmem_max) printf '16777216\n' ;;
            net.ipv4.tcp_rmem) printf '4096 131072 16777216\n' ;;
            net.ipv4.tcp_wmem) printf '4096 16384 16777216\n' ;;
            net.ipv4.tcp_mtu_probing) printf '0\n' ;;
            net.ipv4.tcp_fastopen) printf '1\n' ;;
            net.core.somaxconn|net.ipv4.tcp_max_syn_backlog) printf '4096\n' ;;
            net.core.netdev_max_backlog) printf '1000\n' ;;
            *) return 1 ;;
        esac
    }
    sysctl() {
        [[ "$1" == -n ]] && { fixture_sysctl_value "$2"; return; }
        printf 'sysctl:%s\n' "$*" >> "$network_writes"
        return 1
    }
    tc() {
        case "$*" in
            'qdisc show dev eth0') printf 'qdisc fq 8001: root limit 10000p flow_limit 100p\n' ;;
            'class show dev eth0') : ;;
            filter\ show\ dev\ eth0\ parent\ *) : ;;
            *) printf 'tc:%s\n' "$*" >> "$network_writes"; return 1 ;;
        esac
    }
    ip() {
        case "$*" in
            '-4 route show table all'|'-4 route show default') printf 'default via 192.0.2.1 dev eth0 proto dhcp metric 100\n' ;;
            '-6 route show table all'|'-6 route show default') : ;;
            *) printf 'ip:%s\n' "$*" >> "$network_writes"; return 1 ;;
        esac
    }

    capture_baseline "$integration_iface" adopt-current
    tcp_baseline_validate "$BASELINE_DIR" || fail 'PID-1-backed first baseline did not validate'
    [[ $(<"$BASELINE_DIR/service.unit") == $'not-found\tinactive' ]] || fail 'PID-1-backed first baseline lost current-unit absence'
    [[ $(<"$BASELINE_DIR/legacy-service.unit") == $'not-found\tinactive' ]] || fail 'PID-1-backed first baseline lost legacy-unit absence'

    action_transaction_begin_multi "$integration_iface"
    [[ $(<"$ACTION_TRANSACTION_DIR/transaction.state") == readonly ]] || fail 'PID-1-backed first transaction was not readonly before mutation'
    [[ $(<"$ACTION_TRANSACTION_DIR/service.unit") == $'not-found\tinactive' ]] || fail 'PID-1-backed first transaction lost current-unit absence'
    [[ $(<"$ACTION_TRANSACTION_DIR/legacy-service.unit") == $'not-found\tinactive' ]] || fail 'PID-1-backed first transaction lost legacy-unit absence'
    action_transaction_discard_snapshot
    [[ -z "$ACTION_TRANSACTION_DIR" ]] || fail 'PID-1-backed readonly transaction was not discarded'

    INSTALL_BODY_CALLS=0
    integration_install_transaction_body() {
        ((INSTALL_BODY_CALLS+=1))
        [[ "$ACTION_TRANSACTION_MUTATED" == 1 && $(<"$ACTION_TRANSACTION_DIR/transaction.state") == mutated ]] ||
            fail 'install-path body ran before persisted mutation state'
    }
    run_action_transaction_multi "$integration_iface" integration_install_transaction_body
    [[ "$INSTALL_BODY_CALLS" == 1 && -z "$ACTION_TRANSACTION_DIR" ]] || fail 'PID-1-backed first install-path transaction did not commit cleanly'

    AUTO_BODY_CALLS=0
    auto_tune_execute() {
        ((AUTO_BODY_CALLS+=1))
        [[ "$ACTION_TRANSACTION_MUTATED" == 1 && $(<"$ACTION_TRANSACTION_DIR/transaction.state") == mutated ]] ||
            fail 'auto-path body ran before persisted mutation state'
    }
    auto_tune_run_transaction "$integration_iface" balanced mixed 0 100 0
    [[ "$AUTO_BODY_CALLS" == 1 && -z "$ACTION_TRANSACTION_DIR" ]] || fail 'PID-1-backed first auto transaction did not commit cleanly'

    # Inject a manager/D-Bus style failure while keeping the same controlled
    # network snapshot. Construction must abort and perform no network writes.
    (
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
        ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; ACTION_TRANSACTION_ROLLBACK_FAILED=0
        systemctl() { printf 'Failed to connect to bus: Host is down\n' >&2; return 1; }
        if action_transaction_begin_multi "$integration_iface" >/dev/null 2>&1; then
            fail 'manager failure allowed a transaction to begin'
        fi
        [[ -z "$ACTION_TRANSACTION_DIR" ]] || fail 'manager failure left an active transaction in memory'
    )
    if find "$STATE_DIR" -mindepth 1 -maxdepth 1 -name '.transaction.*' -print -quit | grep -q .; then
        fail 'manager failure left an unpublished transaction directory'
    fi
    [[ ! -s "$network_writes" ]] || fail "PID-1 workflow attempted network writes: $(<"$network_writes")"
)

cat > "$TEST_UNIT_FILE" <<'EOF'
[Unit]
Description=BBRv3 Lite v8.0.3 unit-state integration fixture

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$TEST_UNIT"
[[ $(query_unit_state "$TEST_UNIT") == $'enabled\tactive' ]] || fail 'real enabled/active unit state was not captured'
[[ -L "$TEST_ENABLE_LINK" ]] || fail 'real systemd did not create the enable symlink'

# Reproduce the rollback order used by the action transaction: stop/disable,
# restore the exact pre-operation file presence, reload, then restore lifecycle.
ACTION_TRANSACTION_DIR="$TEST_ROOT/transaction"
mkdir -p -- "$ACTION_TRANSACTION_DIR/files"
printf 'absent\n' > "$ACTION_TRANSACTION_DIR/service.state"
systemctl disable --now "$TEST_UNIT"
action_transaction_restore_path "$TEST_UNIT_FILE" service
systemctl daemon-reload
restore_unit_state "$TEST_UNIT" "$missing_snapshot"

[[ ! -e "$TEST_UNIT_FILE" && ! -L "$TEST_UNIT_FILE" ]] || fail 'absent restore left the service file present'
[[ ! -e "$TEST_ENABLE_LINK" && ! -L "$TEST_ENABLE_LINK" ]] || fail 'absent restore left the enable symlink present'
[[ $(query_unit_state "$TEST_UNIT") == $'not-found\tinactive' ]] || fail 'absent restore did not return the manager to not-found/inactive'

# A missing unit and a missing unit with a dangling WantedBy link have the same
# manager-visible state. Reproduce that partial-install failure and require the
# transaction quiesce helper to remove the otherwise invisible enable link.
cat > "$TEST_UNIT_FILE" <<'EOF'
[Unit]
Description=BBRv3 Lite v8.0.3 dangling-link integration fixture

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$TEST_UNIT"
systemctl stop "$TEST_UNIT"
rm -f -- "$TEST_UNIT_FILE"
systemctl daemon-reload
[[ -L "$TEST_ENABLE_LINK" ]] || fail 'dangling-link fixture lost its enable symlink before quiesce'
[[ $(query_unit_state "$TEST_UNIT") == $'not-found\tinactive' ]] || fail 'real manager did not normalize the dangling-link fixture as missing'
action_transaction_quiesce_unit_for_restore "$TEST_UNIT"
[[ ! -e "$TEST_ENABLE_LINK" && ! -L "$TEST_ENABLE_LINK" ]] || fail 'missing-unit quiesce left a dangling enable symlink'
[[ $(query_unit_state "$TEST_UNIT") == $'not-found\tinactive' ]] || fail 'dangling-link cleanup changed the missing lifecycle state'

# Recreate the same real manager/filesystem state, inject only the disable
# failure, and run the production rollback coordinator. The PID-1 query remains
# real; a failed cleanup must make rollback incomplete and preserve every
# transaction evidence file.
cat > "$TEST_UNIT_FILE" <<'EOF'
[Unit]
Description=BBRv3 Lite v8.0.3 dangling-link failure fixture

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$TEST_UNIT"
systemctl stop "$TEST_UNIT"
rm -f -- "$TEST_UNIT_FILE"
systemctl daemon-reload
[[ -L "$TEST_ENABLE_LINK" ]] || fail 'cleanup-failure fixture lost its dangling link before rollback'
[[ $(query_unit_state "$TEST_UNIT") == $'not-found\tinactive' ]] || fail 'cleanup-failure fixture was not manager-visible as missing'

failure_transaction="$STATE_DIR/.transaction.dangling-failure"
failure_calls="$TEST_ROOT/dangling-disable-failure.calls"
mkdir -p -- "$failure_transaction/qdiscs"
printf 'CREATED_AT\t2026-08-29T10:00:00Z\n' > "$failure_transaction/transaction.meta"
printf 'mutated\n' > "$failure_transaction/transaction.state"
printf 'complete\n' > "$failure_transaction/COMPLETE"
printf 'real-systemd-dangling-evidence\n' > "$failure_transaction/qdiscs/eth0.snapshot"
: > "$failure_calls"
if (
    ACTION_TRANSACTION_DIR="$failure_transaction"
    ACTION_TRANSACTION_IFACE=eth0
    ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1
    ACTION_TRANSACTION_MUTATED=1
    ACTION_TRANSACTION_ROLLING_BACK=0
    ACTION_TRANSACTION_ROLLBACK_FAILED=0
    LOCK_HELD=0
    action_transaction_snapshot_validate() { :; }
    action_transaction_restore_path() { :; }
    action_transaction_restore_tree() { :; }
    restore_tcp_sysctl_snapshot_file() { :; }
    action_transaction_restore_routes() { :; }
    restore_action_qdisc() { :; }
    action_transaction_restore_unit() { :; }
    release_lock() { :; }
    systemctl() {
        if [[ "$1" == disable ]]; then
            printf '%s\n' "$*" >> "$failure_calls"
            return 77
        fi
        command systemctl "$@"
    }
    action_transaction_rollback >/dev/null 2>&1
); then
    fail 'injected dangling-link cleanup failure was reported as a successful rollback'
fi
[[ $(wc -l < "$failure_calls") == 1 ]] || fail 'dangling cleanup failure did not attempt exactly one disable'
[[ -L "$TEST_ENABLE_LINK" ]] || fail 'injected cleanup failure unexpectedly removed the dangling link'
[[ -d "$failure_transaction" ]] || fail 'dangling cleanup failure deleted transaction evidence'
[[ $(<"$failure_transaction/transaction.meta") == $'CREATED_AT\t2026-08-29T10:00:00Z' ]] || fail 'dangling cleanup failure lost transaction.meta'
[[ $(<"$failure_transaction/transaction.state") == mutated ]] || fail 'dangling cleanup failure lost transaction.state'
[[ $(<"$failure_transaction/COMPLETE") == complete ]] || fail 'dangling cleanup failure lost COMPLETE'
[[ $(<"$failure_transaction/qdiscs/eth0.snapshot") == real-systemd-dangling-evidence ]] || fail 'dangling cleanup failure lost snapshot evidence'

echo 'integration systemd unit-state tests passed'
