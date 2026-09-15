#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_MEASUREMENT_COOLDOWN=0

for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh nic.sh measure.sh systemd.sh cli.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN {exit !(v>=lo && v<=hi)}' || fail "$4: $1 not in [$2,$3]"; }

make_row() {
    local receiver="$1" loss="$2" sender="${3:-$1}" fallback="${4:-0}" bytes=100000000 retrans=0
    retrans=$(awk -v l="$loss" -v b="$bytes" 'BEGIN {printf "%d",l*(b/1448)/100}')
    printf '%s\t%s\t%s\t%s\t0.000\t1\t2\t0\t10\t0\t0\t0.00\t1\t1\t%s\t%s\t%s\t%s\t%s\n' \
        "$receiver" "$retrans" "$bytes" "$loss" "$sender" "$receiver" "$bytes" "$bytes" "$fallback"
}

install_sweep_mocks() {
    require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }
    measure_lock_peer() {
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
        path_state_reset; PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
    }
    measure_require_locked_port() { :; }; qdisc_guard() { :; }
    hardware_profile_values() {
        HARDWARE_CLASS=standard; HARDWARE_LINK_MBIT=1000; HARDWARE_LINK_TRUST=virtual-untrusted
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1; EFFECTIVE_BANDWIDTH_MBIT=1000; HARDWARE_CPU_COUNT=2
    }
    measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
    path_profile_tuning_gate() { :; }; measure_append_locked_peer_summary() { :; }
    measure_begin() { MEASURE_IFACE=eth0; }; measure_restore() { MEASURE_IFACE=""; measure_clear_peer_lock; }
    traffic_report() { :; }; apply_fq() { :; }; apply_shaping() { :; }
}

fixture_200_row() {
    local label="$1" rate
    case "$label" in
        path-control) make_row 80 0 80 ;;
        saturation) make_row 192 8.76210 205 ;;
        confirm-*) rate=${label#confirm-}; make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.93}')" 0 "$rate" ;;
        rate-*|refine-*)
            rate=${label#rate-}; rate=${rate#refine-}; rate=${rate%%-recheck-*}
            if (( rate <= 191 )); then make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.93}')" 0.03500 "$rate"
            elif (( rate <= 210 )); then make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.925}')" 0.05920 "$rate"
            else make_row 194 0.90000 "$rate"
            fi
            ;;
        *) fail "unexpected fixture label: $label" ;;
    esac
}

test_real_200m_regression() (
    local summary
    install_sweep_mocks
    sample_repeated() { fixture_200_row "$6"; }
    measure_sweep fixture.example 5201 eth0 200 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq clean "$(summary_value "$summary" PATH_CONTROL_QUALITY)" "200M path control"
    assert_eq 1 "$(summary_value "$summary" POLICER_SUSPECTED)" "200M policer suspicion"
    assert_eq CLEAN_POLICER_FOUND "$(summary_value "$summary" MEASUREMENT_STATE)" "200M state"
    assert_eq 80 "$(summary_value "$summary" PATH_CONTROL_RATE_MBIT)" "200M control rate"
    assert_eq 192 "$(summary_value "$summary" SATURATION_RECEIVER_MBIT)" "200M saturation receiver"
    assert_between "$(summary_value "$summary" SCAN_LOW_MBIT)" 180 185 "200M scan low"
    assert_between "$(summary_value "$summary" SCAN_HIGH_MBIT)" 220 260 "200M scan high"
    assert_between "$(summary_value "$summary" KNEE_MBIT)" 208 211 "200M knee"
    assert_between "$(summary_value "$summary" RECOMMEND)" 199 206 "200M recommendation"
    # v8.0.6 expands only the estimate to include the mandatory single/multi
    # final verify; the frozen v8.0.5 sweep state machine itself is unchanged.
    assert_between "$(summary_value "$summary" PLANNED_SAMPLE_UPPER_BOUND)" 1 38 "200M sample bound including final verify"
    assert_between "$(summary_value "$summary" ESTIMATED_TRAFFIC_BYTES_UPPER_BOUND)" 1 5000000000 "200M traffic bound"
)

test_auto_nominal_runs_saturation_then_control() (
    local events_file="$TEST_ROOT/auto-order" summary
    : > "$events_file"
    install_sweep_mocks
    sample_repeated() {
        printf ' %s' "$6" >> "$events_file"
        case "$6" in
            saturation) make_row 192 0 210 ;;
            path-control) make_row 86 0 86 ;;
            *) fail "auto no-policer unexpectedly scanned: $6" ;;
        esac
    }
    measure_sweep fixture.example 5201 eth0 0 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq ' saturation path-control' "$(<"$events_file")" "auto experiment order"
    assert_eq 86 "$(summary_value "$summary" PATH_CONTROL_RATE_MBIT)" "auto receiver-derived control"
    assert_eq CLEAN_NO_POLICER "$(summary_value "$summary" MEASUREMENT_STATE)" "auto no-policer state"
    assert_eq 1 "$(summary_value "$summary" NO_KNEE)" "auto no-policer marker"
)

test_auto_nominal_lossy_saturation_runs_full_sweep() (
    local events_file="$TEST_ROOT/auto-lossy-order" summary
    : > "$events_file"
    install_sweep_mocks
    sample_repeated() {
        printf ' %s' "$6" >> "$events_file"
        fixture_200_row "$6"
    }
    measure_sweep fixture.example 5201 eth0 0 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    [[ "$(<"$events_file")" == ' saturation path-control '* ]] || fail "auto lossy run did not discover capacity before path control and sweep"
    assert_eq clean "$(summary_value "$summary" PATH_CONTROL_QUALITY)" "auto lossy path control"
    assert_eq 1 "$(summary_value "$summary" POLICER_SUSPECTED)" "auto lossy policer suspicion"
    assert_eq CLEAN_POLICER_FOUND "$(summary_value "$summary" MEASUREMENT_STATE)" "auto lossy final state"
    assert_between "$(summary_value "$summary" KNEE_MBIT)" 208 212 "auto lossy knee"
)

test_clean_sender_receiver_no_policer() (
    local summary
    install_sweep_mocks
    sample_repeated() {
        case "$6" in
            path-control) make_row 40 0 40 ;;
            saturation) make_row 100 0 101 ;;
            *) fail "clean no-policer unexpectedly scanned: $6" ;;
        esac
    }
    measure_sweep fixture.example 5201 eth0 100 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq CLEAN_NO_POLICER "$(summary_value "$summary" MEASUREMENT_STATE)" "clean no-policer state"
    assert_eq 100 "$(summary_value "$summary" SATURATION_RECEIVER_MBIT)" "clean receiver rate"
    assert_eq 101 "$(summary_value "$summary" SATURATION_SENDER_MBIT)" "clean sender rate"
    assert_eq 1 "$(summary_value "$summary" NO_KNEE)" "clean no-knee marker"
)

test_clean_but_slow_peer_is_not_no_policer() (
    local summary rc=0
    install_sweep_mocks
    sample_repeated() {
        case "$6" in
            path-control) make_row 40 0 40 ;;
            saturation) make_row 50 0 50 ;;
            capacity-aggregate) make_row 55 0 55 ;;
            *) fail "slow-peer run unexpectedly scanned: $6" ;;
        esac
    }
    if measure_sweep fixture.example 5201 eth0 100 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null 2>&1; then
        fail "clean but capacity-limited peer was trusted as no-policer"
    else
        rc=$?
    fi
    assert_eq 2 "$rc" "slow peer status"
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq MEASUREMENT_UNSTABLE "$(summary_value "$summary" MEASUREMENT_STATE)" "slow peer state"
    assert_eq unstable "$(summary_value "$summary" SATURATION_STATE)" "slow peer saturation state"
    assert_eq 0 "$(summary_value "$summary" NO_KNEE)" "slow peer no-knee marker"
)

test_sender_does_not_drive_scan_range() (
    local summary
    install_sweep_mocks
    sample_repeated() {
        case "$6" in
            saturation) make_row 100 5 260 ;;
            path-control) make_row 45 0 45 ;;
            rate-*|refine-*|confirm-*) fixture_200_row "$6" ;;
            *) fail "unexpected sender/receiver label: $6" ;;
        esac
    }
    if ! measure_sweep fixture.example 5201 eth0 0 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null 2>&1; then :; fi
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_between "$(summary_value "$summary" SCAN_LOW_MBIT)" 88 94 "receiver-based scan low"
    awk -v h="$(summary_value "$summary" SCAN_HIGH_MBIT)" 'BEGIN {exit !(h<200)}' || fail "sender throughput widened scan range"
)

test_dirty_control_stops_before_saturation() (
    local calls_file="$TEST_ROOT/dirty-calls" rc=0 summary
    : > "$calls_file"
    install_sweep_mocks
    sample_repeated() { printf ' %s' "$6" >> "$calls_file"; make_row 78 1.2 80; }
    if measure_sweep dirty.example 5201 eth0 200 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null 2>&1; then fail "dirty path was accepted"; else rc=$?; fi
    assert_eq "$MEASURE_PATH_QUALITY_RC" "$rc" "dirty path status"
    assert_eq ' path-control' "$(<"$calls_file")" "dirty path reached saturation"
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq PATH_DIRTY "$(summary_value "$summary" MEASUREMENT_STATE)" "dirty path state"
)

test_spike_requires_two_of_three() (
    local counter="$TEST_ROOT/spike-counter" call
    printf '0\n' > "$counter"
    sample_repeated() { call=$(<"$counter"); ((call+=1)); printf '%s\n' "$call" > "$counter"; if (( call == 1 )); then make_row 190 1 200; else make_row 195 0 200; fi; }
    measure_level_with_confirmation x 1 3 6 1 transient 0.1 0
    assert_eq 0 "$MEASURE_LEVEL_SPIKE_CONFIRMED" "transient spike confirmation"
    assert_eq 1 "$MEASURE_LEVEL_SPIKE_HITS" "transient spike hits"

    printf '0\n' > "$counter"
    sample_repeated() { call=$(<"$counter"); ((call+=1)); printf '%s\n' "$call" > "$counter"; if (( call <= 2 )); then make_row 190 1 200; else make_row 195 0 200; fi; }
    measure_level_with_confirmation x 1 3 6 1 confirmed 0.1 0
    assert_eq 1 "$MEASURE_LEVEL_SPIKE_CONFIRMED" "two-hit spike confirmation"
    assert_eq 2 "$MEASURE_LEVEL_SPIKE_HITS" "two-hit spike count"
)

test_first_scan_loss_descends_to_clean_reference() (
    local summary rate
    install_sweep_mocks
    sample_repeated() {
        case "$6" in
            path-control) make_row 40 0 40 ;;
            saturation) make_row 100 5 108 ;;
            rate-91|rate-91-recheck-*) make_row 88 1.2 91 ;;
            lower-control-68) make_row 64 0.02 68 ;;
            refine-*)
                rate=${6#refine-}; rate=${rate%%-recheck-*}
                if (( rate >= 89 )); then make_row 86 1.0 "$rate"; else make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.94}')" 0.02 "$rate"; fi
                ;;
            confirm-*) rate=${6#confirm-}; make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.94}')" 0.02 "$rate" ;;
            *) fail "unexpected descent label: $6" ;;
        esac
    }
    measure_sweep fixture.example 5201 eth0 100 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq 68 "$(summary_value "$summary" CLEAN_REFERENCE_RATE_MBIT)" "descended clean reference"
    assert_between "$(summary_value "$summary" KNEE_MBIT)" 83 88 "shallow policer knee"
    assert_eq CLEAN_POLICER_FOUND "$(summary_value "$summary" MEASUREMENT_STATE)" "shallow policer state"
)

test_capacity_discovery_mode_is_separate() (
    local summary
    install_sweep_mocks
    sample_repeated() {
        case "$6" in
            path-control) make_row 1180 0 1200 ;;
            saturation) make_row 1000 0 1100 ;;
            capacity-aggregate) make_row 2800 0.01 2850 ;;
            *) fail "capacity discovery leaked into scan: $6" ;;
        esac
    }
    measure_sweep fixture.example 5201 eth0 3000 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq single+aggregate "$(summary_value "$summary" CAPACITY_DISCOVERY_MODE)" "capacity discovery mode"
    assert_eq 1000 "$(summary_value "$summary" SATURATION_RECEIVER_MBIT)" "single saturation preserved"
    assert_eq 2800 "$(summary_value "$summary" CAPACITY_RECEIVER_MBIT)" "aggregate capacity recorded"
)

test_receiver_fallback_reduces_confidence() {
    local confidence score grade reasons
    confidence=$(measurement_confidence 3 2 5 0 0 100 1)
    IFS=$'\t' read -r score grade reasons <<< "$confidence"
    assert_eq 80 "$score" "receiver fallback score"
    assert_eq medium "$grade" "receiver fallback grade"
    [[ "$reasons" == *receiver-fallback* ]] || fail "receiver fallback reason missing"
}

test_final_verify_uses_receiver_and_clean_reference() (
    local rc=0 summary
    install_sweep_mocks
    recommended_verify_flows() { printf '4\n'; }
    sample_repeated() {
        case "$6" in
            verify-single) make_row 80 0 120 ;;
            verify-multi-4) make_row 82 0 130 ;;
            *) fail "unexpected verify label: $6" ;;
        esac
    }
    if measure_verify fixture.example 5201 eth0 3 100 0.90 0 0.1 >/dev/null 2>&1; then fail "verify accepted sender-only target"; else rc=$?; fi
    assert_eq 2 "$rc" "receiver verify status"
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq 80 "$(summary_value "$summary" SINGLE_RECEIVER_MBIT)" "verify receiver field"
    assert_eq 120 "$(summary_value "$summary" SINGLE_SENDER_MBIT)" "verify sender field"
    assert_eq 0 "$(summary_value "$summary" ACCEPTED)" "verify receiver decision"
)

test_traffic_bound_is_finite() {
    local bytes
    bytes=$(estimate_sweep_bytes 250 6 60)
    assert_between "$bytes" 10000000000 13000000000 "traffic estimate"
}

run_test() { printf '==> %s\n' "$1"; "$1"; }
run_test test_real_200m_regression
run_test test_auto_nominal_runs_saturation_then_control
run_test test_auto_nominal_lossy_saturation_runs_full_sweep
run_test test_clean_sender_receiver_no_policer
run_test test_clean_but_slow_peer_is_not_no_policer
run_test test_sender_does_not_drive_scan_range
run_test test_dirty_control_stops_before_saturation
run_test test_spike_requires_two_of_three
run_test test_first_scan_loss_descends_to_clean_reference
run_test test_capacity_discovery_mode_is_separate
run_test test_receiver_fallback_reduces_confidence
run_test test_final_verify_uses_receiver_and_clean_reference
run_test test_traffic_bound_is_finite
printf 'v8.0.5 measurement rewrite tests: PASS\n'
