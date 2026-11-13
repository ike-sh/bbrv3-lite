#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
# shellcheck source=helpers/v808-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/v808-fixture.sh"

test_busy_retry_success_has_separate_units() (
    local file row output calls="$TEST_ROOT/transport-calls" used score_before score_after
    install_sweep_fixture
    measurement_budget_configure 67108864 900
    measurement_budget_ensure eth0
    measure_lock_peer speedtest.hkg12.hk.leaseweb.net eth0 5201
    MEASURE_IFACE=eth0
    measure_require_sample_lock() { :; }; measure_peer_route_guard() { :; }
    uname() { printf 'FixtureOS\n'; }
    background_tx_percent() { printf '0\n'; }
    cpu_delta_metrics() { printf '20\t0\n'; }; cpu_core_delta_metrics() { printf '20\t0\n'; }
    latency_stats_from_file() { printf '2\t3\n'; }
    printf '0\n' > "$calls"
    timeout() {
        local n
        n=$(<"$calls"); ((n+=1)); printf '%s\n' "$n" > "$calls"
        if (( n == 1 )); then
            fixture_charge 2048
            printf '{"error":"the server is busy running a test"}\n'
        else
            fixture_charge 1100000
            printf '{"end":{"sum_sent":{"bits_per_second":8000000,"bytes":1000000,"retransmits":0},"sum_received":{"bits_per_second":7800000,"bytes":975000}}}\n'
        fi
    }
    new_measure_run probe
    row=$(sample_repeated speedtest.hkg12.hk.leaseweb.net 5201 3 1 1 busy-then-success 1 0 8 shaped)
    file=$(peer_health_file speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5201)
    peer_health_load "$file"
    assert_eq 1 "$PH_SAMPLE_SUCCESS_COUNT" 'valid iperf sample counter'
    assert_eq 0 "$PH_SUCCESS_COUNT" 'sample is not a completed operation'
    assert_eq 0 "$PH_COMPLETED_SWEEP_COUNT" 'sample is not a completed sweep'
    assert_eq 1 "$PH_BUSY_COUNT" 'busy attempt counter'
    assert_eq BS "$PH_SAMPLE_RECENT_WINDOW" 'availability uses only iperf attempts'
    assert_eq 0 "$PH_TEMPORARY_PENALTY_UNTIL" 'live successful sample clears busy penalty'
    measurement_usage_update
    assert_eq 1102048 "$TEST_TX_BYTES_USED" 'busy and successful retry share real TX ledger'
    assert_eq 1 "$MEASURE_BUDGET_INITIALIZATION_COUNT" 'retry reset global budget'
    measurement_peer_health_finalize speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5201 70 1 7.8 clean
    peer_health_load "$file"
    assert_eq 0 "$PH_SUCCESS_COUNT" 'incomplete sweep counted as complete'
    measurement_peer_health_finalize speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5201 0 1 7.8 clean '' sweep
    peer_health_load "$file"
    assert_eq 1 "$PH_SUCCESS_COUNT" 'legacy operation success'
    assert_eq 1 "$PH_COMPLETED_SWEEP_COUNT" 'explicit completed sweep success'
    assert_eq 1 "$PH_SAMPLE_SUCCESS_COUNT" 'operation inflated sample counter'
    assert_eq BS "$PH_SAMPLE_RECENT_WINDOW" 'operation inflated attempt window'
    output=$(peers_show)
    for used in 'Sample success' 'Completed sweeps' 'Completed ops' 'Busy attempts' 'Reset attempts' 'Timeout attempts'; do
        assert_contains "$output" "$used" 'explicit counter unit'
    done
    # Busy recency expires from the sample window; penalties expire by time.
    peer_health_record speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5202 failure peer-busy na na unknown
    score_before=$(peer_health_score speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5202 1 | cut -f1)
    peer_health_record_sample_success speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5202 1 7.8
    score_after=$(peer_health_score speedtest.hkg12.hk.leaseweb.net 4 64.120.117.34 5202 1 | cut -f1)
    (( score_after > score_before )) || fail 'sample success does not improve endpoint availability'
    assert_not_contains "$(peers_show)" nams 'unknown RTT concatenation'
)

test_legacy_cache_and_unknown_rtt() (
    local host=speedtest.hkg12.hk.leaseweb.net file old output
    peer_health_record "$host" 6 2001:db8::1 5209 failure peer-reset na na unknown
    file=$(peer_health_file "$host" 6 2001:db8::1 5209)
    old="$TEST_ROOT/legacy-health.tsv"
    awk -F'\t' 'BEGIN {OFS="\t"} $1=="SCHEMA" {$2=1} $1!~/^(SAMPLE_SUCCESS_COUNT|COMPLETED_SWEEP_COUNT|SAMPLE_RECENT_WINDOW|SAMPLE_COUNTERS_SINCE)$/ {print}' "$file" > "$old"
    cp "$old" "$file"
    peer_health_load "$file"
    assert_eq 0 "$PH_SAMPLE_COUNTERS_SINCE" 'legacy sample units fabricated'
    output=$(peers_show)
    assert_contains "$output" n/a 'missing RTT display'
    assert_not_contains "$output" nams 'missing RTT suffix'
    peer_health_record_sample_success "$host" 6 2001:db8::1 5209 na 100
    peer_health_load "$file"
    assert_eq 1 "$PH_SAMPLE_SUCCESS_COUNT" 'legacy cache migrated on new sample'
    assert_eq 1 "$PH_RESET_COUNT" 'legacy reset history retained'
    assert_eq 0 "$PH_PATH_DIRTY_COUNT" 'transport reset is not path dirty'
    assert_eq 2 "$(summary_value "$file" SCHEMA)" 'peer cache schema migration'
    [[ "$(peer_health_file "$host" 4 203.0.113.1 5209)" != "$file" ]] || fail 'family/address unit scope'
    [[ "$(peer_health_file "$host" 6 2001:db8::1 5210)" != "$file" ]] || fail 'port unit scope'
    sed -i 's/^SCHEMA\t2$/SCHEMA\t99/' "$file"
    printf 'FUTURE_COUNTER\t1\n' >> "$file"
    old=$(sha256sum "$file")
    if peer_health_record_sample_success "$host" 6 2001:db8::1 5209 na 100 >/dev/null 2>&1; then fail 'future schema overwritten'; fi
    assert_eq "$old" "$(sha256sum "$file")" 'future schema including unknown keys is immutable'
)

test_busy_retry_success_has_separate_units
test_legacy_cache_and_unknown_rtt
printf 'v8.0.8 peer health semantics: PASS\n'
