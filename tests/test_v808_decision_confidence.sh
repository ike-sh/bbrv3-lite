#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"

test_state_matrix() {
    local name rc decision quality confirmed no_knee broke reject expected result grade
    while IFS='|' read -r name rc decision quality confirmed no_knee broke reject expected; do
        result=$(measurement_decision_confidence 100 high clean "$rc" "$decision" "$quality" "$confirmed" "$no_knee" "$broke" "$reject")
        grade=$(cut -f2 <<< "$result")
        assert_eq "$expected" "$grade" "$name decision confidence"
        if [[ "$expected" == low ]]; then assert_eq 0 "$(cut -f1 <<< "$result")" "$name confidence score"; fi
    done <<'MATRIX'
budget-exceeded|70|budget-exceeded|clean|0|0||budget-exceeded|low
peer-unavailable|75|inconclusive-peer-unavailable|clean|0|0||peer-unavailable|low
bad-baseline|2|inconclusive|bad|0|0|||low
path-dirty|68|path-dirty|dirty|0|0||path-dirty|low
unstable-samples|67|inconclusive|clean|0|0||measurement-unstable|low
no-confirmed-knee|0|inconclusive|clean|0|0|||low
candidate-not-confirmed|0|recommend|clean|0|0|1222||low
clean-no-policer-completed|0|no-knee-clean|clean|0|1|||high
confirmed-policer|0|recommend|clean|1|0|210||high
final-verify-failed|2|recommend|clean|1|0|210|final-verify-failed|low
unknown-verdict|0|unknown|clean|1|0|210||low
MATRIX
    assert_eq high "$(measurement_confidence 3 0.73 3 0 0 100 0 | cut -f2)" 'clean collected sample confidence'
}

test_terminal_errors_never_inherit_high() (
    local error rc summary
    install_sweep_fixture
    measurement_budget_feasibility_gate() { :; }
    for error in "$IPERF_UNAVAILABLE_RC" "$IPERF_UNSTABLE_RC" "$IPERF_CONTAMINATED_RC"; do
        sample_repeated() {
            case "$6" in
                saturation) fixture_metrics_row 1138.46 9.31623 1151.55 3 ;;
                path-control) fixture_metrics_row 485.33 0.04603 488.13 3 ;;
                *) return "$error" ;;
            esac
        }
        rc=0
        measure_sweep speedtest.hkg12.hk.leaseweb.net 5201 eth0 0 1036 1470 62 5 1 3 0.1 0 5000 auto > "$TEST_ROOT/error-${error}.log" 2>&1 || rc=$?
        assert_eq "$error" "$rc" "terminal rc ${error}"
        summary="$MEASURE_RUN_DIR/summary.tsv"
        assert_eq high "$(summary_value "$summary" SAMPLE_CONFIDENCE_GRADE)" 'preserved telemetry quality'
        assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" 'incomplete decision'
        assert_eq low "$(summary_value "$summary" CONFIDENCE_GRADE)" 'legacy confidence alias'
        assert_eq '' "$(summary_value "$summary" RECOMMEND)" 'no incomplete recommendation'
    done
)

test_final_verify_rejection_is_low() (
    local rc=0 summary
    install_sweep_fixture
    recommended_verify_flows() { printf '4\n'; }
    sample_repeated() { fixture_metrics_row 60 0 65 3; }
    measure_verify fixture.example 5201 eth0 3 100 0.9 0 0.1 > "$TEST_ROOT/verify.log" 2>&1 || rc=$?
    assert_eq 2 "$rc" 'final verify rejection rc'
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq high "$(summary_value "$summary" SAMPLE_CONFIDENCE_GRADE)" 'verify telemetry'
    assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" 'failed final verification decision'
    assert_eq low "$(summary_value "$summary" CONFIDENCE_GRADE)" 'verify legacy confidence'
    assert_eq 0 "$(summary_value "$summary" ACCEPTED)" 'final verify criteria preserved'
)

test_outer_failure_invalidates_successful_sweep() (
    local summary
    new_measure_run sweep
    summary="$MEASURE_RUN_DIR/summary.tsv"
    printf 'TYPE\tsweep\nSAMPLE_CONFIDENCE_SCORE\t100\nSAMPLE_CONFIDENCE_GRADE\thigh\nSAMPLE_CONFIDENCE_REASONS\tclean\nRECOMMEND\t202\nCONFIRMED\t1\nKNEE_MBIT\t209\nCONFIRMED_KNEE\t209\n' > "$summary"
    failure_finalize_outer_rollback "$summary" 2 0
    assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" 'outer failure decision confidence'
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" 'outer failure recommendation'
    assert_eq high "$(summary_value "$summary" SAMPLE_CONFIDENCE_GRADE)" 'outer failure telemetry'
    assert_eq complete "$(summary_value "$summary" ROLLBACK_RESULT)" 'outer rollback complete'
)

test_final_verify_failure_invalidates_originating_sweep() (
    local rc=0 sweep_summary
    WIZARD_PEER=""
    action_transaction_begin_multi() { :; }; action_transaction_mark_mutated() { :; }
    action_transaction_commit() { fail 'failed verification committed transaction'; }
    action_transaction_rollback() { :; }
    auto_tune_execute() {
        new_measure_run sweep
        sweep_summary="$MEASURE_RUN_DIR/summary.tsv"
        printf 'TYPE\tsweep\nSAMPLE_CONFIDENCE_SCORE\t100\nSAMPLE_CONFIDENCE_GRADE\thigh\nSAMPLE_CONFIDENCE_REASONS\tclean\nRECOMMEND\t202\nCONFIRMED\t1\nKNEE_MBIT\t209\n' > "$sweep_summary"
        AUTO_SWEEP_SUMMARY="$sweep_summary"
        new_measure_run verify
        failure_set FINAL_VERIFY verify-throughput-failed 'receiver below expected threshold' '' 2
        measurement_finalize_run verify fixture 5201 eth0 2 complete
        return 2
    }
    auto_tune_run_transaction eth0 balanced mixed 0 100 1 > "$TEST_ROOT/outer-verify.log" 2>&1 || rc=$?
    assert_eq 2 "$rc" 'final verification failure propagated'
    assert_eq low "$(summary_value "$sweep_summary" DECISION_CONFIDENCE_GRADE)" 'originating sweep downgraded'
    assert_eq '' "$(summary_value "$sweep_summary" RECOMMEND)" 'originating recommendation cleared'
    assert_eq high "$(summary_value "$sweep_summary" SAMPLE_CONFIDENCE_GRADE)" 'originating telemetry retained'
)

test_state_matrix
test_terminal_errors_never_inherit_high
test_final_verify_rejection_is_low
test_outer_failure_invalidates_successful_sweep
test_final_verify_failure_invalidates_originating_sweep
printf 'v8.0.8 decision confidence: PASS\n'
