#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"

test_underfill_recovers_only_with_quorum() (
    local calls="$TEST_ROOT/recovery-calls" n
    printf '0\n' > "$calls"
    new_measure_run sweep
    sleep() { :; }
    sample_repeated() {
        n=$(<"$calls"); ((n+=1)); printf '%s\n' "$n" > "$calls"
        case "$n" in
            1) fixture_metrics_row 631.58 0.13153 635.66 1 ;;
            2) fixture_metrics_row 980 0.13153 990 1 ;;
            3) fixture_metrics_row 982 0.13153 992 1 ;;
            *) return 1 ;;
        esac
    }
    measure_level_with_confirmation fixture 5201 5 7 1 rate-1036 0.1 0.04603 1036 0.75 > "$TEST_ROOT/reference.log" 2>&1
    assert_eq 3 "$(<"$calls")" 'bounded reference recovery'
    assert_eq 1 "$MEASURE_LEVEL_REPRESENTATIVE" 'qualified recovered reference'
    assert_eq 982 "$(cut -f1 <<< "$MEASURE_LEVEL_ROW")" 'low receiver was not selected'
    assert_eq 0 "$MEASURE_LEVEL_SPIKE_CONFIRMED" 'underfill created a spike'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" 'LOSS_CLEAN=1; THROUGHPUT_REPRESENTATIVE=0' 'separate loss/throughput flags'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" THROUGHPUT_RECHECK 'recheck reason'
    assert_eq 0.75000 "$(minimum_efficiency_ratio 631.58 1036)" 'existing efficiency floor unchanged'
    if measurement_throughput_representative "$(fixture_metrics_row 631.58 0.13153 635.66 1)" 1036 0.75; then fail '61% efficiency became representative'; fi
)

test_repeated_underfill_is_peer_limited() (
    local calls="$TEST_ROOT/slow-calls" n rc=0
    printf '0\n' > "$calls"
    new_measure_run sweep
    sample_repeated() {
        n=$(<"$calls"); ((n+=1)); printf '%s\n' "$n" > "$calls"
        fixture_metrics_row 631.58 0.13153 635.66 1
    }
    measure_level_with_confirmation fixture 5201 5 7 1 rate-1036 0.1 0.04603 1036 0.75 > "$TEST_ROOT/slow.log" 2>&1 || rc=$?
    assert_eq 2 "$rc" 'repeated underfill inconclusive'
    assert_eq 2 "$(<"$calls")" 'stop after quorum impossible'
    assert_eq '' "$MEASURE_LEVEL_ROW" 'no unreliable reference'
    assert_eq peer-too-slow "$FAILURE_REASON" 'peer limitation reason'
    assert_eq 0 "$MEASURE_LEVEL_SPIKE_CONFIRMED" 'slow peer is not a policer'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" 'PEER_LIMITED=1; PATH_DIRTY=0' 'peer/path semantics'
)

test_existing_efficiency_applies_to_later_levels() (
    local calls="$TEST_ROOT/later-calls" n rc=0
    printf '0\n' > "$calls"
    sample_repeated() { n=$(<"$calls"); printf '%s\n' "$((n+1))" > "$calls"; fixture_metrics_row 800 0.02 810 1; }
    # Above the absolute 75% floor, but below this scan's measured 92% gate.
    measure_level_with_confirmation fixture 5201 5 7 1 rate-1000 0.1 0.02 1000 0.92 > "$TEST_ROOT/later.log" 2>&1 || rc=$?
    assert_eq 2 "$rc" 'later-level underfill uses current scan efficiency'
    assert_eq 0 "$MEASURE_LEVEL_SPIKE_CONFIRMED" 'underfill cannot manufacture knee'
)

test_slow_public_peer_is_not_path_dirty() (
    local rc=0 file
    install_sweep_fixture
    install_high_bandwidth_samples
    FIXTURE_UNDERFILLED=1
    measurement_budget_feasibility_gate() { :; }
    measurement_budget_configure 6442450944 900
    measure_sweep speedtest.hkg12.hk.leaseweb.net 5201 eth0 0 1036 1470 62 5 1 3 0.1 0 5000 auto > "$TEST_ROOT/slow-public.log" 2>&1 || rc=$?
    assert_eq 2 "$rc" 'slow public peer inconclusive/failover eligible'
    assert_eq '' "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" CLEAN_REFERENCE_RECEIVER_MBIT)" 'slow peer was not a reference'
    assert_eq '' "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" CONFIRMED_KNEE)" 'slow peer was not a knee'
    assert_eq low "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" DECISION_CONFIDENCE_GRADE)" 'slow peer decision confidence'
    file=$(peer_health_file speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5201)
    peer_health_load "$file"
    assert_eq 1 "$PH_SLOW_PEER_COUNT" 'slow peer health unit'
    assert_eq 0 "$PH_PATH_DIRTY_COUNT" 'slow peer polluted path dirty'
)

test_recovery_quorum_must_also_be_stable() (
    local calls="$TEST_ROOT/unstable-recovery-calls" n rc=0
    printf '0\n' > "$calls"
    new_measure_run sweep
    sample_repeated() {
        n=$(<"$calls"); ((n+=1)); printf '%s\n' "$n" > "$calls"
        case "$n" in
            1) fixture_metrics_row 631.58 0.13153 635.66 1 ;;
            2) fixture_metrics_row 800 0.13153 810 1 ;;
            3) fixture_metrics_row 1000 0.13153 1010 1 ;;
        esac
    }
    measure_level_with_confirmation fixture 5201 5 7 1 rate-1036 0.1 0.04603 1036 0.75 > "$TEST_ROOT/unstable-recovery.log" 2>&1 || rc=$?
    assert_eq "$IPERF_UNSTABLE_RC" "$rc" 'two individually efficient but unstable recovery samples'
    assert_eq '' "$MEASURE_LEVEL_ROW" 'unstable recovery selected a reference'
    assert_eq 3 "$(cat "$calls")" 'recovery instability exceeded bounded attempts'
    assert_eq measurement-unstable "$FAILURE_REASON" 'recovery instability classified as peer/path dirty'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" THROUGHPUT_RECOVERY_UNSTABLE 'recovery dispersion recorded'
)

test_underfill_recovers_only_with_quorum
test_repeated_underfill_is_peer_limited
test_existing_efficiency_applies_to_later_levels
test_slow_public_peer_is_not_path_dirty
test_recovery_quorum_must_also_be_stable
printf 'v8.0.8 reference representativeness: PASS\n'
