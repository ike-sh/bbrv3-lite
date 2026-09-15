#!/usr/bin/env bash
# Deterministic v8.0.6 reliability, diagnostics and peer-intelligence tests.
# shellcheck disable=SC2034 # Intentional global-state assignments exercise sourced runtime functions.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
cleanup() {
    rm -rf -- "$TEST_ROOT"
}
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

# shellcheck source=/dev/null
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

test_measurement_profiles_and_high_bandwidth_matrix() {
    local standard quick strict rate rtt duration estimate previous=0 row confidence
    measurement_profile_configure standard
    standard=$(measurement_profile_stage_durations 5)
    assert_eq $'5\t5\t5\t7' "$standard" "standard profile must preserve v8.0.5 durations"
    assert_eq 3 "$MEASURE_CONTROL_SAMPLES" "standard path-control count"
    assert_eq 3 "$MEASURE_CONTROL_MAX_SAMPLES" "standard path-control adaptive ceiling"
    measurement_profile_configure quick; quick=$(measurement_profile_stage_durations 5)
    assert_eq $'5\t4\t3\t6' "$quick" "quick duration profile"
    assert_eq 2 "$MEASURE_CONTROL_MAX_SAMPLES" "quick clean-sample ceiling"
    measurement_profile_configure strict; strict=$(measurement_profile_stage_durations 5)
    assert_eq $'7\t7\t6\t8' "$strict" "strict duration profile"
    assert_eq 4 "$MEASURE_CANDIDATE_MAX_SAMPLES" "strict candidate confirmation ceiling"
    assert_eq 4 "$MEASURE_VERIFY_MAX_SAMPLES" "strict final verify ceiling"

    measurement_profile_configure standard
    while IFS=$'\t' read -r rate rtt; do
        if (( rtt <= 30 )); then duration=4
        elif (( rtt <= 100 )); then duration=5
        elif (( rtt <= 200 )); then duration=6
        else duration=7
        fi
        estimate=$(estimate_measurement_plan_bytes "$((rate*40/100))" "$duration" "$rate" "$duration" "$((rate*115/100))" "$duration" "$((duration+2))" 1)
        is_uint "$estimate" && (( estimate > previous )) || fail "high-bandwidth estimate not monotonic at ${rate}M/${rtt}ms"
        previous="$estimate"
    done <<'EOF'
100	20
200	30
500	80
1000	100
2500	150
5000	200
10000	250
EOF
    if loss_spike 0.05 0.1 0; then fail "clean no-policer fixture classified as policer"; fi
    loss_spike 0.15 0.1 0 || fail "shallow policer fixture was not detected"
    loss_spike 5.4 0.1 0.01 || fail "sharp policer fixture was not detected"
    if awk 'BEGIN {exit !(600<1800*0.70)}'; then :; else fail "single-flow limited fixture did not request aggregate capacity"; fi
    row=$(expanded_scan_cap 5000 1800); is_uint "$row" && (( row >= 5000 )) || fail "aggregate capacity expansion regressed"
    confidence=$(measurement_confidence 3 1 120 0 0 100 1)
    assert_contains "$confidence" receiver-fallback "receiver fallback confidence classification"
    sample_is_contaminated 0 0 99 || fail "CPU-limited sample was not classified as contaminated"
    if sample_is_contaminated 0 0 40; then fail "healthy CPU fixture was classified as limited"; fi
}

test_budget_accounting_and_boundaries() (
    local counter_file="$TEST_ROOT/budget-counter" rc=0
    printf '0\n' > "$counter_file"
    interface_counter() {
        case "$2" in tx_bytes) printf '%s\n' "$(<"$counter_file")" ;; rx_bytes) printf '0\n' ;; esac
    }
    measurement_budget_configure 1048576 60
    measurement_budget_ensure eth0
    printf '1048575\n' > "$counter_file"
    measurement_budget_check COARSE || fail "budget rejected bytes below boundary"
    assert_eq 1048575 "$TEST_TX_BYTES_USED" "actual interface TX accounting"
    printf '1048576\n' > "$counter_file"
    if measurement_budget_check COARSE >/dev/null 2>&1; then fail "exact traffic boundary was accepted"; else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "traffic budget exit code"
    assert_eq COARSE "$MEASURE_BUDGET_STAGE" "traffic budget stage"
    assert_eq budget-exceeded "$FAILURE_REASON" "traffic budget reason"

    measurement_budget_configure 10485760 30
    measurement_budget_ensure eth0
    MEASURE_BUDGET_STARTED_EPOCH=$(( $(date +%s) - 30 ))
    if measurement_budget_check FINAL_VERIFY >/dev/null 2>&1; then fail "exact duration boundary was accepted"; else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "duration budget exit code"
    assert_eq FINAL_VERIFY "$MEASURE_BUDGET_STAGE" "duration budget final-verify stage"

    printf '0\n' > "$counter_file"
    measurement_budget_configure 1048576 60
    measurement_budget_ensure eth0
    printf '1048576\n' > "$counter_file"
    if measurement_budget_check RATE_RECHECK_2 >/dev/null 2>&1; then fail "spike recheck boundary was accepted"; else rc=$?; fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "spike recheck budget exit code"
    assert_eq RATE_RECHECK_2 "$MEASURE_BUDGET_STAGE" "spike recheck budget stage"
)

test_failed_peer_retries_count_actual_tx() (
    local counter_file="$TEST_ROOT/retry-budget-counter" rc=0
    printf '0\n' > "$counter_file"
    interface_counter() { case "$2" in tx_bytes) cat "$counter_file" ;; *) printf '0\n' ;; esac; }
    uname() { printf 'TestOS\n'; }
    validate_peer() { :; }; measure_require_sample_lock() { :; }; measure_peer_route_guard() { :; }
    cpu_snapshot() { printf 'cpu\n'; }; cpu_core_snapshot() { printf 'core\n'; }
    peer_health_record() { :; }
    timeout() {
        local used; used=$(<"$counter_file"); printf '%s\n' "$((used+400000))" > "$counter_file"
        return 124
    }
    MEASURE_PEER_HOST=retry.example; MEASURE_PEER_ADDRESS=203.0.113.10; MEASURE_PEER_SOURCE=192.0.2.10
    MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT=5201; MEASURE_IFACE=eth0
    export BBRV3_IPERF_ATTEMPTS=3
    measurement_budget_configure 2097152 60; measurement_budget_ensure eth0
    if sample_repeated retry.example 5201 3 1 1 retry-budget 1 0 1 shaped >/dev/null 2>&1; then
        fail "failed retries crossed the hard cap but reported success"
    else
        rc=$?
    fi
    measurement_usage_update
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "failed retry hard-budget exit code"
    assert_eq 800000 "$TEST_TX_BYTES_USED" "failed peer retry actual interface TX accounting"
)

test_budget_exhaustion_restores_and_refuses_recommendation() (
    local counter_file="$TEST_ROOT/sweep-budget-counter" restored="$TEST_ROOT/sweep-budget-restored" rc=0 summary
    printf '0\n' > "$counter_file"
    require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }; qdisc_guard() { :; }
    hardware_profile_values() {
        HARDWARE_CLASS=standard; HARDWARE_LINK_MBIT=1000; HARDWARE_LINK_TRUST=trusted
        HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1
    }
    measure_lock_peer() {
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
        path_state_reset; PATH_ROUTE_FINGERPRINT=$(printf 'a%.0s' {1..64}); PATH_ENDPOINT_FINGERPRINT=$(printf 'b%.0s' {1..64})
        PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
    }
    measure_require_locked_port() { :; }; measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
    path_profile_tuning_gate() { :; }; apply_shaping() { :; }; traffic_report() { :; }
    interface_counter() { case "$2" in tx_bytes) cat "$counter_file" ;; *) printf '0\n' ;; esac; }
    measure_begin() { MEASURE_IFACE="$1"; measurement_budget_ensure "$1"; }
    measure_restore() { printf restored > "$restored"; MEASURE_IFACE=""; }
    sample_repeated() {
        printf '%s\n' "$MEASURE_MAX_TX_BYTES" > "$counter_file"
        measurement_budget_check COARSE
    }
    measurement_profile_configure standard; measurement_budget_configure 1048576 60
    if measure_sweep budget.example 5201 eth0 100 0 0 0 3 1 3 0.1 0 500 auto >/dev/null 2>&1; then
        fail "budget-exhausted sweep reported success"
    else
        rc=$?
    fi
    assert_eq "$MEASURE_BUDGET_RC" "$rc" "budget-exhausted sweep rc"
    [[ -f "$restored" ]] || fail "budget exhaustion did not restore temporary qdisc"
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq MEASUREMENT_BUDGET_EXCEEDED "$(summary_value "$summary" MEASUREMENT_STATE)" "budget measurement state"
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" "budget exhaustion produced a recommendation"
    assert_eq FAILURE "$(summary_value "$summary" RESULT)" "budget history result"
    assert_eq complete "$(summary_value "$summary" ROLLBACK_RESULT)" "budget rollback result"
    assert_eq COARSE "$(summary_value "$summary" FAILURE_STAGE)" "budget failure stage"
)

test_peer_health_lifecycle() (
    local host=speedtest.tyo11.jp.leaseweb.net file file2 file3 file6 after no_history good busy score old_hash new_hash host_penalized
    host="$host"
    no_history=$(peer_health_score "$host" 4 203.0.113.10 5201 20); score="${no_history%%$'\t'*}"
    assert_eq 70 "$score" "new peer neutral score"
    peer_health_record "$host" 4 203.0.113.10 5201 success none 20 900 clean
    file=$(peer_health_file "$host" 4 203.0.113.10 5201)
    [[ -f "$file" && ! -L "$file" ]] || fail "peer health record not created"
    assert_eq 600 "$(stat -c '%a' "$file")" "peer health file permission"
    good=$(peer_health_score "$host" 4 203.0.113.10 5201 20); score="${good%%$'\t'*}"
    (( score > 70 )) || fail "successful clean history did not improve peer score"

    peer_health_record "$host" 4 203.0.113.10 5202 failure peer-busy 21 na unknown
    file2=$(peer_health_file "$host" 4 203.0.113.10 5202)
    [[ "$file" != "$file2" && -f "$file2" ]] || fail "port-level health was not separated"
    busy=$(peer_health_score "$host" 4 203.0.113.10 5202 21); score="${busy%%$'\t'*}"
    (( score < 70 )) || fail "active busy penalty did not lower score"
    peer_health_load "$file2"; PH_TEMPORARY_PENALTY_UNTIL=$(( $(date +%s)-1 )); peer_health_write "$file2"
    after=$(peer_health_score "$host" 4 203.0.113.10 5202 21); score="${after%%$'\t'*}"
    (( score > ${busy%%$'\t'*} )) || fail "expired penalty still affected score"

    peer_health_record "$host" 4 203.0.113.10 5203 failure peer-reset 22 na unknown
    peer_health_record "$host" 4 203.0.113.10 5203 failure peer-reset 22 na unknown
    file3=$(peer_health_file "$host" 4 203.0.113.10 5203)
    host_penalized=$(peer_health_score "$host" 4 203.0.113.10 5204 22); score="${host_penalized%%$'\t'*}"
    (( score < 70 )) || fail "repeated host/address resets did not temporarily influence another port"
    peer_health_load "$file3"; PH_TEMPORARY_PENALTY_UNTIL=$(( $(date +%s)-1 )); peer_health_write "$file3"
    assert_eq 70 "$(peer_health_score "$host" 4 203.0.113.10 5204 22 | cut -f1)" "expired host reset influence"

    peer_health_record "$host" 4 203.0.113.99 5201 success none 22 800 clean
    peer_health_record "$host" 6 2001:db8::10 5201 success none 23 700 clean
    file6=$(peer_health_file "$host" 6 2001:db8::10 5201)
    [[ -f "$file6" && "$file6" != "$file" ]] || fail "address/family endpoint fingerprints were conflated"

    printf 'corrupt\n' > "$file"
    peer_health_record "$host" 4 203.0.113.10 5201 success none 19 910 clean
    peer_health_load "$file" || fail "corrupt peer cache was not rebuilt"
    assert_eq 1 "$PH_SUCCESS_COUNT" "corrupt cache rebuild count"

    sed -i 's/^SCHEMA\t1$/SCHEMA\t2/' "$file"
    old_hash=$(sha256sum "$file" | awk '{print $1}')
    if peer_health_record "$host" 4 203.0.113.10 5201 success none 18 920 clean >/dev/null 2>&1; then
        fail "newer peer-health schema was overwritten"
    fi
    new_hash=$(sha256sum "$file" | awk '{print $1}')
    assert_eq "$old_hash" "$new_hash" "newer schema immutability"

    sed -i 's/^SCHEMA\t2$/SCHEMA\t1/' "$file"
    old_hash=$(sha256sum "$file" | awk '{print $1}')
    mv() { return 9; }
    if peer_health_record "$host" 4 203.0.113.10 5201 success none 18 920 clean >/dev/null 2>&1; then fail "interrupted atomic write reported success"; fi
    new_hash=$(sha256sum "$file" | awk '{print $1}')
    assert_eq "$old_hash" "$new_hash" "atomic interruption changed committed cache"
)

test_peer_reset_is_scoped() {
    mkdir -p "$BASELINE_DIR" "$HISTORY_DIR/20260915T000000Z-sweep" "$PEER_HEALTH_DIR"
    printf 'baseline\n' > "$BASELINE_DIR/sentinel"
    printf 'history\n' > "$HISTORY_DIR/20260915T000000Z-sweep/sentinel"
    printf 'peer\n' > "$PEER_HEALTH_DIR/sentinel"
    ( require_root() { :; }; acquire_lock() { :; }; peers_reset >/dev/null )
    [[ ! -e "$PEER_HEALTH_DIR" ]] || fail "peers reset retained cache"
    [[ -f "$BASELINE_DIR/sentinel" && -f "$HISTORY_DIR/20260915T000000Z-sweep/sentinel" ]] || fail "peers reset crossed state boundaries"
}

test_failure_history_and_prune() {
    local id dir file output valid_count reason
    id=20260915T010000Z-sweep; dir="$HISTORY_DIR/$id"; mkdir -p "$dir"; : > "$dir/summary.tsv"
    MEASURE_RUN_DIR="$dir"; TEST_TX_BYTES_USED=851443712; TEST_RX_BYTES_USED=1; TEST_DURATION_USED=31
    failure_set PATH_CONTROL path-dirty 'control retrans spike' '' 68
    measurement_finalize_run sweep public.example 5201 eth0 68 complete
    file="$dir/summary.tsv"
    assert_file_contains "$file" $'RESULT\tFAILURE' "failure result missing"
    assert_file_contains "$file" $'FAILURE_STAGE\tPATH_CONTROL' "failure stage missing"
    assert_file_contains "$file" $'FAILURE_REASON\tpath-dirty' "failure reason missing"
    [[ -f "$dir/failure.tsv" ]] || fail "failure.tsv missing"
    output=$(failure_summary_print "$file")
    assert_contains "$output" 'Suggested action' "human failure suggestion"

    for id in 20260915T020000Z-probe 20260915T030000Z-verify 20260915T040000Z-compare; do
        mkdir -p "$HISTORY_DIR/$id"; printf 'TYPE\tprobe\n' > "$HISTORY_DIR/$id/summary.tsv"; sleep 0.01
    done
    mkdir -p "$HISTORY_DIR/not-a-measurement"; printf keep > "$HISTORY_DIR/not-a-measurement/sentinel"
    MEASURE_RUN_DIR=""; history_prune_internal 2
    valid_count=$(find "$HISTORY_DIR" -mindepth 1 -maxdepth 1 -type d -name '20260915T*' | wc -l)
    assert_eq 2 "$valid_count" "bounded history retention"
    [[ -f "$BASELINE_DIR/sentinel" && -f "$HISTORY_DIR/not-a-measurement/sentinel" ]] || fail "history prune crossed its allowlist"
    id=20260915T050000Z-path; mkdir -p "$HISTORY_DIR/$id"
    printf 'HISTORY_SCHEMA\t2\nTYPE\tpath\n' > "$HISTORY_DIR/$id/summary.tsv"
    if history_show "$id" >/dev/null 2>&1; then fail "newer history schema was accepted"; fi
    assert_contains "$(history_list)" unsupported-schema "newer history list marker"
    for reason in peer-busy path-dirty path-changed candidate-confirm-failed verify-throughput-failed \
        budget-exceeded tc-ownership-conflict rollback-failed; do
        failure_reason_valid "$reason" || fail "required failure enum missing: $reason"
        [[ -n "$(failure_reason_explanation "$reason")" && -n "$(failure_default_suggestion "$reason")" ]] ||
            fail "failure enum lacks explanation/suggestion: $reason"
    done
}

test_preflight_cpu_steal_and_background() (
    local counter_file="$TEST_ROOT/preflight-counter" rc=0
    mkdir -p "$STATE_DIR"
    export BBRV3_SKIP_MEASUREMENT_PREFLIGHT=0 BBRV3_PREFLIGHT_SECONDS=1
    sleep() { :; }; cpu_snapshot() { printf 'snapshot\n'; }; cpu_count() { printf '1\n'; }
    interface_counter() { printf '0\n'; }; cpu_delta_metrics() { printf '96\t0\n'; }
    if measurement_environment_preflight eth0 100 >/dev/null 2>&1; then fail "high CPU preflight was accepted"; else rc=$?; fi
    assert_eq "$MEASUREMENT_PREFLIGHT_RC" "$rc" "CPU preflight rc"; assert_eq cpu-busy "$FAILURE_REASON" "CPU preflight reason"
    cpu_delta_metrics() { printf '10\t16\n'; }
    if measurement_environment_preflight eth0 100 >/dev/null 2>&1; then fail "high steal preflight was accepted"; else rc=$?; fi
    assert_eq high-steal "$FAILURE_REASON" "steal preflight reason"

    printf '0\n' > "$counter_file"; cpu_delta_metrics() { printf '10\t0\n'; }
    interface_counter() {
        local n; n=$(<"$counter_file"); printf '%s\n' "$((n+1))" > "$counter_file"
        case "$n:$2" in 0:tx_bytes|1:rx_bytes) printf '0\n' ;; 2:tx_bytes) printf '200000000\n' ;; *) printf '0\n' ;; esac
    }
    if measurement_environment_preflight eth0 100 >/dev/null 2>&1; then fail "severe background traffic was accepted"; else rc=$?; fi
    assert_eq background-traffic "$FAILURE_REASON" "background preflight reason"
)

test_ipv6_nhid_semantic_fingerprint() (
    local nhid_file="$TEST_ROOT/nhid" gateway_file="$TEST_ROOT/gateway" table_file="$TEST_ROOT/table" mtu_file="$TEST_ROOT/mtu"
    local first churn changed source_changed pmtu_changed
    printf '123\n' > "$nhid_file"; printf 'fe80::1\n' > "$gateway_file"; printf '100\n' > "$table_file"; printf '1500\n' > "$mtu_file"
    ip() {
        case "$*" in
            '-6 route get 2001:db8::10 from 2001:db8::2') printf '2001:db8::10 from 2001:db8::2 nhid %s dev eth0 proto ra expires 1600sec mtu %s\n' "$(<"$nhid_file")" "$(<"$mtu_file")" ;;
            '-6 route get fibmatch 2001:db8::10 from 2001:db8::2') printf 'default nhid %s dev eth0 proto ra metric 1024 expires 1400sec table %s\n' "$(<"$nhid_file")" "$(<"$table_file")" ;;
            '-6 route get 2001:db8::10 from 2001:db8::3') printf '2001:db8::10 from 2001:db8::3 nhid %s dev eth0 proto ra mtu %s\n' "$(<"$nhid_file")" "$(<"$mtu_file")" ;;
            '-6 route get fibmatch 2001:db8::10 from 2001:db8::3') printf 'default nhid %s dev eth0 proto ra table %s\n' "$(<"$nhid_file")" "$(<"$table_file")" ;;
            *) return 1 ;;
        esac
    }
    nexthop_object_output() { printf 'id %s via inet6 %s dev eth0 scope link proto ra\n' "$1" "$(<"$gateway_file")"; }
    detect_mtu() { cat "$mtu_file"; }
    first=$(path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0)
    printf '456\n' > "$nhid_file"
    churn=$(path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0)
    assert_eq "${first%%$'\t'*}" "${churn%%$'\t'*}" "equivalent nhid churn changed route identity"
    assert_eq "$(cut -f2 <<< "$first")" "$(cut -f2 <<< "$churn")" "equivalent nhid churn changed endpoint identity"
    printf 'fe80::9\n' > "$gateway_file"; changed=$(path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0)
    [[ "${changed%%$'\t'*}" != "${first%%$'\t'*}" ]] || fail "real IPv6 leaf change was ignored"
    printf 'fe80::1\n' > "$gateway_file"; source_changed=$(path_capture_route_identity 6 2001:db8::10 2001:db8::3 eth0)
    [[ "${source_changed%%$'\t'*}" != "${first%%$'\t'*}" ]] || fail "IPv6 source selection change was ignored"
    printf '1400\n' > "$mtu_file"; pmtu_changed=$(path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0)
    [[ "${pmtu_changed%%$'\t'*}" != "${first%%$'\t'*}" ]] || fail "PMTU change was ignored"
    printf '1500\n' > "$mtu_file"; printf '200\n' > "$table_file"
    changed=$(path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0)
    [[ "${changed%%$'\t'*}" != "${first%%$'\t'*}" ]] || fail "policy table change was ignored"
    nexthop_object_output() { printf 'id %s group 10/11\n' "$1"; }
    if path_capture_route_identity 6 2001:db8::10 2001:db8::2 eth0 >/dev/null 2>&1; then fail "nexthop group was accepted"; fi
)

test_doctor_state_matrix() (
    local output before after doctor_root="$TEST_ROOT/doctor-state"
    CONFIG_FILE="$doctor_root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$doctor_root/etc/99-bbrv3-lite.conf"
    SERVICE_FILE="$doctor_root/etc/bbrv3-lite.service"; PERSIST_SCRIPT="$doctor_root/persist/net-tcp-tune.sh"
    BASELINE_DIR="$doctor_root/state/baseline"; HISTORY_DIR="$doctor_root/state/history"; PEER_HEALTH_DIR="$doctor_root/state/peer-health"
    mkdir -p "$doctor_root"
    reset_config() { SYSCTL_PROFILE=balanced; }
    load_config() { SYSCTL_PROFILE=balanced; }
    os_id() { printf 'debian\n'; }; os_codename() { printf 'bookworm\n'; }; virtualization_type() { printf 'kvm\n'; }
    sysctl() { case "$*" in *tcp_available_congestion_control*) printf 'reno cubic bbr\n' ;; *) printf 'bbr\n' ;; esac; }
    systemctl() { case "$1" in is-enabled) printf 'disabled\n'; return 1 ;; is-active) return 1 ;; esac; }
    persistence_script_state() { printf 'absent\n'; }
    doctor_default_route_summary() { if [[ "$1" == -6 ]]; then printf 'unresolved/ECMP\n'; else printf 'eth0 / gateway 192.0.2.1 / nhid none\n'; fi; }
    ip() {
        case "$*" in
            '-o link show') printf '2: eth0: <UP> mtu 1500\n' ;;
            '-4 rule show') printf '0: from all lookup local\n32766: from all lookup main\n' ;;
            '-6 rule show') printf '0: from all lookup local\n100: from 2001:db8::/64 lookup 100\n32766: from all lookup main\n' ;;
            'nexthop show') printf 'id 10 group 11/12\n' ;;
            *) return 1 ;;
        esac
    }
    detect_driver() { printf 'virtio_net\n'; }; detect_mtu() { printf '1500\n'; }
    detect_rx_queues() { printf '2\n'; }; detect_tx_queues() { printf '2\n'; }; detect_offload_summary() { printf 'gro=on/gso=on/tso=on\n'; }
    root_qdisc_kind() { printf 'fq_codel\n'; }; managed_htb() { return 1; }
    managed_htb_diagnostic() { printf 'ownership unknown; expected managed HTB/FQ, actual fq_codel\n'; }
    output=$(doctor_report)
    assert_contains "$output" "absent / $CONFIG_FILE" "doctor uninstalled config state"
    assert_contains "$output" 'absent / inactive' "doctor uninstalled service state"
    assert_contains "$output" 'OUT_OF_SYNC (absent)' "doctor missing persistence state"
    assert_contains "$output" 'unresolved/ECMP' "doctor IPv6 ECMP state"
    assert_contains "$output" 'actual fq_codel' "doctor qdisc ownership detail"
    assert_contains "$output" 'No network settings were changed.' "doctor read-only statement"

    mkdir -p "$(dirname "$SERVICE_FILE")"; : > "$SERVICE_FILE"
    output=$(doctor_report)
    assert_contains "$output" 'disabled / inactive' "doctor broken service state"

    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$PERSIST_SCRIPT")" "$BASELINE_DIR" \
        "$HISTORY_DIR/20260915T060000Z-sweep" "$HISTORY_DIR/20260915T070000Z-sweep" "$HISTORY_DIR/20260915T080000Z-verify"
    : > "$CONFIG_FILE"; : > "$SYSCTL_FILE"; : > "$SERVICE_FILE"
    printf 'SCRIPT_VERSION="%s"\n' "$SCRIPT_VERSION" > "$PERSIST_SCRIPT"; chmod 0755 "$PERSIST_SCRIPT"
    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tSUCCESS\nFAILURE_REASON\tnone\n' > "$HISTORY_DIR/20260915T060000Z-sweep/summary.tsv"
    printf 'HISTORY_SCHEMA\t1\nTYPE\tsweep\nRESULT\tFAILURE\nFAILURE_REASON\tpeer-busy\n' > "$HISTORY_DIR/20260915T070000Z-sweep/summary.tsv"
    printf 'HISTORY_SCHEMA\t1\nTYPE\tverify\nRESULT\tSUCCESS\nFAILURE_REASON\tnone\n' > "$HISTORY_DIR/20260915T080000Z-verify/summary.tsv"
    tcp_baseline_validate() { :; }; baseline_provenance() { printf 'native\n'; }
    systemctl() { case "$1" in is-enabled) printf 'enabled\n' ;; is-active) return 0 ;; esac; }
    persistence_script_state() { printf 'matches-running-script\n'; }
    doctor_default_route_summary() { if [[ "$1" == -6 ]]; then printf 'eth0 / gateway fe80::1 / nhid 10 single leaf\n'; else printf 'eth0 / gateway 192.0.2.1 / nhid none\n'; fi; }
    managed_htb() { :; }; managed_rate_mbit() { printf '201\n'; }
    before=$(find "$doctor_root" -printf '%P\t%y\n' | sort | sha256sum | awk '{print $1}')
    output=$(doctor_report)
    after=$(find "$doctor_root" -printf '%P\t%y\n' | sort | sha256sum | awk '{print $1}')
    assert_eq "$before" "$after" "doctor mutated installed state"
    assert_contains "$output" "valid / $CONFIG_FILE" "doctor healthy config state"
    assert_contains "$output" 'enabled / active' "doctor healthy service state"
    assert_contains "$output" 'SYNCED (matches-running-script)' "doctor persistence sync state"
    assert_contains "$output" 'valid / native' "doctor baseline validity"
    assert_contains "$output" 'nhid 10 single leaf' "doctor IPv6 nhid detail"
    assert_contains "$output" '20260915T060000Z-sweep' "doctor latest successful measurement"
    assert_contains "$output" '20260915T070000Z-sweep' "doctor latest failed measurement"
    assert_contains "$output" '20260915T080000Z-verify/summary.tsv' "doctor latest verify"
    assert_contains "$output" 'managed HTB/FQ (201 Mbit)' "doctor managed qdisc state"
)

test_doctor_export_redaction_and_dry_run() (
    local output bundle full_bundle extract="$TEST_ROOT/export" full_extract="$TEST_ROOT/export-full" dry before after rc=0 v4_alias v6_alias
    mkdir -p "$extract" "$full_extract"
    hostname() { printf 'known-host.example\n'; }
    ip() {
        case "$*" in
            '-o link show') printf '1: lo: <LOOPBACK> mtu 65536\n2: eth0: <UP> mtu 1500\n' ;;
            '-4 route show table all') printf 'default via 203.0.113.45 dev eth0\nmachine-id=0123456789abcdef0123456789abcdef\ntoken=known-test-secret\n' ;;
            '-6 route show table all') printf 'default via fe80::1234 dev eth0 src 2001:db8:abcd::45\nboot-id=12345678-1234-1234-1234-123456789abc\nproduct_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' ;;
            '-4 rule show') printf '100: from 203.0.113.45 lookup 100\n' ;;
            '-6 rule show') printf '100: from 2001:db8:abcd::45 lookup 100\n' ;;
            'nexthop show') printf 'id 456 via fe80::1234 dev eth0 lladdr 52:54:00:12:34:56\ninstance-id=i-0123456789abcdef0\nssh_host_key=AAAATESTKEY\n' ;;
            *) return 1 ;;
        esac
    }
    output=$(doctor_export 0)
    bundle=$(awk -F': ' '/^Diagnostic bundle:/ {print $2}' <<< "$output")
    [[ -f "$bundle" && ! -L "$bundle" ]] || fail "doctor export missing"
    assert_eq 600 "$(stat -c '%a' "$bundle")" "doctor bundle permission"
    tar -xzf "$bundle" -C "$extract"
    for file in meta.txt status.txt verify.txt sysctl.txt routes-v4.txt routes-v6.txt rules-v4.txt rules-v6.txt nexthops.txt tc-qdisc.txt tc-class.txt tc-filter.txt service.txt config.redacted.txt latest-sweep-summary.tsv latest-verify-summary.tsv peer-health.tsv; do
        [[ -f "$extract/$file" ]] || fail "doctor export missing $file"
    done
    if grep -ERq '203[.]0[.]113[.]45|2001:db8:abcd::45|known-host[.]example|known-test-secret|52:54:00:12:34:56|0123456789abcdef0123456789abcdef|12345678-1234-1234-1234-123456789abc|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|i-0123456789abcdef0|AAAATESTKEY' "$extract"; then fail "default doctor export leaked known identifiers"; fi
    v4_alias=$(grep -Eo 'ADDR#[0-9a-f]{12}' "$extract/routes-v4.txt" | head -n1)
    [[ -n "$v4_alias" ]] && grep -Fq "$v4_alias" "$extract/rules-v4.txt" || fail "IPv4 pseudonym was not stable across files"
    v6_alias=$(grep -Eo 'ADDR#[0-9a-f]{12}' "$extract/routes-v6.txt" | tail -n1)
    [[ -n "$v6_alias" && "$v6_alias" != "$v4_alias" ]] || fail "different addresses collapsed to one pseudonym"
    diagnostic_capture "$TEST_ROOT/broken-command.txt" bash -c 'exit 7'
    assert_file_contains "$TEST_ROOT/broken-command.txt" '[command failed: rc=7]' "broken diagnostic command was not recorded"
    rm -f -- "$bundle"

    output=$(doctor_export 1)
    full_bundle=$(awk -F': ' '/^Diagnostic bundle:/ {print $2}' <<< "$output")
    tar -xzf "$full_bundle" -C "$full_extract"
    grep -Fq '203.0.113.45' "$full_extract/routes-v4.txt" || fail "--include-addresses did not retain a full address"
    if grep -ERq 'known-host[.]example|known-test-secret|token=|52:54:00:12:34:56|0123456789abcdef0123456789abcdef|12345678-1234-1234-1234-123456789abc|i-0123456789abcdef0|AAAATESTKEY' "$full_extract"; then fail "full-address export leaked a non-address identity or secret"; fi
    rm -f -- "$full_bundle"

    (
        df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nmock 1 1 1024 1%% /tmp\n'; }
        if doctor_export 0 >/dev/null 2>&1; then fail "low-disk doctor export reported success"; else rc=$?; fi
        assert_eq "$DIAGNOSTIC_EXPORT_RC" "$rc" "low-disk diagnostic export rc"
        [[ -z "$DIAGNOSTIC_TEMP_DIR" ]] || fail "low-disk export left a temp directory"
    )

    rm -rf -- "$STATE_DIR"; rm -f -- "$CONFIG_FILE" "$SERVICE_FILE" "$SYSCTL_FILE"
    detect_interface() { printf 'eth0\n'; }; root_qdisc_kind() { printf 'fq_codel\n'; }
    hardware_profile_values() { HARDWARE_CLASS=small; HARDWARE_LINK_MBIT=1000; HARDWARE_LINK_TRUST=trusted; }
    recommended_scan_cap() { printf '1300\n'; }; recommended_measure_duration() { printf '5\n'; }
    doctor_default_route_summary() { printf 'eth0 / single leaf\n'; }; target_route_records() { printf 'IPv6 source-bound / eth0\n'; }
    command_exists() { :; }; sysctl() { printf 'cubic\n'; }
    before=$(find "$TEST_ROOT" -mindepth 1 -printf '%P\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')
    dry=$(auto_dry_run auto standard 6442450944 900 2001:db8::10)
    after=$(find "$TEST_ROOT" -mindepth 1 -printf '%P\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')
    assert_eq "$before" "$after" "dry-run filesystem mutation"
    assert_contains "$dry" 'No system changes were made.' "dry-run safety statement"
    assert_contains "$dry" 'No throughput measurement was performed.' "dry-run throughput boundary"
    assert_contains "$dry" 'Minimum first-sample budget' "dry-run first-sample feasibility"
    [[ ! -e "$BASELINE_DIR" && ! -e "$CONFIG_FILE" && ! -e "$SERVICE_FILE" ]] || fail "dry-run created managed state"
)

test_diagnostic_signal_cleanup() (
    DIAGNOSTIC_TEMP_DIR=$(mktemp -d "/tmp/.bbrv3-lite-diagnostic.XXXXXX")
    DIAGNOSTIC_TEMP_ARCHIVE=$(mktemp "/tmp/.bbrv3-lite-diagnostic-archive.XXXXXX")
    local temp_dir="$DIAGNOSTIC_TEMP_DIR" temp_archive="$DIAGNOSTIC_TEMP_ARCHIVE"
    cleanup_core 0 || fail "diagnostic cleanup failed"
    [[ ! -e "$temp_dir" ]] || fail "diagnostic temp directory survived cleanup"
    [[ ! -e "$temp_archive" ]] || fail "diagnostic temp archive survived cleanup"
    [[ -z "$DIAGNOSTIC_TEMP_DIR" && -z "$DIAGNOSTIC_TEMP_ARCHIVE" ]] || fail "diagnostic cleanup globals were not cleared"
)

test_cli_dispatch_and_read_only_surfaces() (
    local called="" output
    peers_show() { called=peers; }; history_list() { called=history; }; doctor_report() { called=doctor; }
    cmd_peers; assert_eq peers "$called" "peers CLI dispatch"
    called=""; cmd_history; assert_eq history "$called" "history CLI dispatch"
    called=""; cmd_doctor; assert_eq doctor "$called" "doctor CLI dispatch"
    if cmd_doctor --include-addresses >/dev/null 2>&1; then fail "doctor accepted --include-addresses without --export"; fi
    output=$(show_help)
    assert_contains "$output" 'auto [--dry-run]' "dry-run help"
    assert_contains "$output" 'measurement-profile quick|standard|strict' "measurement profile help"
)

test_measurement_profiles_and_high_bandwidth_matrix
test_budget_accounting_and_boundaries
test_failed_peer_retries_count_actual_tx
test_budget_exhaustion_restores_and_refuses_recommendation
test_peer_health_lifecycle
test_peer_reset_is_scoped
test_failure_history_and_prune
test_preflight_cpu_steal_and_background
test_ipv6_nhid_semantic_fingerprint
test_doctor_state_matrix
test_doctor_export_redaction_and_dry_run
test_diagnostic_signal_cleanup
test_cli_dispatch_and_read_only_surfaces

printf 'v8.0.6 reliability/diagnostics tests: PASS\n'
