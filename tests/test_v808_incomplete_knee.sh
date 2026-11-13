#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"

test_production_late_interruption() (
    local file output
    run_production_late_interruption
    assert_eq "$MEASURE_BUDGET_RC" "$FIXTURE_RC" 'late budget interruption rc'
    assert_eq 1160 "$(summary_value "$FIXTURE_SUMMARY" LAST_CLEAN)" 'last clean audit evidence'
    assert_eq 1222 "$(summary_value "$FIXTURE_SUMMARY" SUSPECTED_BREAK)" 'partial spike suspicion'
    assert_eq '' "$(summary_value "$FIXTURE_SUMMARY" CONFIRMED_BREAK)" 'one spike is not confirmed break'
    assert_eq '' "$(summary_value "$FIXTURE_SUMMARY" CONFIRMED_KNEE)" 'no confirmed knee'
    assert_eq '' "$(summary_value "$FIXTURE_SUMMARY" KNEE_MBIT)" 'legacy knee cannot alias partial last clean'
    assert_eq 1 "$(summary_value "$FIXTURE_SUMMARY" LAST_LEVEL_SPIKE_HITS)" 'partial spike hit count'
    assert_eq 0 "$(summary_value "$FIXTURE_SUMMARY" CONFIRMED)" 'no unverified candidate'
    assert_eq '' "$(summary_value "$FIXTURE_SUMMARY" RECOMMEND)" 'no recommendation'
    assert_eq high "$(summary_value "$FIXTURE_SUMMARY" SAMPLE_CONFIDENCE_GRADE)" 'clean collected samples'
    assert_eq low "$(summary_value "$FIXTURE_SUMMARY" DECISION_CONFIDENCE_GRADE)" 'incomplete confidence'
    assert_eq low "$(summary_value "$FIXTURE_SUMMARY" CONFIDENCE_GRADE)" 'legacy confidence'
    assert_eq 982 "$(summary_value "$FIXTURE_SUMMARY" CLEAN_REFERENCE_RECEIVER_MBIT)" 'underfilled reference replaced by quorum'
    assert_eq "$(fixture_value USED_TX_BYTES)" "$(summary_value "$FIXTURE_SUMMARY" TEST_TX_BYTES_USED)" 'exact production TX snapshot'
    assert_eq RATE_1222_RECHECK_3 "$(summary_value "$FIXTURE_SUMMARY" FAILURE_STAGE)" 'reservation rejected before third experiment'
    assert_not_contains "$(cat "$FIXTURE_SPAWNS")" RATE_1222_RECHECK_3 'third iperf spawned despite reservation failure'
    assert_eq complete "$(summary_value "$FIXTURE_SUMMARY" ROLLBACK_RESULT)" 'rollback complete'
    assert_eq none "$(summary_value "$FIXTURE_SUMMARY" PERSISTENT_CHANGES)" 'no persistence commit'
    cmp -s "$TEST_ROOT/qdisc-before" "$TEST_ROOT/qdisc-after" || fail 'qdisc rollback differs'
    [[ ! -e "$CONFIG_FILE" && ! -e "$SYSCTL_FILE" && ! -e "$PERSIST_SCRIPT" ]] || fail 'incomplete scan persisted product parameters'
    (( TEST_TX_BYTES_USED < MEASURE_MAX_TX_BYTES )) || fail 'hard budget overshoot'
    file=$(peer_health_file speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5201)
    peer_health_load "$file"
    assert_eq 13 "$PH_SAMPLE_SUCCESS_COUNT" '11 production successes plus two synthetic reference rechecks'
    assert_eq 0 "$PH_COMPLETED_SWEEP_COUNT" 'incomplete sweep counted successful'
    assert_eq 0 "$PH_SUCCESS_COUNT" 'incomplete operation counted successful'
    assert_eq 4 "$PH_BUSY_COUNT" 'four busy attempts'
    assert_eq 0 "$PH_PATH_DIRTY_COUNT" 'incomplete/slow sample polluted path dirty'
    output=$(history_print_one "$FIXTURE_SUMMARY")
    assert_contains "$output" 'Knee               none/unconfirmed' 'history partial knee display'
)

test_outer_transaction_does_not_commit() (
    local rc=0
    mkdir -p "$BASELINE_DIR"
    printf 'earliest\n' > "$BASELINE_DIR/fixture-baseline"
    printf 'original-runtime\n' > "$TEST_ROOT/runtime"
    WIZARD_PEER=speedtest.hkg12.hk.leaseweb.net; WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
    action_transaction_begin_multi() { cp "$TEST_ROOT/runtime" "$TEST_ROOT/runtime-before"; }
    action_transaction_mark_mutated() { :; }
    action_transaction_rollback() { cp "$TEST_ROOT/runtime-before" "$TEST_ROOT/runtime"; }
    action_transaction_commit() { printf 'COMMITTED\n' > "$TEST_ROOT/commit"; }
    persist_current_tuning() { printf 'PERSISTED\n' > "$TEST_ROOT/persist-called"; }
    auto_tune_execute() {
        printf 'temporary-runtime\n' > "$TEST_ROOT/runtime"
        run_production_late_interruption
        return "$FIXTURE_RC"
    }
    auto_tune_run_transaction eth0 balanced mixed 0 100 1 > "$TEST_ROOT/transaction.log" 2>&1 || rc=$?
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'transaction failure propagated'
    assert_eq original-runtime "$(cat "$TEST_ROOT/runtime")" 'outer runtime restored'
    assert_eq earliest "$(cat "$BASELINE_DIR/fixture-baseline")" 'earliest baseline preserved'
    [[ ! -e "$TEST_ROOT/commit" && ! -e "$TEST_ROOT/persist-called" ]] || fail 'failed transaction committed/persisted'
    assert_eq complete "$(summary_value "$FIXTURE_SUMMARY" ROLLBACK_RESULT)" 'outer final rollback record'
)

test_spike_cooldown_preserves_budget_rc() (
    local rc=0 calls=0
    export BBRV3_MEASUREMENT_COOLDOWN=1
    interface_counter() { printf '0\n'; }
    measurement_budget_configure 6442450944 30
    measurement_budget_ensure eth0
    MEASURE_BUDGET_STARTED_EPOCH=$(($(date +%s)-25))
    sample_repeated() { fixture_metrics_row 1137.92 1.02685 1145 1; }
    measure_level_with_confirmation fixture 5201 5 7 1 rate-1222 0.1 0.13153 1222 0.92 > "$TEST_ROOT/cooldown-budget.log" 2>&1 || rc=$?
    assert_eq "$MEASURE_BUDGET_RC" "$rc" 'budget failure during cooldown was not flattened to rc1'
    assert_eq 1 "$MEASURE_LEVEL_SPIKE_HITS" 'partial spike evidence retained'
    assert_eq 0 "$MEASURE_LEVEL_SPIKE_CONFIRMED" 'incomplete cooldown confirmed a break'
    assert_eq '' "$MEASURE_LEVEL_ROW" 'incomplete spike exposed a selected row'
)

test_production_late_interruption
test_outer_transaction_does_not_commit
test_spike_cooldown_preserves_budget_rc
printf 'v8.0.8 incomplete knee / production fixture: PASS\n'
