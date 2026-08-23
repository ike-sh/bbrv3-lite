#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_SYS_CLASS_NET_ROOT="$TEST_ROOT/sys/class/net"
mkdir -p "$BBRV3_SYS_CLASS_NET_ROOT/eth0" "$BBRV3_SYS_CLASS_NET_ROOT/eth1"

for module in 00-header.sh core.sh config.sh platform.sh state.sh sysctl.sh tc.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

test_managed_interface_scan_is_complete() {
    (
        managed_htb() { [[ "$1" == eth0 || "$1" == eth1 ]]; }
        assert_eq $'eth0\neth1' "$(managed_htb_interfaces)" "managed HTB interface scan"
    )
}

test_pinned_shaping_cannot_move_implicitly() {
    (
        load_config() {
            TC_ENABLED=1; TC_INTERFACE=eth0; TC_RATE_MBIT=300
        }
        managed_htb_interfaces_strict() { printf 'eth0\n'; }
        if shaping_target_preflight eth1 enable auto >/dev/null 2>&1; then
            fail "pinned shaping moved to another interface"
        fi
        shaping_target_preflight eth0 enable eth0 || fail "same pinned interface was rejected"
    )
}

test_orphan_managed_htb_blocks_second_interface() {
    (
        load_config() {
            TC_ENABLED=0; TC_INTERFACE=eth1; TC_RATE_MBIT=0
        }
        managed_htb_interfaces_strict() { printf 'eth0\n'; }
        if shaping_target_preflight eth1 auto auto >/dev/null 2>&1; then
            fail "orphan managed HTB allowed a second shaping interface"
        fi
    )
}

test_strict_interface_scan_fails_closed() {
    (
        tc() {
            [[ "$1" == qdisc || "$1" == class ]] || return 1
            [[ "$2" == show && "$3" == dev ]] || return 1
            if [[ "$4" == eth1 ]]; then return 1; fi
            if [[ "$1" == qdisc ]]; then
                printf '%s\n' \
                    'qdisc htb 1: root refcnt 2 default 0x10 direct_packets_stat 0' \
                    'qdisc fq 10: parent 1:10 limit 10000p'
            else
                printf '%s\n' 'class htb 1:10 root rate 100Mbit ceil 100Mbit'
            fi
        }
        if managed_htb_interfaces_strict >/dev/null 2>&1; then
            fail "strict interface scan ignored an unreadable interface"
        fi
    )
}

test_unreadable_interface_scan_blocks_mutation() {
    (
        load_config() {
            TC_ENABLED=0; TC_INTERFACE=eth1; TC_RATE_MBIT=0
        }
        managed_htb_interfaces_strict() { return 1; }
        if shaping_target_preflight eth1 auto auto >/dev/null 2>&1; then
            fail "unreadable all-interface scan was treated as no managed HTB"
        fi
    )
}

test_legacy_auto_requires_explicit_cleanup() {
    (
        load_config() {
            TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT=300
        }
        managed_htb_interfaces_strict() { printf 'eth0\n'; }
        if shaping_target_preflight eth0 enable auto >/dev/null 2>&1; then
            fail "legacy auto rate was reused"
        fi
        if shaping_target_preflight eth0 disable auto >/dev/null 2>&1; then
            fail "legacy auto disable guessed an interface"
        fi
        shaping_target_preflight eth0 disable eth0 || fail "explicit legacy cleanup was rejected"
        if shaping_target_preflight eth1 disable eth1 >/dev/null 2>&1; then
            fail "legacy cleanup accepted a non-managed interface"
        fi
    )
}

test_legacy_preflight_is_read_only_and_current_corruption_fails() {
    (
        CONFIG_FILE="$TEST_ROOT/legacy-preflight.conf"
        cat > "$CONFIG_FILE" <<'EOF'
SYSCTL_PROFILE=balanced-minimal
TC_ENABLED=1
TC_INTERFACE=eth0
TC_RATE_MBIT=300
EOF
        chmod 0600 "$CONFIG_FILE"
        before=$(<"$CONFIG_FILE")
        managed_htb_interfaces_strict() { printf 'eth0\n'; }
        shaping_target_preflight eth0 install eth0 || fail "read-only legacy shaping preflight failed"
        assert_eq "$before" "$(<"$CONFIG_FILE")" "legacy preflight rewrote configuration"
        assert_eq eth0 "$TC_INTERFACE" "legacy preflight interface"
        assert_eq 300 "$TC_RATE_MBIT" "legacy preflight rate"

        cat > "$CONFIG_FILE" <<'EOF'
SCHEMA_VERSION=1
# balanced-minimal must not make a damaged current config look legacy.
SYSCTL_PROFILE=invalid-current-value
TC_ENABLED=0
TC_INTERFACE=eth0
TC_RATE_MBIT=0
EOF
        chmod 0600 "$CONFIG_FILE"
        if shaping_target_preflight eth0 install eth0 >/dev/null 2>&1; then
            fail "invalid current-schema configuration was treated as legacy"
        fi
    )
}

test_auto_trial_route_guard_precedes_changes() {
    (
        events=""
        require_root() { :; }
        require_host_network_control() { :; }
        acquire_lock() { :; }
        tc_dependencies() { :; }
        is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
        detect_interface() { printf 'eth0\n'; }
        auto_tune_route_guard() { events+=" guard"; return 1; }
        shaping_target_preflight() { events+=" target"; }
        network_tuning_preflight() { events+=" preflight"; }
        capture_baseline() { events+=" baseline"; }
        apply_shaping() { events+=" shaping"; }
        if tc_trial 100 auto >/dev/null 2>&1; then
            fail "tc trial ignored a failed peer-less route guard"
        fi
        assert_eq ' guard' "$events" "route guard ordering"
    )
}

test_explicit_trial_does_not_guess_default_route() {
    (
        events=""
        require_root() { :; }
        require_host_network_control() { :; }
        acquire_lock() { :; }
        tc_dependencies() { :; }
        is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
        detect_interface() { printf 'eth0\n'; }
        auto_tune_route_guard() { events+=" guard"; return 1; }
        shaping_target_preflight() { events+=" target"; }
        network_tuning_preflight() { events+=" preflight"; }
        capture_baseline() { events+=" baseline"; }
        tc_trial_transaction_begin() { events+=" begin"; }
        tc_trial_transaction_commit() { events+=" commit"; }
        apply_shaping() { events+=" shaping"; }
        log() { :; }
        tc_trial 100 eth0 || fail "explicit tc trial was rejected by automatic route selection"
        assert_eq ' target preflight baseline begin shaping commit' "$events" "explicit interface flow"
    )
}

test_trial_apply_failure_uses_outer_qdisc_rollback() {
    (
        events=""
        require_root() { :; }
        require_host_network_control() { :; }
        acquire_lock() { :; }
        tc_dependencies() { :; }
        is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
        detect_interface() { printf 'eth0\n'; }
        shaping_target_preflight() { :; }
        network_tuning_preflight() { :; }
        capture_baseline() { :; }
        tc_trial_transaction_begin() { events+=" begin"; }
        tc_trial_transaction_commit() { events+=" commit"; }
        tc_trial_transaction_rollback() { events+=" rollback"; }
        apply_shaping() { events+=" shaping"; return 1; }
        if tc_trial 100 eth0 >/dev/null 2>&1; then
            fail "failed trial shaping reported success"
        fi
        assert_eq ' begin shaping rollback' "$events" "trial failure rollback"
    )
}

test_real_single_interface_ownership_guard() {
    [[ "${BBRV3_NETWORK_INTEGRATION:-0}" == 1 ]] || return 0
    [[ "$(id -u)" == 0 ]] || return 0
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || return 0
    (
        local old_iface=bv721old new_iface=bv721new
        cleanup_real_tc() {
            ip link del "$old_iface" >/dev/null 2>&1 || true
            ip link del "$new_iface" >/dev/null 2>&1 || true
        }
        trap cleanup_real_tc EXIT
        cleanup_real_tc
        ip link add "$old_iface" type dummy
        ip link add "$new_iface" type dummy
        ip link set "$old_iface" up
        ip link set "$new_iface" up
        tc qdisc add dev "$old_iface" root handle 1: htb default 10
        tc class add dev "$old_iface" parent 1: classid 1:10 htb rate 10mbit ceil 10mbit
        tc qdisc add dev "$old_iface" parent 1:10 handle 10: fq
        BBRV3_SYS_CLASS_NET_ROOT=/sys/class/net
        load_config() {
            TC_ENABLED=0; TC_INTERFACE="$new_iface"; TC_RATE_MBIT=0
        }
        if shaping_target_preflight "$new_iface" auto auto >/dev/null 2>&1; then
            fail "real managed HTB on the old NIC did not block a second target"
        fi
        managed_htb "$old_iface" || fail "real managed HTB fixture was not recognized"
    )
}

test_managed_interface_scan_is_complete
test_pinned_shaping_cannot_move_implicitly
test_orphan_managed_htb_blocks_second_interface
test_strict_interface_scan_fails_closed
test_unreadable_interface_scan_blocks_mutation
test_legacy_auto_requires_explicit_cleanup
test_legacy_preflight_is_read_only_and_current_corruption_fails
test_auto_trial_route_guard_precedes_changes
test_explicit_trial_does_not_guess_default_route
test_trial_apply_failure_uses_outer_qdisc_rollback
test_real_single_interface_ownership_guard

echo "tc v7.2.1 tests passed"
