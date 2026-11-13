#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"
HIGH_ARGS=(1138.46 1151.55 0.04603 1036 1470 62 5 0 1 488.13 512 3)

test_expected_and_bound_are_distinct() (
    local quick standard small expected upper quick_expected
    measurement_profile_configure standard
    standard=$(measurement_remaining_plan standard "${HIGH_ARGS[@]}")
    quick=$(measurement_remaining_plan quick "${HIGH_ARGS[@]}")
    small=$(measurement_remaining_plan standard 191.38 200 0.0036 183 220 6 5 0 1 78.8 80 3)
    expected=$(summary_value /dev/stdin EXPECTED_REMAINING_TX <<< "$standard")
    upper=$(summary_value /dev/stdin CONSERVATIVE_REMAINING_UPPER_BOUND <<< "$standard")
    quick_expected=$(summary_value /dev/stdin EXPECTED_REMAINING_TX <<< "$quick")
    (( expected > 6442450944 && upper > expected && quick_expected < expected )) || fail 'high-bandwidth expected/bound/quick relation'
    (( $(summary_value /dev/stdin EXPECTED_REMAINING_TX <<< "$small") < 6442450944 )) || fail '200M ordinary plan cannot fit default budget'
    assert_eq standard "$MEASUREMENT_PROFILE" 'comparison silently changed profile'
    assert_contains "$standard" 'BUDGET_ESTIMATE_UNCERTAINTY' 'uncertain model must be labelled'
    assert_contains "$standard" $'RETRY_ALLOWANCE\t2' 'retry allowance'
    printf '200M expected remaining: %s\n1.14G standard expected remaining: %s\n1.14G quick expected remaining: %s\n' \
        "$(human_bytes "$(summary_value /dev/stdin EXPECTED_REMAINING_TX <<< "$small")")" "$(human_bytes "$expected")" "$(human_bytes "$quick_expected")"
)

prepare_gate() {
    printf '0\n' > "$FIXTURE_COUNTER"
    interface_counter() { fixture_interface_counter "$@"; }
    measurement_profile_configure standard
    measurement_budget_configure 6442450944 900
    measurement_budget_ensure eth0
    printf '2500000000\n' > "$FIXTURE_COUNTER"
    new_measure_run sweep
}

test_noninteractive_failure_preserves_ledger() (
    local rc=0 initialized started
    prepare_gate
    initialized="$MEASURE_BUDGET_INITIALIZATION_COUNT"; started="$MEASURE_BUDGET_STARTED_EPOCH"
    measurement_budget_interactive() { return 1; }
    measurement_budget_feasibility_gate "${HIGH_ARGS[@]}" > "$TEST_ROOT/gate.log" 2>&1 || rc=$?
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'noninteractive budget risk'
    assert_eq standard "$MEASUREMENT_PROFILE" 'no silent quick downgrade'
    assert_eq 6442450944 "$MEASURE_MAX_TX_BYTES" 'no silent budget increase'
    assert_eq "$initialized" "$MEASURE_BUDGET_INITIALIZATION_COUNT" 'ledger reinitialized'
    assert_eq "$started" "$MEASURE_BUDGET_STARTED_EPOCH" 'duration clock reset'
    assert_eq 2500000000 "$TEST_TX_BYTES_USED" 'used bytes reset'
    assert_eq 0 "$(wc -l < "$FIXTURE_SPAWNS")" 'spawn after feasibility rejection'
    assert_contains "$(cat "$TEST_ROOT/gate.log")" --measurement-profile 'explicit rerun advice'
    assert_contains "$(cat "$MEASURE_RUN_DIR/budget-plan.tsv")" $'REMAINING_TX_BYTES\t3942450944' 'actual remaining counter'
)

test_explicit_quick_and_budget_choices() (
    local rc=0 initialized
    prepare_gate
    initialized="$MEASURE_BUDGET_INITIALIZATION_COUNT"
    measurement_budget_interactive() { return 0; }
    # Quick may still be too costly: selecting it never implies success.
    measurement_budget_feasibility_gate "${HIGH_ARGS[@]}" > "$TEST_ROOT/quick.log" 2>&1 <<< $'q\nc' || rc=$?
    assert_eq quick "$MEASUREMENT_PROFILE" 'explicit quick choice'
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'quick insufficient remains failure'
    assert_eq 6442450944 "$MEASURE_MAX_TX_BYTES" 'quick raised hard cap'
    measurement_profile_configure standard
    measurement_budget_feasibility_gate "${HIGH_ARGS[@]}" > "$TEST_ROOT/increase.log" 2>&1 <<< $'b\n32'
    assert_eq 34359738368 "$MEASURE_MAX_TX_BYTES" 'explicit 32 GiB limit'
    assert_eq "$initialized" "$MEASURE_BUDGET_INITIALIZATION_COUNT" 'limit change reset ledger'
    assert_eq 2500000000 "$TEST_TX_BYTES_USED" 'limit change lost past traffic'
)

test_real_pre_spawn_guard_at_incident_snapshot() (
    local rc=0
    interface_counter() { fixture_interface_counter "$@"; }
    measure_require_sample_lock() { :; }
    timeout() { printf 'unexpected\n' >> "$FIXTURE_SPAWNS"; return 1; }
    printf '0\n' > "$FIXTURE_COUNTER"
    measurement_budget_configure "$(fixture_value HARD_BUDGET_BYTES)" 900
    measurement_budget_ensure eth0
    printf '%s\n' "$(fixture_value USED_TX_BYTES)" > "$FIXTURE_COUNTER"
    MEASURE_ACTIVE_STAGE=RATE_1222_RECHECK_3
    iperf_sample fixture.example 5201 7 1 1222 655 0.22191 0 shaped > "$TEST_ROOT/reserve.log" 2>&1 || rc=$?
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'production reservation rejection'
    assert_eq "$(fixture_value NEXT_RESERVATION_BYTES)" "$(measurement_sample_projected_tx 1222 7 1 655 0.22191 0 shaped)" 'exact production reservation'
    assert_eq 0 "$(wc -l < "$FIXTURE_SPAWNS")" 'real iperf timeout spawned after failed reservation'
    assert_eq "$(fixture_value USED_TX_BYTES)" "$(cat "$FIXTURE_COUNTER")" 'rejection changed actual traffic'
    (( $(cat "$FIXTURE_COUNTER") < MEASURE_MAX_TX_BYTES )) || fail 'hard budget overshoot'
)

test_normal_entry_stops_before_scan() (
    local rc=0 summary
    install_sweep_fixture
    install_high_bandwidth_samples
    measurement_budget_interactive() { return 1; }
    measurement_budget_configure 6442450944 900
    measure_sweep speedtest.hkg12.hk.leaseweb.net 5201 eth0 0 1036 1470 62 5 1 3 0.1 0 5000 auto > "$TEST_ROOT/early.log" 2>&1 || rc=$?
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'early feasibility rejection'
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq BUDGET_FEASIBILITY "$(summary_value "$summary" FAILURE_STAGE)" 'gate stage'
    assert_not_contains "$(cat "$FIXTURE_SPAWNS")" RATE_1036 'scan spawned despite known budget risk'
    assert_eq high "$(summary_value "$summary" SAMPLE_CONFIDENCE_GRADE)" 'stable saturation confidence after outlier'
    assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" 'budget-infeasible decision confidence'
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" 'no infeasible recommendation'
    assert_eq complete "$(summary_value "$summary" ROLLBACK_RESULT)" 'early rollback'
)

test_expected_and_bound_are_distinct
test_noninteractive_failure_preserves_ledger
test_explicit_quick_and_budget_choices
test_real_pre_spawn_guard_at_incident_snapshot
test_normal_entry_stops_before_scan
printf 'v8.0.8 budget feasibility: PASS\n'
