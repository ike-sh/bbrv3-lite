#!/usr/bin/env bash
# Shared deterministic fixtures; no real networking or persistent product state.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_PEER_HEALTH_DIR="$TEST_ROOT/state/peer-health"
export BBRV3_PERSIST_DIR="$TEST_ROOT/persist"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/persist/net-tcp-tune.sh"
export BBRV3_SERVICE_FILE="$TEST_ROOT/etc/bbrv3-lite.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite.conf"
export BBRV3_LOCK_FILE="$TEST_ROOT/run/lock"
export BBRV3_MEASUREMENT_COOLDOWN=0
# shellcheck source=../../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures/v808-high-bandwidth"
FIXTURE_COUNTER="$TEST_ROOT/tx-counter"
FIXTURE_SPAWNS="$TEST_ROOT/spawns"
printf '0\n' > "$FIXTURE_COUNTER"
: > "$FIXTURE_SPAWNS"
fail() { printf 'FAIL: %s\n' "$*" >&2; for log_file in "$TEST_ROOT"/*.log; do [[ ! -f "$log_file" ]] || tail -35 "$log_file" >&2; done; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }
fixture_value() { summary_value "$FIXTURE_DIR/context.tsv" "$1"; }
fixture_metrics_row() {
    local receiver="$1" loss="$2" sender="${3:-$1}" count="${4:-2}"
    printf '%s\t0\t100000000\t%s\t0.000\t2\t3\t0\t20\t0\t0\t0.00\t%s\t2\t%s\t%s\t100000000\t99000000\t0\n' \
        "$receiver" "$loss" "$count" "$sender" "$receiver"
}
fixture_raw_row() {
    local row="$1"
    awk -F'\t' 'BEGIN {OFS="\t"} {print $4,$5,$6,$8,$9,$12,$13,$15,$16,$17,$18,$3,$4,$6,$7,$10}' <<< "$row"
}
fixture_sample_row() {
    local label="$1" index="${2:-1}"
    awk -F'\t' -v label="$label" -v wanted="$index" 'NR>1 && $2==label {n++; if(n==wanted) {print; exit}}' "$FIXTURE_DIR/samples.tsv"
}
fixture_charge() {
    local bytes="$1" used
    used=$(<"$FIXTURE_COUNTER")
    (( used+bytes < MEASURE_MAX_TX_BYTES )) || { printf 'fixture hard-budget overshoot\n' >&2; return 1; }
    printf '%s\n' "$((used+bytes))" > "$FIXTURE_COUNTER"
}
fixture_interface_counter() {
    if [[ "$2" == tx_bytes ]]; then cat "$FIXTURE_COUNTER"; else printf '0\n'; fi
}
install_sweep_fixture() {
    printf '0\n' > "$FIXTURE_COUNTER"; : > "$FIXTURE_SPAWNS"
    rm -f -- "$TEST_ROOT"/*-calls
    require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
    interface_counter() { fixture_interface_counter "$@"; }
    measure_lock_peer() {
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=64.120.117.34; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
        path_state_reset; PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
    }
    measure_require_locked_port() { :; }; qdisc_guard() { :; }
    measurement_environment_preflight() { :; }
    hardware_profile_values() {
        HARDWARE_CLASS=micro; HARDWARE_LINK_MBIT=5000; HARDWARE_LINK_TRUST=virtual-untrusted
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1; HARDWARE_CPU_COUNT=1; HARDWARE_MEMORY_MB=967; EFFECTIVE_BANDWIDTH_MBIT=1138
    }
    measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
    path_profile_tuning_gate() { :; }; measure_append_locked_peer_summary() { :; }
    measure_begin() { MEASURE_IFACE=eth0; measurement_budget_ensure eth0; printf 'original-qdisc\n' > "$TEST_ROOT/qdisc-before"; }
    measure_restore() { cp "$TEST_ROOT/qdisc-before" "$TEST_ROOT/qdisc-after"; MEASURE_IFACE=""; measure_clear_peer_lock; }
    traffic_report() { :; }; apply_fq() { :; }; apply_shaping() { :; }
    sleep() { :; }
}
# This mock replaces only network I/O. It still executes the production
# reservation guard and charges the same interface ledger before every retry.
install_high_bandwidth_samples() {
    iperf_sample() {
        local stage="$MEASURE_ACTIVE_STAGE" label index_file index=0 row used bytes=100000000
        measurement_budget_reserve_sample "$stage" "$5" "$3" "$4" "${6:-0}" "${7:-0}" "${8:-0}" "${9:-aggregate}" || return $?
        printf '%s\n' "$stage" >> "$FIXTURE_SPAWNS"
        index_file="$TEST_ROOT/${stage}-calls"
        [[ ! -f "$index_file" ]] || index=$(<"$index_file")
        ((index+=1)); printf '%s\n' "$index" > "$index_file"
        if [[ "$stage" == SATURATION || "$stage" == RATE_1036 ]]; then
            if (( index <= 2 )); then
                fixture_charge 100000
                failure_set "$stage" peer-busy 'the server is busy running a test' '' "$IPERF_UNAVAILABLE_RC"
                peer_health_record "$MEASURE_PEER_HOST" 4 "$MEASURE_PEER_ADDRESS" 5201 failure peer-busy na na unknown
                return "$IPERF_UNAVAILABLE_RC"
            fi
            index=$((index-2))
        fi
        label="${stage,,}"; label="${label//_/-}"
        case "$stage" in
            RATE_1036_RECHECK_2|RATE_1036_RECHECK_3)
                if [[ "${FIXTURE_UNDERFILLED:-0}" == 1 ]]; then
                    row=$(fixture_metrics_row 631.58 0.13153 635.66 1)
                elif [[ "$stage" == RATE_1036_RECHECK_2 ]]; then row=$(fixture_metrics_row 980 0.13153 990 1)
                else row=$(fixture_metrics_row 982 0.13153 992 1)
                fi
                row=$(awk -F'\t' 'BEGIN{OFS="\t"} {print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$15,$16,$17,$18,$19}' <<< "$row")
                ;;
            *)
                row=$(fixture_sample_row "$label" "$index")
                [[ -n "$row" ]] || { printf 'unexpected stage %s/%s\n' "$stage" "$index" >&2; return 1; }
                row=$(fixture_raw_row "$row") ;;
        esac
        if [[ "$stage" == RATE_1222_RECHECK_2 && "${FIXTURE_LATE_BUDGET:-0}" == 1 ]]; then
            used=$(<"$FIXTURE_COUNTER"); bytes=$(($(fixture_value USED_TX_BYTES)-used))
        fi
        fixture_charge "$bytes"
        peer_health_record_sample_success "$MEASURE_PEER_HOST" 4 "$MEASURE_PEER_ADDRESS" 5201 1 "$(cut -f13 <<< "$row")"
        printf '%s\n' "$row"
    }
}
run_production_late_interruption() {
    install_sweep_fixture
    install_high_bandwidth_samples
    FIXTURE_LATE_BUDGET=1
    # Replay a pre-existing scan's late interruption. The normal entry-point
    # behavior is covered separately: it stops at the feasibility gate.
    measurement_budget_feasibility_gate() { :; }
    measurement_budget_configure "$(fixture_value HARD_BUDGET_BYTES)" 900
    measurement_profile_configure standard
    FIXTURE_RC=0
    measure_sweep speedtest.hkg12.hk.leaseweb.net 5201 eth0 0 1036 1470 62 5 1 3 0.1 0 5000 auto > "$TEST_ROOT/production.log" 2>&1 || FIXTURE_RC=$?
    FIXTURE_SUMMARY="$MEASURE_RUN_DIR/summary.tsv"
}
