#!/usr/bin/env bash
# Run only in a disposable privileged container. The test builds a real
# dual-stack veth path while keeping IPv6 enabled on both endpoints.
# shellcheck disable=SC1091,SC2016,SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
NS_NAME="b8ifns${BASHPID}"
HOST_IF="b8ifh${BASHPID}"
PEER_IF="b8ifp${BASHPID}"
V4_LOCAL=198.51.100.1
V4_PEER=198.51.100.2
V6_LOCAL=2001:db8:801::1
V6_PEER=2001:db8:801::2
V4_PORT=5231
V6_PORT=5232
SERVER_PID=""

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stop_server() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

cleanup() {
    stop_server
    ip link del "$HOST_IF" >/dev/null 2>&1 || true
    ip netns del "$NS_NAME" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

[[ "$(id -u)" == 0 ]] || { echo "SKIP: root is required" >&2; exit 77; }
for command in ip iperf3 jq ping sysctl timeout; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "SKIP: $command is required" >&2
        exit 77
    }
done
ip netns add "$NS_NAME" 2>/dev/null || {
    echo "SKIP: network namespace capability is required" >&2
    exit 77
}

ip link add "$HOST_IF" type veth peer name "$PEER_IF"
ip link set "$PEER_IF" netns "$NS_NAME"

# Enable IPv6 only on the disposable veth/namespace interfaces. Do not toggle
# the container-wide all/default switches: this test must prove no workaround
# that globally disables IPv6 is necessary.
sysctl -qw "net.ipv6.conf.${HOST_IF}.disable_ipv6=0"
ip netns exec "$NS_NAME" sysctl -qw "net.ipv6.conf.${PEER_IF}.disable_ipv6=0"
ip netns exec "$NS_NAME" sysctl -qw net.ipv6.conf.lo.disable_ipv6=0

ip addr add "$V4_LOCAL/30" dev "$HOST_IF"
ip -6 addr add "$V6_LOCAL/64" dev "$HOST_IF" nodad
ip link set "$HOST_IF" up
ip -n "$NS_NAME" addr add "$V4_PEER/30" dev "$PEER_IF"
ip -n "$NS_NAME" -6 addr add "$V6_PEER/64" dev "$PEER_IF" nodad
ip -n "$NS_NAME" link set "$PEER_IF" up
ip -n "$NS_NAME" link set lo up

[[ "$(<"/proc/sys/net/ipv6/conf/${HOST_IF}/disable_ipv6")" == 0 ]] || fail "IPv6 is not enabled on $HOST_IF"
[[ "$(ip netns exec "$NS_NAME" cat "/proc/sys/net/ipv6/conf/${PEER_IF}/disable_ipv6")" == 0 ]] || fail "IPv6 is not enabled in the peer namespace"
ip -6 route get "$V6_PEER" >/dev/null || fail "real IPv6 candidate is not routeable"
ip -4 route get "$V4_PEER" >/dev/null || fail "real IPv4 candidate is not routeable"

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_MAX_BACKGROUND_TX_PERCENT=100
export BBRV3_MAX_CPU_STEAL_PERCENT=100
export BBRV3_MAX_CPU_BUSY_PERCENT=100

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

# Use a deterministic dual-stack resolver record while exercising real Linux
# routes, source binding, TCP sockets and iperf3. AAAA is deliberately first.
resolve_route_target_addresses() {
    case "$1" in
        dualstack.integration)
            printf '6\t%s\n4\t%s\n' "$V6_PEER" "$V4_PEER"
            ;;
        "$V6_PEER") printf '6\t%s\n' "$V6_PEER" ;;
        "$V4_PEER") printf '4\t%s\n' "$V4_PEER" ;;
        *) return 1 ;;
    esac
}

# The route is genuinely dual-stack, but the service listens only on IPv4.
# Endpoint selection must skip the unusable AAAA without changing IPv6 state.
ip netns exec "$NS_NAME" iperf3 -s -4 -B "$V4_PEER" -p "$V4_PORT" > "$TEST_ROOT/iperf4.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
    if timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$V4_PEER" "$V4_PORT" >/dev/null 2>&1; then break; fi
    sleep 1
done
timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$V4_PEER" "$V4_PORT" >/dev/null 2>&1 || fail "IPv4 iperf3 server did not start"

measure_lock_peer dualstack.integration "$HOST_IF" "$V4_PORT"
[[ "$MEASURE_PEER_FAMILY" == 4 ]] || fail "v4-only service locked IPv${MEASURE_PEER_FAMILY:-unknown}"
[[ "$MEASURE_PEER_ADDRESS" == "$V4_PEER" ]] || fail "v4-only service locked the wrong address"
[[ "$MEASURE_PEER_SOURCE" == "$V4_LOCAL" ]] || fail "v4-only service locked the wrong source"
MEASURE_IFACE="$HOST_IF"
row=$(iperf_sample dualstack.integration "$V4_PORT" 2 1)
is_decimal "$(cut -f1 <<< "$row")" || fail "real IPv4 fallback sample did not produce goodput"
[[ "$(<"/proc/sys/net/ipv6/conf/${HOST_IF}/disable_ipv6")" == 0 ]] || fail "IPv4 fallback disabled IPv6"

stop_server
measure_clear_peer_lock
MEASURE_IFACE=""

# With the same dual-stack name and both routes intact, an IPv6-only service
# must be selected after the IPv4 endpoint fails its real transport preflight.
ip netns exec "$NS_NAME" iperf3 -s -6 -B "$V6_PEER" -p "$V6_PORT" > "$TEST_ROOT/iperf6.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
    if timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$V6_PEER" "$V6_PORT" >/dev/null 2>&1; then break; fi
    sleep 1
done
timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$V6_PEER" "$V6_PORT" >/dev/null 2>&1 || fail "IPv6 iperf3 server did not start"

measure_lock_peer dualstack.integration "$HOST_IF" "$V6_PORT"
[[ "$MEASURE_PEER_FAMILY" == 6 ]] || fail "IPv6-only service did not trigger IPv6 fallback"
[[ "$MEASURE_PEER_ADDRESS" == "$V6_PEER" ]] || fail "IPv6-only service locked the wrong address"
[[ "$MEASURE_PEER_SOURCE" == "$V6_LOCAL" ]] || fail "IPv6-only service locked the wrong source"
MEASURE_IFACE="$HOST_IF"
row=$(iperf_sample dualstack.integration "$V6_PORT" 2 1)
is_decimal "$(cut -f1 <<< "$row")" || fail "real IPv6 fallback sample did not produce goodput"
[[ "$(<"/proc/sys/net/ipv6/conf/${HOST_IF}/disable_ipv6")" == 0 ]] || fail "IPv6 fallback changed IPv6 state"

measure_clear_peer_lock
MEASURE_IFACE=""

# Explicit IPv6 remains exact: with the same live service it must stay on
# IPv6 rather than re-resolving or silently changing family.
measure_lock_peer "$V6_PEER" "$HOST_IF" "$V6_PORT"
[[ "$MEASURE_PEER_FAMILY" == 6 ]] || fail "explicit IPv6 endpoint did not stay on IPv6"
[[ "$MEASURE_PEER_ADDRESS" == "$V6_PEER" ]] || fail "explicit IPv6 locked the wrong address"
[[ "$MEASURE_PEER_SOURCE" == "$V6_LOCAL" ]] || fail "explicit IPv6 locked the wrong source"
MEASURE_IFACE="$HOST_IF"
row=$(iperf_sample "$V6_PEER" "$V6_PORT" 2 1)
is_decimal "$(cut -f1 <<< "$row")" || fail "real explicit IPv6 sample did not produce goodput"
[[ "$(<"/proc/sys/net/ipv6/conf/${HOST_IF}/disable_ipv6")" == 0 ]] || fail "explicit IPv6 sample changed IPv6 state"

echo "iperf family integration test: OK ($HOST_IF)"
