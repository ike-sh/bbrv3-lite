#!/usr/bin/env bash
# shellcheck disable=SC2034
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
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: '$1' lacks '$2'"; }

ROUTE_GATEWAY=192.0.2.1
ROUTE_TABLE=100
ROUTE_MTU=1500
ROUTE_UID=0
MOCK_PMTU=1500
MOCK_PING_MODE=stable

install_path_mocks() {
    getent() { printf '203.0.113.10 STREAM peer.example\n'; }
    detect_mtu() { printf '1500\n'; }
    detect_interface() { printf 'eth0\n'; }
    ip() {
        local args="$*" address
        case "$args" in
            '-4 route get 203.0.113.10'|'-4 route get 203.0.113.11')
                address=${args##* }
                printf '%s via %s dev eth0 src 192.0.2.10 uid %s mtu %s cache rtt %s cwnd %s\n' \
                    "$address" "$ROUTE_GATEWAY" "$ROUTE_UID" "$ROUTE_MTU" "$ROUTE_UID" "$ROUTE_UID"
                ;;
            '-4 route get fibmatch 203.0.113.10'|'-4 route get fibmatch 203.0.113.11')
                printf '203.0.113.0/24 via %s dev eth0 table %s mtu %s\n' "$ROUTE_GATEWAY" "$ROUTE_TABLE" "$ROUTE_MTU"
                ;;
            '-4 route get 203.0.113.10 from 192.0.2.10'|'-4 route get 203.0.113.11 from 192.0.2.10')
                address=$(awk '{print $4}' <<< "$args")
                printf '%s from 192.0.2.10 via %s dev eth0 uid %s mtu %s cache rtt %s cwnd %s\n' \
                    "$address" "$ROUTE_GATEWAY" "$ROUTE_UID" "$ROUTE_MTU" "$ROUTE_UID" "$ROUTE_UID"
                ;;
            '-4 route get fibmatch 203.0.113.10 from 192.0.2.10'|'-4 route get fibmatch 203.0.113.11 from 192.0.2.10')
                printf '203.0.113.0/24 via %s dev eth0 table %s mtu %s\n' "$ROUTE_GATEWAY" "$ROUTE_TABLE" "$ROUTE_MTU"
                ;;
            *) return 1 ;;
        esac
    }
    ping() {
        local args=("$@") count=0 payload="" target="" icmp_overhead=28 i
        target="${args[${#args[@]}-1]}"
        for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
                -c) count="${args[$((i+1))]}" ;;
                -s) payload="${args[$((i+1))]}" ;;
            esac
        done
        if [[ " $* " == *' -M do '* ]]; then
            [[ -n "$payload" ]] || return 1
            [[ " $* " != *' -6 '* ]] || icmp_overhead=48
            (( payload + icmp_overhead <= MOCK_PMTU ))
            return
        fi
        if [[ "$target" == "$ROUTE_GATEWAY" ]]; then
            printf '%s\n' \
                "64 bytes from $target: time=0.4 ms" \
                "64 bytes from $target: time=0.5 ms" \
                "64 bytes from $target: time=0.6 ms"
            return 0
        fi
        case "$MOCK_PING_MODE" in
            stable)
                for value in 1 2 2 2 3 3 4; do printf '64 bytes from %s: time=%s ms\n' "$target" "$value"; done
                ;;
            unstable)
                printf '64 bytes from %s: time=10 ms\n' "$target"
                printf '64 bytes from %s: time=100 ms\n' "$target"
                return 1
                ;;
            unavailable) return 1 ;;
            *) return 1 ;;
        esac
        (( count > 0 ))
    }
}

lock_peer() {
    measure_lock_peer peer.example eth0 >/dev/null
}

test_route_and_endpoint_fingerprints() {
    (
        local one two route_one endpoint_one route_two endpoint_two
        install_path_mocks
        one=$(path_capture_route_identity 4 203.0.113.10 192.0.2.10 eth0)
        ROUTE_UID=999
        two=$(path_capture_route_identity 4 203.0.113.11 192.0.2.10 eth0)
        IFS=$'\t' read -r route_one endpoint_one _ <<< "$one"
        IFS=$'\t' read -r route_two endpoint_two _ <<< "$two"
        assert_eq "$route_one" "$route_two" "canonical route fingerprint"
        [[ "$endpoint_one" != "$endpoint_two" ]] || fail "endpoint fingerprint ignored target literal"
        [[ "$route_one" =~ ^[0-9a-f]{64}$ ]] || fail "route fingerprint is not SHA-256"
    )
}

test_gateway_table_and_mtu_drift_is_rejected() {
    (
        install_path_mocks
        lock_peer
        ROUTE_UID=1000
        path_verify_route_identity >/dev/null || fail "volatile uid/cache changed route identity"
        ROUTE_GATEWAY=192.0.2.254
        if path_verify_route_identity >/dev/null 2>&1; then fail "gateway drift was accepted"; fi
    )
    (
        install_path_mocks
        lock_peer
        ROUTE_TABLE=200
        if path_verify_route_identity >/dev/null 2>&1; then fail "routing-table drift was accepted"; fi
    )
    (
        install_path_mocks
        lock_peer
        ROUTE_MTU=1400
        if path_verify_route_identity >/dev/null 2>&1; then fail "route MTU drift was accepted"; fi
    )
}

test_stable_profile_and_pmtu() {
    (
        install_path_mocks
        MOCK_PMTU=1400
        lock_peer
        path_profile_capture 7 1
        assert_eq 7 "$PATH_PING_RECEIVED" "received ping samples"
        assert_eq 0.00 "$PATH_LOSS_PERCENT" "path loss"
        assert_eq 2 "$PATH_RTT_MEDIAN_MS" "median RTT"
        assert_eq 4 "$PATH_RTT_P95_MS" "p95 RTT"
        assert_eq 2.00 "$PATH_RTT_JITTER_P95_MS" "p95 jitter"
        assert_eq 1400 "$PATH_PMTU" "PMTU binary search"
        assert_eq 1360 "$PATH_MSS" "IPv4 TCP MSS"
        assert_eq stable "$PATH_STABILITY" "stable classification"
        assert_eq trusted "$PATH_DECISION" "stable tuning decision"
        assert_contains "$PATH_RISK_FLAGS" reduced-pmtu "reduced PMTU risk"
        path_profile_tuning_gate 0 >/dev/null || fail "stable path was rejected"
    )
}

test_ipv6_tcp_mss_math() {
    (
        install_path_mocks
        MEASURE_PEER_FAMILY=6
        PATH_INTERFACE_MTU=1500
        MOCK_PMTU=1280
        state=$(path_probe_pmtu 1)
        IFS=$'\t' read -r pmtu mss capped <<< "$state"
        assert_eq 1280 "$pmtu" "IPv6 PMTU"
        assert_eq 1220 "$mss" "IPv6 TCP MSS"
        assert_eq 0 "$capped" "IPv6 PMTU cap flag"
    )
}

test_unstable_and_unknown_profiles() {
    (
        install_path_mocks
        MOCK_PING_MODE=unstable
        lock_peer
        path_profile_capture 7 1
        assert_eq unsafe "$PATH_DECISION" "unstable decision"
        assert_eq unstable "$PATH_STABILITY" "unstable classification"
        if path_profile_tuning_gate 0 >/dev/null 2>&1; then fail "unsafe path passed automatic gate"; fi
        path_profile_tuning_gate 1 >/dev/null || fail "explicit force did not bypass quality-only path gate"
    )
    (
        install_path_mocks
        MOCK_PING_MODE=unavailable
        lock_peer
        path_profile_capture 7 0
        assert_eq limited "$PATH_DECISION" "ICMP-unavailable decision"
        assert_eq unknown "$PATH_STABILITY" "ICMP-unavailable stability"
        assert_contains "$PATH_RISK_FLAGS" icmp-unavailable "missing ICMP risk"
        path_profile_tuning_gate 0 >/dev/null || fail "ICMP-blocked path should degrade rather than hard-fail"
    )
}

test_history_and_latest_path() {
    (
        local summary brief
        install_path_mocks
        require_root() { :; }
        acquire_lock() { :; }
        measure_path_profile peer.example eth0 7 1 >/dev/null
        summary=$(latest_path_summary) || fail "latest path summary missing"
        grep -Fq $'TYPE\tpath' "$summary" || fail "path history type missing"
        grep -Fq $'PATH_PROFILE_SCHEMA\t1' "$summary" || fail "path schema missing"
        grep -Eq $'PATH_ROUTE_FINGERPRINT\t[0-9a-f]{64}' "$summary" || fail "path fingerprint missing from history"
        [[ -f "$(dirname "$summary")/path-rtt.tsv" ]] || fail "raw path RTT history missing"
        brief=$(latest_path_brief)
        assert_contains "$brief" 'peer.example / eth0 / IPv4' "latest path status"
    )
}

test_path_confidence_penalty() {
    local result
    result=$(measurement_confidence 3 1.0 10 0 0 30)
    assert_eq 65 "$(cut -f1 <<< "$result")" "path confidence penalty"
    assert_contains "$(cut -f3 <<< "$result")" path-unsafe "path penalty reason"
}

run_test() { printf '==> %s\n' "$1"; "$1"; }
run_test test_route_and_endpoint_fingerprints
run_test test_gateway_table_and_mtu_drift_is_rejected
run_test test_stable_profile_and_pmtu
run_test test_ipv6_tcp_mss_math
run_test test_unstable_and_unknown_profiles
run_test test_history_and_latest_path
run_test test_path_confidence_penalty
printf 'path v7.3.0 tests: OK\n'
