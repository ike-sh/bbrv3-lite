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
mq_iface=bbrmq0
mq_peer=bbrmqp
mq_created=0
zero_iface=bbrh0
zero_iface_type=
cls_iface=bbrcls0
cls_peer=bbrclsp
cls_created=0
ra_iface=bbrra0
ra_peer=bbrrap
ra_created=0
cleanup() {
    (( ra_created == 0 )) || ip link del "$ra_iface" >/dev/null 2>&1 || true
    (( cls_created == 0 )) || ip link del "$cls_iface" >/dev/null 2>&1 || true
    case "$zero_iface_type" in
        ifb) ip link del "$zero_iface" >/dev/null 2>&1 || true ;;
        tap) ip tuntap del dev "$zero_iface" mode tap >/dev/null 2>&1 || true ;;
    esac
    (( mq_created == 0 )) || ip link del "$mq_iface" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "$*" >&2
    exit 1
}

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

require_commands ip tc
tc qdisc show >/dev/null 2>&1 || { echo "SKIP: CAP_NET_ADMIN required" >&2; exit 77; }
iface=$(detect_interface auto)
qdisc_guard "$iface"

# IPv6 RA routes expose a live `expires Nsec` countdown, while route mutation
# accepts only a numeric expiry.  Identity checks must ignore that countdown,
# and apply/restore must replay its current value without disabling IPv6.
ip link show dev "$ra_iface" >/dev/null 2>&1 && fail "RA route test interface already exists: $ra_iface"
ip link add "$ra_iface" type veth peer name "$ra_peer"
ra_created=1
ip link set "$ra_iface" up
ip link set "$ra_peer" up
ip -6 addr add 2001:db8:802::1/64 dev "$ra_iface"
ip -6 route add default via 2001:db8:802::2 dev "$ra_iface" proto ra metric 1024 expires 300 pref medium
ra_snapshot="$TEST_ROOT/ra-route"
mkdir -p -- "$ra_snapshot"
ip -4 route show default > "$ra_snapshot/default-route-v4.txt"
ip -6 route show default > "$ra_snapshot/default-route-v6.txt"
grep -Eq 'expires [0-9]+sec' "$ra_snapshot/default-route-v6.txt" || fail 'kernel did not expose an RA expiry countdown'
# These globals are consumed by apply_initial_windows from the sourced release.
# shellcheck disable=SC2034
INITCWND=10
# shellcheck disable=SC2034
INITRWND=20
apply_initial_windows
ip -6 route show default | grep -Eq 'initcwnd 10.*initrwnd 20|initrwnd 20.*initcwnd 10' ||
    fail 'RA default route did not receive initial windows'
sleep 2
default_route_windows_snapshot_preflight "$ra_snapshot" || fail 'RA expiry countdown caused false route drift'
restore_default_route_windows_snapshot "$ra_snapshot" || fail 'RA route window restore failed'
if ip -6 route show default | grep -Eq '(^| )initcwnd |(^| )initrwnd '; then
    fail 'RA route window restore left managed window attributes behind'
fi
echo 'IPv6 RA expiry transaction test: OK'

# A kernel-owned classless root uses handle 0:.  `tc qdisc replace ... handle
# 0:` cannot recreate that identity; the restore path must delete the explicit
# HTB root and let the kernel instantiate its default qdisc again.  IFB normally
# exposes that real path.  A persistent single-queue TAP is a deterministic
# fallback for kernels without IFB.  This is a hard gate: an environment that
# cannot provide a supported real handle-0 device fails instead of silently
# skipping the coverage.
ip link show dev "$zero_iface" >/dev/null 2>&1 && fail "handle-0 test interface already exists: $zero_iface"
if ip link add "$zero_iface" type ifb >/dev/null 2>&1; then
    zero_iface_type=ifb
elif [[ -c /dev/net/tun ]] && ip tuntap add dev "$zero_iface" mode tap >/dev/null 2>&1; then
    zero_iface_type=tap
else
    fail 'cannot create an IFB or single-queue TAP for the real handle-0 restore test'
fi
ip link set "$zero_iface" up
zero_kind=$(root_qdisc_kind "$zero_iface")
zero_handle=$(root_qdisc_handle "$zero_iface")
case "$zero_kind:$zero_handle" in
    fq:0:|fq_codel:0:|pfifo_fast:0:) ;;
    *) fail "real handle-0 test device has unsupported root: kind=$zero_kind handle=$zero_handle" ;;
esac
zero_args=$(root_qdisc_replay_args "$zero_iface")
zero_classes=$(tc class show dev "$zero_iface")
zero_snapshot=$(mktemp "$TEST_ROOT/handle-zero.XXXXXX")
action_qdisc_snapshot "$zero_iface" "$zero_snapshot"
apply_shaping "$zero_iface" 100
verify_shaping "$zero_iface"

# Docker Desktop and some container runtimes mask this global sysctl even in a
# privileged network namespace.  Only its read is supplied from the observed
# real kernel-created qdisc in that case.  If the sysctl is visible, a mismatch
# remains a hard failure.  The destructive tc delete, automatic re-creation and
# exact post-restore comparisons below always use the real kernel.
zero_default_kind=$(command sysctl -n net.core.default_qdisc 2>/dev/null || true)
zero_default_source=sysctl
if [[ -e /proc/sys/net/core/default_qdisc ]]; then
    [[ "$zero_default_kind" == "$zero_kind" ]] ||
        fail "visible default_qdisc does not match the kernel-created handle-0 root: default=$zero_default_kind root=$zero_kind"
else
    zero_default_source=kernel-observed
    sysctl() {
        if [[ "$#" == 2 && "$1" == -n && "$2" == net.core.default_qdisc ]]; then
            printf '%s\n' "$zero_kind"
        else
            command sysctl "$@"
        fi
    }
fi
zero_restore_rc=0
restore_action_qdisc "$zero_iface" "$zero_snapshot" || zero_restore_rc=$?
[[ "$zero_default_source" == sysctl ]] || unset -f sysctl
(( zero_restore_rc == 0 )) || fail "real handle-0 restore failed (kind=$zero_kind metadata=$zero_default_source)"
rm -f "$zero_snapshot"
[[ "$(root_qdisc_kind "$zero_iface")" == "$zero_kind" ]]
[[ "$(root_qdisc_handle "$zero_iface")" == 0: ]]
[[ "$(root_qdisc_replay_args "$zero_iface")" == "$zero_args" ]]
[[ "$(tc class show dev "$zero_iface")" == "$zero_classes" ]]
printf 'handle-0 restore test: OK (%s, kind=%s, default=%s)\n' "$zero_iface_type" "$zero_kind" "$zero_default_source"

# clsact is an independent ingress/egress attachment, not part of the root
# qdisc tree owned by this project.  A root snapshot -> HTB -> restore cycle
# must leave both clsact and its filter byte-for-byte visible to tc.
ip link show dev "$cls_iface" >/dev/null 2>&1 && fail "clsact test interface already exists: $cls_iface"
ip link add "$cls_iface" type veth peer name "$cls_peer"
cls_created=1
ip link set "$cls_iface" up
ip link set "$cls_peer" up
tc qdisc replace dev "$cls_iface" root handle 125: fq_codel limit 4096 target 6ms
tc qdisc add dev "$cls_iface" clsact
if ! tc filter add dev "$cls_iface" egress protocol all pref 10 matchall action pass >/dev/null 2>&1; then
    tc filter add dev "$cls_iface" egress protocol ip pref 10 u32 match u32 0 0 action pass
fi
cls_kind=$(root_qdisc_kind "$cls_iface")
cls_handle=$(root_qdisc_handle "$cls_iface")
cls_args=$(root_qdisc_replay_args "$cls_iface")
clsact_before=$(tc qdisc show dev "$cls_iface" | awk '$1=="qdisc" && $2=="clsact" {print}')
cls_filter_before=$(tc filter show dev "$cls_iface" egress)
[[ -n "$clsact_before" && -n "$cls_filter_before" ]] || fail 'clsact or its egress filter was not installed'
cls_snapshot=$(mktemp "$TEST_ROOT/clsact.XXXXXX")
action_qdisc_snapshot "$cls_iface" "$cls_snapshot"
apply_shaping "$cls_iface" 100
verify_shaping "$cls_iface"
[[ "$(tc qdisc show dev "$cls_iface" | awk '$1=="qdisc" && $2=="clsact" {print}')" == "$clsact_before" ]]
[[ "$(tc filter show dev "$cls_iface" egress)" == "$cls_filter_before" ]]
restore_action_qdisc "$cls_iface" "$cls_snapshot"
rm -f "$cls_snapshot"
[[ "$(root_qdisc_kind "$cls_iface")" == "$cls_kind" ]]
[[ "$(root_qdisc_handle "$cls_iface")" == "$cls_handle" ]]
[[ "$(root_qdisc_replay_args "$cls_iface")" == "$cls_args" ]]
[[ "$(tc qdisc show dev "$cls_iface" | awk '$1=="qdisc" && $2=="clsact" {print}')" == "$clsact_before" ]]
[[ "$(tc filter show dev "$cls_iface" egress)" == "$cls_filter_before" ]]
echo "clsact preservation test: OK ($cls_iface)"

# A known fq_codel root is replayed with its exact non-zero handle and visible
# parameters after a test.
tc qdisc replace dev "$iface" root handle 123: fq_codel limit 2048 target 7ms
snapshot=$(mktemp)
action_qdisc_snapshot "$iface" "$snapshot"
apply_shaping "$iface" 100
verify_shaping "$iface"
[[ "$(managed_rate_mbit "$iface")" == 100 ]]
restore_action_qdisc "$iface" "$snapshot"
rm -f "$snapshot"
tc -d qdisc show dev "$iface" | grep 'fq_codel.*limit 2048p.*target 7ms' >/dev/null
[[ "$(root_qdisc_handle "$iface")" == 123: ]]

# A root filter is an external reference to the qdisc handle.  It cannot be
# reconstructed from qdisc text, so every mutation gate must fail before the
# qdisc or filter is changed.
tc filter add dev "$iface" parent 123: protocol ip pref 10 u32 match u32 0 0 action pass
filter_before=$(tc filter show dev "$iface" parent 123:)
if qdisc_guard "$iface" >/dev/null 2>&1; then
    echo 'root qdisc filter was accepted' >&2
    exit 1
fi
blocked_snapshot=$(mktemp)
if action_qdisc_snapshot "$iface" "$blocked_snapshot" >/dev/null 2>&1; then
    echo 'snapshot accepted a root qdisc filter' >&2
    exit 1
fi
[[ "$(tc filter show dev "$iface" parent 123:)" == "$filter_before" ]]
[[ "$(root_qdisc_handle "$iface")" == 123: ]]
rm -f "$blocked_snapshot"
tc filter del dev "$iface" parent 123:

# Newer kernels expose read-only FQ band maps. A snapshot must ignore those
# presentation fields and still restore the original FQ root successfully.
tc qdisc replace dev "$iface" root handle 124: fq
snapshot=$(mktemp)
action_qdisc_snapshot "$iface" "$snapshot"
apply_shaping "$iface" 100
restore_action_qdisc "$iface" "$snapshot"
rm -f "$snapshot"
[[ "$(root_qdisc_kind "$iface")" == fq ]]
[[ "$(root_qdisc_handle "$iface")" == 124: ]]

apply_shaping "$iface" 100
managed_htb "$iface"

# The project HTB is an exclusive topology.  Extra classes/leaves and filters
# must be treated as external drift instead of being silently deleted by a
# later unmanage/restore operation.
tc class add dev "$iface" parent 1: classid 1:20 htb rate 10mbit ceil 10mbit
tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
if managed_htb "$iface"; then
    echo 'managed HTB accepted an extra class/leaf' >&2
    exit 1
fi
if qdisc_guard "$iface" >/dev/null 2>&1; then
    echo 'qdisc guard accepted an extended HTB tree' >&2
    exit 1
fi
tc qdisc del dev "$iface" parent 1:20 handle 20:
tc class del dev "$iface" classid 1:20
managed_htb "$iface"

tc filter add dev "$iface" parent 1: protocol ip pref 10 u32 match u32 0 0 flowid 1:10
if managed_htb "$iface" || qdisc_guard "$iface" >/dev/null 2>&1; then
    echo 'managed HTB accepted a root filter' >&2
    exit 1
fi
tc filter del dev "$iface" parent 1:
managed_htb "$iface"

tc filter add dev "$iface" parent 1:10 protocol ip pref 10 u32 match u32 0 0 action pass
if managed_htb "$iface" || qdisc_guard "$iface" >/dev/null 2>&1; then
    echo 'managed HTB accepted a leaf-class filter' >&2
    exit 1
fi
tc filter del dev "$iface" parent 1:10
managed_htb "$iface"

apply_shaping "$iface" 120
[[ "$(managed_rate_mbit "$iface")" == 120 ]]
# High-rate bucket must also be accepted by the real kernel and parsed back
# correctly; v7.1's 8 MiB cap could throttle 25/100G configurations.
apply_shaping "$iface" 25000
[[ "$(managed_rate_mbit "$iface")" == 25000 ]]
apply_fq "$iface"
[[ "$(root_qdisc_kind "$iface")" == fq ]]

# Exercise the real tc representation used by non-zero MQ roots.  Modern
# kernels report children as parent MAJOR:MINOR, not only the shorthand :MINOR.
ip link add "$mq_iface" numtxqueues 2 numrxqueues 2 type veth \
    peer name "$mq_peer" numtxqueues 2 numrxqueues 2
mq_created=1
ip link set "$mq_iface" up
ip link set "$mq_peer" up
tc qdisc replace dev "$mq_iface" root handle 8003: mq
tc qdisc replace dev "$mq_iface" parent 8003:1 handle 123: fq_codel limit 2048 target 7ms
mq_snapshot=$(mktemp)
action_qdisc_snapshot "$mq_iface" "$mq_snapshot"
mq_rows_before=$(mq_child_replay_rows_from_stream < "$mq_snapshot")
mq_classes_before=$(tc class show dev "$mq_iface")
[[ "$(awk 'END {print NR}' <<< "$mq_rows_before")" == 2 ]]
grep -F $'8003:1\tfq_codel\t123:' <<< "$mq_rows_before" >/dev/null
apply_shaping "$mq_iface" 100
mq_zero_kind=$(mq_zero_handle_default_kind_from_rows "$mq_rows_before")
mq_default_source=sysctl
mq_current_default=$(command sysctl -n net.core.default_qdisc 2>/dev/null || true)
if [[ ! -e /proc/sys/net/core/default_qdisc ]]; then
    mq_default_source=kernel-observed
    sysctl() {
        if [[ "$#" == 2 && "$1" == -n && "$2" == net.core.default_qdisc ]]; then
            printf '%s\n' "$mq_zero_kind"
        else
            command sysctl "$@"
        fi
    }
else
    [[ -z "$mq_zero_kind" || "$mq_current_default" == "$mq_zero_kind" ]] ||
        fail "visible default_qdisc does not match the MQ zero-handle child kind: default=$mq_current_default child=$mq_zero_kind"
fi
mq_restore_rc=0
restore_action_qdisc "$mq_iface" "$mq_snapshot" || mq_restore_rc=$?
[[ "$mq_default_source" == sysctl ]] || unset -f sysctl
(( mq_restore_rc == 0 )) || fail "MQ exact restore failed (default=$mq_default_source)"
[[ "$(root_qdisc_kind "$mq_iface")" == mq ]]
[[ "$(root_qdisc_handle "$mq_iface")" == 8003: ]]
mq_rows_after=$(tc qdisc show dev "$mq_iface" | mq_child_replay_rows_from_stream)
[[ "$mq_rows_after" == "$mq_rows_before" ]]
[[ "$(tc class show dev "$mq_iface")" == "$mq_classes_before" ]]

# Filters attached to a non-zero MQ leaf handle are external state and must
# block the mutation without being removed.
tc filter add dev "$mq_iface" parent 123: protocol ip pref 10 u32 match u32 0 0 action pass
mq_filter_before=$(tc filter show dev "$mq_iface" parent 123:)
if qdisc_guard "$mq_iface" >/dev/null 2>&1; then
    echo 'MQ leaf filter was accepted' >&2
    exit 1
fi
[[ "$(tc filter show dev "$mq_iface" parent 123:)" == "$mq_filter_before" ]]
tc filter del dev "$mq_iface" parent 123:

# A truncated MQ snapshot must not be reported as a successful partial restore.
mq_incomplete=$(mktemp)
grep -v 'parent 8003:2' "$mq_snapshot" > "$mq_incomplete"
if action_qdisc_snapshot_validate "$mq_incomplete"; then
    echo 'incomplete MQ qdisc set with complete class rows passed snapshot validation' >&2
    exit 1
fi
apply_shaping "$mq_iface" 100
if restore_mq_qdisc_snapshot "$mq_iface" "$mq_incomplete" >/dev/null 2>&1; then
    echo 'incomplete MQ snapshot was reported as restored' >&2
    exit 1
fi
rm -f "$mq_snapshot" "$mq_incomplete"
echo "tc integration test: OK ($iface)"
