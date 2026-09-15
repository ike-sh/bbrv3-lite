#!/usr/bin/env bash
# Deterministic v8.0.6 pre-sample hard-budget regression tests.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_PEER_HEALTH_DIR="$TEST_ROOT/state/peer-health"
export BBRV3_PERSIST_DIR="$TEST_ROOT/persist"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/persist/net-tcp-tune.sh"
export BBRV3_SERVICE_FILE="$TEST_ROOT/etc/bbrv3-lite.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite.conf"
export BBRV3_LOCK_FILE="$TEST_ROOT/run/bbrv3-lite.lock"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"

# shellcheck source=/dev/null
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

install_iperf_fixture() {
    FIXTURE_COUNTER_FILE="$1"
    FIXTURE_CALLS_FILE="$2"
    FIXTURE_SAMPLE_BYTES="$3"
    uname() { printf 'TestOS\n'; }
    validate_peer() { :; }
    measure_require_sample_lock() { :; }
    measure_peer_route_guard() { :; }
    cpu_snapshot() { printf 'cpu\n'; }
    cpu_core_snapshot() { printf 'core\n'; }
    cpu_delta_metrics() { printf '10\t0\n'; }
    latency_stats_from_file() { printf 'na\tna\n'; }
    interface_counter() {
        case "$2" in
            tx_bytes) cat "$FIXTURE_COUNTER_FILE" ;;
            rx_bytes) printf '0\n' ;;
        esac
    }
    timeout() {
        local calls used
        calls=$(<"$FIXTURE_CALLS_FILE"); printf '%s\n' "$((calls+1))" > "$FIXTURE_CALLS_FILE"
        used=$(<"$FIXTURE_COUNTER_FILE"); printf '%s\n' "$((used+FIXTURE_SAMPLE_BYTES))" > "$FIXTURE_COUNTER_FILE"
        printf '{}\n'
        return "${FIXTURE_TIMEOUT_RC:-0}"
    }
    jq() {
        case "$2" in
            '.error // empty') printf '\n' ;;
            '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0') printf '200000000\n' ;;
            '.end.sum_received.bits_per_second // 0') printf '190360000\n' ;;
            '.end.sum_sent.bytes // .end.sum.bytes // 0') printf '100000000\n' ;;
            '.end.sum_received.bytes // 0') printf '95180000\n' ;;
            '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0') printf '3947\n' ;;
            *) return 1 ;;
        esac
    }
    MEASURE_PEER_HOST=fixture.example
    MEASURE_PEER_ADDRESS=203.0.113.10
    MEASURE_PEER_SOURCE=192.0.2.10
    MEASURE_PEER_FAMILY=4
    MEASURE_PEER_IFACE=eth0
    MEASURE_PEER_PORT=5201
    MEASURE_IFACE=eth0
    FIXTURE_TIMEOUT_RC=0
    sleep() { :; }
}

test_seeded_stage_path_control_is_rejected_before_spawn() (
    local counter_file="$TEST_ROOT/production-counter" calls_file="$TEST_ROOT/production-calls"
    local mib=$((1024*1024)) row rc=0 before after
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$((100*mib))"
    measurement_budget_configure "$((256*mib))" 900
    measurement_budget_ensure eth0

    # This is deliberately a seeded stage-level regression: pre-existing
    # operation traffic plus one SATURATION-like sample leaves materially less
    # than a safe 86 Mbit/s x 5s reservation. It is not the unknown-link CLI
    # entry flow, which is covered separately below.
    printf '%s\n' "$((100*mib))" > "$counter_file"
    MEASURE_ACTIVE_STAGE=SATURATION
    row=$(iperf_sample fixture.example 5201 5 1 190.36 0 0 0) || fail "fixture saturation unexpectedly failed"
    [[ -n "$row" ]] || fail "fixture saturation returned no row"

    before=$(<"$calls_file")
    MEASURE_ACTIVE_STAGE=PATH_CONTROL
    if iperf_sample fixture.example 5201 5 1 86 190.36 5.71572 0 >/dev/null 2>&1; then
        fail "PATH_CONTROL was allowed despite an unsafe remaining budget"
    else
        rc=$?
    fi
    after=$(<"$calls_file")
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "pre-sample PATH_CONTROL budget rc"
    assert_eq "$before" "$after" "iperf invocation count changed after reservation failure"
    measurement_usage_update
    assert_eq "$((200*mib))" "$TEST_TX_BYTES_USED" "rejected PATH_CONTROL changed actual TX"
    (( TEST_TX_BYTES_USED < 293670000 )) || fail "production fixture retained the old full-sample overshoot"
)

test_first_sample_reservation_semantics() (
    local plan stage rate duration flows semantics reserved seconds rc=0
    local mib=$((1024*1024)) gib=$((1024*1024*1024))
    measurement_profile_configure standard

    plan=$(measurement_first_sample_plan auto 0 5000 5)
    IFS=$'\t' read -r stage rate duration flows semantics reserved seconds <<< "$plan"
    assert_eq SATURATION "$stage" "unknown-link first stage"
    assert_eq 5000 "$rate" "unknown-link safety ceiling"
    assert_eq 5 "$duration" "standard saturation duration"
    assert_eq unshaped "$semantics" "unknown-link first-stage semantics"
    assert_eq 3501048576 "$reserved" "5000M first-sample safe reservation"
    assert_eq 25 "$seconds" "first-sample time reservation"
    if measurement_first_sample_budget_check "$((256*mib))" 900 auto 0 5000 5; then
        fail "unknown-link 0.25 GiB first sample was accepted"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "unknown-link first-sample budget rc"

    plan=$(measurement_first_sample_plan known 1000 5000 5)
    IFS=$'\t' read -r stage rate duration flows semantics reserved seconds <<< "$plan"
    assert_eq PATH_CONTROL "$stage" "known-rate first stage"
    assert_eq 400 "$rate" "known-rate path-control planning rate"
    assert_eq 281048576 "$reserved" "known-rate first-sample reservation"
    rc=0
    if measurement_first_sample_budget_check "$((256*mib))" 900 known 1000 5000 5; then
        fail "known-rate insufficient first-sample budget was accepted"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "known-rate first-sample budget rc"

    rc=0
    if measurement_first_sample_budget_check "$reserved" 900 known 1000 5000 5; then
        fail "exact first-sample reservation boundary was accepted"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "exact first-sample boundary rc"
    measurement_first_sample_budget_check "$((reserved+1))" 900 known 1000 5000 5 || \
        fail "budget above first-sample reservation was rejected"
    measurement_first_sample_budget_check "$((6*gib))" 900 auto 0 5000 5 || \
        fail "default 6 GiB budget rejected unknown-link first sample"
)

test_unknown_entry_fails_before_transaction() (
    local mib=$((1024*1024)) events="" rc=0 output_file="$TEST_ROOT/unknown-entry.log"
    BASELINE_DIR="$TEST_ROOT/unknown-entry-baseline"
    CONFIG_FILE="$TEST_ROOT/unknown-entry-config"
    SYSCTL_FILE="$TEST_ROOT/unknown-entry-sysctl"
    WIZARD_PEER=fixture.example; WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
    AUTO_MAX_TX_BYTES=$((256*mib)); AUTO_MAX_DURATION_SECONDS=900
    measurement_profile_configure standard
    action_transaction_begin_multi() { events+=" transaction"; mkdir -p "$BASELINE_DIR"; }
    action_transaction_mark_mutated() { events+=" baseline"; }
    auto_tune_execute() { events+=" sysctl qdisc iperf"; }
    if auto_tune_run_transaction eth0 balanced proxy 0 100 29 >"$output_file" 2>&1; then
        fail "unknown-link insufficient entry budget reported success"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "unknown-link production-entry rc"
    assert_eq "" "$events" "first-sample gate ran after transaction or network mutation"
    [[ ! -e "$BASELINE_DIR" && ! -e "$CONFIG_FILE" && ! -e "$SYSCTL_FILE" ]] || \
        fail "first-sample fail-fast created product state"
    assert_contains "$(<"$output_file")" '首样本安全预留' "fail-fast reservation UX"
    assert_contains "$(<"$output_file")" '未创建调优 transaction' "fail-fast transaction UX"
    assert_contains "$(<"$output_file")" '未启动 iperf' "fail-fast no-iperf UX"
)

test_default_budget_uses_actual_then_converges_from_telemetry() (
    local gib=$((1024*1024*1024)) plan reserved first_projection later_projection
    local rates_file="$TEST_ROOT/converged-rates" counter_file="$TEST_ROOT/converged-counter"
    local -a rates=()
    measurement_profile_configure standard
    plan=$(measurement_first_sample_plan auto 0 5000 5)
    reserved=$(cut -f6 <<< "$plan")
    measurement_first_sample_budget_check "$((6*gib))" 900 auto 0 5000 5 || \
        fail "default budget did not admit first SATURATION"

    : > "$rates_file"
    iperf_sample() {
        printf '%s\n' "$5" >> "$rates_file"
        printf '190.36\t3947\t100000000\t5.71572\t42380\t30\t40\t0.10\t20\t0\t0\t200\t190.36\t100000000\t95180000\t0\n'
    }
    sample_repeated fixture.example 5201 5 1 2 saturation 2 0 5000 unshaped >/dev/null || \
        fail "telemetry-convergence fixture failed"
    mapfile -t rates < "$rates_file"
    assert_eq 2 "${#rates[@]}" "telemetry-convergence sample count"
    assert_eq 5000 "${rates[0]}" "first SATURATION did not use safety ceiling"
    assert_eq 200 "${rates[1]}" "second SATURATION did not use fresh sender telemetry"
    first_projection=$(measurement_sample_projected_tx 5000 5 1 0 0 0 unshaped)
    later_projection=$(measurement_sample_projected_tx 200 5 1 200 5.71572 0.10 unshaped)
    (( later_projection < first_projection )) || fail "later reservation did not tighten after telemetry"

    printf '0\n' > "$counter_file"
    interface_counter() { case "$2" in tx_bytes) cat "$counter_file" ;; *) printf '0\n' ;; esac; }
    measurement_budget_configure "$((6*gib))" 900; measurement_budget_ensure eth0
    measurement_budget_reserve_sample SATURATION 5000 5 1 0 0 0 unshaped || fail "first reservation rejected default budget"
    assert_eq 0 "$TEST_TX_BYTES_USED" "reservation was charged as actual usage"
    printf '100000000\n' > "$counter_file"
    measurement_budget_reserve_sample SATURATION 200 5 1 200 5.71572 0.10 unshaped || \
        fail "telemetry-based repeat reservation was rejected"
    assert_eq 100000000 "$TEST_TX_BYTES_USED" "actual interface usage did not replace estimate"
    assert_eq 3501048576 "$reserved" "default fixture initial reservation changed"
)

test_projection_semantics() (
    local one four shaped shaped_sender unshaped_sender background payload
    one=$(measurement_sample_projected_tx 86 5 1 0 5.71572 0 shaped)
    four=$(measurement_sample_projected_tx 86 5 4 0 5.71572 0 shaped)
    assert_eq "$one" "$four" "aggregate shaping rate was multiplied by flow count"
    payload=$(awk 'BEGIN {printf "%.0f",86*1000000/8*5}')
    (( one > payload )) || fail "reservation omitted protocol/retransmission margin"
    shaped=$(measurement_sample_projected_tx 86 5 1 0 0 0 shaped)
    shaped_sender=$(measurement_sample_projected_tx 86 5 1 190.36 0 0 shaped)
    assert_eq "$shaped" "$shaped_sender" "recent sender incorrectly overrode aggregate shaping rate"
    unshaped_sender=$(measurement_sample_projected_tx 86 5 1 190.36 0 0 unshaped)
    (( unshaped_sender > shaped )) || fail "unshaped projection ignored recent sender throughput"
    background=$(measurement_sample_projected_tx 86 5 1 0 0 10 shaped)
    (( background > shaped )) || fail "background traffic headroom did not increase reservation"
)

test_exact_boundary_and_actual_counter_truth() (
    local counter_file="$TEST_ROOT/boundary-counter" calls_file="$TEST_ROOT/boundary-calls"
    local mib=$((1024*1024)) reserved maximum rc=0
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$mib"
    reserved=$(measurement_sample_projected_tx 86 5 1 0 0 0 shaped)
    maximum=$((40*mib+reserved))
    measurement_budget_configure "$maximum" 900; measurement_budget_ensure eth0
    printf '%s\n' "$((40*mib))" > "$counter_file"
    MEASURE_ACTIVE_STAGE=BOUNDARY
    if iperf_sample fixture.example 5201 5 1 86 0 0 0 shaped >/dev/null 2>&1; then
        fail "exact projected traffic boundary was accepted"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "exact projected boundary rc"
    assert_eq 0 "$(<"$calls_file")" "exact boundary spawned iperf"
    assert_eq "$((40*mib))" "$TEST_TX_BYTES_USED" "reservation replaced actual interface accounting"
)

test_unknown_saturation_fails_closed() (
    local counter_file="$TEST_ROOT/saturation-counter" calls_file="$TEST_ROOT/saturation-calls" rc=0 mib=$((1024*1024))
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$((100*mib))"
    measurement_budget_configure "$((256*mib))" 900; measurement_budget_ensure eth0
    MEASURE_ACTIVE_STAGE=SATURATION
    if iperf_sample fixture.example 5201 5 4 5000 0 0 0 unshaped >/dev/null 2>&1; then
        fail "unsafe unknown-rate saturation sample was accepted"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "unknown-rate saturation budget rc"
    assert_eq 0 "$(<"$calls_file")" "unknown-rate saturation spawned iperf"
)

test_retry_is_reserved_before_every_attempt() (
    local counter_file="$TEST_ROOT/retry-counter" calls_file="$TEST_ROOT/retry-calls" rc=0
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" 400000
    FIXTURE_TIMEOUT_RC=124
    measurement_budget_configure 2097152 900; measurement_budget_ensure eth0
    export BBRV3_IPERF_ATTEMPTS=3
    if sample_repeated fixture.example 5201 3 1 1 retry 1 0 1 shaped >/dev/null 2>&1; then
        fail "retry fixture unexpectedly succeeded"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "retry reservation rc"
    assert_eq 2 "$(<"$calls_file")" "retry spawned an attempt after reservation failure"
    measurement_usage_update
    assert_eq 800000 "$TEST_TX_BYTES_USED" "retry actual interface accounting"
)

test_peer_failover_shares_reservation_ledger() (
    local counter_file="$TEST_ROOT/failover-counter" calls_file="$TEST_ROOT/failover-calls"
    local mib=$((1024*1024)) rc=0 before init
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$((20*mib))"
    measurement_budget_configure "$((80*mib))" 900; measurement_budget_ensure eth0
    init="$MEASURE_BUDGET_INITIALIZATION_COUNT"
    MEASURE_ACTIVE_STAGE=PEER_A
    iperf_sample fixture.example 5201 3 1 20 0 0 0 shaped >/dev/null || fail "first peer fixture failed"
    printf '%s\n' "$((50*mib))" > "$counter_file"
    before=$(<"$calls_file")
    MEASURE_PEER_HOST=other.example; MEASURE_PEER_ADDRESS=203.0.113.11; MEASURE_PEER_PORT=5201
    MEASURE_ACTIVE_STAGE=PEER_FAILOVER
    if iperf_sample other.example 5201 5 4 50 20 0 0 shaped >/dev/null 2>&1; then
        fail "peer failover escaped the operation budget"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "peer-failover reservation rc"
    assert_eq "$before" "$(<"$calls_file")" "peer failover spawned iperf after rejection"
    assert_eq "$init" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "peer failover reset the operation ledger"
)

test_same_host_final_verify_fallback_shares_reservation_ledger() (
    local counter_file="$TEST_ROOT/port-counter" calls_file="$TEST_ROOT/port-calls"
    local mib=$((1024*1024)) rc=0 before init
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$((20*mib))"
    measurement_budget_configure "$((80*mib))" 900; measurement_budget_ensure eth0
    init="$MEASURE_BUDGET_INITIALIZATION_COUNT"
    MEASURE_ACTIVE_STAGE=FINAL_VERIFY_5202
    iperf_sample fixture.example 5202 3 1 20 0 0 0 shaped >/dev/null || fail "first final-verify port fixture failed"
    printf '%s\n' "$((50*mib))" > "$counter_file"
    before=$(<"$calls_file")
    MEASURE_PEER_PORT=5201
    MEASURE_ACTIVE_STAGE=FINAL_VERIFY_5201
    if iperf_sample fixture.example 5201 5 4 50 20 0 0 shaped >/dev/null 2>&1; then
        fail "same-host alternate final verify escaped the operation budget"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "alternate final-verify port reservation rc"
    assert_eq "$before" "$(<"$calls_file")" "alternate final-verify port spawned iperf after rejection"
    assert_eq "$init" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "alternate final-verify port reset the operation ledger"
)

test_time_budget_blocks_sample_and_cooldown() (
    local counter_file="$TEST_ROOT/time-counter" calls_file="$TEST_ROOT/time-calls" slept_file="$TEST_ROOT/time-slept"
    local rc=0
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" 1
    sleep() { : > "$slept_file"; }
    measurement_budget_configure 1073741824 30; measurement_budget_ensure eth0
    MEASURE_BUDGET_STARTED_EPOCH=$(( $(date +%s) - 6 ))
    MEASURE_ACTIVE_STAGE=TIME_SAMPLE
    if iperf_sample fixture.example 5201 5 1 1 0 0 0 shaped >/dev/null 2>&1; then
        fail "sample exceeded remaining wall-clock reservation"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "pre-sample time budget rc"
    assert_eq 0 "$(<"$calls_file")" "time budget rejection spawned iperf"

    MEASURE_BUDGET_STARTED_EPOCH=$(date +%s)
    if measurement_cooldown PRE_VERIFY 86 7 >/dev/null 2>&1; then
        fail "cooldown plus next sample exceeded wall-clock budget"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "cooldown time reservation rc"
    [[ ! -e "$slept_file" ]] || fail "cooldown slept after time reservation failure"
)

test_shell_exit_code_is_70() (
    local counter_file="$TEST_ROOT/shell-counter" calls_file="$TEST_ROOT/shell-calls" rc=0 mib=$((1024*1024))
    printf '0\n' > "$counter_file"; printf '0\n' > "$calls_file"
    install_iperf_fixture "$counter_file" "$calls_file" "$mib"
    measurement_budget_configure "$((64*mib))" 900; measurement_budget_ensure eth0
    printf '%s\n' "$((63*mib))" > "$counter_file"
    MEASURE_ACTIVE_STAGE=SHELL_RC
    if (iperf_sample fixture.example 5201 5 1 86 0 0 0 shaped >/dev/null 2>&1); then
        fail "shell RC fixture unexpectedly succeeded"
    else rc=$?; fi
    assert_eq 70 "$rc" "actual shell exit code"
)

test_seeded_stage_path_control_is_rejected_before_spawn
test_first_sample_reservation_semantics
test_unknown_entry_fails_before_transaction
test_default_budget_uses_actual_then_converges_from_telemetry
test_projection_semantics
test_exact_boundary_and_actual_counter_truth
test_unknown_saturation_fails_closed
test_retry_is_reserved_before_every_attempt
test_peer_failover_shares_reservation_ledger
test_same_host_final_verify_fallback_shares_reservation_ledger
test_time_budget_blocks_sample_and_cooldown
test_shell_exit_code_is_70
printf 'v8.0.6 hard-budget guard tests: PASS\n'
