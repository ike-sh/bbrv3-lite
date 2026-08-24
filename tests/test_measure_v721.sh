#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_MAX_BACKGROUND_TX_PERCENT=100
export BBRV3_MAX_CPU_STEAL_PERCENT=100
export BBRV3_MAX_CPU_BUSY_PERCENT=100

for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh measure.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
assert_file_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$3"; }

mock_ipv4_routes() {
    local drift_file="$1"
    ip() {
        local dev=eth0 source=192.0.2.10
        if [[ -s "$drift_file" ]]; then dev=eth1; source=198.51.100.10; fi
        case "$*" in
            '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev %s src %s\n' "$dev" "$source" ;;
            '-4 route get fibmatch 203.0.113.10') printf '203.0.113.0/24 via 192.0.2.1 dev %s src %s\n' "$dev" "$source" ;;
            "-4 route get 203.0.113.10 from $source") printf '203.0.113.10 from %s via 192.0.2.1 dev %s\n' "$source" "$dev" ;;
            "-4 route get fibmatch 203.0.113.10 from $source") printf '203.0.113.0/24 via 192.0.2.1 dev %s src %s\n' "$dev" "$source" ;;
            *) return 1 ;;
        esac
    }
}

mock_ipv4_resolver() {
    local dns_state_file="$1" dns_calls_file="$2"
    getent() {
        local calls
        calls=$(<"$dns_calls_file"); printf '%s\n' "$((calls + 1))" > "$dns_calls_file"
        if [[ "$(<"$dns_state_file")" == before ]]; then
            printf '203.0.113.10 STREAM peer.example\n'
        else
            printf '203.0.113.99 STREAM peer.example\n'
        fi
    }
}

mock_success_metrics() {
    interface_counter() { printf '0\n'; }
    cpu_snapshot() { printf '100\t50\t0\n'; }
    cpu_core_snapshot() { :; }
    cpu_delta_metrics() { printf '10\t0\n'; }
    cpu_core_delta_metrics() { printf 'na\tna\n'; }
}

test_hostname_is_resolved_once_and_iperf_is_bound() {
    (
        local dns_state_file="$TEST_ROOT/dns-state" dns_calls_file="$TEST_ROOT/dns-calls"
        local iperf_args_file="$TEST_ROOT/iperf-args" ping_args_file="$TEST_ROOT/ping-args" row
        local drift_file="$TEST_ROOT/no-drift"
        printf 'before\n' > "$dns_state_file"; printf '0\n' > "$dns_calls_file"
        : > "$iperf_args_file"; : > "$ping_args_file"; : > "$drift_file"; rm -f -- "$drift_file"
        mock_ipv4_routes "$drift_file"
        mock_ipv4_resolver "$dns_state_file" "$dns_calls_file"
        mock_success_metrics
        timeout() { shift; "$@"; }
        ping() {
            printf '%s\n' "$*" >> "$ping_args_file"
            printf '64 bytes from 203.0.113.10: time=1.0 ms\n'
            printf 'rtt min/avg/max/mdev = 1.000/1.000/1.000/0.000 ms\n'
        }
        peer_port_open() { :; }
        iperf3() {
            printf '%s\n' "$*" >> "$iperf_args_file"
            printf 'after\n' > "$dns_state_file"
            printf '%s\n' '{"end":{"sum_sent":{"bits_per_second":100000000,"bytes":1000000,"retransmits":0}}}'
        }

        MEASURE_IFACE=eth0
        measure_lock_peer peer.example eth0
        assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "frozen resolver address"
        measure_set_latency_baseline peer.example
        assert_eq 1.0 "$MEASURE_IDLE_RTT_MS" "source-bound idle RTT baseline"
        row=$(iperf_sample peer.example 5201 3 1)
        is_decimal "$(cut -f1 <<< "$row")" || fail "bound iperf sample did not produce goodput"
        assert_eq 1 "$(<"$dns_calls_file")" "hostname resolution count"
        assert_file_contains "$iperf_args_file" '-4 -c 203.0.113.10 -B 192.0.2.10' "iperf3 did not use frozen IPv4 address and source bind"
        assert_file_not_contains "$iperf_args_file" 'peer.example' "iperf3 re-resolved the hostname"
        assert_file_not_contains "$iperf_args_file" '203.0.113.99' "iperf3 followed changed DNS"
        assert_file_contains "$ping_args_file" '-4 ' "loaded-latency ping did not force IPv4"
        assert_file_contains "$ping_args_file" '-I eth0 -I 192.0.2.10' "RTT ping did not bind the frozen interface and source"
        assert_file_contains "$ping_args_file" '203.0.113.10' "loaded-latency ping did not use the frozen literal"
    )
}

test_ipv6_literal_and_source_are_bound() {
    (
        local iperf_args_file="$TEST_ROOT/iperf6-args" row
        : > "$iperf_args_file"
        resolve_route_target_addresses() {
            if [[ "$1" == v6.example ]]; then printf '6\t2001:db8::10\n'; else printf '6\t%s\n' "$1"; fi
        }
        ip() {
            case "$*" in
                '-6 route get 2001:db8::10') printf '2001:db8::10 via 2001:db8::1 dev eth0 src 2001:db8::2\n' ;;
                '-6 route get fibmatch 2001:db8::10') printf '2001:db8::/64 dev eth0 src 2001:db8::2\n' ;;
                '-6 route get 2001:db8::10 from 2001:db8::2') printf '2001:db8::10 from 2001:db8::2 via 2001:db8::1 dev eth0\n' ;;
                '-6 route get fibmatch 2001:db8::10 from 2001:db8::2') printf '2001:db8::/64 dev eth0 src 2001:db8::2\n' ;;
                *) return 1 ;;
            esac
        }
        mock_success_metrics
        command_exists() { [[ "$1" != ping ]]; }
        timeout() { shift; "$@"; }
        peer_port_open() { :; }
        iperf3() {
            printf '%s\n' "$*" >> "$iperf_args_file"
            printf '%s\n' '{"end":{"sum_sent":{"bits_per_second":100000000,"bytes":1000000,"retransmits":0}}}'
        }
        MEASURE_IFACE=eth0
        measure_lock_peer v6.example eth0
        row=$(iperf_sample v6.example 5201 3 1)
        is_decimal "$(cut -f1 <<< "$row")" || fail "bound IPv6 sample did not produce goodput"
        assert_file_contains "$iperf_args_file" '-6 -c 2001:db8::10 -B 2001:db8::2' "iperf3 did not force IPv6 and bind its source"
        assert_file_not_contains "$iperf_args_file" 'v6.example' "IPv6 hostname reached iperf3"
    )
}

test_post_sample_route_drift_fails_and_restores() {
    (
        local drift_file="$TEST_ROOT/drift-after-iperf" applied_file="$TEST_ROOT/qdisc-applied"
        local restored_file="$TEST_ROOT/qdisc-restored" port_file="$TEST_ROOT/port-target" rc=0
        rm -f -- "$drift_file" "$applied_file" "$restored_file"; : > "$port_file"
        mock_ipv4_routes "$drift_file"
        resolve_route_target_addresses() {
            if [[ "$1" == peer.example ]]; then printf '4\t203.0.113.10\n'; else printf '4\t%s\n' "$1"; fi
        }
        mock_success_metrics
        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        detect_interface() { printf 'eth0\n'; }
        peer_port_open() { printf '%s\n' "$1" >> "$port_file"; }
        iperf_peer_usable() { :; }
        qdisc_guard() { :; }; detect_link_speed() { printf 'unknown\n'; }
        measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
        measure_begin() { MEASURE_IFACE="$1"; MEASURE_TX_START=0; MEASURE_RX_START=0; }
        measure_restore() { printf 'restored\n' > "$restored_file"; MEASURE_IFACE=""; measure_clear_peer_lock; }
        traffic_report() { :; }
        apply_fq() { printf 'applied\n' > "$applied_file"; }
        command_exists() { [[ "$1" != ping ]]; }
        timeout() { shift; "$@"; }
        iperf3() {
            printf 'drifted\n' > "$drift_file"
            printf '%s\n' '{"end":{"sum_sent":{"bits_per_second":100000000,"bytes":1000000,"retransmits":0}}}'
        }

        if measure_probe peer.example 5201 auto 3 1 >/dev/null 2>&1; then
            fail "post-sample route drift was reported as success"
        else
            rc=$?
        fi
        assert_eq 1 "$rc" "route drift exit status"
        [[ -f "$applied_file" ]] || fail "probe did not reach the temporary qdisc write"
        [[ -f "$restored_file" ]] || fail "route drift did not restore the qdisc transaction"
        assert_eq 203.0.113.10 "$(head -n1 "$port_file")" "formal port probe target"
        [[ ! -f "$MEASURE_RUN_DIR/summary.tsv" ]] || fail "route-drifted probe wrote a success summary"
    )
}

test_pre_sample_route_drift_never_runs_iperf() {
    (
        local drift_file="$TEST_ROOT/drift-before-iperf" iperf_file="$TEST_ROOT/pre-drift-iperf" rc=0
        rm -f -- "$drift_file" "$iperf_file"
        mock_ipv4_routes "$drift_file"
        resolve_route_target_addresses() {
            if [[ "$1" == peer.example ]]; then printf '4\t203.0.113.10\n'; else printf '4\t%s\n' "$1"; fi
        }
        command_exists() { [[ "$1" != ping ]]; }
        timeout() { shift; "$@"; }
        iperf3() { printf 'unexpected\n' > "$iperf_file"; }
        MEASURE_IFACE=eth0
        measure_lock_peer peer.example eth0
        printf 'drifted\n' > "$drift_file"
        if iperf_sample peer.example 5201 3 1 >/dev/null 2>&1; then
            fail "pre-sample route drift was accepted"
        else
            rc=$?
        fi
        assert_eq 1 "$rc" "pre-sample route drift exit status"
        [[ ! -f "$iperf_file" ]] || fail "iperf3 ran after the pre-sample route guard failed"
    )
}

test_measure_restore_retains_failed_snapshot_for_retry() {
    (
        local snapshot="$TEST_ROOT/measure-qdisc.snapshot" calls=0 rc=0
        printf 'snapshot\n' > "$snapshot"
        MEASURE_IFACE=eth0
        MEASURE_SNAPSHOT="$snapshot"
        MEASURE_PEER_HOST=peer.example
        MEASURE_PEER_ADDRESS=203.0.113.10
        MEASURE_PEER_SOURCE=192.0.2.10
        MEASURE_PEER_FAMILY=4
        MEASURE_PEER_IFACE=eth0
        restore_action_qdisc() {
            ((calls+=1))
            (( calls >= 2 )) || return 9
        }
        if measure_restore >/dev/null 2>&1; then
            fail "failed qdisc restore was reported as success"
        else
            rc=$?
        fi
        assert_eq 9 "$rc" "failed qdisc restore status"
        [[ -f "$snapshot" ]] || fail "failed qdisc restore deleted its only snapshot"
        assert_eq eth0 "$MEASURE_IFACE" "failed restore interface state"
        assert_eq "$snapshot" "$MEASURE_SNAPSHOT" "failed restore snapshot state"
        assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "failed restore peer lock state"
        if measure_begin eth0 >/dev/null 2>&1; then
            fail "a new measurement overwrote an unrecovered qdisc snapshot"
        fi
        assert_eq "$snapshot" "$MEASURE_SNAPSHOT" "unrecovered snapshot overwrite guard"

        measure_restore
        assert_eq 2 "$calls" "qdisc restore retry count"
        [[ ! -e "$snapshot" ]] || fail "successful qdisc restore retained stale snapshot"
        assert_eq '' "$MEASURE_IFACE" "successful restore interface cleanup"
        assert_eq '' "$MEASURE_SNAPSHOT" "successful restore snapshot cleanup"
        assert_eq '' "$MEASURE_PEER_ADDRESS" "successful restore peer lock cleanup"
    )
}

assert_formal_entry_locks_before_writes() {
    local label="$1"; shift
    (
        local events_file="$TEST_ROOT/events-$label" rc=0
        : > "$events_file"
        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        detect_interface() { printf 'detect\n' >> "$events_file"; printf 'eth0\n'; }
        measure_lock_peer() { printf 'lock\n' >> "$events_file"; return 42; }
        peer_port_open() { printf 'port\n' >> "$events_file"; }
        qdisc_guard() { printf 'qdisc\n' >> "$events_file"; }
        new_measure_run() { printf 'history\n' >> "$events_file"; }
        apply_fq() { printf 'write\n' >> "$events_file"; }
        apply_shaping() { printf 'write\n' >> "$events_file"; }
        if "$@" >/dev/null 2>&1; then fail "$label continued after lock failure"; else rc=$?; fi
        assert_eq 42 "$rc" "$label lock failure status"
        assert_eq 'lock' "$(sed '/^$/d' "$events_file")" "$label operation order"
    )
}

test_all_formal_entries_lock_before_writes() {
    assert_formal_entry_locks_before_writes probe measure_probe peer.example 5201 auto 3 1
    assert_formal_entry_locks_before_writes sweep measure_sweep peer.example 5201 auto 300 200 400 10 3 1 3 0.1 0 5000
    assert_formal_entry_locks_before_writes path-check measure_path_check peer.example 5201 auto 100
    assert_formal_entry_locks_before_writes verify measure_verify peer.example 5201 auto 3
    assert_formal_entry_locks_before_writes compare measure_compare peer.example 5201 auto 100 3 2
}

test_summary_keeps_hostname_and_locked_route() {
    (
        local drift_file="$TEST_ROOT/summary-no-drift" port_file="$TEST_ROOT/summary-port" summary
        rm -f -- "$drift_file"; : > "$port_file"
        mock_ipv4_routes "$drift_file"
        resolve_route_target_addresses() {
            if [[ "$1" == peer.example ]]; then printf '4\t203.0.113.10\n'; else printf '4\t%s\n' "$1"; fi
        }
        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        detect_interface() { printf 'eth0\n'; }
        peer_port_open() { printf '%s\n' "$1" >> "$port_file"; }
        iperf_peer_usable() { :; }
        qdisc_guard() { :; }; detect_link_speed() { printf 'unknown\n'; }
        measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
        measure_begin() {
            MEASURE_IFACE="$1"; MEASURE_TX_START=0; MEASURE_RX_START=0
            MEASURE_SNAPSHOT="$TEST_ROOT/summary-qdisc.snapshot"
            printf 'snapshot\n' > "$MEASURE_SNAPSHOT"
        }
        restore_action_qdisc() { :; }
        traffic_report() { :; }; apply_fq() { :; }
        sample_repeated() { printf '100\t0\t1000000\t0.00000\t0.000\t1\t2\t0\t10\t0\t0\t0.00\t2\t1\n'; }

        measure_probe peer.example 5201 auto 3 1
        summary="$MEASURE_RUN_DIR/summary.tsv"
        assert_eq peer.example "$(summary_value "$summary" PEER)" "summary hostname"
        assert_eq 203.0.113.10 "$(summary_value "$summary" LOCKED_ADDRESS)" "summary locked address"
        assert_eq 192.0.2.10 "$(summary_value "$summary" LOCKED_SOURCE)" "summary locked source"
        assert_eq eth0 "$(summary_value "$summary" LOCKED_INTERFACE)" "summary locked interface"
        assert_eq 4 "$(summary_value "$summary" LOCKED_FAMILY)" "summary locked family"
        assert_eq 203.0.113.10 "$(head -n1 "$port_file")" "formal port probe literal"
    )
}

test_real_loopback_integration() {
    local row
    [[ "${BBRV3_REAL_IPERF:-0}" == 1 ]] || return 0
    require_commands ip iperf3 jq ping timeout
    iperf3 -s -p 5219 > "$TEST_ROOT/iperf-server.log" 2>&1 & SERVER_PID=$!
    for _ in 1 2 3 4 5; do peer_port_open 127.0.0.1 5219 && break; sleep 1; done
    peer_port_open 127.0.0.1 5219 || fail "real loopback iperf3 server did not start"
    MEASURE_IFACE=lo
    measure_lock_peer 127.0.0.1 lo
    assert_eq 127.0.0.1 "$MEASURE_PEER_ADDRESS" "real loopback frozen address"
    assert_eq 127.0.0.1 "$MEASURE_PEER_SOURCE" "real loopback source"
    row=$(iperf_sample 127.0.0.1 5219 3 1)
    is_decimal "$(cut -f1 <<< "$row")" || fail "real bound loopback iperf3 sample failed"
    kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

    if ip -6 route get ::1 >/dev/null 2>&1; then
        iperf3 -s -B ::1 -p 5220 > "$TEST_ROOT/iperf6-server.log" 2>&1 & SERVER_PID=$!
        for _ in 1 2 3 4 5; do peer_port_open ::1 5220 && break; sleep 1; done
        peer_port_open ::1 5220 || fail "real IPv6 loopback iperf3 server did not start"
        MEASURE_IFACE=lo
        measure_lock_peer ::1 lo
        assert_eq ::1 "$MEASURE_PEER_ADDRESS" "real IPv6 loopback frozen address"
        assert_eq ::1 "$MEASURE_PEER_SOURCE" "real IPv6 loopback source"
        row=$(iperf_sample ::1 5220 3 1)
        is_decimal "$(cut -f1 <<< "$row")" || fail "real bound IPv6 loopback iperf3 sample failed"
        kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
    fi
}

test_hostname_is_resolved_once_and_iperf_is_bound
test_ipv6_literal_and_source_are_bound
test_post_sample_route_drift_fails_and_restores
test_pre_sample_route_drift_never_runs_iperf
test_measure_restore_retains_failed_snapshot_for_retry
test_all_formal_entries_lock_before_writes
test_summary_keeps_hostname_and_locked_route
test_real_loopback_integration

echo "measure v7.2.1 route-lock tests: OK"
