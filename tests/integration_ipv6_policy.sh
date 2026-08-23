#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d /var/tmp/bbrv3-ipv6-policy.XXXXXX)
NS=bbrv740
HOST_IF=v740host
NS_IF=v740ns

cleanup() {
    local rc=$?
    set +e
    ip netns del "$NS" >/dev/null 2>&1
    ip link del "$HOST_IF" >/dev/null 2>&1
    rm -rf -- "$TEST_ROOT"
    return "$rc"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'integration_ipv6_policy.sh requires root'
command -v ip >/dev/null 2>&1 || fail 'integration_ipv6_policy.sh requires iproute2'

ip netns del "$NS" >/dev/null 2>&1 || true
ip link del "$HOST_IF" >/dev/null 2>&1 || true
ip netns add "$NS"
ip link add "$HOST_IF" type veth peer name "$NS_IF"
ip link set "$NS_IF" netns "$NS"
ip addr add 192.0.2.1/24 dev "$HOST_IF"
ip link set "$HOST_IF" up
ip -n "$NS" link set lo up
ip -n "$NS" addr add 192.0.2.2/24 dev "$NS_IF"
ip -n "$NS" link set "$NS_IF" up
ip -n "$NS" route add default via 192.0.2.1

ip netns exec "$NS" env \
    BBRV3_TEST_ROOT="$TEST_ROOT" \
    BBRV3_ROOT_DIR="$ROOT_DIR" \
    BBRV3_STATE_DIR="$TEST_ROOT/state" \
    BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline" \
    BBRV3_HISTORY_DIR="$TEST_ROOT/state/history" \
    BBRV3_IPV6_BACKUP_DIR="$TEST_ROOT/state/ipv6" \
    BBRV3_IPV6_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite-ipv6.conf" \
    BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock" \
    BBRV3_NS_IF="$NS_IF" \
    bash <<'INNER'
set -Eeuo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3: missing '$2'"; }

# shellcheck source=../src/00-header.sh
source "$BBRV3_ROOT_DIR/src/00-header.sh"
# shellcheck source=../src/core.sh
source "$BBRV3_ROOT_DIR/src/core.sh"
# shellcheck source=../src/state.sh
source "$BBRV3_ROOT_DIR/src/state.sh"
# shellcheck source=../src/ipv6.sh
source "$BBRV3_ROOT_DIR/src/ipv6.sh"
# shellcheck source=../src/ipv6-policy.sh
source "$BBRV3_ROOT_DIR/src/ipv6-policy.sh"

# This runs inside a dedicated network namespace in a privileged disposable
# container. Keep every production topology/snapshot/transaction check, while
# bypassing only the generic container guard.
require_host_network_control() { :; }
SSH_CONNECTION=""

iface="$BBRV3_NS_IF"
default_before=$(<"/proc/sys/net/ipv6/conf/default/disable_ipv6")
iface_before=$(<"/proc/sys/net/ipv6/conf/$iface/disable_ipv6")
lo_before=$(<"/proc/sys/net/ipv6/conf/lo/disable_ipv6")
all_before=$(<"/proc/sys/net/ipv6/conf/all/disable_ipv6")

plan=$(ipv6_policy_plan disabled-temporary)
assert_contains "$plan" 'Decision               ready' 'temporary plan was not ready'
assert_contains "$plan" 'Plan mutation          none (read-only)' 'temporary plan was not marked read-only'
[[ ! -e "$IPV6_BACKUP_DIR/baseline" && ! -e "$IPV6_SYSCTL_FILE" ]] || fail 'IPv6 plan mutated files or baseline'
assert_eq "$default_before" "$(<"/proc/sys/net/ipv6/conf/default/disable_ipv6")" 'plan changed default flag'
assert_eq "$iface_before" "$(<"/proc/sys/net/ipv6/conf/$iface/disable_ipv6")" 'plan changed interface flag'
assert_eq "$lo_before" "$(<"/proc/sys/net/ipv6/conf/lo/disable_ipv6")" 'plan changed loopback flag'

ipv6_policy_apply disabled-temporary >/dev/null
assert_eq 1 "$(<"/proc/sys/net/ipv6/conf/default/disable_ipv6")" 'temporary policy did not disable default'
assert_eq 1 "$(<"/proc/sys/net/ipv6/conf/$iface/disable_ipv6")" 'temporary policy did not disable interface'
assert_eq "$lo_before" "$(<"/proc/sys/net/ipv6/conf/lo/disable_ipv6")" 'temporary policy changed loopback'
assert_eq "$all_before" "$(<"/proc/sys/net/ipv6/conf/all/disable_ipv6")" 'temporary policy wrote all trigger'
[[ ! -e "$IPV6_SYSCTL_FILE" ]] || fail 'temporary policy left a persistent file'
ipv6_policy_verify disabled-temporary

ipv6_policy_apply native >/dev/null
assert_eq "$default_before" "$(<"/proc/sys/net/ipv6/conf/default/disable_ipv6")" 'native restore missed default'
assert_eq "$iface_before" "$(<"/proc/sys/net/ipv6/conf/$iface/disable_ipv6")" 'native restore missed interface'
assert_eq "$lo_before" "$(<"/proc/sys/net/ipv6/conf/lo/disable_ipv6")" 'native restore changed loopback'
assert_eq "$all_before" "$(<"/proc/sys/net/ipv6/conf/all/disable_ipv6")" 'native restore wrote all trigger'

ipv6_policy_apply disabled-persistent >/dev/null
[[ -f "$IPV6_SYSCTL_FILE" ]] || fail 'persistent policy file is absent'
grep -Fxq '# Policy: disabled-persistent' "$IPV6_SYSCTL_FILE" || fail 'persistent policy marker is absent'
grep -Fqx 'net/ipv6/conf/default/disable_ipv6 = 1' "$IPV6_SYSCTL_FILE" || fail 'persistent default rule is absent'
grep -Fqx "net/ipv6/conf/$iface/disable_ipv6 = 1" "$IPV6_SYSCTL_FILE" || fail 'persistent interface rule is absent'
! grep -Eq 'conf/(all|lo)/|conf[.](all|lo)[.]' "$IPV6_SYSCTL_FILE" || fail 'persistent policy modifies all/lo'
ipv6_policy_verify disabled-persistent

ipv6_policy_apply native >/dev/null
[[ ! -e "$IPV6_SYSCTL_FILE" ]] || fail 'final native restore left persistent policy'
assert_eq "$iface_before" "$(<"/proc/sys/net/ipv6/conf/$iface/disable_ipv6")" 'final restore missed interface'
assert_eq "$lo_before" "$(<"/proc/sys/net/ipv6/conf/lo/disable_ipv6")" 'final restore changed loopback'
printf 'integration IPv6 policy tests passed\n'
INNER
