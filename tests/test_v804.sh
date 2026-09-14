#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_PERSIST_DIR="$TEST_ROOT/persist"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/persist/net-tcp-tune.sh"
export BBRV3_SERVICE_FILE="$TEST_ROOT/bbrv3-lite.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/99-bbrv3-lite.conf"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
export BBRV3_MEASUREMENT_COOLDOWN=0
trap 'rm -rf -- "$TEST_ROOT"' EXIT

for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh nic.sh measure.sh systemd.sh cli.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: '$1' lacks '$2'"; }

test_single_ipv6_nhid_default_passes() (
    ip() {
        case "$*" in
            '-4 route show default') : ;;
            '-6 route show default') printf 'default nhid 703065545 via fe80::e:fcff:fe8a:db dev eth0 proto ra metric 512\n' ;;
            'nexthop get id 703065545') printf 'id 703065545 via fe80::e:fcff:fe8a:db dev eth0 scope link proto ra\n' ;;
            *) return 1 ;;
        esac
    }
    assert_eq eth0 "$(default_route_interface)" "single nhid default interface"
    auto_tune_route_guard eth0 "" >/dev/null || fail "single IPv6 nhid default was rejected"
)

test_fibmatch_single_nhid_passes() (
    ip() {
        case "$*" in
            '-6 route get 2606:4700:4700::1111')
                printf '2606:4700:4700::1111 from :: via fe80::e:fcff:fe8a:db dev eth0 proto ra src 2001:db8::10 metric 512\n'
                ;;
            '-6 route get fibmatch 2606:4700:4700::1111')
                printf 'default nhid 703065545 via fe80::e:fcff:fe8a:db dev eth0 proto ra metric 512\n'
                ;;
            'nexthop get id 703065545') printf 'id 703065545 via fe80::e:fcff:fe8a:db dev eth0 scope link proto ra\n' ;;
            *) return 1 ;;
        esac
    }
    assert_eq $'6\t2606:4700:4700::1111\teth0' "$(target_route_records 2606:4700:4700::1111)" "fibmatch nhid route record"
)

test_nhid_exact_get_dump_fallback() (
    ip() {
        case "$*" in
            '-6 nexthop get id 703065545') return 2 ;;
            'nexthop show')
                printf 'id 703065544 via 192.0.2.2 dev eth9 scope link\n'
                printf 'id 703065545 via 2001:db8::2 dev eth0 scope link\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_eq $'eth0\t2001:db8::2\t6\t703065545' \
        "$(nexthop_object_leaf_record 703065545 'dump fallback' 6)" "nexthop dump exact-ID fallback"
)

test_nhid_fail_closed_matrix() {
    (
        nexthop_object_output() { printf 'id 100 group 101,102 type resilient buckets 64\n'; }
        if route_unique_path_iface 'default nhid 100 dev eth0' group 4 >/dev/null 2>&1; then fail "multi-member nhid group was accepted"; fi
    )
    (
        # iproute2 uses slash-separated group members. It must fail closed even
        # when both leaves would ultimately resolve to the same interface.
        nexthop_object_output() { printf 'id 100 group 101/102\n'; }
        if route_unique_path_iface 'default nhid 100 dev eth0' group 4 >/dev/null 2>&1; then fail "slash-form nhid group was accepted"; fi
    )
    (
        nexthop_object_output() { printf 'id 100 group 101,102\n'; }
        if route_unique_path_iface 'default nhid 100 dev eth0' same-interface-group 4 >/dev/null 2>&1; then fail "same-interface multipath group was accepted"; fi
    )
    (
        nexthop_object_output() { printf 'id 103 blackhole\n'; }
        if route_unique_path_iface 'default nhid 103' blackhole 4 >/dev/null 2>&1; then fail "blackhole nhid was accepted"; fi
    )
    (
        nexthop_object_output() { return 2; }
        local output rc=0
        if output=$(route_unique_path_iface 'default nhid 999 dev eth0' unresolved 4 2>&1); then fail "unresolved nhid was accepted"; else rc=$?; fi
        assert_eq 1 "$rc" "unresolved nhid status"
        assert_contains "$output" 'nhid 999' "unresolved nhid diagnostic"
    )
    (
        nexthop_object_output() { printf 'id 123 via 192.0.2.1 dev eth1 scope link\n'; }
        if route_unique_path_iface 'default nhid 123 via 192.0.2.1 dev eth0' mismatch 4 >/dev/null 2>&1; then fail "route/object interface mismatch was accepted"; fi
    )
    (
        nexthop_object_output() { printf 'id 124 via 192.0.2.2 dev eth0 scope link\n'; }
        if route_unique_path_iface 'default nhid 124 via 192.0.2.1 dev eth0' gateway-mismatch 4 >/dev/null 2>&1; then fail "route/object gateway mismatch was accepted"; fi
    )
    (
        nexthop_object_output() { printf 'id 125 via 192.0.2.2 dev eth0 scope link\n'; }
        if route_unique_path_iface 'default nhid 125 via 192.0.2.2 dev eth0' family-mismatch 6 >/dev/null 2>&1; then fail "route/object address-family mismatch was accepted"; fi
    )
    (
        if route_unique_path_iface 'default proto static nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 198.51.100.1 dev eth1 weight 1' inline 4 >/dev/null 2>&1; then
            fail "inline ECMP was accepted"
        fi
    )
}

install_sweep_quality_mocks() {
    require_root() { :; }
    acquire_lock() { :; }
    tc_dependencies() { :; }
    require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }
    measure_lock_peer() {
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10; MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE=eth0; MEASURE_PEER_PORT="$3"
        path_state_reset; PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
    }
    measure_require_locked_port() { :; }
    qdisc_guard() { :; }
    hardware_profile_values() {
        HARDWARE_CLASS=standard; HARDWARE_LINK_MBIT=1000; HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1
    }
    measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
    path_profile_tuning_gate() { :; }
    measure_begin() { MEASURE_IFACE=eth0; }
    measure_restore() { MEASURE_IFACE=""; }
    traffic_report() { :; }
    apply_fq() { :; }
    apply_shaping() { :; }
}

test_dirty_path_control_is_inconclusive_and_low_confidence() (
    local summary output rc=0 output_file="$TEST_ROOT/dirty-path-control.log"
    install_sweep_quality_mocks
    sample_repeated() {
        printf '100.00\t100\t1000000\t12.74263\t107374.182\t5\t6\t0\t10\t0\t0\t0.00\t2\t5\n'
    }
    if measure_sweep dirty.example 5201 eth0 0 0 0 0 3 1 3 0.1 0 5000 auto >"$output_file" 2>&1; then
        fail "dirty path control was reported as a successful no-knee sweep"
    else
        rc=$?
    fi
    output=$(<"$output_file")
    assert_eq "$MEASURE_PATH_QUALITY_RC" "$rc" "dirty path-control result status"
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq bad "$(summary_value "$summary" BASELINE_QUALITY)" "legacy path-control compatibility quality"
    assert_eq path-dirty "$(summary_value "$summary" SCAN_DECISION)" "dirty path-control decision"
    assert_eq PATH_DIRTY "$(summary_value "$summary" MEASUREMENT_STATE)" "dirty path state"
    assert_eq 0 "$(summary_value "$summary" NO_KNEE)" "dirty path no-knee marker"
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" "dirty path recommendation"
    assert_eq high "$(summary_value "$summary" SAMPLE_CONFIDENCE_GRADE)" "sample telemetry confidence"
    assert_eq low "$(summary_value "$summary" DECISION_CONFIDENCE_GRADE)" "decision confidence downgrade"
    assert_eq path-control-dirty "$(summary_value "$summary" CONFIDENCE_REASONS)" "path-control confidence reason"
    [[ "$output" != *'扫描置信度: high'* && "$output" != *'100/100, clean'* ]] || fail "inconclusive baseline was displayed as high/clean"
)

test_public_dirty_path_restarts_on_next_peer() (
    local events=""
    PUBLIC_PEER_CANDIDATES=(
        'dirty.example|203.0.113.10|4|192.0.2.10|eth0|5201|1|脏路径|ProviderA'
        'clean.example|198.51.100.10|4|192.0.2.10|eth0|5201|2|干净|ProviderB'
    )
    WIZARD_PUBLIC_PEER=1; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0; WIZARD_ROUTE_GUARD_ACTIVE=0
    WIZARD_SAMPLE_DURATION=5; WIZARD_SCAN_CAP=5000
    measure_sweep() {
        events+=" $1:control+sweep"
        [[ "$1" != dirty.example ]] || return "$MEASURE_PATH_QUALITY_RC"
        return 0
    }
    auto_measure_with_peer_failover eth0 0 >/dev/null
    assert_eq ' dirty.example:control+sweep clean.example:control+sweep' "$events" "public peer full-sweep restart"
    assert_eq clean.example "$WIZARD_SWEEP_PEER" "clean sweep peer"
    assert_eq 1 "$WIZARD_FAILOVERS" "dirty path failover count"
)

test_all_public_dirty_rolls_back_without_persisting() (
    local events=""
    PUBLIC_PEER_CANDIDATES=(
        'dirty-a.example|203.0.113.10|4|192.0.2.10|eth0|5201|1|脏路径 A|ProviderA'
        'dirty-b.example|198.51.100.10|4|192.0.2.10|eth0|5201|2|脏路径 B|ProviderB'
    )
    WIZARD_PEER=dirty-a.example; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=1; WIZARD_PUBLIC_INDEX=0
    WIZARD_FAILOVERS=0; WIZARD_ROUTE_GUARD_ACTIVE=0; WIZARD_PEER_IFACE=eth0
    WIZARD_SAMPLE_DURATION=5; WIZARD_SCAN_CAP=5000
    action_transaction_begin_multi() { events+=' begin'; }
    action_transaction_mark_mutated() { events+=' mark'; }
    action_transaction_commit() { events+=' commit'; }
    action_transaction_rollback() { events+=' rollback'; }
    prepare_auto_tuning_runtime() { events+=' prepare'; }
    measure_sweep() { events+=" $1:control+sweep"; return "$MEASURE_PATH_QUALITY_RC"; }
    persist_current_tuning() { events+=' persist'; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 1 >/dev/null 2>&1; then fail "all-bad public peer transaction reported success"; fi
    assert_eq ' begin mark prepare dirty-a.example:control+sweep dirty-b.example:control+sweep rollback' "$events" "all-dirty public peer rollback"
    [[ "$events" != *persist* && "$events" != *commit* ]] || fail "all-dirty public peer transaction persisted or committed"
)

write_auto_summary() {
    local file="$1" mode="$2"
    local path_fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local endpoint_fp=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    if [[ "$mode" == fq ]]; then
        printf '%s\n' \
            $'RECOMMEND\t' $'BROKE_AT\t' $'UNSHAPED_MBIT\t100' $'NO_KNEE\t1' $'NO_KNEE_REASON\tscan-complete-no-knee' \
            $'BASELINE_QUALITY\tgood' $'SCAN_DECISION\tno-knee-clean' $'CONFIRMED\t0' $'REJECT_REASON\t' > "$file"
    else
        printf '%s\n' \
            $'RECOMMEND\t97' $'BROKE_AT\t105' $'UNSHAPED_MBIT\t110' $'NO_KNEE\t0' \
            $'BASELINE_QUALITY\tgood' $'SCAN_DECISION\trecommend' $'CONFIRMED\t1' $'REJECT_REASON\t' > "$file"
    fi
    printf '%s\n' \
        $'MIN_EFFICIENCY_RATIO\t0.94' $'CLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t0' \
        $'PATH_ROUTE_FINGERPRINT\t'"$path_fp" $'PATH_ENDPOINT_FINGERPRINT\t'"$endpoint_fp" \
        $'PATH_RTT_P95_MS\t1' >> "$file"
}

run_final_verify_case() (
    local mode="$1" mock_verify_rc="$2" local_rc="$3" expected_rc="$4" expected_events="$5"
    local summary_dir="$TEST_ROOT/final-$mode-$mock_verify_rc-$local_rc" events="" rc=0
    local path_fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local endpoint_fp=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    mkdir -p "$summary_dir"
    WIZARD_PEER=peer.example; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=0; WIZARD_FAILOVERS=0; WIZARD_ROUTE_GUARD_ACTIVE=0
    WIZARD_PEER_ADDRESS=203.0.113.10; WIZARD_PEER_FAMILY=4; WIZARD_PEER_SOURCE=192.0.2.10; WIZARD_PEER_IFACE=eth0
    WIZARD_SWEEP_PEER=peer.example; WIZARD_SWEEP_PORT=5201; WIZARD_SWEEP_ADDRESS=203.0.113.10
    WIZARD_SWEEP_FAMILY=4; WIZARD_SWEEP_SOURCE=192.0.2.10; WIZARD_SWEEP_IFACE=eth0
    action_transaction_begin_multi() { events+=' begin'; }
    action_transaction_mark_mutated() { events+=' mark'; }
    action_transaction_commit() { events+=' commit'; }
    action_transaction_rollback() { events+=' rollback'; }
    prepare_auto_tuning_runtime() { events+=' prepare'; }
    auto_measure_with_peer_failover() { events+=' sweep'; MEASURE_RUN_DIR="$summary_dir"; write_auto_summary "$summary_dir/summary.tsv" "$mode"; }
    nic_stage_candidate_global_model() { events+=' model'; SYSCTL_PROFILE=adaptive; ROLE=mixed; BANDWIDTH_MBIT="$4"; RTT_MS="$5"; NIC_MODEL_INTERFACE=eth0; }
    apply_sysctl_profile() { events+=' sysctl'; }
    apply_fq() { events+=' fq'; }
    apply_shaping() { events+=' shape'; }
    verify_runtime_tuning() { events+=' runtime'; }
    auto_verify_with_peer_failover() { events+=' peer-verify'; return "$mock_verify_rc"; }
    auto_verify_local_fq_fallback() {
        events+=' local-fallback'
        (( local_rc == 0 )) || return "$local_rc"
        printf '%s\t%s\n' "$path_fp" "$endpoint_fp"
    }
    persist_current_tuning() { events+=' persist'; }
    show_status() { :; }
    if auto_tune_run_transaction eth0 balanced mixed 0 100 1 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    assert_eq "$expected_rc" "$rc" "final verify case status ($mode/$mock_verify_rc/$local_rc)"
    assert_eq "$expected_events" "$events" "final verify case events ($mode/$mock_verify_rc/$local_rc)"
    if (( expected_rc == 0 )); then
        assert_eq local-fallback "$(summary_value "$summary_dir/summary.tsv" FINAL_VERIFY_MODE)" "fallback summary mode"
        assert_eq 1 "$(summary_value "$summary_dir/summary.tsv" FINAL_VERIFY_DEGRADED)" "fallback summary degraded"
        assert_eq peer-unavailable "$(summary_value "$summary_dir/summary.tsv" FINAL_VERIFY_REASON)" "fallback summary reason"
    fi
)

test_final_verification_fallback_boundaries() {
    run_final_verify_case fq "$IPERF_UNAVAILABLE_RC" 0 0 ' begin mark prepare sweep model sysctl fq runtime peer-verify persist commit'
    run_final_verify_case shape "$IPERF_UNAVAILABLE_RC" 0 "$IPERF_UNAVAILABLE_RC" ' begin mark prepare sweep model sysctl shape runtime peer-verify rollback'
    run_final_verify_case fq 2 0 2 ' begin mark prepare sweep model sysctl fq runtime peer-verify rollback'
    run_final_verify_case fq "$IPERF_UNAVAILABLE_RC" 1 1 ' begin mark prepare sweep model sysctl fq runtime peer-verify rollback'
}

test_local_fallback_rechecks_frozen_path() (
    local expected_path=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local expected_endpoint=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    local drift_path=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local events_file="$TEST_ROOT/local-fallback-events" count_file="$TEST_ROOT/local-fallback-count" diagnostic_file="$TEST_ROOT/local-fallback-diagnostic" output
    WIZARD_SWEEP_FAMILY=4; WIZARD_SWEEP_ADDRESS=203.0.113.10
    WIZARD_SWEEP_SOURCE=192.0.2.10; WIZARD_SWEEP_IFACE=eth0
    printf '0\n' > "$count_file"
    verify_runtime_tuning() { printf 'runtime\n' >> "$events_file"; }
    auto_tune_route_guard() { printf 'route-guard\n' >> "$events_file"; }
    path_capture_route_identity() {
        local count
        count=$(<"$count_file"); count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
        printf 'path\n' >> "$events_file"
        if (( count == 2 )); then printf '%s\t%s\n' "$drift_path" "$expected_endpoint"
        else printf '%s\t%s\n' "$expected_path" "$expected_endpoint"
        fi
    }
    ping() { printf 'ping\n' >> "$events_file"; }
    if output=$(auto_verify_local_fq_fallback eth0 "$expected_path" "$expected_endpoint" 2>"$diagnostic_file"); then
        fail "local fallback accepted a post-connectivity path fingerprint change: $output"
    fi
    assert_eq $'runtime\nroute-guard\npath\nping\npath' "$(<"$events_file")" "local fallback path recheck order ($( <"$diagnostic_file"))"
)

run_test() { printf '==> %s\n' "$1"; "$1"; }
run_test test_single_ipv6_nhid_default_passes
run_test test_fibmatch_single_nhid_passes
run_test test_nhid_exact_get_dump_fallback
run_test test_nhid_fail_closed_matrix
run_test test_dirty_path_control_is_inconclusive_and_low_confidence
run_test test_public_dirty_path_restarts_on_next_peer
run_test test_all_public_dirty_rolls_back_without_persisting
run_test test_final_verification_fallback_boundaries
run_test test_local_fallback_rechecks_frozen_path
printf 'v8.0.4 regression tests: PASS\n'
