#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"
P3_FIXTURE="$ROOT_DIR/tests/fixtures/v808-p3-budget-semantics"
P3_ARGS=(1142.86 1148.28 0 1040 1569 76 5 0 0 490.17 514 3)
budget_test_cleanup() {
    local rc=$? file
    if (( rc != 0 )); then
        for file in "$TEST_ROOT"/*.log; do [[ ! -f "$file" ]] || tail -25 "$file" >&2; done
    fi
    rm -rf -- "$TEST_ROOT"
}
trap budget_test_cleanup EXIT

prepare_budget_case() {
    interface_counter() { fixture_interface_counter "$@"; }
    printf '0\n' > "$FIXTURE_COUNTER"
    measurement_profile_configure standard
    measurement_budget_configure 6442450944 900
    measurement_budget_ensure eth0
    new_measure_run sweep
    printf 'TYPE\tsweep\nSAMPLE_CONFIDENCE_SCORE\t100\nSAMPLE_CONFIDENCE_GRADE\thigh\n' > "$MEASURE_RUN_DIR/summary.tsv"
}

assert_budget_failure() {
    local subtype="$1" summary="$MEASURE_RUN_DIR/summary.tsv" failure="$MEASURE_RUN_DIR/failure.tsv" key
    assert_eq 70 "$(summary_value "$summary" INTERNAL_RC)" 'RC70 compatibility'
    assert_eq budget-exceeded "$(summary_value "$summary" FAILURE_REASON)" 'reason compatibility'
    assert_eq FAILURE "$(summary_value "$summary" RESULT)" 'failure not success'
    assert_eq "$subtype" "$(summary_value "$summary" BUDGET_FAILURE_SUBTYPE)" 'budget classification'
    assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" 'incomplete decision confidence'
    assert_eq 0 "$(summary_value "$summary" CONFIRMED)" 'no confirmed candidate'
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" 'no recommendation'
    assert_eq '' "$(summary_value "$summary" CONFIRMED_KNEE)" 'no confirmed knee'
    for key in "${BUDGET_DIAGNOSTIC_KEYS[@]}"; do
        assert_eq "$(summary_value "$summary" "$key")" "$(summary_value "$failure" "$key")" 'summary/failure budget snapshot mismatch'
    done
    assert_eq "$(summary_value "$summary" SUGGESTED_ACTION)" "$(summary_value "$failure" SUGGESTION)" 'suggestion consistency'
    history_schema_supported "$summary" || fail 'additive schema-1 metadata rejected'
    if [[ "$subtype" != exhausted ]]; then
        assert_not_contains "$(cat "$failure")$(failure_summary_print "$summary")$(history_latest)" 已耗尽 'false exhaustion claim'
    fi
}

test_exhausted_and_reservation_cases() (
    local rc=0
    prepare_budget_case
    printf '6442450944\n' > "$FIXTURE_COUNTER"
    measurement_budget_check SAMPLE 1 1 > "$TEST_ROOT/exhausted.log" 2>&1 || rc=$?
    assert_eq 70 "$rc" 'actual exhausted guard'
    measurement_finalize_run sweep fixture.example 5201 eth0 "$rc" complete
    assert_budget_failure exhausted
    assert_eq 0 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_REMAINING_BYTES)" 'actual no budget'
    assert_contains "$(failure_summary_print "$MEASURE_RUN_DIR/summary.tsv")" 已耗尽 'actual exhaustion explanation'

    prepare_budget_case; rc=0
    printf '5739233591\n' > "$FIXTURE_COUNTER"
    # Same exact-boundary guard and pending-file path as real iperf_sample.
    (measurement_budget_check RATE_1222_RECHECK_3 1200981349 27) > "$TEST_ROOT/reservation.log" 2>&1 || rc=$?
    assert_eq 70 "$rc" 'positive remainder reservation guard'
    # A later counter read must not relabel the original reservation incident.
    printf '6442450944\n' > "$FIXTURE_COUNTER"
    measurement_finalize_run sweep fixture.example 5201 eth0 "$rc" complete
    assert_budget_failure insufficient-reservation
    assert_eq 5739233591 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_USED_BYTES)" 'incident snapshot preserved across subshell'
    assert_eq 703217353 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_REMAINING_BYTES)" 'incident positive remainder'
    assert_eq 6442450944 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" TEST_TX_BYTES_USED)" 'final counter still authoritative'
    assert_eq 0 "$(wc -l < "$FIXTURE_SPAWNS")" 'no iperf spawn'
)

test_duration_classification_and_boundary() (
    local rc=0
    prepare_budget_case
    MEASURE_BUDGET_STARTED_EPOCH=$(($(date +%s)-900))
    measurement_budget_check TIME 0 0 >/dev/null 2>&1 || rc=$?
    measurement_finalize_run sweep fixture.example 5201 eth0 "$rc" complete
    assert_budget_failure exhausted
    assert_eq 6442450944 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_REMAINING_BYTES)" 'time exhaustion is not TX exhaustion'
    assert_contains "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_FEASIBILITY_REASON)" actual-duration-limit 'time dimension'

    prepare_budget_case; rc=0
    MEASURE_BUDGET_STARTED_EPOCH=$(($(date +%s)-895))
    measurement_budget_check TIME 0 10 >/dev/null 2>&1 || rc=$?
    measurement_finalize_run sweep fixture.example 5201 eth0 "$rc" complete
    assert_budget_failure insufficient-reservation
    assert_contains "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_FEASIBILITY_REASON)" next-duration-reservation 'time reservation'

    prepare_budget_case; rc=0
    measurement_budget_check BOUNDARY 6442450944 0 >/dev/null 2>&1 || rc=$?
    measurement_finalize_run sweep fixture.example 5201 eth0 "$rc" complete
    assert_budget_failure insufficient-reservation
    assert_eq 6442450944 "$(summary_value "$MEASURE_RUN_DIR/summary.tsv" BUDGET_REMAINING_BYTES)" 'equality rejection has available budget'
)

install_p3_sweep() {
    install_sweep_fixture
    rm -f -- "$TEST_ROOT"/p3-*-count
    FIXTURE_DIR="$P3_FIXTURE"
    # Only the clock and I/O are fixtures; the gate and finalizers are real.
    date() { if [[ "$*" == +%s ]]; then printf '1000\n'; else command date "$@"; fi; }
    measurement_profile_configure standard
    measurement_budget_configure 6442450944 900
    MEASURE_BUDGET_STARTED_EPOCH=951
    iperf_sample() {
        local stage="$MEASURE_ACTIVE_STAGE" label index_file index=0 row bytes
        measurement_budget_reserve_sample "$stage" "$5" "$3" "$4" "${6:-0}" "${7:-0}" "${8:-0}" "${9:-aggregate}" || return $?
        printf '%s\n' "$stage" >> "$FIXTURE_SPAWNS"
        case "$stage" in SATURATION|PATH_CONTROL) ;; *) fail 'scan spawned after known budget risk' ;; esac
        index_file="$TEST_ROOT/p3-$stage-count"
        [[ ! -f "$index_file" ]] || index=$(<"$index_file")
        ((index+=1)); printf '%s\n' "$index" > "$index_file"
        label="${stage,,}"; label="${label//_/-}"
        row=$(fixture_sample_row "$label" "$index")
        [[ -n "$row" ]] || fail 'unexpected extra P3 sample'
        bytes=$(cut -f6 <<< "$row")
        fixture_charge "$bytes"
        if [[ "$stage" == PATH_CONTROL && "$index" == 3 ]]; then
            printf '%s\n' "$(summary_value "$P3_FIXTURE/context.tsv" USED_TX_BYTES)" > "$FIXTURE_COUNTER"
        fi
        fixture_raw_row "$row"
    }
}

run_p3_sweep() {
    local rc=0
    install_p3_sweep
    measure_sweep fixture.example 5201 eth0 0 0 0 0 5 1 3 0.1 0 5000 manual > "$TEST_ROOT/p3.log" 2>&1 || rc=$?
    assert_eq 70 "$rc" 'P3 early feasibility RC70'
}

test_p3_actual_telemetry_replay() (
    local summary failure output key
    run_p3_sweep
    summary="$MEASURE_RUN_DIR/summary.tsv"; failure="$MEASURE_RUN_DIR/failure.tsv"
    assert_budget_failure feasibility-rejected
    assert_eq 1142.86 "$(summary_value "$summary" CAPACITY_RECEIVER_MBIT)" 'P3 measured capacity'
    assert_eq 14640332764 "$(summary_value "$summary" BUDGET_REQUIRED_RESERVATION_BYTES)" 'actual gate uses expected plan'
    assert_eq 757319478624 "$(summary_value "$summary" CONSERVATIVE_REMAINING_UPPER_BOUND)" 'upper remains distinct'
    assert_eq 2562106393 "$(summary_value "$summary" BUDGET_USED_BYTES)" 'P3 gate counter'
    assert_eq 3880344551 "$(summary_value "$summary" BUDGET_REMAINING_BYTES)" 'P3 still has budget'
    assert_eq 49 "$(summary_value "$summary" BUDGET_USED_SECONDS)" 'P3 elapsed clock'
    assert_eq standard "$MEASUREMENT_PROFILE" 'no silent quick downgrade'
    assert_eq 6442450944 "$MEASURE_MAX_TX_BYTES" 'no budget increase'
    assert_eq budget-exceeded "$(summary_value "$summary" SCAN_DECISION)" 'stable scan decision'
    assert_eq MEASUREMENT_BUDGET_EXCEEDED "$(summary_value "$summary" MEASUREMENT_STATE)" 'stable state'
    assert_eq complete "$(summary_value "$summary" ROLLBACK_RESULT)" 'rollback'
    assert_eq none "$(summary_value "$summary" PERSISTENT_CHANGES)" 'no persistence'
    cmp -s "$TEST_ROOT/qdisc-before" "$TEST_ROOT/qdisc-after" || fail 'qdisc fixture not restored'
    [[ ! -e "$CONFIG_FILE" && ! -e "$SYSCTL_FILE" && ! -e "$PERSIST_SCRIPT" ]] || fail 'unverified config committed'
    assert_eq 5 "$(wc -l < "$FIXTURE_SPAWNS")" 'two saturation and three control samples only'
    output=$(history_list)
    assert_contains "$output" feasibility-rejected 'history list subtype'
    assert_eq "$(history_latest)" "$(history_show "${MEASURE_RUN_DIR##*/}")" 'latest/show consistent'
    assert_not_contains "$(cat "$TEST_ROOT/p3.log")" 已耗尽 'CLI misleading exhaustion'
    if [[ -n "${BBRV3_RC1_EVIDENCE_DIR:-}" ]]; then
        mkdir -p "$BBRV3_RC1_EVIDENCE_DIR"
        cp "$summary" "$failure" "$MEASURE_RUN_DIR/budget-plan.tsv" "$MEASURE_RUN_DIR/samples.tsv" "$BBRV3_RC1_EVIDENCE_DIR/"
        cp "$TEST_ROOT/p3.log" "$BBRV3_RC1_EVIDENCE_DIR/cli.log"
        history_latest > "$BBRV3_RC1_EVIDENCE_DIR/history.txt"
    fi
)

test_sufficient_and_quick_feasible_budgets() (
    local rc=0 quick
    prepare_budget_case
    printf '2562106393\n' > "$FIXTURE_COUNTER"
    MEASURE_MAX_TX_BYTES=$((20*1073741824))
    measurement_budget_feasibility_gate "${P3_ARGS[@]}" > "$TEST_ROOT/enough.log" 2>&1
    assert_eq '' "$FAILURE_BUDGET_CONTEXT" 'successful feasibility is not a failure'
    assert_eq standard "$MEASUREMENT_PROFILE" 'successful profile unchanged'

    MEASURE_MAX_TX_BYTES=$((15*1073741824))
    quick=$(measurement_remaining_plan quick "${P3_ARGS[@]}")
    (( $(summary_value /dev/stdin EXPECTED_REMAINING_TX <<< "$quick") < MEASURE_MAX_TX_BYTES-2562106393 )) || fail 'quick fixture not feasible'
    measurement_budget_feasibility_gate "${P3_ARGS[@]}" > "$TEST_ROOT/quick-option.log" 2>&1 || rc=$?
    assert_eq 70 "$rc" 'noninteractive standard must still fail'
    assert_eq standard "$MEASUREMENT_PROFILE" 'feasible quick not silently selected'
    assert_eq "$((15*1073741824))" "$MEASURE_MAX_TX_BYTES" 'no automatic budget increase'
    assert_contains "$(cat "$TEST_ROOT/quick-option.log")" --measurement-profile 'explicit rerun option'
)

test_outer_rollback_keeps_budget_diagnosis() (
    local rc=0
    printf 'original\n' > "$TEST_ROOT/runtime"
    WIZARD_PEER=fixture.example; WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
    action_transaction_begin_multi() { cp "$TEST_ROOT/runtime" "$TEST_ROOT/runtime-before"; }
    action_transaction_mark_mutated() { :; }
    action_transaction_rollback() { cp "$TEST_ROOT/runtime-before" "$TEST_ROOT/runtime"; }
    action_transaction_commit() { fail 'budget failure committed transaction'; }
    auto_tune_execute() { printf 'temporary\n' > "$TEST_ROOT/runtime"; run_p3_sweep; return 70; }
    auto_tune_run_transaction eth0 balanced mixed 0 100 1 > "$TEST_ROOT/outer.log" 2>&1 || rc=$?
    assert_eq 70 "$rc" 'outer RC70 compatibility'
    assert_eq original "$(cat "$TEST_ROOT/runtime")" 'outer state restored'
    assert_budget_failure feasibility-rejected
)

test_legacy_records_are_read_only_and_not_guessed() (
    local dir="$HISTORY_DIR/20261112T220549Z-sweep" before output
    mkdir -p "$dir"
    cp "$P3_FIXTURE/legacy-summary.tsv" "$dir/summary.tsv"
    cp "$P3_FIXTURE/legacy-failure.tsv" "$dir/failure.tsv"
    before=$(sha256sum "$dir/summary.tsv" "$dir/failure.tsv")
    assert_contains "$(cat "$dir/failure.tsv")" 已耗尽 'old build reproduced misleading text'
    output="$(history_show 20261112T220549Z-sweep)$(failure_summary_print "$dir/summary.tsv")"
    assert_contains "$output" feasibility-rejected 'old P3 stage classification'
    assert_not_contains "$output" 已耗尽 'new reader repeats old false claim'
    assert_eq "$before" "$(sha256sum "$dir/summary.tsv" "$dir/failure.tsv")" 'legacy evidence rewritten'

    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tFAILURE\nFAILURE_REASON\tbudget-exceeded\nFAILURE_STAGE\tRATE_1222_RECHECK_3\nMAX_TEST_TX_BYTES\t6442450944\nTEST_TX_BYTES_USED\t5739235251\nFAILURE_DETAIL\tTX=5739233591/6442450944 bytes; reserved-next=1200981349; duration=121/900s; reserved-time-next=27s\n' > "$dir/summary.tsv"
    output=$(history_show 20261112T220549Z-sweep)
    assert_contains "$output" insufficient-reservation 'legacy guard classified from recorded detail'
    assert_contains "$output" '703217353 bytes' 'legacy incident snapshot precedes final counter'
    assert_not_contains "$output" 已耗尽 'legacy reservation is not exhaustion'

    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tFAILURE\nFAILURE_REASON\tbudget-exceeded\n' > "$dir/summary.tsv"
    output=$(history_show 20261112T220549Z-sweep)
    assert_contains "$output" unknown 'missing historical subtype remains unknown'
    assert_not_contains "$output" 已耗尽 'legacy missing evidence guessed exhausted'
    printf 'MAX_TEST_TX_BYTES\t6442450944\nTEST_TX_BYTES_USED\t$(touch %s)\n' "$TEST_ROOT/injected" >> "$dir/summary.tsv"
    output=$(history_show 20261112T220549Z-sweep)
    [[ ! -e "$TEST_ROOT/injected" ]] || fail 'historical budget value executed'
    assert_contains "$output" unknown 'invalid historical counter is not exhaustion'
    rm -f -- "$dir/summary.tsv"
    failure_record_write "$dir" SAMPLE budget-exceeded 'legacy detail' 70 complete none
    assert_eq unknown "$(summary_value "$dir/failure.tsv" BUDGET_FAILURE_SUBTYPE)" 'standalone failure writer compatibility'
    assert_not_contains "$(summary_value "$dir/failure.tsv" EXPLANATION)" 已耗尽 'standalone writer fabricated exhaustion'
)

test_exhausted_and_reservation_cases
test_duration_classification_and_boundary
test_p3_actual_telemetry_replay
test_sufficient_and_quick_feasible_budgets
test_outer_rollback_keeps_budget_diagnosis
test_legacy_records_are_read_only_and_not_guessed
printf 'v8.0.8 P3-RC1 budget failure semantics: PASS\n'
