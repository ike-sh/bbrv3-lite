#!/usr/bin/env bash
# shellcheck disable=SC2034  # transaction globals are consumed dynamically by cleanup_core
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

ACTION_TRANSACTION_DIR=""
ACTION_TRANSACTION_IFACE=""
TC_TRIAL_IFACE=""
TC_TRIAL_SNAPSHOT=""
MEASURE_IFACE=""
MEASURE_SNAPSHOT=""
DNS_TRANSACTION_DIR=""
IPV6_TRANSACTION_DIR=""

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { :; }

run_persisted_action_signal_case() {
    local signal="$1" expected_rc="$2" rollback_mode="${3:-success}" rc=0 snapshot_checks=0
    local state_root="$TEST_ROOT/persisted-$signal-$rollback_mode/state"
    local dir="$state_root/.transaction.signal" events="$TEST_ROOT/persisted-$signal-$rollback_mode.events"
    mkdir -p -- "$dir/qdiscs"
    printf 'CREATED_AT\t2026-08-29T07:00:00Z\n' > "$dir/transaction.meta"
    printf 'readonly\n' > "$dir/transaction.state"
    printf 'complete\n' > "$dir/COMPLETE"
    printf 'persisted-signal-snapshot\n' > "$dir/qdiscs/eth0.snapshot"
    chmod -R go-rwx "$dir"
    : > "$events"

    if (
        set -Eeuo pipefail
        STATE_DIR="$state_root"; PERSIST_DIR="$TEST_ROOT/persisted-$signal-$rollback_mode/persist"
        ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
        ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0; ACTION_TRANSACTION_ROLLING_BACK=0
        ACTION_TRANSACTION_ROLLBACK_FAILED=0
        LOCK_HELD=0; QDISC_DEFAULT_TRANSACTION_ACTIVE=0; NIC_RUNTIME_TRANSACTION_DIR=""
        TC_TRIAL_IFACE=""; TC_TRIAL_SNAPSHOT=""; MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        DNS_TRANSACTION_DIR=""; IPV6_TRANSACTION_DIR=""
        action_transaction_begin_multi() { :; }
        if [[ "$rollback_mode" == fail ]]; then
            action_transaction_snapshot_validate() {
                ((snapshot_checks+=1))
                (( snapshot_checks == 1 ))
            }
        else
            action_transaction_snapshot_validate() { :; }
        fi
        action_transaction_quiesce_unit_for_restore() { :; }
        action_transaction_restore_path() { printf 'restore-path:%s\n' "$2" >> "$events"; }
        action_transaction_restore_tree() { :; }
        restore_tcp_sysctl_snapshot_file() { :; }
        action_transaction_restore_routes() { :; }
        restore_action_qdisc() { :; }
        action_transaction_restore_unit() { :; }
        release_lock() {
            printf 'cleanup-latch:%s\n' "$ACTION_TRANSACTION_ROLLBACK_FAILED" >> "$events"
        }
        systemctl() { [[ "$1" == daemon-reload ]]; }
        auto_tune_execute() {
            printf 'body:%s\n' "$(<"$ACTION_TRANSACTION_DIR/transaction.state")" >> "$events"
            kill "-$signal" "$BASHPID"
            sleep 5
            printf 'continued-after-signal\n' >> "$events"
        }
        action_transaction_commit() { printf 'commit\n' >> "$events"; }
        trap cleanup_core_exit EXIT
        auto_tune_run_transaction eth0 balanced mixed 0 100 0
    ); then
        rc=0
    else
        rc=$?
    fi

    [[ "$rc" == "$expected_rc" ]] || fail "persisted action SIG$signal/$rollback_mode returned $rc instead of $expected_rc"
    grep -Fxq 'body:mutated' "$events" || fail "persisted action SIG$signal did not publish mutated before its body"
    ! grep -Eq '^(commit|continued-after-signal)$' "$events" || fail "persisted action SIG$signal continued or committed"
    if [[ "$rollback_mode" == success ]]; then
        [[ ! -e "$dir" ]] || fail "successful signal rollback retained transaction evidence: SIG$signal"
        [[ $(grep -c '^restore-path:' "$events") == 6 ]] || fail "successful signal rollback did not execute all path restores: SIG$signal"
        grep -Fxq 'cleanup-latch:0' "$events" || fail "successful signal rollback left its failure latch set: SIG$signal"
    else
        [[ -d "$dir" ]] || fail 'failed signal rollback deleted its transaction directory'
        [[ $(<"$dir/transaction.meta") == $'CREATED_AT\t2026-08-29T07:00:00Z' ]] || fail 'failed signal rollback lost transaction.meta'
        [[ $(<"$dir/transaction.state") == mutated && $(<"$dir/COMPLETE") == complete ]] || fail 'failed signal rollback lost mutated/completion state'
        [[ $(<"$dir/qdiscs/eth0.snapshot") == persisted-signal-snapshot ]] || fail 'failed signal rollback lost snapshot evidence'
        ! grep -q '^restore-path:' "$events" || fail 'failed rollback validation performed restore writes'
        grep -Fxq 'cleanup-latch:1' "$events" || fail 'failed signal rollback did not preserve its failure latch'
        rm -rf -- "$dir"
    fi
}

# Compose the real atomic state transition and real EXIT rollback with all
# three production-default fatal signals. A separate TERM case forces rollback
# validation failure and proves on-disk evidence survives emergency cleanup.
run_persisted_action_signal_case INT 130
run_persisted_action_signal_case TERM 143
run_persisted_action_signal_case HUP 129
run_persisted_action_signal_case TERM 143 fail

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

AUTO_SIGNAL=""
AUTO_SIGNAL_EVENTS=""
action_transaction_begin_multi() {
    printf 'begin\n' >> "$AUTO_SIGNAL_EVENTS"
    ACTION_TRANSACTION_DIR="$TEST_ROOT/auto-$AUTO_SIGNAL.transaction"
    ACTION_TRANSACTION_IFACE="$1"
}
action_transaction_mark_mutated() {
    printf 'mark\n' >> "$AUTO_SIGNAL_EVENTS"
    ACTION_TRANSACTION_MUTATED=1
}
auto_tune_execute() {
    printf 'execute\n' >> "$AUTO_SIGNAL_EVENTS"
    kill "-$AUTO_SIGNAL" "$BASHPID"
    sleep 5
    printf 'continued-after-signal\n' >> "$AUTO_SIGNAL_EVENTS"
}
action_transaction_commit() {
    printf 'commit\n' >> "$AUTO_SIGNAL_EVENTS"
    ACTION_TRANSACTION_DIR=""
}
action_transaction_rollback() {
    printf 'rollback\n' >> "$AUTO_SIGNAL_EVENTS"
    ACTION_TRANSACTION_DIR=""
    ACTION_TRANSACTION_IFACE=""
    ACTION_TRANSACTION_MUTATED=0
}

run_auto_helper_signal_case() {
    local signal="$1" expected_rc="$2" rc=0 events rollback_count
    AUTO_SIGNAL="$signal"
    AUTO_SIGNAL_EVENTS="$TEST_ROOT/auto-helper-$signal.events"
    : > "$AUTO_SIGNAL_EVENTS"
    if (
        set -Eeuo pipefail
        ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_MUTATED=0
        trap cleanup_core_exit EXIT
        auto_tune_run_transaction eth0 balanced mixed 0 100 0
    ); then
        rc=0
    else
        rc=$?
    fi
    [[ "$rc" == "$expected_rc" ]] || fail "auto helper SIG$signal returned $rc instead of $expected_rc"
    events=$(paste -sd, "$AUTO_SIGNAL_EVENTS")
    [[ "$events" == begin,mark,execute,rollback ]] || fail "auto helper SIG$signal events were: $events"
    rollback_count=$(grep -Fxc rollback "$AUTO_SIGNAL_EVENTS")
    [[ "$rollback_count" == 1 ]] || fail "auto helper SIG$signal rollback count was $rollback_count"
    ! grep -Eq '^(commit|continued-after-signal)$' "$AUTO_SIGNAL_EVENTS" || fail "auto helper SIG$signal continued or committed"
}

run_auto_helper_signal_case INT 130
run_auto_helper_signal_case TERM 143
run_auto_helper_signal_case HUP 129

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
    tc qdisc show dev "$iface" | grep -E '^qdisc fq .* root([[:space:]]|$)' >/dev/null ||
        fail "real TC trial qdisc was not restored after SIGTERM"
    cleanup_real_tc_signal
    trap 'rm -rf -- "$TEST_ROOT"' EXIT
}

test_real_tc_trial_signal_restore

echo "integration signal cleanup tests passed"
