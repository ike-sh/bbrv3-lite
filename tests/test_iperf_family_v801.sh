#!/usr/bin/env bash
# Dual-stack endpoint selection regressions for v8.0.1.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh measure.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

assert_lock_empty() {
    assert_eq "" "$MEASURE_PEER_HOST" "$1 host"
    assert_eq "" "$MEASURE_PEER_ADDRESS" "$1 address"
    assert_eq "" "$MEASURE_PEER_SOURCE" "$1 source"
    assert_eq "" "$MEASURE_PEER_FAMILY" "$1 family"
    assert_eq "" "$MEASURE_PEER_IFACE" "$1 interface"
    assert_eq "" "$MEASURE_PEER_PORT" "$1 port"
}

install_route_and_path_mocks() {
    IPV4_ROUTE_AVAILABLE=1
    IPV6_ROUTE_AVAILABLE=1
    ROUTE_DRIFTED=0

    measure_capture_route_state() {
        local family="$1" address="$2" expected_iface="$3" expected_source="${4:-}" source
        [[ "$expected_iface" == eth0 ]] || return 1
        case "$family:$address" in
            4:203.0.113.10)
                (( IPV4_ROUTE_AVAILABLE )) || return 1
                source=192.0.2.10
                ;;
            6:2001:db8::10)
                (( IPV6_ROUTE_AVAILABLE )) || return 1
                source=2001:db8::2
                ;;
            *) return 1 ;;
        esac
        (( ROUTE_DRIFTED == 0 )) || return 1
        [[ -z "$expected_source" || "$expected_source" == "$source" ]] || return 1
        printf 'eth0\t%s\n' "$source"
    }

    path_lock_route_identity() {
        PATH_ROUTE_FINGERPRINT=$(printf 'a%.0s' {1..64})
        PATH_ENDPOINT_FINGERPRINT=$(printf 'b%.0s' {1..64})
        PATH_GATEWAY=none
        PATH_TABLE=main
        PATH_INTERFACE_MTU=1500
        PATH_ROUTE_MTU=1500
    }

    path_verify_route_identity() {
        (( ROUTE_DRIFTED == 0 ))
    }
}

install_dual_stack_resolver() {
    RESOLVE_COUNT_FILE="$1"
    printf '0\n' > "$RESOLVE_COUNT_FILE"
    resolve_route_target_addresses() {
        local target="$1" calls
        calls=$(<"$RESOLVE_COUNT_FILE")
        printf '%s\n' "$((calls + 1))" > "$RESOLVE_COUNT_FILE"
        case "$target" in
            dual.example)
                # Deliberately put AAAA first to reproduce systems whose
                # resolver prefers IPv6 despite an unusable IPv6 transport.
                printf '6\t2001:db8::10\n4\t203.0.113.10\n'
                ;;
            2001:db8::10) printf '6\t2001:db8::10\n' ;;
            203.0.113.10) printf '4\t203.0.113.10\n' ;;
            *) return 1 ;;
        esac
    }
}

test_unroutable_aaaa_falls_back_to_a() (
    local resolve_count="$TEST_ROOT/resolve-unroutable"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV6_ROUTE_AVAILABLE=0
    peer_port_open() { :; }
    iperf_peer_usable() { :; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 4 "$MEASURE_PEER_FAMILY" "unroutable AAAA fallback family"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "unroutable AAAA fallback address"
    assert_eq 192.0.2.10 "$MEASURE_PEER_SOURCE" "unroutable AAAA fallback source"
    assert_eq 1 "$(<"$resolve_count")" "unroutable AAAA resolver count"
)

test_aaaa_closed_port_falls_back_to_a() (
    local resolve_count="$TEST_ROOT/resolve-closed-port"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { [[ "$1" == 203.0.113.10 ]]; }
    iperf_peer_usable() { [[ "$1" == 203.0.113.10 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 4 "$MEASURE_PEER_FAMILY" "closed IPv6 port fallback family"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "closed IPv6 port fallback address"
)

test_aaaa_open_port_but_unusable_iperf_falls_back_to_a() (
    local resolve_count="$TEST_ROOT/resolve-unusable-iperf"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { :; }
    iperf_peer_usable() { [[ "$1" == 203.0.113.10 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 4 "$MEASURE_PEER_FAMILY" "unusable IPv6 iperf fallback family"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "unusable IPv6 iperf fallback address"
)

test_unroutable_a_falls_back_to_aaaa() (
    local resolve_count="$TEST_ROOT/resolve-unroutable-v4"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV4_ROUTE_AVAILABLE=0
    peer_port_open() { :; }
    iperf_peer_usable() { :; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 6 "$MEASURE_PEER_FAMILY" "unroutable A fallback family"
    assert_eq 2001:db8::10 "$MEASURE_PEER_ADDRESS" "unroutable A fallback address"
    assert_eq 2001:db8::2 "$MEASURE_PEER_SOURCE" "unroutable A fallback source"
    assert_eq 1 "$(<"$resolve_count")" "unroutable A resolver count"
)

test_a_closed_port_falls_back_to_aaaa() (
    local resolve_count="$TEST_ROOT/resolve-v4-closed-port"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { [[ "$1" == 2001:db8::10 ]]; }
    iperf_peer_usable() { [[ "$1" == 2001:db8::10 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 6 "$MEASURE_PEER_FAMILY" "closed IPv4 port fallback family"
    assert_eq 2001:db8::10 "$MEASURE_PEER_ADDRESS" "closed IPv4 port fallback address"
)

test_a_open_port_but_unusable_iperf_falls_back_to_aaaa() (
    local resolve_count="$TEST_ROOT/resolve-v4-unusable-iperf"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { :; }
    iperf_peer_usable() { [[ "$1" == 2001:db8::10 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 6 "$MEASURE_PEER_FAMILY" "unusable IPv4 iperf fallback family"
    assert_eq 2001:db8::10 "$MEASURE_PEER_ADDRESS" "unusable IPv4 iperf fallback address"
)

test_explicit_ipv6_never_falls_back() (
    local resolve_count="$TEST_ROOT/resolve-explicit-v6" rc=0
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { :; }
    iperf_peer_usable() { return 1; }

    if measure_lock_peer 2001:db8::10 eth0 5201 >/dev/null 2>&1; then
        fail "unusable explicit IPv6 endpoint unexpectedly succeeded"
    else
        rc=$?
    fi
    assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "explicit IPv6 unavailable status"
    assert_eq 1 "$(<"$resolve_count")" "explicit IPv6 resolver count"
    assert_lock_empty "explicit IPv6 failure leaked a lock"
)

test_all_candidates_unavailable_returns_75() (
    local resolve_count="$TEST_ROOT/resolve-all-unavailable" rc=0
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    peer_port_open() { :; }
    iperf_peer_usable() { return 1; }

    if measure_lock_peer dual.example eth0 5201 >/dev/null 2>&1; then
        fail "hostname with no usable endpoint unexpectedly succeeded"
    else
        rc=$?
    fi
    assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "all endpoints unavailable status"
    assert_lock_empty "all-endpoint failure leaked a lock"
)

test_invalid_relock_clears_previous_endpoint() (
    local resolve_count="$TEST_ROOT/resolve-invalid-relock" rc=0
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV6_ROUTE_AVAILABLE=0
    peer_port_open() { :; }
    iperf_peer_usable() { :; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    [[ -n "$MEASURE_PEER_ADDRESS" ]] || fail "precondition lock was not created"
    if measure_lock_peer dual.example 'bad iface' 5201 >/dev/null 2>&1; then
        fail "invalid interface unexpectedly re-locked endpoint"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "invalid re-lock interface status"
    assert_lock_empty "invalid interface retained stale lock"

    measure_lock_peer dual.example eth0 5201 >/dev/null
    if measure_lock_peer dual.example eth0 70000 >/dev/null 2>&1; then
        fail "invalid port unexpectedly re-locked endpoint"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "invalid re-lock port status"
    assert_lock_empty "invalid port retained stale lock"

    measure_lock_peer dual.example eth0 5201 >/dev/null
    if measure_lock_requested_peer dual.example 5201 'bad iface' >/dev/null 2>&1; then
        fail "invalid wrapper interface unexpectedly re-locked endpoint"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "invalid wrapper interface status"
    assert_lock_empty "invalid wrapper interface retained stale lock"
)

test_path_lock_gains_exact_port_before_sample() (
    local resolve_count="$TEST_ROOT/resolve-path-to-sample" checks="$TEST_ROOT/path-to-sample-checks"
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV6_ROUTE_AVAILABLE=0
    : > "$checks"
    peer_port_open() {
        printf 'tcp\t%s\t%s\n' "$1" "$2" >> "$checks"
        [[ "$1" == 203.0.113.10 && "$2" == 5201 ]]
    }
    iperf_peer_usable() {
        printf 'iperf\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$checks"
        [[ "$1" == 203.0.113.10 && "$2" == 5201 && "$3" == 4 && "$4" == 192.0.2.10 ]]
    }

    measure_lock_peer dual.example eth0 >/dev/null
    assert_eq "" "$MEASURE_PEER_PORT" "path-only lock unexpectedly had a port"
    measure_require_sample_lock dual.example 5201 >/dev/null
    assert_eq 5201 "$MEASURE_PEER_PORT" "sample did not freeze its preflighted port"
    grep -Fxq $'tcp\t203.0.113.10\t5201' "$checks" || fail "path-to-sample TCP preflight missing"
    grep -Fxq $'iperf\t203.0.113.10\t5201\t4\t192.0.2.10' "$checks" || fail "path-to-sample iperf preflight missing"
)

test_public_filter_uses_selected_endpoint_rtt() (
    require_commands() { :; }
    PUBLIC_PEER_POOL='dual.example|测试|Provider'
    peer_route_rtt() { printf '5\n'; }
    public_peer_ports() {
        # Host-level RTT came from another address. The endpoint actually
        # selected for iperf3 is outside the configured latency boundary.
        printf '5201\t203.0.113.10\t4\t192.0.2.10\teth0\t999\n'
    }
    if BBRV3_PEER_MAX_RTT=120 BBRV3_PUBLIC_PEER_CANDIDATES=2 auto_pick_peer auto >/dev/null 2>&1; then
        fail "public selection accepted endpoint RTT above the configured limit"
    fi
    assert_eq 0 "${#PUBLIC_PEER_CANDIDATES[@]}" "over-limit endpoint leaked into public candidates"

    public_peer_ports() {
        printf '5201\t203.0.113.10\t4\t192.0.2.10\teth0\t5\n'
    }
    BBRV3_PEER_MAX_RTT='not-a-number' BBRV3_PUBLIC_PEER_CANDIDATES=2 auto_pick_peer auto >/dev/null
    assert_eq 1 "${#PUBLIC_PEER_CANDIDATES[@]}" "invalid RTT environment value did not fall back safely"
)

test_frozen_endpoint_is_not_resolved_again_and_drift_still_fails() (
    local resolve_count="$TEST_ROOT/resolve-frozen" rc=0
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV6_ROUTE_AVAILABLE=0
    peer_port_open() { [[ "$1" == 203.0.113.10 ]]; }
    iperf_peer_usable() { [[ "$1" == 203.0.113.10 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    assert_eq 1 "$(<"$resolve_count")" "initial resolver count"
    measure_require_sample_lock dual.example 5201 >/dev/null
    assert_eq 1 "$(<"$resolve_count")" "frozen sample re-resolved hostname"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "frozen endpoint changed"

    ROUTE_DRIFTED=1
    if measure_require_sample_lock dual.example 5201 >/dev/null 2>&1; then
        fail "route drift was accepted after endpoint-family fallback"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "route drift status"
    assert_eq 1 "$(<"$resolve_count")" "route-drift guard re-resolved hostname"
)

test_frozen_endpoint_rejects_port_drift() (
    local resolve_count="$TEST_ROOT/resolve-port-drift" rc=0
    install_route_and_path_mocks
    install_dual_stack_resolver "$resolve_count"
    IPV6_ROUTE_AVAILABLE=0
    peer_port_open() { [[ "$1" == 203.0.113.10 && "$2" == 5201 ]]; }
    iperf_peer_usable() { [[ "$1" == 203.0.113.10 && "$2" == 5201 ]]; }

    measure_lock_peer dual.example eth0 5201 >/dev/null
    if measure_require_sample_lock dual.example 5202 >/dev/null 2>&1; then
        fail "a sample changed the frozen endpoint port"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "frozen port drift status"
    assert_eq 5201 "$MEASURE_PEER_PORT" "frozen port changed after rejection"
    assert_eq 1 "$(<"$resolve_count")" "port-drift guard re-resolved hostname"
)

test_preferred_tuple_bypasses_changed_dns_and_stays_frozen() (
    local resolve_count="$TEST_ROOT/resolve-preferred" probe_count="$TEST_ROOT/probe-preferred"
    install_route_and_path_mocks
    printf '0\n' > "$resolve_count"
    : > "$probe_count"
    resolve_route_target_addresses() {
        local calls
        calls=$(<"$resolve_count")
        printf '%s\n' "$((calls + 1))" > "$resolve_count"
        # A changed DNS answer must be irrelevant to a tuple frozen during
        # public endpoint discovery.
        printf '4\t198.51.100.99\n6\t2001:db8:ffff::99\n'
    }
    peer_port_open() {
        [[ "$1" == 203.0.113.10 && "$2" == 5207 ]] || return 1
        printf 'tcp\t%s\t%s\n' "$1" "$2" >> "$probe_count"
    }
    iperf_peer_usable() {
        [[ "$1" == 203.0.113.10 && "$2" == 5207 && "$3" == 4 && "$4" == 192.0.2.10 ]] || return 1
        printf 'iperf\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$probe_count"
    }

    measure_lock_peer public.example eth0 5207 203.0.113.10 192.0.2.10 >/dev/null
    assert_eq 0 "$(<"$resolve_count")" "preferred tuple unexpectedly resolved DNS"
    assert_eq public.example "$MEASURE_PEER_HOST" "preferred tuple host"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "preferred tuple address"
    assert_eq 192.0.2.10 "$MEASURE_PEER_SOURCE" "preferred tuple source"
    assert_eq 4 "$MEASURE_PEER_FAMILY" "preferred tuple family"
    assert_eq eth0 "$MEASURE_PEER_IFACE" "preferred tuple interface"
    assert_eq 5207 "$MEASURE_PEER_PORT" "preferred tuple port"
    grep -Fxq $'tcp\t203.0.113.10\t5207' "$probe_count" || fail "preferred TCP preflight used another tuple"
    grep -Fxq $'iperf\t203.0.113.10\t5207\t4\t192.0.2.10' "$probe_count" || fail "preferred iperf preflight used another tuple"

    measure_require_sample_lock public.example 5207 >/dev/null
    assert_eq 0 "$(<"$resolve_count")" "frozen preferred tuple was re-resolved"
    assert_eq 203.0.113.10 "$MEASURE_PEER_ADDRESS" "preferred tuple address changed after guard"
    assert_eq 192.0.2.10 "$MEASURE_PEER_SOURCE" "preferred tuple source changed after guard"
    assert_eq eth0 "$MEASURE_PEER_IFACE" "preferred tuple interface changed after guard"
    assert_eq 5207 "$MEASURE_PEER_PORT" "preferred tuple port changed after guard"
)

test_auto_interface_tracks_selected_family_and_wrong_explicit_iface_fails() (
    local resolve_count="$TEST_ROOT/resolve-multi-iface" rc=0
    install_dual_stack_resolver "$resolve_count"
    target_route_records() {
        case "$1" in
            203.0.113.10) printf '4\t203.0.113.10\teth0\n' ;;
            2001:db8::10) printf '6\t2001:db8::10\teth1\n' ;;
            *) return 1 ;;
        esac
    }
    measure_capture_route_state() {
        local family="$1" address="$2" expected_iface="$3" expected_source="${4:-}" source
        case "$family:$address:$expected_iface" in
            4:203.0.113.10:eth0) source=192.0.2.10 ;;
            6:2001:db8::10:eth1) source=2001:db8::2 ;;
            *) return 1 ;;
        esac
        [[ -z "$expected_source" || "$expected_source" == "$source" ]] || return 1
        printf '%s\t%s\n' "$expected_iface" "$source"
    }
    interface_is_excluded() { return 1; }
    peer_port_open() { [[ "$1" == 2001:db8::10 ]]; }
    iperf_peer_usable() { [[ "$1" == 2001:db8::10 ]]; }
    path_lock_route_identity() {
        PATH_ROUTE_FINGERPRINT=$(printf 'c%.0s' {1..64})
        PATH_ENDPOINT_FINGERPRINT=$(printf 'd%.0s' {1..64})
    }
    path_verify_route_identity() { :; }

    measure_lock_peer dual.example auto 5201 >/dev/null
    assert_eq 6 "$MEASURE_PEER_FAMILY" "multi-interface selected family"
    assert_eq eth1 "$MEASURE_PEER_IFACE" "auto did not follow selected endpoint interface"
    assert_eq 2001:db8::10 "$MEASURE_PEER_ADDRESS" "multi-interface selected address"
    measure_clear_peer_lock

    # An explicit literal cannot silently jump from its real eth0 route to an
    # operator-requested eth1 interface.
    if measure_lock_peer 203.0.113.10 eth1 5201 >/dev/null 2>&1; then
        fail "explicit endpoint accepted the wrong interface"
    else
        rc=$?
    fi
    assert_eq 1 "$rc" "wrong explicit interface status"
    assert_lock_empty "wrong explicit interface leaked a lock"
)

test_unroutable_aaaa_falls_back_to_a
test_aaaa_closed_port_falls_back_to_a
test_aaaa_open_port_but_unusable_iperf_falls_back_to_a
test_unroutable_a_falls_back_to_aaaa
test_a_closed_port_falls_back_to_aaaa
test_a_open_port_but_unusable_iperf_falls_back_to_aaaa
test_explicit_ipv6_never_falls_back
test_all_candidates_unavailable_returns_75
test_invalid_relock_clears_previous_endpoint
test_path_lock_gains_exact_port_before_sample
test_public_filter_uses_selected_endpoint_rtt
test_frozen_endpoint_is_not_resolved_again_and_drift_still_fails
test_frozen_endpoint_rejects_port_drift
test_preferred_tuple_bypasses_changed_dns_and_stays_frozen
test_auto_interface_tracks_selected_family_and_wrong_explicit_iface_fails

echo "iperf family v8.0.1 tests: OK"
