#!/usr/bin/env bash
# Post-implementation hardening and production peer-churn regression for v8.0.6.
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
export BBRV3_SKIP_MEASUREMENT_PREFLIGHT=1
export BBRV3_MEASUREMENT_COOLDOWN=0

# shellcheck source=/dev/null
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
assert_between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN {exit !(v>=lo && v<=hi)}' || fail "$4: $1 not in [$2,$3]"; }

make_row() {
    local receiver="$1" loss="$2" sender="${3:-$1}" fallback="${4:-0}" bytes=100000000 retrans
    retrans=$(awk -v l="$loss" -v b="$bytes" 'BEGIN {printf "%d",l*(b/1448)/100}')
    printf '%s\t%s\t%s\t%s\t0.000\t1\t2\t0\t10\t0\t0\t0.00\t1\t1\t%s\t%s\t%s\t%s\t%s\n' \
        "$receiver" "$retrans" "$bytes" "$loss" "$sender" "$receiver" "$bytes" "$bytes" "$fallback"
}

install_measurement_fixture_mocks() {
    require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
    qdisc_guard() { :; }; interface_counter() { printf '0\n'; }
    measure_lock_peer() {
        local address=203.0.113.10
        case "$1" in
            speedtest.hkg12.hk.leaseweb.net) address=203.0.113.20 ;;
            speedtest.sin1.sg.leaseweb.net) address=203.0.113.30 ;;
        esac
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS="$address"; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
        path_state_reset; PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
        PATH_ROUTE_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        PATH_ENDPOINT_FINGERPRINT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    }
    measure_require_locked_port() { :; }
    hardware_profile_values() {
        HARDWARE_CLASS=standard; HARDWARE_LINK_MBIT=1000; HARDWARE_LINK_TRUST=virtual-untrusted
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1; EFFECTIVE_BANDWIDTH_MBIT=1000; HARDWARE_CPU_COUNT=2
    }
    measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=12; PATH_RTT_MEDIAN_MS=12; }
    path_profile_tuning_gate() { :; }
    measure_append_locked_peer_summary() {
        printf 'LOCKED_ADDRESS\t%s\nLOCKED_SOURCE\t%s\nLOCKED_INTERFACE\teth0\nLOCKED_FAMILY\t4\nLOCKED_PORT\t%s\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_RTT_P95_MS\t12\n' \
            "$MEASURE_PEER_ADDRESS" "$MEASURE_PEER_SOURCE" "$MEASURE_PEER_PORT" "$PATH_ROUTE_FINGERPRINT" "$PATH_ENDPOINT_FINGERPRINT" >> "$1"
    }
    measure_begin() { MEASURE_IFACE=eth0; measurement_budget_ensure eth0; }
    measure_restore() { MEASURE_IFACE=""; measure_clear_peer_lock; }
    traffic_report() { :; }; apply_fq() { :; }; apply_shaping() { :; }
}

test_global_operation_budget_lifetime() (
    local counter="$TEST_ROOT/global-budget-counter" before start rc=0 gib=$((1024*1024*1024))
    printf '0\n' > "$counter"
    interface_counter() { case "$2" in tx_bytes) cat "$counter" ;; rx_bytes) printf '%s\n' "$(( $(<"$counter") / 9 ))" ;; esac; }
    before="$MEASURE_BUDGET_INITIALIZATION_COUNT"
    measurement_budget_configure "$((6*gib))" 900
    start="$MEASURE_BUDGET_STARTED_EPOCH"
    measurement_budget_ensure eth0
    printf '%s\n' "$((1*gib))" > "$counter"; measurement_budget_check PEER_A
    measurement_budget_ensure eth0
    printf '%s\n' "$((17*gib/10))" > "$counter"; measurement_budget_check PEER_B
    measurement_budget_ensure eth0
    printf '%s\n' "$((37*gib/10))" > "$counter"; measurement_budget_check PEER_C_SWEEP
    measurement_budget_ensure eth0
    printf '%s\n' "$((39*gib/10))" > "$counter"; measurement_budget_check FINAL_VERIFY_FAILED
    measurement_budget_ensure eth0
    printf '%s\n' "$((45*gib/10))" > "$counter"; measurement_budget_check FINAL_VERIFY_ALT_PORT
    assert_eq "$((before+1))" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "operation budget initialized more than once"
    assert_eq "$start" "$MEASURE_BUDGET_STARTED_EPOCH" "operation start time reset on failover"
    assert_eq "$((45*gib/10))" "$TEST_TX_BYTES_USED" "operation TX did not accumulate across peers/ports"
    assert_eq eth0 "$MEASURE_BUDGET_IFACE" "operation accounting interface"
    assert_between "$((MEASURE_MAX_TX_BYTES-TEST_TX_BYTES_USED))" "$((15*gib/10-1))" "$((15*gib/10+1))" "remaining operation budget"

    printf '0\n' > "$counter"
    measurement_budget_configure "$((6*gib))" 900; measurement_budget_ensure eth0
    printf '%s\n' "$((57*gib/10))" > "$counter"
    if measurement_budget_check FINAL_VERIFY "$((4*gib/10))" >/dev/null 2>&1; then
        fail "a sample projected past the operation cap was allowed to start"
    else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "projected final-verify budget rc"
    assert_eq FINAL_VERIFY "$MEASURE_BUDGET_STAGE" "projected budget stage"
    assert_eq "$((57*gib/10))" "$TEST_TX_BYTES_USED" "projected rejection changed actual traffic accounting"
)

test_formal_peer_precheck_traffic_is_accounted() (
    local counter="$TEST_ROOT/precheck-counter" mib=$((1024*1024)) before start
    printf '0\n' > "$counter"
    interface_counter() { case "$2" in tx_bytes) cat "$counter" ;; rx_bytes) printf '0\n' ;; esac; }
    detect_interface() { printf 'eth0\n'; }
    measure_lock_peer() {
        printf '%s\n' "$(( $(<"$counter") + $5 ))" > "$counter"
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
    }
    before="$MEASURE_BUDGET_INITIALIZATION_COUNT"
    measurement_budget_configure "$((64*mib))" 900
    start="$MEASURE_BUDGET_STARTED_EPOCH"
    measure_lock_requested_peer example.test 5201 eth0 '' "$mib"
    assert_eq "$mib" "$TEST_TX_BYTES_USED" "first formal peer precheck traffic"
    measure_lock_requested_peer example.test 5202 eth0 '' "$((mib/2))"
    assert_eq "$((mib+mib/2))" "$TEST_TX_BYTES_USED" "retry/alternate-port precheck traffic"
    assert_eq "$((before+1))" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "formal prechecks reset the operation budget"
    assert_eq "$start" "$MEASURE_BUDGET_STARTED_EPOCH" "formal prechecks reset operation time"
)

test_budget_exhaustion_rolls_back_without_commit() (
    local gib=$((1024*1024*1024)) counter="$TEST_ROOT/exhaust-counter" dir="$HISTORY_DIR/20260915T120000Z-verify"
    local outer_rollback="$TEST_ROOT/exhaust-outer-rollback" temporary_restore="$TEST_ROOT/exhaust-temp-restore" committed="$TEST_ROOT/exhaust-commit" rc=0 init
    mkdir -p "$dir"; printf '0\n' > "$counter"
    interface_counter() { case "$2" in tx_bytes) cat "$counter" ;; rx_bytes) printf '0\n' ;; esac; }
    init="$MEASURE_BUDGET_INITIALIZATION_COUNT"; measurement_budget_configure "$((6*gib))" 900; measurement_budget_ensure eth0
    action_transaction_begin_multi() { ACTION_TRANSACTION_DIR="$TEST_ROOT/exhaust-transaction"; }
    action_transaction_mark_mutated() { :; }
    action_transaction_rollback() { : > "$outer_rollback"; ACTION_TRANSACTION_DIR=""; }
    auto_tune_execute() {
        local inner_rc=0
        MEASURE_RUN_DIR="$dir"
        printf 'HISTORY_SCHEMA\t1\nTYPE\tverify\nPEER\tspeedtest.tyo11.jp.leaseweb.net\nPORT\t5202\nRECOMMEND\t202\n' > "$dir/summary.tsv"
        printf '%s\n' "$((2*gib))" > "$counter"; measurement_budget_check PEER_A
        printf '%s\n' "$((4*gib))" > "$counter"; measurement_budget_check PEER_B
        printf '%s\n' "$((57*gib/10))" > "$counter"; measurement_budget_check PEER_C
        if measurement_budget_check FINAL_VERIFY "$((4*gib/10))"; then fail "budget exhaustion fixture started final verify"; else inner_rc=$?; fi
        : > "$temporary_restore"
        measurement_finalize_run verify speedtest.tyo11.jp.leaseweb.net 5202 eth0 "$inner_rc" complete
        return "$inner_rc"
    }
    persist_current_tuning() { : > "$committed"; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 10 >/dev/null 2>&1; then fail "budget-exhausted operation reported success"; else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "budget exhaustion high-level rc"
    assert_eq "$((init+1))" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "budget exhaustion reset ledger during failover"
    [[ -f "$temporary_restore" && -f "$outer_rollback" ]] || fail "budget exhaustion missed temporary or outer rollback"
    [[ ! -e "$committed" ]] || fail "budget exhaustion committed a recommendation"
    assert_eq complete "$(summary_value "$dir/summary.tsv" ROLLBACK_RESULT)" "budget final outer rollback result"
    assert_eq "$((57*gib/10))" "$(summary_value "$dir/summary.tsv" TEST_TX_BYTES_USED)" "budget summary full-operation TX"
    assert_eq none "$(summary_value "$dir/summary.tsv" PERSISTENT_CHANGES)" "budget persistent changes"
)

test_peer_reputation_decay_and_relative_capacity() (
    local host=speedtest.tyo11.jp.leaseweb.net low high file old neutral ranked now
    PEER_HEALTH_DIR="$TEST_ROOT/decay-peer-health"; mkdir -p "$PEER_HEALTH_DIR"
    peer_health_record "$host" 4 203.0.113.40 5201 inconclusive measurement-inconclusive 20 96.84 clean
    peer_health_record "$host" 4 203.0.113.41 5201 inconclusive measurement-inconclusive 20 191.38 clean
    low=$(peer_health_score "$host" 4 203.0.113.40 5201 20 | cut -f1)
    high=$(peer_health_score "$host" 4 203.0.113.41 5201 20 | cut -f1)
    assert_eq "$low" "$high" "absolute receiver capacity created a fixed slow-peer penalty"
    ranked=$(printf '%s\n' \
        "$host|203.0.113.40|4|192.0.2.10|eth0|5201|20|low|fixture" \
        "$host|203.0.113.41|4|192.0.2.10|eth0|5201|20|high|fixture" | peer_health_rank_candidates | head -n1)
    [[ "$ranked" == *'|203.0.113.41|'* ]] || fail "relative receiver capacity did not act as a tie-breaker"

    peer_health_record "$host" 4 203.0.113.42 5201 failure path-dirty 20 na dirty
    file=$(peer_health_file "$host" 4 203.0.113.42 5201); peer_health_load "$file"
    now=$(date +%s); PH_UPDATED_AT=$((now-604801)); PH_TEMPORARY_PENALTY_UNTIL=0; peer_health_write "$file"
    old=$(peer_health_score "$host" 4 203.0.113.42 5201 20 | cut -f1)
    neutral=$(peer_health_score "$host" 4 203.0.113.99 5201 20 | cut -f1)
    assert_eq "$neutral" "$old" "old peer failure did not decay back to neutral"
)

test_real_production_measurement_fixtures() (
    local rc summary file calls="$TEST_ROOT/tokyo-spike-calls"
    install_measurement_fixture_mocks
    measurement_profile_configure standard; measurement_budget_configure 6442450944 900

    sample_repeated() {
        local rate="${6#rate-}"; rate="${rate#refine-}"; rate="${rate%%-recheck-*}"
        case "$6" in
            saturation) make_row 166.70 7.10755 171 ;;
            path-control) make_row 75 0.01 76 ;;
            rate-*|refine-*) make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.95}')" 0.01 "$rate" ;;
            *) fail "unexpected Hong Kong fixture label: $6" ;;
        esac
    }
    if measure_sweep speedtest.hkg12.hk.leaseweb.net 5201 eth0 0 152 206 9 3 1 3 0.1 0 5000 auto >/dev/null 2>&1; then fail "Hong Kong no-knee fixture reported success"; else rc=$?; fi
    assert_eq 2 "$rc" "Hong Kong inconclusive rc"; summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq clean "$(summary_value "$summary" PATH_CONTROL_QUALITY)" "Hong Kong control quality"
    assert_eq inconclusive-policer-out-of-range "$(summary_value "$summary" SCAN_DECISION)" "Hong Kong no-knee decision"
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" "Hong Kong generated recommendation"
    file=$(peer_health_file speedtest.hkg12.hk.leaseweb.net 4 203.0.113.20 5201); peer_health_load "$file"
    assert_eq 0 "$PH_PATH_DIRTY_COUNT" "Hong Kong no-knee polluted path-dirty"
    assert_eq knee-not-located "$PH_LAST_RESULT" "Hong Kong peer-health semantic"

    sample_repeated() {
        local rate="${6#rate-}"; rate="${rate#refine-}"; rate="${rate%%-recheck-*}"
        case "$6" in
            saturation) make_row 96.84 8.11799 101 ;;
            path-control) make_row 44 0.01 45 ;;
            rate-*|refine-*) make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.94}')" 0.01 "$rate" ;;
            *) fail "unexpected Singapore fixture label: $6" ;;
        esac
    }
    if measure_sweep speedtest.sin1.sg.leaseweb.net 5201 eth0 0 88 123 5 3 1 3 0.1 0 5000 auto >/dev/null 2>&1; then fail "Singapore no-knee fixture reported success"; else rc=$?; fi
    assert_eq 2 "$rc" "Singapore inconclusive rc"; summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq inconclusive-policer-out-of-range "$(summary_value "$summary" SCAN_DECISION)" "Singapore no-knee decision"
    file=$(peer_health_file speedtest.sin1.sg.leaseweb.net 4 203.0.113.30 5201); peer_health_load "$file"
    assert_eq 0 "$PH_PATH_DIRTY_COUNT" "Singapore no-knee polluted path-dirty"
    assert_eq knee-not-located "$PH_LAST_RESULT" "Singapore peer-health semantic"

    printf '0\n' > "$calls"
    sample_repeated() {
        local rate count
        case "$6" in
            path-control) make_row 80 0.0036 81 ;;
            saturation) make_row 191.38 5.38 202 ;;
            rate-*|refine-*)
                rate="${6#rate-}"; rate="${rate#refine-}"; rate="${rate%%-recheck-*}"
                if (( rate >= 210 )); then
                    count=$(<"$calls"); printf '%s\n' "$((count+1))" > "$calls"; make_row 192.70 0.37152 "$rate"
                else make_row "$(awk -v r="$rate" 'BEGIN {printf "%.2f",r*0.925}')" 0.0036 "$rate"
                fi
                ;;
            confirm-202) make_row 187.20 0.0036 202 ;;
            *) fail "unexpected Tokyo fixture label: $6" ;;
        esac
    }
    measure_sweep speedtest.tyo11.jp.leaseweb.net 5202 eth0 200 183 210 9 3 1 3 0.1 0 5000 auto >/dev/null
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq CLEAN_POLICER_FOUND "$(summary_value "$summary" MEASUREMENT_STATE)" "Tokyo v8.0.5 state"
    assert_eq 209 "$(summary_value "$summary" LAST_OK)" "Tokyo last clean"
    assert_eq 210 "$(summary_value "$summary" BROKE_AT)" "Tokyo break"
    assert_eq 202 "$(summary_value "$summary" RECOMMEND)" "Tokyo recommendation"
    assert_eq 3 "$(<"$calls")" "Tokyo 210 spike experiment count"
)

test_profile_safety() (
    local calls="$TEST_ROOT/quick-spike-calls" call standard strict std_eff strict_eff
    printf '0\n' > "$calls"
    measurement_profile_configure quick
    sample_repeated() {
        call=$(<"$calls"); ((call+=1)); printf '%s\n' "$call" > "$calls"
        if (( call <= 2 )); then make_row 190 1 200; else make_row 195 0 200; fi
    }
    measure_level_with_confirmation fixture 5201 3 5 1 quick-spike 0.1 0 >/dev/null
    assert_eq 3 "$(<"$calls")" "quick spike confirmation experiment count"
    assert_eq 2 "$MEASURE_LEVEL_SPIKE_HITS" "quick spike hit requirement"
    assert_eq 1 "$MEASURE_LEVEL_SPIKE_CONFIRMED" "quick 2/3 spike decision"

    measurement_profile_configure standard; standard=$(measurement_profile_stage_durations 5)
    std_eff=$(minimum_efficiency_ratio 185 200)
    measurement_profile_configure strict; strict=$(measurement_profile_stage_durations 5)
    strict_eff=$(minimum_efficiency_ratio 185 200)
    assert_eq $'5\t5\t5\t7' "$standard" "standard v8.0.5 duration semantics"
    assert_eq "$std_eff" "$strict_eff" "strict changed efficiency/margin math"
    loss_spike 0.11 0.1 0 || fail "strict profile changed spike threshold semantics"
    [[ "$strict" == $'7\t7\t6\t8' ]] || fail "strict did not only increase evidence duration"
)

write_failure_summary() {
    local dir="$1" reason="${2:-peer-unavailable}" rc="${3:-75}"
    mkdir -p "$dir"
    printf 'HISTORY_SCHEMA\t1\nTYPE\tverify\nPEER\tspeedtest.tyo11.jp.leaseweb.net\nPORT\t5202\nRESULT\tFAILURE\nFAILURE_STAGE\tFINAL_VERIFY\nFAILURE_REASON\t%s\nFAILURE_DETAIL\toriginal failure\nSUGGESTED_ACTION\tretry later\nINTERNAL_RC\t%s\nROLLBACK_RESULT\tprovisional\nPERSISTENT_CHANGES\tunknown\n' "$reason" "$rc" > "$dir/summary.tsv"
}

test_failure_summary_after_outer_rollback() (
    local dir="$HISTORY_DIR/20260915T130000Z-verify" failed="$HISTORY_DIR/20260915T130001Z-verify" output rc=0 events=""
    write_failure_summary "$dir"
    failure_finalize_outer_rollback "$dir/summary.tsv" 75 0
    assert_eq complete "$(summary_value "$dir/summary.tsv" ROLLBACK_RESULT)" "successful outer rollback finalization"
    assert_eq none "$(summary_value "$dir/summary.tsv" PERSISTENT_CHANGES)" "successful rollback persistent state"
    assert_eq peer-unavailable "$(summary_value "$dir/summary.tsv" FAILURE_REASON)" "original reason lost after successful rollback"

    write_failure_summary "$failed"
    failure_finalize_outer_rollback "$failed/summary.tsv" 75 9
    assert_eq rollback-failed "$(summary_value "$failed/summary.tsv" FAILURE_REASON)" "rollback failure priority"
    assert_eq peer-unavailable "$(summary_value "$failed/summary.tsv" ORIGINAL_FAILURE_REASON)" "rollback original reason"
    assert_eq "$ROLLBACK_FAILURE_RC" "$(summary_value "$failed/summary.tsv" INTERNAL_RC)" "rollback registry rc"
    output=$(failure_summary_print "$failed/summary.tsv" 1)
    assert_contains "$output" 'ROLLBACK FAILED' "rollback failure human priority"
    assert_contains "$output" 'Original reason' "rollback original reason display"

    write_failure_summary "$dir"
    action_transaction_begin_multi() { events+=" begin"; ACTION_TRANSACTION_DIR="$TEST_ROOT/transaction"; }
    action_transaction_mark_mutated() { events+=" mutated"; }
    auto_tune_execute() { events+=" failure"; MEASURE_RUN_DIR="$dir"; return 75; }
    action_transaction_rollback() { events+=" rollback"; ACTION_TRANSACTION_DIR=""; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 10 >/dev/null 2>&1; then fail "failed auto transaction reported success"; else rc=$?; fi
    assert_eq 75 "$rc" "successful rollback original rc"
    assert_eq ' begin mutated failure rollback' "$events" "outer rollback ordering"

    write_failure_summary "$failed"; events=""
    auto_tune_execute() { events+=" failure"; MEASURE_RUN_DIR="$failed"; return 75; }
    action_transaction_rollback() { events+=" rollback-failed"; return 9; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 10 >/dev/null 2>&1; then fail "rollback failure reported success"; else rc=$?; fi
    assert_eq "$ROLLBACK_FAILURE_RC" "$rc" "rollback failure high-level rc"
    assert_eq rollback-failed "$(summary_value "$failed/summary.tsv" FAILURE_REASON)" "outer wrapper rollback priority"
)

test_status_measurement_age_and_semantics() (
    local saved_history="$HISTORY_DIR" empty="$TEST_ROOT/empty-history" dir output stale fp
    mkdir -p "$empty"; HISTORY_DIR="$empty"
    output=$(status_measurement_details)
    assert_contains "$output" 'Delivered capacity   not measured' "defaults-only delivered status"
    assert_contains "$output" 'Shaping rate         none' "defaults-only shaping status"

    HISTORY_DIR="$TEST_ROOT/status-history"; dir="$HISTORY_DIR/20260914T195000Z-sweep"; mkdir -p "$dir"
    fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tSUCCESS\nCOMPLETED_AT\t2026-09-14T19:50:00Z\nMEASUREMENT_STATE\tCLEAN_POLICER_FOUND\nSCAN_DECISION\trecommend\nCAPACITY_RECEIVER_MBIT\t191\nRECOMMEND\t202\nPATH_ROUTE_FINGERPRINT\t%s\nLOCKED_FAMILY\t4\nLOCKED_ADDRESS\t203.0.113.10\nLOCKED_SOURCE\t192.0.2.10\nLOCKED_INTERFACE\teth0\n' "$fp" > "$dir/summary.tsv"
    date() {
        if [[ "$*" == '-u -d 2026-09-14T19:50:00Z +%s' ]]; then printf '1000\n'
        elif [[ "$*" == '+%s' ]]; then printf '38920\n'
        else command date "$@"; fi
    }
    path_capture_route_identity() { printf '%s\tendpoint\tleaf\n' "$fp"; }
    output=$(status_measurement_details)
    assert_contains "$output" 'Measurement age      10h 32m' "measurement age"
    assert_contains "$output" 'Measurement          verified' "equivalent route status"
    assert_contains "$output" 'Decision             CLEAN_POLICER_FOUND' "measurement decision semantics"
    assert_contains "$output" 'Delivered capacity   191 Mbit' "delivered capacity"
    assert_contains "$output" 'Shaping rate         202 Mbit' "shaping rate"
    path_capture_route_identity() { printf '%064d\tendpoint\tchanged-leaf\n' 0; }
    stale=$(status_measurement_details)
    assert_contains "$stale" 'Measurement          stale' "real leaf change stale status"
    HISTORY_DIR="$saved_history"
)

test_no_network_read_only_commands() (
    local marker="$TEST_ROOT/read-only-network-called" dir id output
    HISTORY_DIR="$TEST_ROOT/read-only-history"; PEER_HEALTH_DIR="$TEST_ROOT/read-only-peer-health"
    id=20260915T140000Z-sweep; dir="$HISTORY_DIR/$id"; mkdir -p "$dir" "$PEER_HEALTH_DIR"
    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tSUCCESS\nCOMPLETED_AT\t2026-09-15T14:00:00Z\nSCAN_DECISION\tno-knee-clean\n' > "$dir/summary.tsv"
    getent() { : > "$marker"; return 99; }; ping() { : > "$marker"; return 99; }
    timeout() { : > "$marker"; return 99; }; iperf3() { : > "$marker"; return 99; }
    curl() { : > "$marker"; return 99; }; wget() { : > "$marker"; return 99; }; git() { : > "$marker"; return 99; }
    show_status >/dev/null 2>&1 || true
    verify_system_state >/dev/null 2>&1 || true
    doctor_report >/dev/null 2>&1 || true
    cmd_history >/dev/null; cmd_history latest >/dev/null; cmd_history show "$id" >/dev/null
    cmd_peers >/dev/null
    [[ ! -e "$marker" ]] || fail "a read-only command attempted DNS/ping/TCP/iperf/GitHub access"
    detect_interface() { printf 'eth0\n'; }; root_qdisc_kind() { printf 'fq\n'; }
    hardware_profile_values() { HARDWARE_CLASS=small; HARDWARE_LINK_MBIT=1000; HARDWARE_LINK_TRUST=trusted; }
    recommended_scan_cap() { printf '1300\n'; }; recommended_measure_duration() { printf '5\n'; }
    doctor_default_route_summary() { printf 'eth0 / local route state\n'; }; command_exists() { :; }; sysctl() { printf 'bbr\n'; }
    output=$(auto_dry_run auto standard 6442450944 900 2>/dev/null || true)
    assert_contains "$output" 'No throughput measurement was performed.' "dry-run no-throughput statement"
)

test_state_parsing_and_tsv_sanitization() (
    local marker="$TEST_ROOT/pwned" host=speedtest.tyo11.jp.leaseweb.net file dir pending
    peer_health_record "$host" 4 203.0.113.10 5201 success none 10 191 clean
    file=$(peer_health_file "$host" 4 203.0.113.10 5201)
    sed -i 's|^HOST.*|HOST\t$(touch '"$marker"')|' "$file"
    if peer_health_load "$file" >/dev/null 2>&1; then fail "malicious peer-health host was accepted"; fi
    [[ ! -e "$marker" ]] || fail "peer-health command substitution executed"

    dir="$HISTORY_DIR/20260915T150000Z-probe"; mkdir -p "$dir"
    printf 'HISTORY_SCHEMA\t$(touch %s)\nTYPE\tprobe\nRESULT\tSUCCESS\n' "$marker" > "$dir/summary.tsv"
    if history_schema_supported "$dir/summary.tsv" >/dev/null 2>&1; then fail "malicious history schema was accepted"; fi
    [[ ! -e "$marker" ]] || fail "history command substitution executed"

    MEASURE_RUN_DIR="$dir"; failure_set MEASUREMENT protocol-failure $'remote\tline\nINJECTED\tvalue\033[31m' '' 65
    pending="$dir/.failure-pending.tsv"
    [[ "$(wc -l < "$pending")" == 4 ]] || fail "failure text injected extra TSV records"
    if grep -q '^INJECTED' "$pending"; then fail "failure text injected a key"; fi
    awk -F'\t' 'NF!=2 {exit 1}' "$pending" || fail "sanitized failure TSV has extra columns"
    if LC_ALL=C grep -q $'\033' "$pending"; then fail "control character survived failure TSV sanitization"; fi

    printf 'STAGE\tMEASUREMENT\nREASON\tprotocol-failure\nDETAIL\t`touch %s`\nSUGGESTION\t;rm -rf /\nBROKEN\n' "$marker" > "$pending"
    if failure_pending_load "$pending" >/dev/null 2>&1; then fail "malformed failure state was accepted"; fi
    [[ ! -e "$marker" ]] || fail "failure TSV backticks executed"
)

test_rc_registry_and_dispatch() {
    local values count unique
    values=$(awk -F= '/^[A-Z][A-Z0-9_]*_RC=[0-9]+([[:space:]]|$)/ {sub(/[[:space:]].*/,"",$2); print $2}' "$ROOT_DIR/src/00-header.sh")
    count=$(wc -l <<< "$values"); unique=$(sort -u <<< "$values" | wc -l)
    assert_eq "$count" "$unique" "special RC collision"
    assert_eq peer-failover "$(operation_rc_class 75)" "unavailable dispatch"
    operation_rc_is_retryable 75 || fail "unavailable RC not retryable"
    assert_eq peer-failover "$(operation_rc_class 2)" "inconclusive failover dispatch"
    assert_eq budget "$(operation_rc_class 70)" "budget dispatch"
    assert_eq preflight "$(operation_rc_class 71)" "preflight dispatch"
    assert_eq rollback "$(operation_rc_class 73)" "rollback dispatch"
    assert_eq fatal "$(operation_rc_class 65)" "protocol fatal dispatch"
}

test_telemetry_failure_boundary() (
    install_measurement_fixture_mocks
    measurement_profile_configure standard; measurement_budget_configure 6442450944 900
    sample_repeated() {
        case "$6" in path-control) make_row 40 0 40 ;; saturation) make_row 100 0 101 ;; *) fail "unexpected telemetry fixture" ;; esac
    }
    measurement_finalize_run() { return 28; }
    measurement_peer_health_finalize() { return 28; }
    measure_sweep speedtest.tyo11.jp.leaseweb.net 5201 eth0 100 0 0 0 3 1 3 0.1 0 5000 auto >/dev/null 2>&1 ||
        fail "telemetry cache/history failure changed successful network measurement rc"

    local rolled="$TEST_ROOT/critical-rolled" rc=0
    action_transaction_begin_multi() { ACTION_TRANSACTION_DIR="$TEST_ROOT/critical-tx"; }
    action_transaction_mark_mutated() { :; }
    auto_tune_execute() { return 1; } # models config/service persistence failure: critical
    action_transaction_rollback() { : > "$rolled"; ACTION_TRANSACTION_DIR=""; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 10 >/dev/null 2>&1; then fail "critical persistence failure committed"; else rc=$?; fi
    assert_eq 1 "$rc" "critical persistence failure rc"
    [[ -f "$rolled" ]] || fail "critical persistence failure did not rollback"
)

test_doctor_export_prune_locking() (
    local marker="$TEST_ROOT/export-snapshot-point" output="$TEST_ROOT/export-output" bundle extract="$TEST_ROOT/concurrent-export" id
    HISTORY_DIR="$TEST_ROOT/concurrent-history"; LOCK_FILE="$TEST_ROOT/concurrent.lock"; MAX_HISTORY_ENTRIES=1; LOCK_HELD=0
    for id in 20260915T160000Z-sweep 20260915T160001Z-verify; do
        mkdir -p "$HISTORY_DIR/$id"; printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tSUCCESS\n' > "$HISTORY_DIR/$id/summary.tsv"; sleep 0.02
    done
    require_commands() { :; }; require_root() { :; }
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nmock 1 1 1048576 1%% /tmp\n'; }
    diagnostic_capture() {
        printf 'default via 203.0.113.10 dev eth0\n' > "$1"
        if [[ "$1" == */status.txt ]]; then : > "$marker"; sleep 1; fi
    }
    systemctl() { printf 'inactive\n'; }; persistence_script_state() { printf 'absent\n'; }
    load_config() { return 1; }; peers_show() { printf 'none\n'; }; hostname() { printf 'lock-host\n'; }
    mkdir -p "$extract"
    ( doctor_export 0 > "$output" ) &
    local export_pid=$!
    for _ in {1..100}; do [[ -f "$marker" ]] && break; sleep 0.02; done
    [[ -f "$marker" ]] || fail "doctor export did not reach the concurrent snapshot fixture"
    history_prune >/dev/null || fail "concurrent history prune failed"
    wait "$export_pid" || fail "doctor export failed during concurrent history snapshot"
    bundle=$(awk -F': ' '/^Diagnostic bundle:/ {print $2}' "$output"); [[ -f "$bundle" ]] || fail "concurrent diagnostic bundle missing"
    tar -xzf "$bundle" -C "$extract"
    [[ -f "$extract/latest-sweep-summary.tsv" && -f "$extract/latest-verify-summary.tsv" ]] || fail "concurrent export omitted snapshot files"
    if [[ -s "$extract/latest-sweep-summary.tsv" ]]; then history_summary_well_formed "$extract/latest-sweep-summary.tsv" 2>/dev/null || {
        # The validator deliberately requires HISTORY_DIR ownership; validate
        # the exported two-column snapshot without weakening that boundary.
        awk -F'\t' 'NF!=2 {exit 1}' "$extract/latest-sweep-summary.tsv" || fail "concurrent export produced a partial TSV"
    }; fi
    rm -f -- "$bundle"
)

test_production_peer_churn_operation() (
    local gib=$((1024*1024*1024)) mib=$((1024*1024)) counter="$TEST_ROOT/churn-counter" seq=0 committed="$TEST_ROOT/churn-committed"
    local fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ep=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local start_init total first score_hk score_sg score_5201 score_5202 ranked busy_retries=0
    printf '0\n' > "$counter"
    interface_counter() { case "$2" in tx_bytes) cat "$counter" ;; rx_bytes) printf '%s\n' "$(( $(<"$counter") / 8 ))" ;; esac; }
    consume() { printf '%s\n' "$(( $(<"$counter") + $1 ))" > "$counter"; measurement_usage_update; }
    new_fixture_history() {
        local type="$1"; ((seq+=1)); MEASURE_RUN_DIR="$HISTORY_DIR/20260915T17$(printf '%04d' "$seq")Z-${type}"
        mkdir -p "$MEASURE_RUN_DIR"
    }
    PUBLIC_PEER_CANDIDATES=(
        'speedtest.tyo11.jp.leaseweb.net|203.0.113.10|4|192.0.2.10|eth0|5201|12|东京|Leaseweb'
        'speedtest.hkg12.hk.leaseweb.net|203.0.113.20|4|192.0.2.10|eth0|5201|40|香港|Leaseweb'
        'speedtest.sin1.sg.leaseweb.net|203.0.113.30|4|192.0.2.10|eth0|5201|60|新加坡|Leaseweb'
        'speedtest.tyo11.jp.leaseweb.net|203.0.113.10|4|192.0.2.10|eth0|5202|12|东京|Leaseweb'
    )
    WIZARD_PUBLIC_PEER=1; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0; WIZARD_ROUTE_GUARD_ACTIVE=0
    WIZARD_SAMPLE_DURATION=5; WIZARD_SCAN_CAP=5000; activate_public_peer_candidate 0
    start_init="$MEASURE_BUDGET_INITIALIZATION_COUNT"; measurement_budget_configure "$((6*gib))" 900; measurement_budget_ensure eth0
    measure_sweep() {
        case "$1:$2" in
            speedtest.tyo11.jp.leaseweb.net:5201)
                consume "$((8*mib))"; new_fixture_history sweep; : > "$MEASURE_RUN_DIR/summary.tsv"
                failure_set PEER_PREFLIGHT peer-unavailable 'initial formal precheck unavailable' '' 75
                measurement_finalize_run sweep "$1" "$2" eth0 75 complete
                peer_health_record "$1" 4 203.0.113.10 "$2" failure peer-unavailable 12 na unknown
                return 75
                ;;
            speedtest.hkg12.hk.leaseweb.net:5201)
                consume "$((1015*mib))"; new_fixture_history sweep
                printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nPATH_CONTROL_QUALITY\tclean\nSATURATION_RECEIVER_MBIT\t166.70\nSCAN_DECISION\tinconclusive-policer-out-of-range\nRECOMMEND\t\n' > "$MEASURE_RUN_DIR/summary.tsv"
                failure_set MEASUREMENT no-knee-confidence 'policer-suspected-but-knee-not-located' '' 2
                measurement_finalize_run sweep "$1" "$2" eth0 2 complete
                peer_health_record "$1" 4 203.0.113.20 "$2" inconclusive knee-not-located 40 166.70 clean
                return 2
                ;;
            speedtest.sin1.sg.leaseweb.net:5201)
                consume "$((649*mib))"; new_fixture_history sweep
                printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nPATH_CONTROL_QUALITY\tclean\nSATURATION_RECEIVER_MBIT\t96.84\nSCAN_DECISION\tinconclusive-policer-out-of-range\nRECOMMEND\t\n' > "$MEASURE_RUN_DIR/summary.tsv"
                failure_set MEASUREMENT no-knee-confidence 'capacity-limited measurement insufficient' '' 2
                measurement_finalize_run sweep "$1" "$2" eth0 2 complete
                peer_health_record "$1" 4 203.0.113.30 "$2" inconclusive measurement-inconclusive 60 96.84 clean
                return 2
                ;;
            speedtest.tyo11.jp.leaseweb.net:5202)
                consume "$((2136746229))"; new_fixture_history sweep
                printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tSUCCESS\nPATH_CONTROL_QUALITY\tclean\nMEASUREMENT_STATE\tCLEAN_POLICER_FOUND\nSCAN_DECISION\trecommend\nSATURATION_RECEIVER_MBIT\t191.38\nCAPACITY_RECEIVER_MBIT\t191.38\nRECOMMEND\t202\nKNEE_MBIT\t209\nBROKE_AT\t210\nNO_KNEE\t0\nCONFIRMED\t1\nREJECT_REASON\t\nMIN_EFFICIENCY_RATIO\t0.90\nCLEAN_REFERENCE_RETRANS_EST_PERCENT\t0.0036\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_RTT_P95_MS\t12\n' "$fp" "$ep" > "$MEASURE_RUN_DIR/summary.tsv"
                measurement_finalize_run sweep "$1" "$2" eth0 0 complete
                peer_health_record "$1" 4 203.0.113.10 "$2" success none 12 191.38 clean
                return 0
                ;;
        esac
    }
    measure_verify() {
        if [[ "$2" == 5202 ]]; then
            busy_retries=3; consume "$((136*mib))"; new_fixture_history verify; : > "$MEASURE_RUN_DIR/summary.tsv"
            failure_set FINAL_VERIFY peer-busy 'server busy for all 3 retries' '' 75
            measurement_finalize_run verify "$1" "$2" eth0 75 complete
            peer_health_record "$1" 4 203.0.113.10 "$2" failure peer-busy 12 191.38 clean
            return 75
        fi
        consume "$((548*mib))"; new_fixture_history verify
        printf 'HISTORY_SCHEMA\t1\nTYPE\tverify\nRESULT\tSUCCESS\nSINGLE_RECEIVER_MBIT\t187.25\nMULTI_RECEIVER_MBIT\t188.49\nCONFIDENCE_SCORE\t95\nCONFIDENCE_GRADE\thigh\nCONFIDENCE_REASONS\tclean\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\n' "$fp" "$ep" > "$MEASURE_RUN_DIR/summary.tsv"
        measurement_finalize_run verify "$1" "$2" eth0 0 complete
        peer_health_record "$1" 4 203.0.113.10 "$2" success none 12 188.49 clean
    }
    prepare_auto_tuning_runtime() { :; }; verify_runtime_tuning() { :; }
    nic_stage_candidate_global_model() { :; }; apply_sysctl_profile() { :; }; apply_shaping() { :; }; apply_fq() { :; }
    recommended_verify_flows() { printf '4\n'; }; persist_current_tuning() { : > "$committed"; }; show_status() { :; }
    auto_tune_execute eth0 balanced mixed 0 100 12 >/dev/null
    measurement_usage_update; total="$TEST_TX_BYTES_USED"
    assert_eq "$((start_init+1))" "$MEASURE_BUDGET_INITIALIZATION_COUNT" "peer churn reset the operation budget"
    assert_between "$total" "$((42*gib/10))" "$((44*gib/10))" "peer churn operation traffic"
    assert_eq 3 "$busy_retries" "5202 final busy retry count"
    assert_eq 5201 "$WIZARD_PORT" "same-host recovered port"
    assert_eq 4 "$WIZARD_FAILOVERS" "sweep plus port failover count"
    [[ -f "$committed" ]] || fail "successful recovered verification did not commit"
    first=$(history_latest_type_result sweep SUCCESS); assert_eq 202 "$(summary_value "$first" RECOMMEND)" "production churn recommendation"
    assert_eq peer-failover "$(summary_value "$first" FINAL_VERIFY_CONFIDENCE_REASONS)" "port failover confidence degradation"

    peer_health_load "$(peer_health_file speedtest.hkg12.hk.leaseweb.net 4 203.0.113.20 5201)"; assert_eq 0 "$PH_PATH_DIRTY_COUNT" "Hong Kong churn path-dirty"
    score_hk=$(peer_health_score speedtest.hkg12.hk.leaseweb.net 4 203.0.113.20 5201 40 | cut -f1)
    peer_health_load "$(peer_health_file speedtest.sin1.sg.leaseweb.net 4 203.0.113.30 5201)"; assert_eq 0 "$PH_PATH_DIRTY_COUNT" "Singapore churn path-dirty"
    score_sg=$(peer_health_score speedtest.sin1.sg.leaseweb.net 4 203.0.113.30 5201 60 | cut -f1)
    peer_health_load "$(peer_health_file speedtest.tyo11.jp.leaseweb.net 4 203.0.113.10 5201)"
    assert_eq clean "$PH_LAST_RESULT" "5201 did not recover after early failure"
    assert_eq 0 "$PH_TEMPORARY_PENALTY_UNTIL" "5201 success did not clear temporary penalty"
    score_5201=$(peer_health_score speedtest.tyo11.jp.leaseweb.net 4 203.0.113.10 5201 12 | cut -f1)
    score_5202=$(peer_health_score speedtest.tyo11.jp.leaseweb.net 4 203.0.113.10 5202 12 | cut -f1)
    (( score_5201 > score_hk && score_5201 > score_sg && score_5201 > score_5202 )) || fail "peer-health recovery/penalty directions are wrong"
    ranked=$(printf '%s\n' "${PUBLIC_PEER_CANDIDATES[@]}" | peer_health_rank_candidates | head -n1)
    [[ "$ranked" == *'|5201|'* && "$ranked" == speedtest.tyo11.jp.leaseweb.net* ]] || fail "recovered Tokyo port did not re-enter candidate ordering"
)

run_test() { printf '==> %s\n' "$1"; "$1"; }
run_test test_global_operation_budget_lifetime
run_test test_formal_peer_precheck_traffic_is_accounted
run_test test_budget_exhaustion_rolls_back_without_commit
run_test test_peer_reputation_decay_and_relative_capacity
run_test test_real_production_measurement_fixtures
run_test test_profile_safety
run_test test_failure_summary_after_outer_rollback
run_test test_status_measurement_age_and_semantics
run_test test_no_network_read_only_commands
run_test test_state_parsing_and_tsv_sanitization
run_test test_rc_registry_and_dispatch
run_test test_telemetry_failure_boundary
run_test test_doctor_export_prune_locking
run_test test_production_peer_churn_operation

printf 'v8.0.6 post-hardening tests: PASS\n'
