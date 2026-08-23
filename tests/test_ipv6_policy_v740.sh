#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

STATE_DIR="$TEST_ROOT/state"
IPV6_BACKUP_DIR="$STATE_DIR/ipv6"
export BBRV3_IPV6_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite-ipv6.conf"
export BBRV3_IPV6_PROC_CONF_ROOT="$TEST_ROOT/proc/sys/net/ipv6/conf"
IPV6_SYSCTL_FILE="$BBRV3_IPV6_SYSCTL_FILE"
IPV6_PROC_CONF_ROOT="$BBRV3_IPV6_PROC_CONF_ROOT"
IPV6_PROC_CONF_ROOT_EXPLICIT=1
export BBRV3_IPV6_CMDLINE_FILE="$TEST_ROOT/proc/cmdline"
export BBRV3_IPV6_MODULE_DISABLE_FILE="$TEST_ROOT/sys/module/ipv6/parameters/disable"
IPV6_CMDLINE_FILE="$BBRV3_IPV6_CMDLINE_FILE"
IPV6_MODULE_DISABLE_FILE="$BBRV3_IPV6_MODULE_DISABLE_FILE"
IPV6_TRANSACTION_DIR=""
SCRIPT_VERSION=7.4.0-test

# shellcheck source=../src/ipv6.sh
source "$ROOT_DIR/src/ipv6.sh"
# shellcheck source=../src/ipv6-policy.sh
source "$ROOT_DIR/src/ipv6-policy.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3: missing '$2'"; }
die() { printf 'ERR %s\n' "$*" >&2; return 1; }
log() { :; }
command_exists() { return 0; }

MOCK_ROUTE_MODE=ipv4
MOCK_ADDRS=""
MOCK_ROUTES=""
DISABLE_CALLS=0
RESTORE_CALLS=0

ip() {
    case "$*" in
        '-4 route show default') [[ "$MOCK_ROUTE_MODE" == ipv4 || "$MOCK_ROUTE_MODE" == dual ]] && printf 'default via 192.0.2.1 dev eth0\n' ;;
        '-6 route show default') [[ "$MOCK_ROUTE_MODE" == ipv6 || "$MOCK_ROUTE_MODE" == dual ]] && printf 'default via 2001:db8::1 dev eth0\n' ;;
        '-6 -o addr show') printf '%s' "$MOCK_ADDRS" ;;
        '-6 route show table all') printf '%s' "$MOCK_ROUTES" ;;
    esac
}

set_flag() { printf '%s\n' "$2" > "$IPV6_PROC_CONF_ROOT/$1/disable_ipv6"; }
get_flag() { local value; IFS= read -r value < "$IPV6_PROC_CONF_ROOT/$1/disable_ipv6"; printf '%s\n' "$value"; }

write_new_policy() {
    mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")"
    printf '%s\n' '# Managed by bbrv3-lite' '# Policy: disabled-persistent' \
        '# IPv6 is disabled per interface; lo/::1 is intentionally not modified.' \
        'net/ipv6/conf/default/disable_ipv6 = 1' \
        'net/ipv6/conf/eth0/disable_ipv6 = 1' > "$IPV6_SYSCTL_FILE"
}

write_legacy_policy() {
    mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")"
    printf '%s\n' '# Managed by bbrv3-lite' \
        'net.ipv6.conf.all.disable_ipv6 = 1' \
        'net.ipv6.conf.default.disable_ipv6 = 1' \
        'net.ipv6.conf.lo.disable_ipv6 = 1' > "$IPV6_SYSCTL_FILE"
}

ipv6_validate_snapshot() { return 0; }
ipv6_snapshot_quality() { printf 'disable-flags-exact\n'; }
ipv6_policy_persistent_matches_snapshot() { [[ ! -e "$IPV6_SYSCTL_FILE" && ! -L "$IPV6_SYSCTL_FILE" ]]; }
ipv6_policy_runtime_matches_snapshot() { [[ "$(get_flag default)" == 0 && "$(get_flag lo)" == 0 && "$(get_flag eth0)" == 0 ]]; }

ipv6_disable() {
    local mode="$1"
    DISABLE_CALLS=$((DISABLE_CALLS + 1))
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    set_flag default 1
    set_flag eth0 1
    if [[ "$mode" == permanent ]]; then write_new_policy; else rm -f -- "$IPV6_SYSCTL_FILE"; fi
}

ipv6_restore() {
    RESTORE_CALLS=$((RESTORE_CALLS + 1))
    set_flag default 0
    set_flag eth0 0
    set_flag lo 0
    rm -f -- "$IPV6_SYSCTL_FILE"
}

reset_case() {
    rm -rf -- "$TEST_ROOT"
    mkdir -p -- "$IPV6_PROC_CONF_ROOT"/{all,default,lo,eth0} "$(dirname "$IPV6_CMDLINE_FILE")" "$(dirname "$IPV6_MODULE_DISABLE_FILE")"
    set_flag all 0; set_flag default 0; set_flag lo 0; set_flag eth0 0
    printf 'BOOT_IMAGE=/vmlinuz\n' > "$IPV6_CMDLINE_FILE"
    printf 'N\n' > "$IPV6_MODULE_DISABLE_FILE"
    MOCK_ROUTE_MODE=ipv4; MOCK_ADDRS=""; MOCK_ROUTES=""; SSH_CONNECTION=""
    DISABLE_CALLS=0; RESTORE_CALLS=0
}

test_aliases_and_inference() {
    reset_case
    assert_eq disabled-temporary "$(ipv6_policy_normalize temporary)" 'temporary alias'
    assert_eq disabled-persistent "$(ipv6_policy_normalize permanent)" 'permanent alias'
    assert_eq native "$(ipv6_policy_detect_current)" 'native inference'

    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    set_flag default 1; set_flag eth0 1
    assert_eq disabled-temporary "$(ipv6_policy_detect_current)" 'temporary inference'
    write_new_policy
    assert_eq disabled-persistent "$(ipv6_policy_detect_current)" 'persistent inference'
    mkdir -p -- "$IPV6_PROC_CONF_ROOT/eth1"
    set_flag eth1 1
    assert_eq disabled-persistent-drift "$(ipv6_policy_detect_current)" 'persistent interface-set drift inference'
    rm -rf -- "$IPV6_PROC_CONF_ROOT/eth1"
    set_flag eth0 0
    assert_eq disabled-persistent-drift "$(ipv6_policy_detect_current)" 'persistent drift inference'

    set_flag eth0 1
    write_legacy_policy
    assert_eq legacy-disabled-persistent "$(ipv6_policy_detect_current)" 'legacy inference'
}

test_plan_is_read_only_and_topology_aware() {
    local before after output
    reset_case
    before=$(find "$TEST_ROOT" -type f -o -type l | sort | xargs -r sha256sum)
    output=$(ipv6_policy_plan disabled-temporary)
    after=$(find "$TEST_ROOT" -type f -o -type l | sort | xargs -r sha256sum)
    assert_eq "$before" "$after" 'IPv6 plan filesystem mutation'
    assert_eq 0 "$DISABLE_CALLS" 'IPv6 plan executor calls'
    assert_contains "$output" 'Decision               ready' 'ready plan'
    assert_contains "$output" 'Plan mutation          none (read-only)' 'read-only marker'

    MOCK_ADDRS='2: eth0    inet6 2001:db8::10/64 scope global dynamic\n'
    if output=$(ipv6_policy_plan disabled-temporary 2>&1); then fail 'routable IPv6 topology was accepted'; fi
    assert_contains "$output" 'blocked' 'topology block decision'
    assert_contains "$output" '可路由 IPv6 地址' 'topology block reason'

    MOCK_ADDRS=""; MOCK_ROUTE_MODE=dual
    if output=$(ipv6_policy_plan disabled-persistent 2>&1); then fail 'dual-stack default route was accepted'; fi
    assert_contains "$output" 'dual-stack' 'dual-stack block reason'
}

test_legacy_and_foreign_policies_are_blocked() {
    local before
    reset_case
    write_legacy_policy
    set_flag default 1; set_flag lo 1; set_flag eth0 1
    before=$(sha256sum "$IPV6_SYSCTL_FILE")
    if ipv6_policy_apply disabled-persistent >/dev/null 2>&1; then fail 'legacy all/lo policy was auto-migrated'; fi
    assert_eq "$before" "$(sha256sum "$IPV6_SYSCTL_FILE")" 'legacy policy changed'
    assert_eq 0 "$DISABLE_CALLS" 'legacy policy reached executor'

    reset_case
    mkdir -p -- "$(dirname "$IPV6_SYSCTL_FILE")"
    printf 'foreign=true\n' > "$IPV6_SYSCTL_FILE"
    before=$(sha256sum "$IPV6_SYSCTL_FILE")
    if ipv6_policy_apply disabled-temporary >/dev/null 2>&1; then fail 'foreign IPv6 policy was overwritten'; fi
    assert_eq "$before" "$(sha256sum "$IPV6_SYSCTL_FILE")" 'foreign policy changed'
}

test_apply_verify_restore_and_loopback_invariant() {
    reset_case
    ipv6_policy_apply disabled-temporary >/dev/null
    assert_eq 1 "$DISABLE_CALLS" 'temporary apply dispatch'
    assert_eq 0 "$(get_flag lo)" 'temporary apply changed loopback'
    assert_eq disabled-temporary "$(ipv6_policy_detect_current)" 'temporary apply inference'
    ipv6_policy_verify disabled-temporary

    ipv6_policy_apply disabled-persistent >/dev/null
    assert_eq 2 "$DISABLE_CALLS" 'persistent apply dispatch'
    assert_eq 0 "$(get_flag lo)" 'persistent apply changed loopback'
    assert_eq disabled-persistent "$(ipv6_policy_detect_current)" 'persistent apply inference'
    ipv6_policy_verify disabled-persistent

    ipv6_policy_apply native >/dev/null
    assert_eq 1 "$RESTORE_CALLS" 'native restore dispatch'
    assert_eq native "$(ipv6_policy_detect_current)" 'native restore inference'
}

test_native_without_baseline_preserves_external_state() {
    reset_case
    set_flag default 1; set_flag eth0 1
    assert_eq external-disabled "$(ipv6_policy_detect_current)" 'external disable inference'
    ipv6_policy_apply native >/dev/null
    assert_eq 0 "$RESTORE_CALLS" 'external native noop restore calls'
    assert_eq 1 "$(get_flag eth0)" 'external native state changed'
    if ipv6_policy_verify >/dev/null 2>&1; then fail 'external-disabled state passed inferred managed verification'; fi
}

test_pending_transaction_blocks_native_plan() {
    local output
    reset_case
    mkdir -p -- "$IPV6_BACKUP_DIR/.transaction.stale"
    if output=$(ipv6_policy_plan native 2>&1); then fail 'stale IPv6 transaction allowed native plan'; fi
    assert_contains "$output" 'blocked' 'stale IPv6 transaction decision'
    assert_contains "$output" '未完成 IPv6 事务' 'stale IPv6 transaction reason'
}

test_aliases_and_inference
test_plan_is_read_only_and_topology_aware
test_legacy_and_foreign_policies_are_blocked
test_apply_verify_restore_and_loopback_invariant
test_native_without_baseline_preserves_external_state
test_pending_transaction_blocks_native_plan
printf 'ipv6 v7.4.0 policy tests: OK\n'
