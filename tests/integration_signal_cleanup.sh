#!/usr/bin/env bash
# shellcheck disable=SC2034  # transaction globals are consumed dynamically by cleanup_core
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../src/core.sh
source "$ROOT_DIR/src/core.sh"

ACTION_TRANSACTION_DIR=""
ACTION_TRANSACTION_IFACE=""
TC_TRIAL_IFACE=""
TC_TRIAL_SNAPSHOT=""
MEASURE_IFACE=""
MEASURE_SNAPSHOT=""
DNS_TRANSACTION_DIR=""
IPV6_TRANSACTION_DIR=""

# Only menu_run is exercised here. Sourcing cli.sh is safe because its main
# entry point is guarded by BASH_SOURCE.
# shellcheck source=../src/cli.sh
source "$ROOT_DIR/src/cli.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { :; }

ROLLBACK_MARKER=""
measure_restore() {
    printf 'measure\n' > "$ROLLBACK_MARKER"
    MEASURE_IFACE=""
    MEASURE_SNAPSHOT=""
}
dns_transaction_rollback() {
    printf 'dns\n' > "$ROLLBACK_MARKER"
    DNS_TRANSACTION_DIR=""
}
ipv6_transaction_rollback() {
    printf 'ipv6\n' > "$ROLLBACK_MARKER"
    IPV6_TRANSACTION_DIR=""
}
action_transaction_rollback() {
    printf 'action\n' > "$ROLLBACK_MARKER"
    ACTION_TRANSACTION_DIR=""
    ACTION_TRANSACTION_IFACE=""
}
tc_trial_transaction_rollback() {
    printf 'tc-trial\n' > "$ROLLBACK_MARKER"
    TC_TRIAL_IFACE=""
    TC_TRIAL_SNAPSHOT=""
}

signal_action() {
    local kind="$1" signal="$2"
    case "$kind" in
        measure) MEASURE_IFACE=eth0; MEASURE_SNAPSHOT="$TEST_ROOT/qdisc.snapshot" ;;
        dns) DNS_TRANSACTION_DIR="$TEST_ROOT/dns.transaction" ;;
        ipv6) IPV6_TRANSACTION_DIR="$TEST_ROOT/ipv6.transaction" ;;
        action) ACTION_TRANSACTION_DIR="$TEST_ROOT/action.transaction"; ACTION_TRANSACTION_IFACE=eth0 ;;
        tc-trial) TC_TRIAL_IFACE=eth0; TC_TRIAL_SNAPSHOT="$TEST_ROOT/tc-trial.snapshot" ;;
        *) return 2 ;;
    esac
    kill "-$signal" "$BASHPID"
    sleep 5
}

run_signal_case() {
    local kind="$1" signal="$2" expected="$3"
    ROLLBACK_MARKER="$TEST_ROOT/${kind}-${signal}.marker"
    export ROLLBACK_MARKER
    menu_run signal_action "$kind" "$signal"
    [[ -f "$ROLLBACK_MARKER" ]] || fail "$kind transaction was not rolled back after SIG$signal"
    [[ $(<"$ROLLBACK_MARKER") == "$expected" ]] || fail "$kind transaction used the wrong rollback handler"
}

# TERM covers the common service-manager/remote termination path for every
# transaction type. INT separately covers the interactive Ctrl-C path.
run_signal_case measure TERM measure
run_signal_case dns TERM dns
run_signal_case ipv6 TERM ipv6
run_signal_case action TERM action
run_signal_case tc-trial TERM tc-trial
run_signal_case dns INT dns

test_real_tc_trial_signal_restore() {
    [[ "${BBRV3_NETWORK_INTEGRATION:-0}" == 1 ]] || return 0
    [[ "$(id -u)" == 0 ]] || return 0
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || return 0
    local iface=bv721sig marker="$TEST_ROOT/real-tc-ready" child rc=0
    cleanup_real_tc_signal() {
        [[ -z "${child:-}" ]] || kill -KILL "$child" >/dev/null 2>&1 || true
        ip link del "$iface" >/dev/null 2>&1 || true
    }
    trap 'cleanup_real_tc_signal; rm -rf -- "$TEST_ROOT"' EXIT
    ip link del "$iface" >/dev/null 2>&1 || true
    ip link add "$iface" type dummy
    ip link set "$iface" up
    tc qdisc replace dev "$iface" root fq
    (
        for module in 00-header.sh config.sh platform.sh state.sh sysctl.sh tc.sh; do
            # shellcheck source=/dev/null
            source "$ROOT_DIR/src/$module"
        done
        trap cleanup_core EXIT
        tc_trial_transaction_begin "$iface"
        apply_shaping "$iface" 20
        : > "$marker"
        sleep 30
    ) &
    child=$!
    for _ in $(seq 1 100); do
        [[ -e "$marker" ]] && break
        kill -0 "$child" >/dev/null 2>&1 || break
        sleep 0.1
    done
    [[ -e "$marker" ]] || fail "real TC trial did not reach the shaped state"
    kill -TERM "$child"
    wait "$child" || rc=$?
    child=""
    (( rc != 0 )) || fail "SIGTERM trial child reported success"
    tc qdisc show dev "$iface" | grep -Eq '^qdisc fq .* root([[:space:]]|$)' ||
        fail "real TC trial qdisc was not restored after SIGTERM"
    cleanup_real_tc_signal
    trap 'rm -rf -- "$TEST_ROOT"' EXIT
}

test_real_tc_trial_signal_restore

echo "integration signal cleanup tests passed"
