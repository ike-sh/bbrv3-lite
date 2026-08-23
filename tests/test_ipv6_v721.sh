#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BBRV3_CONFIG="$TEST_ROOT/bootstrap/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/bootstrap/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/bootstrap/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/bootstrap/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bootstrap/bbrv3-lite.lock"
export BBRV3_IPV6_BACKUP_DIR="$TEST_ROOT/bootstrap/state/ipv6"
export BBRV3_IPV6_SYSCTL_FILE="$TEST_ROOT/bootstrap/etc/99-bbrv3-lite-ipv6.conf"
export BBRV3_IPV6_PROC_CONF_ROOT="$TEST_ROOT/bootstrap/proc/sys/net/ipv6/conf"
export BBRV3_IPV6_CMDLINE_FILE="$TEST_ROOT/bootstrap/proc/cmdline"
export BBRV3_IPV6_MODULE_DISABLE_FILE="$TEST_ROOT/bootstrap/sys/module/ipv6/parameters/disable"

# shellcheck source=../src/00-header.sh
source "$ROOT_DIR/src/00-header.sh"
# shellcheck source=../src/core.sh
source "$ROOT_DIR/src/core.sh"
# shellcheck source=../src/state.sh
source "$ROOT_DIR/src/state.sh"
# shellcheck source=../src/ipv6.sh
source "$ROOT_DIR/src/ipv6.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

require_root() { :; }
HOST_NETWORK_ALLOWED=1
require_host_network_control() { (( HOST_NETWORK_ALLOWED == 1 )); }
acquire_lock() { :; }
require_commands() { :; }

MOCK_ROUTE_MODE=ipv4
MOCK_IPV6_ADDR_OUTPUT=""
MOCK_IPV6_ROUTE_OUTPUT=""
ip() {
    case "$*" in
        '-4 route show default') [[ "$MOCK_ROUTE_MODE" == ipv4 || "$MOCK_ROUTE_MODE" == dual ]] && printf 'default via 192.0.2.1 dev eth0\n' ;;
        '-6 route show default') [[ "$MOCK_ROUTE_MODE" == ipv6 || "$MOCK_ROUTE_MODE" == dual ]] && printf 'default via 2001:db8::1 dev eth0\n' ;;
        '-6 -o addr show') printf '%s' "$MOCK_IPV6_ADDR_OUTPUT" ;;
        '-6 route show table all') printf '%s' "$MOCK_IPV6_ROUTE_OUTPUT" ;;
    esac
}

sysctl() {
    local assignment key value iface
    if [[ "${1:-}" == -q && "${2:-}" == -w ]]; then
        assignment=${3:-}
        key=${assignment%%=*}
        value=${assignment#*=}
        case "$key" in
            net.ipv6.conf.*.disable_ipv6)
                iface=${key#net.ipv6.conf.}
                iface=${iface%.disable_ipv6}
                ipv6_write_interface_value "$iface" "$value"
                ;;
            *) return 1 ;;
        esac
    elif [[ "${1:-}" == -n ]]; then
        key=${2:-}
        iface=${key#net.ipv6.conf.}
        iface=${iface%.disable_ipv6}
        ipv6_read_interface_value "$iface"
    else
        return 1
    fi
}

eval "$(declare -f ipv6_write_interface_value | sed '1s/ipv6_write_interface_value/ipv6_write_interface_value_original/')"
WRITE_EVENTS=""
MOCK_ALL_WRITE_COUNT=0
MOCK_FAIL_IFACE=""
MOCK_FAIL_VALUE=""
MOCK_DRIFT_ON_FAIL=""
MOCK_MUTATE_POLICY_ON_FAIL=0
ipv6_write_interface_value() {
    local iface="$1" value="$2" path
    WRITE_EVENTS+=" $iface=$value"
    if [[ "$iface" == "$MOCK_FAIL_IFACE" && "$value" == "$MOCK_FAIL_VALUE" ]]; then
        case "$MOCK_DRIFT_ON_FAIL" in
            removed) rm -rf -- "$IPV6_PROC_CONF_ROOT/eth0.100" ;;
            added)
                mkdir -p -- "$IPV6_PROC_CONF_ROOT/eth1"
                printf '1\n' > "$IPV6_PROC_CONF_ROOT/eth1/disable_ipv6"
                ;;
        esac
        (( MOCK_MUTATE_POLICY_ON_FAIL == 0 )) || printf 'partial-mutated-policy\n' > "$IPV6_SYSCTL_FILE"
        return 1
    fi
    if [[ "$iface" == all ]]; then
        MOCK_ALL_WRITE_COUNT=$((MOCK_ALL_WRITE_COUNT + 1))
        if [[ "$value" == 1 ]]; then
            # Model the destructive kernel behavior: all=1 removes topology,
            # and writing interface flags back to 0 does not reconstruct it.
            MOCK_IPV6_ADDR_OUTPUT=""
            MOCK_IPV6_ROUTE_OUTPUT=""
        fi
        for path in "$IPV6_PROC_CONF_ROOT"/*/disable_ipv6; do printf '%s\n' "$value" > "$path"; done
    fi
    ipv6_write_interface_value_original "$iface" "$value"
}

set_case() {
    local name="$1" iface value
    STATE_DIR="$TEST_ROOT/$name/state"
    HISTORY_DIR="$STATE_DIR/history"
    BASELINE_DIR="$STATE_DIR/baseline"
    IPV6_BACKUP_DIR="$STATE_DIR/ipv6"
    IPV6_SYSCTL_FILE="$TEST_ROOT/$name/etc/99-bbrv3-lite-ipv6.conf"
    IPV6_PROC_CONF_ROOT="$TEST_ROOT/$name/proc/sys/net/ipv6/conf"
    IPV6_CMDLINE_FILE="$TEST_ROOT/$name/proc/cmdline"
    IPV6_MODULE_DISABLE_FILE="$TEST_ROOT/$name/sys/module/ipv6/parameters/disable"
    IPV6_PROC_CONF_ROOT_EXPLICIT=1
    IPV6_TRANSACTION_DIR=""
    IPV6_LAST_RESTORE_QUALITY=""
    IPV6_RESTORE_DISABLE_TARGETS=""
    IPV6_RESTORE_DISABLES_LOOPBACK=0
    WRITE_EVENTS=""
    MOCK_ALL_WRITE_COUNT=0
    MOCK_FAIL_IFACE=""
    MOCK_FAIL_VALUE=""
    MOCK_DRIFT_ON_FAIL=""
    MOCK_MUTATE_POLICY_ON_FAIL=0
    HOST_NETWORK_ALLOWED=1
    MOCK_ROUTE_MODE=ipv4
    MOCK_IPV6_ADDR_OUTPUT=""
    MOCK_IPV6_ROUTE_OUTPUT=""
    SSH_CONNECTION=""
    mkdir -p -- "$IPV6_PROC_CONF_ROOT" "$(dirname "$IPV6_CMDLINE_FILE")" "$(dirname "$IPV6_MODULE_DISABLE_FILE")" "$(dirname "$IPV6_SYSCTL_FILE")"
    printf 'BOOT_IMAGE=/boot/vmlinuz root=/dev/vda1\n' > "$IPV6_CMDLINE_FILE"
    printf 'N\n' > "$IPV6_MODULE_DISABLE_FILE"
    for iface in all default lo eth0 eth0.100; do
        mkdir -p -- "$IPV6_PROC_CONF_ROOT/$iface"
        case "$iface" in eth0.100) value=1 ;; *) value=0 ;; esac
        printf '%s\n' "$value" > "$IPV6_PROC_CONF_ROOT/$iface/disable_ipv6"
    done
}

read_iface() { local value; IFS= read -r value < "$IPV6_PROC_CONF_ROOT/$1/disable_ipv6"; printf '%s\n' "$value"; }
write_legacy_ipv6_manifest() {
    printf 'CREATED_AT\t2026-08-22T00:00:00Z\nCREATED_BY\t7.2.0\n' > "$1/manifest"
}

test_interface_aware_disable_and_flag_restore() {
    local policy manifest
    set_case interface-aware
    ipv6_disable permanent >/dev/null

    assert_eq 0 "$(read_iface all)" "safe disable must not use all write trigger"
    assert_eq 1 "$(read_iface default)" "new interface default disabled"
    assert_eq 0 "$(read_iface lo)" "loopback preserved"
    assert_eq 1 "$(read_iface eth0)" "eth0 disabled"
    assert_eq 1 "$(read_iface eth0.100)" "dotted VLAN interface disabled"

    policy="$IPV6_SYSCTL_FILE"
    assert_contains "$policy" 'net/ipv6/conf/default/disable_ipv6 = 1'
    assert_contains "$policy" 'net/ipv6/conf/eth0.100/disable_ipv6 = 1'
    assert_not_contains "$policy" 'net/ipv6/conf/all/disable_ipv6'
    assert_not_contains "$policy" 'net/ipv6/conf/lo/disable_ipv6'

    manifest="$IPV6_BACKUP_DIR/baseline/manifest"
    assert_contains "$manifest" $'FORMAT\tinterface-values-v2'
    assert_contains "$manifest" $'CAPTURE\tper-interface'
    assert_contains "$manifest" $'RESTORE_SCOPE\tdisable-flags-only'
    assert_contains "$manifest" $'AGGREGATE_ALL\taudit-only/write-trigger/not-replayed'
    assert_contains "$manifest" $'TOPOLOGY_DIAGNOSTICS\tdiagnostic-only/not-replayable'
    assert_contains "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" $'INTERFACE\teth0.100\t1'
    [[ -f "$IPV6_BACKUP_DIR/baseline/addresses-v6.txt" && -f "$IPV6_BACKUP_DIR/baseline/routes-v6.txt" ]] || fail "IPv6 topology audit files missing"

    WRITE_EVENTS=""
    ipv6_restore >/dev/null
    assert_eq 0 "$(read_iface all)" "aggregate trigger restored"
    assert_eq 0 "$(read_iface default)" "default restored"
    assert_eq 0 "$(read_iface lo)" "loopback restored"
    assert_eq 0 "$(read_iface eth0)" "eth0 restored"
    assert_eq 1 "$(read_iface eth0.100)" "dotted VLAN original exception restored"
    [[ "$WRITE_EVENTS" != *' all='* ]] || fail "v2 restore replayed the all write trigger: $WRITE_EVENTS"
    [[ "$WRITE_EVENTS" == *' default=0'* && "$WRITE_EVENTS" == *' eth0=0'* && "$WRITE_EVENTS" == *' eth0.100=1'* && "$WRITE_EVENTS" == *' lo=0'* ]] ||
        fail "v2 restore did not replay every default/interface disable flag: $WRITE_EVENTS"
}

test_v2_restore_never_replays_all_over_new_topology() {
    local global_addr business_route
    global_addr=$'2: eth0    inet6 2001:db8:720::1/64 scope global\n'
    business_route=$'2001:db8:721::/64 dev eth0 proto static metric 100\n'
    set_case restore-all-audit-only
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/all/disable_ipv6"
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/eth0.100/disable_ipv6"
    ipv6_capture_baseline

    # This topology was added after capture. The historical all=1 observation
    # must never be replayed; all remains the current value and topology survives.
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/all/disable_ipv6"
    MOCK_IPV6_ADDR_OUTPUT="$global_addr"
    MOCK_IPV6_ROUTE_OUTPUT="$business_route"
    WRITE_EVENTS=""
    ipv6_restore >/dev/null
    assert_eq 0 "$(read_iface all)" "v2 restore changed the current all write-trigger value"
    assert_eq 0 "$MOCK_ALL_WRITE_COUNT" "v2 restore invoked the all write trigger"
    [[ "$WRITE_EVENTS" != *' all='* ]] || fail "v2 restore wrote all while topology existed: $WRITE_EVENTS"
    assert_eq "$global_addr" "$MOCK_IPV6_ADDR_OUTPUT" "v2 restore destroyed a newly added global address"
    assert_eq "$business_route" "$MOCK_IPV6_ROUTE_OUTPUT" "v2 restore destroyed a newly added business route"
}

test_restore_target_one_fails_before_any_write() {
    local global_addr loopback_addr
    global_addr=$'2: eth0    inet6 2001:db8:720::1/64 scope global\n'
    loopback_addr=$'1: lo    inet6 ::1/128 scope host\n'

    set_case restore-interface-one
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/eth0/disable_ipv6"
    ipv6_capture_baseline
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/eth0/disable_ipv6"
    printf 'keep-current-policy\n' > "$IPV6_SYSCTL_FILE"
    MOCK_IPV6_ADDR_OUTPUT="$global_addr"
    WRITE_EVENTS=""
    if ipv6_restore >/dev/null 2>&1; then fail "restore target interface=1 accepted current routable topology"; fi
    assert_eq '' "$WRITE_EVENTS" "interface=1 restore guard wrote a flag before refusal"
    assert_eq 0 "$(read_iface eth0)" "interface=1 restore guard changed the live flag"
    assert_eq keep-current-policy "$(<"$IPV6_SYSCTL_FILE")" "interface=1 restore guard changed persistent state"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "interface=1 restore guard created a transaction"

    set_case restore-loopback-one
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/lo/disable_ipv6"
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/eth0.100/disable_ipv6"
    ipv6_capture_baseline
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/lo/disable_ipv6"
    MOCK_IPV6_ADDR_OUTPUT="$loopback_addr"
    WRITE_EVENTS=""
    if ipv6_restore >/dev/null 2>&1; then fail "restore target lo=1 accepted an existing ::1 address"; fi
    assert_eq '' "$WRITE_EVENTS" "lo=1 restore guard wrote a flag before refusal"
    assert_eq 0 "$(read_iface lo)" "lo=1 restore guard changed loopback"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "lo=1 restore guard created a transaction"
}

test_legacy_all_one_is_guarded_but_zero_can_continue() {
    local global_addr
    global_addr=$'2: eth0    inet6 2001:db8:720::1/64 scope global\n'

    set_case legacy-all-one
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    write_legacy_ipv6_manifest "$IPV6_BACKUP_DIR/baseline"
    printf '%s\n' \
        $'net.ipv6.conf.all.disable_ipv6\t1' \
        $'net.ipv6.conf.default.disable_ipv6\t0' \
        $'net.ipv6.conf.lo.disable_ipv6\t0' > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    printf 'absent\n' > "$IPV6_BACKUP_DIR/baseline/persistent.state"
    MOCK_IPV6_ADDR_OUTPUT="$global_addr"
    if ipv6_restore >/dev/null 2>&1; then fail "legacy all=1 restore accepted routable topology"; fi
    assert_eq '' "$WRITE_EVENTS" "legacy all=1 guard wrote before refusal"
    assert_eq 0 "$MOCK_ALL_WRITE_COUNT" "legacy all=1 guard invoked all before refusal"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "legacy all=1 guard created a transaction"

    set_case legacy-all-zero
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    write_legacy_ipv6_manifest "$IPV6_BACKUP_DIR/baseline"
    printf '%s\n' \
        $'net.ipv6.conf.all.disable_ipv6\t0' \
        $'net.ipv6.conf.default.disable_ipv6\t0' \
        $'net.ipv6.conf.lo.disable_ipv6\t0' > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    printf 'absent\n' > "$IPV6_BACKUP_DIR/baseline/persistent.state"
    MOCK_IPV6_ADDR_OUTPUT="$global_addr"
    ipv6_restore >/dev/null
    assert_eq 1 "$MOCK_ALL_WRITE_COUNT" "legacy all=0 compatibility restore did not continue"
    assert_eq "$global_addr" "$MOCK_IPV6_ADDR_OUTPUT" "legacy all=0 restore destroyed topology"
}

test_restore_requires_host_network_control_before_writes() {
    set_case restore-host-network-guard
    printf '0\n' > "$IPV6_PROC_CONF_ROOT/eth0.100/disable_ipv6"
    ipv6_capture_baseline
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/eth0/disable_ipv6"
    printf 'keep-current-policy\n' > "$IPV6_SYSCTL_FILE"
    HOST_NETWORK_ALLOWED=0
    WRITE_EVENTS=""
    if ipv6_restore >/dev/null 2>&1; then fail "restore bypassed host network-control guard"; fi
    assert_eq '' "$WRITE_EVENTS" "host network-control guard wrote a flag"
    assert_eq 1 "$(read_iface eth0)" "host network-control guard changed a live flag"
    assert_eq keep-current-policy "$(<"$IPV6_SYSCTL_FILE")" "host network-control guard changed persistent state"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "host network-control guard created a transaction"
}

test_failed_change_rolls_back_every_interface_and_policy() {
    set_case rollback
    printf 'pre-existing-policy\n' > "$IPV6_SYSCTL_FILE"
    MOCK_FAIL_IFACE=eth0
    MOCK_FAIL_VALUE=1
    if ipv6_disable permanent >/dev/null 2>&1; then fail "injected IPv6 interface failure reported success"; fi
    assert_eq 0 "$(read_iface all)" "rollback all"
    assert_eq 0 "$(read_iface default)" "rollback default"
    assert_eq 0 "$(read_iface lo)" "rollback lo"
    assert_eq 0 "$(read_iface eth0)" "rollback eth0"
    assert_eq 1 "$(read_iface eth0.100)" "rollback dotted VLAN"
    assert_eq pre-existing-policy "$(<"$IPV6_SYSCTL_FILE")" "persistent policy rollback"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "transaction directory cleanup"
}

test_partial_rollback_restores_survivors_across_interface_drift() {
    local drift
    for drift in removed added; do
        set_case "rollback-drift-$drift"
        printf 'pre-existing-policy\n' > "$IPV6_SYSCTL_FILE"
        MOCK_FAIL_IFACE=eth0
        MOCK_FAIL_VALUE=1
        MOCK_DRIFT_ON_FAIL="$drift"
        MOCK_MUTATE_POLICY_ON_FAIL=1
        if ipv6_disable permanent >/dev/null 2>&1; then fail "$drift interface drift reported rollback success"; fi

        assert_eq 0 "$(read_iface default)" "$drift drift rollback did not restore default"
        assert_eq 0 "$(read_iface lo)" "$drift drift rollback did not restore lo"
        assert_eq 0 "$(read_iface eth0)" "$drift drift rollback did not restore surviving eth0"
        assert_eq pre-existing-policy "$(<"$IPV6_SYSCTL_FILE")" "$drift drift rollback did not restore persistent policy"
        assert_eq partial/interface-set-changed "$IPV6_LAST_RESTORE_QUALITY" "$drift drift rollback quality"
        [[ -n "$IPV6_TRANSACTION_DIR" && -d "$IPV6_TRANSACTION_DIR" ]] || fail "$drift drift rollback did not retain partial transaction"
        [[ "$WRITE_EVENTS" != *' all='* ]] || fail "$drift drift rollback wrote all: $WRITE_EVENTS"

        if [[ "$drift" == removed ]]; then
            [[ ! -e "$IPV6_PROC_CONF_ROOT/eth0.100" ]] || fail "removed interface unexpectedly recreated during rollback"
        else
            assert_eq 1 "$(read_iface eth1)" "new interface flag was changed during rollback"
            assert_eq 1 "$(read_iface eth0.100)" "captured VLAN flag was not restored after added-interface drift"
        fi
    done
}

test_remote_access_and_boot_guards() {
    local output
    set_case ssh-guard
    SSH_CONNECTION='2001:db8::10 50123 2001:db8::20 22'
    if ipv6_disable temporary >/dev/null 2>&1; then fail "IPv6 SSH session was allowed to disable IPv6"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "SSH guard ran after baseline mutation"

    set_case ipv6-only
    MOCK_ROUTE_MODE=ipv6
    MOCK_IPV6_ROUTE_OUTPUT=$'default via 2001:db8::1 dev eth0\n'
    if ipv6_disable temporary >/dev/null 2>&1; then fail "IPv6-only default route was allowed to disable IPv6"; fi

    set_case boot-disabled
    printf 'BOOT_IMAGE=/boot/vmlinuz ipv6.disable=1 root=/dev/vda1\n' > "$IPV6_CMDLINE_FILE"
    if ipv6_disable permanent >/dev/null 2>&1; then fail "boot-disabled IPv6 accepted runtime management"; fi
    output=$(ipv6_status)
    [[ "$output" == *'kernel-command-line'* ]] || fail "boot-level disable source missing from status"
    [[ "$output" == *'observed; not aggregate state'* ]] || fail "all was presented as aggregate truth"
}

test_boot_disabled_restore_is_persistent_only() {
    set_case boot-restore
    ipv6_capture_baseline
    printf 'managed-policy\n' > "$IPV6_SYSCTL_FILE"
    printf 'BOOT_IMAGE=/boot/vmlinuz ipv6.disable=1 root=/dev/vda1\n' > "$IPV6_CMDLINE_FILE"
    ipv6_restore >/dev/null
    [[ ! -e "$IPV6_SYSCTL_FILE" ]] || fail "boot-disabled restore did not restore persistent-file baseline"
    assert_eq persistent-only/reboot-required "$IPV6_LAST_RESTORE_QUALITY" "boot-disabled restore quality"
}

test_interface_set_drift_refuses_exact_flag_restore() {
    local drift
    for drift in added removed; do
        set_case "drift-$drift"
        ipv6_capture_baseline
        if [[ "$drift" == added ]]; then
            mkdir -p -- "$IPV6_PROC_CONF_ROOT/eth1"
            printf '0\n' > "$IPV6_PROC_CONF_ROOT/eth1/disable_ipv6"
        else
            rm -rf -- "$IPV6_PROC_CONF_ROOT/eth0.100"
        fi
        if ipv6_restore >/dev/null 2>&1; then fail "exact disable-flag restore accepted an interface that was $drift after snapshot"; fi
        assert_eq partial/interface-set-changed "$IPV6_LAST_RESTORE_QUALITY" "interface-set drift quality"
        assert_eq '' "$IPV6_TRANSACTION_DIR" "interface-set drift rollback cleanup"
    done
}

test_legacy_baseline_is_never_claimed_exact_flags() {
    local output
    set_case legacy
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    write_legacy_ipv6_manifest "$IPV6_BACKUP_DIR/baseline"
    printf '%s\n' \
        $'net.ipv6.conf.all.disable_ipv6\t0' \
        $'net.ipv6.conf.default.disable_ipv6\t0' \
        $'net.ipv6.conf.lo.disable_ipv6\t0' > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    printf 'absent\n' > "$IPV6_BACKUP_DIR/baseline/persistent.state"
    output=$(ipv6_status)
    [[ "$output" == *'legacy/partial-best-effort'* ]] || fail "legacy IPv6 baseline was not marked partial: $output"
    assert_eq legacy/partial-best-effort "$(ipv6_snapshot_quality "$IPV6_BACKUP_DIR/baseline")" "legacy baseline quality"
}

test_topology_classifiers_and_fail_closed_preflight() {
    local global_addr ula_addr link_addr link_routes default_route business_route typed_business_route mixed_typed_routes
    global_addr=$'2: eth0    inet6 2001:db8:720::1/64 scope global tentative\n'
    ula_addr=$'2: eth0    inet6 fd72::1/64 scope global\n'
    link_addr=$'1: lo    inet6 ::1/128 scope host\n2: eth0    inet6 fe80::1/64 scope link\n'
    link_routes=$'::1 dev lo proto kernel metric 256 pref medium\nfe80::/64 dev eth0 proto kernel metric 256 pref medium\nlocal fe80::1 dev eth0 table local proto kernel metric 0 pref medium\nmulticast ff00::/8 dev eth0 table local proto kernel metric 256 pref medium\n'
    default_route=$'default via fe80::1 dev eth0 proto ra metric 1024\n'
    business_route=$'2001:db8:721::/64 dev eth0 proto static metric 100\n'
    typed_business_route=$'local 2001:db8:722::1 dev eth0 table local proto kernel metric 0\n'
    mixed_typed_routes=$'fe80::/64 dev eth0 proto kernel metric 256\nlocal 2001:db8:723::1 dev eth0 table local proto kernel metric 0\n'

    ipv6_address_output_has_routable_topology "$global_addr" || fail "global IPv6 address was classified safe"
    ipv6_address_output_has_routable_topology "$ula_addr" || fail "ULA address was classified safe"
    if ipv6_address_output_has_routable_topology "$link_addr"; then fail "pure link-local addresses were classified routable"; fi
    ipv6_route_output_has_business_topology "$default_route" || fail "IPv6 default route was classified safe"
    ipv6_route_output_has_business_topology "$business_route" || fail "non-link-local IPv6 business route was classified safe"
    ipv6_route_output_has_business_topology "$typed_business_route" || fail "type-prefixed global IPv6 route was classified safe"
    ipv6_route_output_has_business_topology "$mixed_typed_routes" || fail "type-prefixed route reused a previous destination"
    if ipv6_route_output_has_business_topology "$link_routes"; then fail "pure link-local routes were classified as business routes"; fi

    set_case global-address
    MOCK_IPV6_ADDR_OUTPUT="$global_addr"
    if ipv6_disable temporary >/dev/null 2>&1; then fail "global IPv6 topology was allowed to disable"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "global-address guard ran after baseline creation"
    assert_eq 0 "$(read_iface eth0)" "global-address guard changed disable flag"
    assert_eq '' "$WRITE_EVENTS" "global-address guard wrote a disable flag before refusal"

    set_case ula-address
    MOCK_IPV6_ADDR_OUTPUT="$ula_addr"
    if ipv6_disable temporary >/dev/null 2>&1; then fail "ULA topology was allowed to disable"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "ULA guard ran after baseline creation"
    assert_eq '' "$WRITE_EVENTS" "ULA guard wrote a disable flag before refusal"

    set_case dual-default
    MOCK_ROUTE_MODE=dual
    MOCK_IPV6_ROUTE_OUTPUT="$default_route"
    if ipv6_disable temporary >/dev/null 2>&1; then fail "dual-stack IPv6 default was allowed to disable"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "dual-default guard ran after baseline creation"
    assert_eq '' "$WRITE_EVENTS" "dual-stack guard wrote a disable flag before refusal"

    set_case business-route
    MOCK_IPV6_ROUTE_OUTPUT="$business_route"
    if ipv6_disable temporary >/dev/null 2>&1; then fail "non-link-local IPv6 business route was allowed to disable"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "business-route guard ran after baseline creation"
    assert_eq '' "$WRITE_EVENTS" "business-route guard wrote a disable flag before refusal"

    set_case link-local-only
    MOCK_IPV6_ADDR_OUTPUT="$link_addr"
    MOCK_IPV6_ROUTE_OUTPUT="$link_routes"
    ipv6_disable temporary >/dev/null
    assert_eq 1 "$(read_iface eth0)" "link-local-only host did not proceed"
    assert_eq 0 "$(read_iface lo)" "link-local-only path modified loopback"
}

test_real_global_topology_counterexample() (
    [[ "${BBRV3_IPV6_REAL_INTEGRATION:-0}" == 1 ]] || return 0
    local real_ip real_sysctl iface=bbrv6test0 all_before
    real_ip=$(type -P ip)
    real_sysctl=$(type -P sysctl)
    [[ -n "$real_ip" ]] || fail "real IPv6 integration requires iproute2"
    [[ -n "$real_sysctl" ]] || fail "real IPv6 integration requires procps"
    "$real_ip" link add name "$iface" type dummy
    trap '"$real_ip" link del "$iface" 2>/dev/null || true' EXIT
    "$real_ip" link set "$iface" up
    "$real_sysctl" -q -w "net.ipv6.conf.${iface}.disable_ipv6=0"
    "$real_ip" -6 addr add 2001:db8:720::1/64 dev "$iface"
    "$real_ip" -6 route add 2001:db8:721::/64 dev "$iface"

    unset -f ip sysctl
    STATE_DIR="$TEST_ROOT/real-topology/state"
    HISTORY_DIR="$STATE_DIR/history"
    BASELINE_DIR="$STATE_DIR/baseline"
    IPV6_BACKUP_DIR="$STATE_DIR/ipv6"
    IPV6_SYSCTL_FILE="$TEST_ROOT/real-topology/etc/99-bbrv3-lite-ipv6.conf"
    IPV6_PROC_CONF_ROOT=/proc/sys/net/ipv6/conf
    IPV6_CMDLINE_FILE=/proc/cmdline
    IPV6_MODULE_DISABLE_FILE=/sys/module/ipv6/parameters/disable
    IPV6_PROC_CONF_ROOT_EXPLICIT=1
    IPV6_TRANSACTION_DIR=""
    SSH_CONNECTION=""
    if ipv6_disable temporary >/dev/null 2>&1; then fail "real global IPv6 topology was allowed to disable"; fi
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "real topology guard created a baseline before refusal"
    grep -qx 0 "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" || fail "real topology guard changed disable flag"
    "$real_ip" -6 -o addr show dev "$iface" | grep -F '2001:db8:720::1/64' >/dev/null || fail "global address disappeared during refused operation"
    "$real_ip" -6 route show 2001:db8:721::/64 | grep -F '2001:db8:721::/64' >/dev/null || fail "static IPv6 route disappeared during refused operation"
    printf 'real global IPv6 topology counterexample: OK\n'

    # A v2 snapshot may contain a historical all=1 observation. Manufacture
    # that audit record while retaining per-interface target=0, then prove the
    # restore path never invokes all and preserves real kernel topology.
    mkdir -p -- "$IPV6_BACKUP_DIR"
    ipv6_snapshot_current "$IPV6_BACKUP_DIR/baseline"
    { printf 'CREATED_AT\t2026-08-23T00:00:00Z\nCREATED_BY\t7.2.1\n'; cat "$IPV6_BACKUP_DIR/baseline/snapshot.meta"; } \
        > "$IPV6_BACKUP_DIR/baseline/manifest"
    sed -i $'s/^AGGREGATE\tall\t[01]$/AGGREGATE\tall\t1/' "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    sed -i $'/^INTERFACE\t/s/\t[01]$/\t0/' "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    grep -Fqx $'AGGREGATE\tall\t1' "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" || fail "could not construct historical all=1 audit record"
    all_before=$(<"/proc/sys/net/ipv6/conf/all/disable_ipv6")
    WRITE_EVENTS=""
    MOCK_ALL_WRITE_COUNT=0
    ipv6_restore >/dev/null
    assert_eq "$all_before" "$(<"/proc/sys/net/ipv6/conf/all/disable_ipv6")" "real v2 restore changed all write-trigger state"
    assert_eq 0 "$MOCK_ALL_WRITE_COUNT" "real v2 restore invoked all write trigger"
    [[ "$WRITE_EVENTS" != *' all='* ]] || fail "real v2 restore replayed all: $WRITE_EVENTS"
    "$real_ip" -6 -o addr show dev "$iface" | grep -F '2001:db8:720::1/64' >/dev/null || fail "real v2 restore deleted global address"
    "$real_ip" -6 route show 2001:db8:721::/64 | grep -F '2001:db8:721::/64' >/dev/null || fail "real v2 restore deleted static route"
    printf 'real v2 restore all-trigger regression: OK\n'
)

test_corrupt_baseline_is_not_silently_replaced() {
    set_case corrupt
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline"
    : > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    if ipv6_capture_baseline >/dev/null 2>&1; then fail "empty existing baseline was silently accepted or replaced"; fi
    [[ ! -s "$IPV6_BACKUP_DIR/baseline/sysctl.tsv" ]] || fail "corrupt immutable baseline was overwritten"
}

assert_current_snapshot_invalid() {
    local label="$1" base="$IPV6_BACKUP_DIR/baseline"
    if ipv6_validate_snapshot "$base"; then fail "$label malformed snapshot passed validator"; fi
    assert_eq malformed/invalid "$(ipv6_snapshot_quality "$base")" "$label malformed snapshot quality"
}

test_unified_snapshot_validator_and_inert_malformed_restore() {
    local base output

    set_case malformed-live-inert
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'CAPTURE\tper-interface\n' >> "$base/snapshot.meta"
    assert_current_snapshot_invalid duplicate-metadata
    printf 'keep-live-policy\n' > "$IPV6_SYSCTL_FILE"
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/eth0/disable_ipv6"
    WRITE_EVENTS=""
    if ipv6_restore >/dev/null 2>&1; then fail "malformed baseline was restored"; fi
    assert_eq '' "$WRITE_EVENTS" "malformed restore wrote a disable flag"
    assert_eq 1 "$(read_iface eth0)" "malformed restore changed live interface flag"
    assert_eq keep-live-policy "$(<"$IPV6_SYSCTL_FILE")" "malformed restore deleted live persistent policy"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "malformed restore created a transaction"
    output=$(ipv6_status)
    [[ "$output" == *'malformed/invalid'* ]] || fail "status trusted malformed CAPTURE metadata: $output"
    if ipv6_capture_baseline >/dev/null 2>&1; then fail "existing malformed baseline was silently accepted or replaced"; fi
    grep -Fqx $'CAPTURE\tper-interface' "$base/snapshot.meta" || fail "malformed immutable baseline was overwritten"

    set_case malformed-duplicate-interface
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'INTERFACE\tdefault\t0\n' >> "$base/sysctl.tsv"
    assert_current_snapshot_invalid duplicate-interface

    set_case malformed-missing-aggregate
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    sed -i $'/^AGGREGATE\tall\t/d' "$base/sysctl.tsv"
    assert_current_snapshot_invalid missing-aggregate

    set_case malformed-unsafe-interface
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'INTERFACE\tbad/name\t0\n' >> "$base/sysctl.tsv"
    assert_current_snapshot_invalid unsafe-interface

    set_case malformed-flag
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    sed -i $'s/^INTERFACE\teth0\t[01]$/INTERFACE\teth0\t2/' "$base/sysctl.tsv"
    assert_current_snapshot_invalid invalid-flag

    set_case malformed-persistent-state
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'unknown\n' > "$base/persistent.state"
    assert_current_snapshot_invalid invalid-persistent-state

    set_case malformed-missing-persistent-copy
    printf 'original-policy\n' > "$IPV6_SYSCTL_FILE"
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    rm -f -- "$base/persistent.conf"
    assert_current_snapshot_invalid missing-persistent-copy

    set_case malformed-extra-persistent-copy
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'unexpected-policy\n' > "$base/persistent.conf"
    assert_current_snapshot_invalid extra-persistent-copy

    set_case malformed-duplicate-manifest-field
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'CREATED_AT\t2026-08-23T00:00:01Z\n' >> "$base/manifest"
    assert_current_snapshot_invalid duplicate-manifest-field

    set_case malformed-unknown-manifest-field
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    printf 'UNTRUSTED\t1\n' >> "$base/manifest"
    assert_current_snapshot_invalid unknown-manifest-field

    set_case malformed-mismatched-manifest
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    sed -i $'s/^CAPTURE\tper-interface$/CAPTURE\tpartial/' "$base/manifest"
    assert_current_snapshot_invalid mismatched-manifest

    set_case malformed-missing-manifest
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    rm -f -- "$base/manifest"
    if ipv6_restore >/dev/null 2>&1; then fail "baseline without manifest was restored"; fi
    assert_eq malformed/invalid "$(ipv6_snapshot_quality "$base" 1)" "missing manifest baseline quality"

    set_case malformed-missing-diagnostics
    ipv6_capture_baseline
    base="$IPV6_BACKUP_DIR/baseline"
    rm -f -- "$base/routes-v6.txt"
    assert_current_snapshot_invalid missing-diagnostics
}

test_stale_transaction_blocks_all_new_ipv6_writes() {
    local stale before

    set_case stale-transaction-disable
    stale="$IPV6_BACKUP_DIR/.transaction.interrupted"
    mkdir -p -- "$stale"
    printf 'forensic-snapshot\n' > "$stale/marker"
    before=$(read_iface eth0)
    WRITE_EVENTS=""
    if ipv6_disable permanent >/dev/null 2>&1; then fail "stale IPv6 transaction allowed a new disable"; fi
    assert_eq "$before" "$(read_iface eth0)" "stale transaction disable changed eth0"
    assert_eq '' "$WRITE_EVENTS" "stale transaction disable wrote a flag"
    [[ ! -e "$IPV6_BACKUP_DIR/baseline" ]] || fail "stale transaction disable created a new baseline"
    assert_eq forensic-snapshot "$(<"$stale/marker")" "stale transaction evidence was modified"

    set_case stale-transaction-restore
    ipv6_capture_baseline
    stale="$IPV6_BACKUP_DIR/.transaction.interrupted"
    mkdir -p -- "$stale"
    printf 'forensic-snapshot\n' > "$stale/marker"
    printf '1\n' > "$IPV6_PROC_CONF_ROOT/eth0/disable_ipv6"
    WRITE_EVENTS=""
    if ipv6_restore >/dev/null 2>&1; then fail "stale IPv6 transaction allowed a new restore"; fi
    assert_eq 1 "$(read_iface eth0)" "stale transaction restore changed eth0"
    assert_eq '' "$WRITE_EVENTS" "stale transaction restore wrote a flag"
    assert_eq forensic-snapshot "$(<"$stale/marker")" "stale restore evidence was modified"
}

test_interface_aware_disable_and_flag_restore
test_v2_restore_never_replays_all_over_new_topology
test_restore_target_one_fails_before_any_write
test_legacy_all_one_is_guarded_but_zero_can_continue
test_restore_requires_host_network_control_before_writes
test_failed_change_rolls_back_every_interface_and_policy
test_partial_rollback_restores_survivors_across_interface_drift
test_remote_access_and_boot_guards
test_boot_disabled_restore_is_persistent_only
test_interface_set_drift_refuses_exact_flag_restore
test_legacy_baseline_is_never_claimed_exact_flags
test_corrupt_baseline_is_not_silently_replaced
test_unified_snapshot_validator_and_inert_malformed_restore
test_stale_transaction_blocks_all_new_ipv6_writes
test_topology_classifiers_and_fail_closed_preflight
test_real_global_topology_counterexample
printf 'ipv6 v7.2.1 tests: OK\n'
