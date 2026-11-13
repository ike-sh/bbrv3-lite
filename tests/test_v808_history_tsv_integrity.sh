#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"

assert_schema() {
    awk -F'\t' 'NR==1 {expected=NF; if(NF!=20) bad=1; for(i=1;i<=NF;i++) if(seen[$i]++)bad=1} NF!=expected {bad=1} END {exit bad}' "$1" || fail 'TSV 20-column schema/row integrity'
    assert_eq 1 "$(awk -F'\t' '$1=="TIME" {n++} END {print n+0}' "$1")" 'header is unique'
}

test_actual_writer_and_saturation_outlier() (
    local row file output
    install_sweep_fixture
    install_high_bandwidth_samples
    measurement_budget_configure 6442450944 900
    measurement_budget_ensure eth0
    measure_lock_peer speedtest.hkg12.hk.leaseweb.net eth0 5201
    MEASURE_IFACE=eth0; MEASURE_IDLE_RTT_MS=1
    new_measure_run sweep
    row=$(sample_repeated speedtest.hkg12.hk.leaseweb.net 5201 5 1 2 saturation 3 6 5000 unshaped)
    file="$MEASURE_RESULT_FILE"
    assert_schema "$file"
    assert_eq 4 "$(wc -l < "$file")" 'actual three sample rows'
    assert_eq 1138.46 "$(cut -f1 <<< "$row")" 'median selected a real receiver sample'
    assert_eq high "$(measurement_confidence "$(cut -f13 <<< "$row")" "$(cut -f12 <<< "$row")" "$(cut -f7 <<< "$row")" 0 0 100 0 | cut -f2)" 'post-recovery sample stability'
    assert_eq 0.73000 "$(awk -v s="$(cut -f12 <<< "$row")" 'BEGIN{printf "%.5f",s}')" 'robust dispersion precision'
    assert_contains "$(cat "$file")" $'1151.55\t1138.46' 'decimal precision preserved'
    output=$(sed -n '1,5l' "$file")
    assert_contains "$output" 'LOADED_RTT_MEDIAN_MS\tLOADED_RTT_P95_MS' 'raw header tab separators'
    assert_contains "$output" 'CONTAMINATED\tDURATION_SECONDS' 'raw ending header separators'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" OUTLIER 'outlier recorded'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" DISPERSION_RECHECK 'adaptive reason recorded'
    assert_contains "$(cat "$MEASURE_RUN_DIR/sample-events.tsv")" 'final-spread=' 'final stability recorded'
)

test_injection_rejected_before_append() (
    local bad before rc=0
    new_measure_run probe
    before=$(sha256sum "$MEASURE_RESULT_FILE")
    iperf_sample() { printf '90\t0\t1000000\t0.00000\t0\t2\t3\t0\t20\t0\t0\t91\t90\t1000000\t990000\t0\n'; }
    sleep() { :; }
    for bad in $'safe\tinjected' $'safe\ninjected' $'safe\rinjected'; do
        rc=0
        sample_repeated fixture 5201 3 1 1 "$bad" 1 0 100 shaped > "$TEST_ROOT/injection.log" 2>&1 || rc=$?
        assert_eq "$IPERF_DATA_RC" "$rc" 'TSV label injection rejected'
        assert_eq "$before" "$(sha256sum "$MEASURE_RESULT_FILE")" 'rejected row partially appended'
    done
    assert_schema "$MEASURE_RESULT_FILE"
)

test_legacy_history_remains_readable() (
    local summary output before
    new_measure_run sweep
    summary="$MEASURE_RUN_DIR/summary.tsv"
    printf 'TYPE\tsweep\nDECISION_CONFIDENCE_GRADE\thigh\nSAMPLE_CONFIDENCE_GRADE\thigh\nRESULT\tFAILURE\nSCAN_DECISION\tbudget-exceeded\nLAST_OK\t1160\nKNEE_MBIT\t1160\nBROKE_AT\t\nCONFIRMED\t0\nRECOMMEND\t\n' > "$summary"
    printf 'TIME\tLABEL\tGOODPUT_MBIT\tRETRANSMITS\tBYTES\tRETRANS_RATIO_EST_PERCENT\tDURATION_SECONDS\tFLOWS\nlegacy\told\t200.12\t0\t1000000\t0.00000\t3\t1\n' > "$MEASURE_RESULT_FILE"
    before=$(sha256sum "$summary" "$MEASURE_RESULT_FILE")
    output=$(history_print_one "$summary")
    assert_contains "$output" 'Last clean         1160' 'legacy last-clean alias'
    assert_contains "$output" 'Knee               none/unconfirmed' 'legacy partial knee is not confirmed'
    assert_contains "$output" 'Decision confidence low' 'legacy budget-exceeded high is not displayed'
    assert_contains "$output" 'Sample confidence  high' 'legacy sample confidence preserved'
    assert_eq "$before" "$(sha256sum "$summary" "$MEASURE_RESULT_FILE")" 'legacy history mutated by reader'
    printf 'TYPE\tsweep\nLAST_OK\t209\nKNEE_MBIT\t209\nBROKE_AT\t210\nCONFIRMED\t1\nRECOMMEND\t202\n' > "$summary"
    output=$(history_print_one "$summary")
    assert_contains "$output" 'Knee               209' 'legacy confirmed knee preserved'
    assert_contains "$output" 'Recommendation     202' 'legacy recommendation preserved'
)

test_actual_writer_and_saturation_outlier
test_injection_rejected_before_append
test_legacy_history_remains_readable
assert_schema "$FIXTURE_DIR/samples.tsv"
printf 'v8.0.8 history TSV integrity: PASS\n'
