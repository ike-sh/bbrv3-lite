#!/usr/bin/env bash
# Run only in a disposable privileged container/network namespace.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
NS_NAME="bvpns${BASHPID}"
HOST_IF="bvph${BASHPID}"
PEER_IF="bvpp${BASHPID}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    ip link del "$HOST_IF" >/dev/null 2>&1 || true
    ip netns del "$NS_NAME" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

[[ "$(id -u)" == 0 ]] || { echo "SKIP: root is required" >&2; exit 77; }
command -v ip >/dev/null 2>&1 && command -v ping >/dev/null 2>&1 || {
    echo "SKIP: iproute2 and iputils-ping are required" >&2
    exit 77
}
if ! ip netns add "$NS_NAME" 2>/dev/null; then
    echo "SKIP: network namespace capability is required" >&2
    exit 77
fi

ip link add "$HOST_IF" type veth peer name "$PEER_IF"
ip link set "$PEER_IF" netns "$NS_NAME"
ip addr add 198.51.100.1/30 dev "$HOST_IF"
ip link set "$HOST_IF" mtu 1500 up
ip -n "$NS_NAME" addr add 198.51.100.2/30 dev "$PEER_IF"
ip -n "$NS_NAME" link set "$PEER_IF" mtu 1500 up
ip -n "$NS_NAME" link set lo up

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_PATH_PMTU_CAP=1500

# Exercise the public CLI over a real isolated path. No qdisc, route, address,
# DNS or persistent tuning file may be changed by the command itself.
bash "$ROOT_DIR/net-tcp-tune.sh" measure path \
    --peer 198.51.100.2 --interface "$HOST_IF" --samples 3

summary=$(find "$BBRV3_HISTORY_DIR" -type f -name summary.tsv -print -quit)
[[ -n "$summary" ]] || fail "measure path did not create a summary"
grep -Eq $'^PATH_ROUTE_FINGERPRINT\t[0-9a-f]{64}$' "$summary" || fail "route fingerprint is missing"
grep -Eq $'^PATH_ENDPOINT_FINGERPRINT\t[0-9a-f]{64}$' "$summary" || fail "endpoint fingerprint is missing"
grep -Eq $'^PATH_PMTU\t1500$' "$summary" || fail "real PMTU probe did not find 1500"
grep -Eq $'^PATH_MSS\t1460$' "$summary" || fail "real IPv4 TCP MSS calculation is wrong"
grep -Eq $'^PATH_DECISION\ttrusted$' "$summary" || fail "stable local path was not trusted"
grep -Eq $'^PATH_PING_RECEIVED\t3$' "$summary" || fail "real RTT samples were not recorded"

# The public CLI must also propagate --samples and --no-pmtu instead of
# silently falling back to the automatic-tuning defaults.
NO_PMTU_STATE="$TEST_ROOT/no-pmtu/state"
BBRV3_CONFIG="$TEST_ROOT/no-pmtu/config" \
BBRV3_STATE_DIR="$NO_PMTU_STATE" \
BBRV3_BASELINE_DIR="$NO_PMTU_STATE/baseline" \
BBRV3_HISTORY_DIR="$NO_PMTU_STATE/history" \
BBRV3_LOCK_FILE="$TEST_ROOT/no-pmtu/lock" \
    bash "$ROOT_DIR/net-tcp-tune.sh" measure path \
        --peer 198.51.100.2 --interface "$HOST_IF" --samples 4 --no-pmtu >/dev/null
no_pmtu_summary=$(find "$NO_PMTU_STATE/history" -type f -name summary.tsv -print -quit)
[[ -n "$no_pmtu_summary" ]] || fail "--no-pmtu run did not create a summary"
grep -Eq $'^PATH_PING_RECEIVED\t4$' "$no_pmtu_summary" || fail "--samples was not propagated"
grep -Eq $'^PATH_PMTU\tdisabled$' "$no_pmtu_summary" || fail "--no-pmtu was not propagated"
grep -Eq $'^PATH_MSS\tunknown$' "$no_pmtu_summary" || fail "disabled PMTU reported an MSS"

# Lock the same route, then alter only its route-level MTU. The endpoint still
# responds, but the forwarding identity must be treated as changed.
# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"
measure_lock_peer 198.51.100.2 "$HOST_IF"
locked_fingerprint="$PATH_ROUTE_FINGERPRINT"
ip route replace 198.51.100.0/30 dev "$HOST_IF" src 198.51.100.1 mtu 1400
if path_verify_route_identity; then
    fail "route MTU drift was accepted after the path was locked"
fi
[[ "$PATH_ROUTE_FINGERPRINT" == "$locked_fingerprint" ]] || fail "locked fingerprint was mutated after rejection"
measure_clear_peer_lock

echo "path integration test: OK ($HOST_IF)"
