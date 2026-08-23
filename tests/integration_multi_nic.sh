#!/usr/bin/env bash
# Real qdisc validation in a disposable privileged container/network namespace.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_ALLOW_VIRTUAL_NIC=1
export TMPDIR="$TEST_ROOT/tmp"
mkdir -p "$TMPDIR"

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

cleanup() {
    ip link del bbrv8a >/dev/null 2>&1 || true
    ip link del bbrv8b >/dev/null 2>&1 || true
    remove_tree_within "$TEST_ROOT" "$(dirname "$TEST_ROOT")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_commands ip tc
tc qdisc show >/dev/null 2>&1 || { echo 'CAP_NET_ADMIN is required' >&2; exit 1; }
ip link add bbrv8a type veth peer name bbrv8ap
ip link add bbrv8b type veth peer name bbrv8bp
ip link set bbrv8a up
ip link set bbrv8ap up
ip link set bbrv8b up
ip link set bbrv8bp up

nic_baseline_capture bbrv8a
nic_baseline_capture bbrv8b
nic_policy_write bbrv8a shape 120 130 3 balanced mixed 0 0
nic_policy_write bbrv8b fq 0 0 3 balanced proxy 0 0
nic_finalize_multi_config
MULTI_NIC_ENABLED=1

# This integration targets real multi-interface qdisc behavior.  Kernel-global
# sysctl and route-window rollback are covered by unit tests and must not alter
# the Docker host while these namespace-local qdiscs are exercised.
apply_sysctl_profile() { [[ "$1" == runtime ]]; }
capture_runtime_sysctls() { printf 'net.test.key\tbefore\n'; }
apply_initial_windows() { :; }
nic_restore_runtime_snapshot() { :; }

nic_apply_runtime_policies
managed_htb bbrv8a
[[ "$(managed_rate_mbit bbrv8a)" == 120 ]]
[[ "$(root_qdisc_kind bbrv8b)" == fq ]]
nic_verify_runtime_policies

# Update both desired policies, fail the second mutation deliberately, and
# prove the first interface is restored too (cross-interface atomicity).
nic_policy_write bbrv8a shape 80 90 3 balanced mixed 0 0
nic_policy_write bbrv8b shape 90 100 3 balanced proxy 0 0
nic_finalize_multi_config
eval "$(declare -f apply_shaping | sed '1s/apply_shaping/apply_shaping_real/')"
fail_second=1
apply_shaping() {
    if [[ "$1" == bbrv8b && "$fail_second" == 1 ]]; then return 71; fi
    apply_shaping_real "$@"
}
if nic_apply_runtime_policies >/dev/null 2>&1; then
    echo 'cross-interface failure was reported as success' >&2
    exit 1
fi
[[ "$(managed_rate_mbit bbrv8a)" == 120 ]]
[[ "$(root_qdisc_kind bbrv8b)" == fq ]]

nic_baseline_restore bbrv8a
nic_baseline_restore bbrv8b
! managed_htb bbrv8a
! managed_htb bbrv8b

printf 'multi-NIC integration test: OK (bbrv8a + bbrv8b)\n'
