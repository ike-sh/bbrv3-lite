#!/usr/bin/env bash
# Run only in a disposable container/network namespace with CAP_NET_ADMIN.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

require_commands ip tc
tc qdisc show >/dev/null 2>&1 || { echo "SKIP: CAP_NET_ADMIN required" >&2; exit 77; }
iface=$(detect_interface auto)
qdisc_guard "$iface"

# A known fq_codel root is replayed with its visible parameters after a test.
tc qdisc replace dev "$iface" root fq_codel limit 2048 target 7ms
snapshot=$(mktemp)
action_qdisc_snapshot "$iface" "$snapshot"
apply_shaping "$iface" 100
verify_shaping "$iface"
[[ "$(managed_rate_mbit "$iface")" == 100 ]]
restore_action_qdisc "$iface" "$snapshot"
rm -f "$snapshot"
tc -d qdisc show dev "$iface" | grep 'fq_codel.*limit 2048p.*target 7ms' >/dev/null

# Newer kernels expose read-only FQ band maps. A snapshot must ignore those
# presentation fields and still restore the original FQ root successfully.
tc qdisc replace dev "$iface" root fq
snapshot=$(mktemp)
action_qdisc_snapshot "$iface" "$snapshot"
apply_shaping "$iface" 100
restore_action_qdisc "$iface" "$snapshot"
rm -f "$snapshot"
[[ "$(root_qdisc_kind "$iface")" == fq ]]

apply_shaping "$iface" 100
managed_htb "$iface"
apply_shaping "$iface" 120
[[ "$(managed_rate_mbit "$iface")" == 120 ]]
# High-rate bucket must also be accepted by the real kernel and parsed back
# correctly; v7.1's 8 MiB cap could throttle 25/100G configurations.
apply_shaping "$iface" 25000
[[ "$(managed_rate_mbit "$iface")" == 25000 ]]
apply_fq "$iface"
[[ "$(root_qdisc_kind "$iface")" == fq ]]
echo "tc integration test: OK ($iface)"
