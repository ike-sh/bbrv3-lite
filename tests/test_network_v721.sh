#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_PERSIST_DIR="$TEST_ROOT/persist"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/persist/net-tcp-tune.sh"
export BBRV3_SERVICE_FILE="$TEST_ROOT/bbrv3-lite.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/99-bbrv3-lite.conf"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

for module in 00-header.sh core.sh config.sh platform.sh path.sh state.sh sysctl.sh tc.sh nic.sh measure.sh systemd.sh cli.sh; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/src/$module"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

test_route_dev_token_is_position_independent() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default dev ppp0 proto static metric 50\n' ;;
                '-6 route show default') : ;;
                *) return 1 ;;
            esac
        }
        assert_eq ppp0 "$(default_route_interface)" "default route dev token parsing"
    )
}

test_multiple_metric_defaults_use_target_route() {
    (
        ip() {
            case "$*" in
                '-4 route show default')
                    printf '%s\n' \
                        'default via 192.0.2.1 dev eth0 metric 100' \
                        'default via 198.51.100.1 dev eth1 metric 200'
                    ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-4 route get fibmatch 203.0.113.10') printf 'default via 192.0.2.1 dev eth0 metric 100\n' ;;
                *) return 1 ;;
            esac
        }
        getent() { printf '203.0.113.10 STREAM peer.example\n'; }
        auto_tune_route_guard eth0 peer.example || fail "unique target route was rejected with multiple metric defaults"
    )
}

test_fibmatch_interface_mismatch_is_rejected() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-4 route get fibmatch 203.0.113.10') printf '203.0.113.0/24 via 198.51.100.1 dev eth1\n' ;;
                *) return 1 ;;
            esac
        }
        getent() { printf '203.0.113.10 STREAM peer.example\n'; }
        if auto_tune_route_guard eth0 peer.example >/dev/null 2>&1; then
            fail "route-get/fibmatch interface mismatch was accepted"
        fi
    )
}

test_unavailable_fibmatch_does_not_use_cross_interface_fallback() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-4 route get fibmatch 203.0.113.10') return 2 ;;
                '-4 route show match 203.0.113.10')
                    printf '%s\n' \
                        '203.0.113.0/24 via 192.0.2.1 dev eth0 metric 100' \
                        '203.0.113.0/24 via 198.51.100.1 dev eth1 metric 200'
                    ;;
                *) return 1 ;;
            esac
        }
        getent() { printf '203.0.113.10 STREAM peer.example\n'; }
        if auto_tune_route_guard eth0 peer.example >/dev/null 2>&1; then
            fail "unsupported fibmatch was accepted through an incomplete route-show fallback"
        fi
    )
}

test_every_resolved_address_requires_route_get() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-4 route get fibmatch 203.0.113.10') printf '203.0.113.0/24 via 192.0.2.1 dev eth0\n' ;;
                '-4 route get 198.51.100.10') return 2 ;;
                *) return 1 ;;
            esac
        }
        getent() {
            printf '%s\n' \
                '203.0.113.10 STREAM peer.example' \
                '198.51.100.10 STREAM peer.example'
        }
        if auto_tune_route_guard eth0 peer.example >/dev/null 2>&1; then
            fail "a target with an unverified resolved address was accepted"
        fi
    )
}

test_target_interface_mismatch_is_rejected() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 198.51.100.1 dev eth1 src 198.51.100.10\n' ;;
                '-4 route get fibmatch 203.0.113.10') printf 'default via 198.51.100.1 dev eth1\n' ;;
                *) return 1 ;;
            esac
        }
        getent() { printf '203.0.113.10 STREAM peer.example\n'; }
        if auto_tune_route_guard eth0 peer.example >/dev/null 2>&1; then
            fail "target route on another interface was accepted"
        fi
    )
}

test_dual_stack_target_split_is_rejected() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') printf 'default via 2001:db8:2::1 dev eth1\n' ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-6 route get 2001:db8:2::10') printf '2001:db8:2::10 via 2001:db8:2::1 dev eth1 src 2001:db8:2::20\n' ;;
                '-4 route get fibmatch 203.0.113.10') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route get fibmatch 2001:db8:2::10') printf 'default via 2001:db8:2::1 dev eth1\n' ;;
                *) return 1 ;;
            esac
        }
        getent() {
            printf '%s\n' \
                '203.0.113.10 STREAM peer.example' \
                '2001:db8:2::10 STREAM peer.example'
        }
        if auto_tune_route_guard eth0 peer.example >/dev/null 2>&1; then
            fail "dual-stack peer with split egress was accepted"
        fi
    )
}

test_ecmp_is_rejected() {
    (
        ip() {
            case "$*" in
                '-4 route show default')
                    printf 'default proto static nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 198.51.100.1 dev eth1 weight 1\n'
                    ;;
                '-6 route show default') : ;;
                *) return 1 ;;
            esac
        }
        if auto_tune_route_guard eth0 203.0.113.10 >/dev/null 2>&1; then
            fail "ECMP/nexthop default was accepted"
        fi
    )
}

test_hashed_ecmp_is_rejected_from_matching_route() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') : ;;
                '-4 route get 203.0.113.10') printf '203.0.113.10 via 192.0.2.1 dev eth0 src 192.0.2.10\n' ;;
                '-4 route get fibmatch 203.0.113.10')
                    printf 'default proto static nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 198.51.100.1 dev eth1 weight 1\n'
                    ;;
                *) return 1 ;;
            esac
        }
        if auto_tune_route_guard eth0 203.0.113.10 >/dev/null 2>&1; then
            fail "hashed ECMP hidden by route-get was accepted"
        fi
    )
}

test_no_peer_ambiguous_exit_is_rejected() {
    (
        ip() {
            case "$*" in
                '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
                '-6 route show default') printf 'default via 2001:db8:2::1 dev eth1\n' ;;
                *) return 1 ;;
            esac
        }
        if auto_tune_route_guard eth0 "" >/dev/null 2>&1; then
            fail "peer-less auto tune accepted split IPv4/IPv6 exits"
        fi
    )
}

test_runtime_auto_shaping_is_pinned_on_save() {
    (
        local config="$TEST_ROOT/pinned.conf"
        managed_htb() { [[ "$1" == eth7 ]]; }
        managed_rate_mbit() { [[ "$1" == eth7 ]] && printf '321\n'; }
        reset_config
        TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT=321; TC_SESSION_HTB_IFACE=eth7
        save_config "$config"
        grep -Fqx 'TC_INTERFACE=eth7' "$config" || fail "runtime auto interface was not pinned"
    )
}

test_legacy_auto_shaping_apply_fails_closed() {
    (
        local events=""
        reset_config
        TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT=321; TC_KNEE_MBIT=330
        save_config "$CONFIG_FILE"
        require_root() { :; }
        acquire_lock() { :; }
        apply_sysctl_profile() { events+=" sysctl"; }
        apply_shaping() { events+=" shape"; }
        if apply_configured_state >/dev/null 2>&1; then
            fail "legacy auto shaping config was applied"
        fi
        assert_eq "" "$events" "legacy auto config changed runtime before rejection"
    )
}

test_install_does_not_migrate_legacy_auto_rate() {
    (
        local events=""
        reset_config
        TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT=321; TC_KNEE_MBIT=330
        save_config "$CONFIG_FILE"
        capture_baseline() { :; }
        migrate_legacy_config() { :; }
        apply_sysctl_profile() { events+=" sysctl"; }
        apply_shaping() { events+=" shape"; }
        apply_fq() { events+=" fq"; }
        if install_base_tuning_steps eth1 auto balanced mixed 0 0 >/dev/null 2>&1; then
            fail "install migrated a legacy auto shaping rate"
        fi
        assert_eq "" "$events" "install changed runtime before rejecting legacy auto rate"
    )
}

test_auto_tune_persists_actual_interface_without_peer() {
    (
        local prepared_iface="" persisted_iface=""
        WIZARD_PEER=""
        prepare_auto_tuning_runtime() { prepared_iface="$2"; TC_INTERFACE="$2"; TC_ENABLED=0; }
        verify_runtime_tuning() { :; }
        persist_current_tuning() { persisted_iface="$TC_INTERFACE"; }
        show_status() { :; }
        auto_tune_execute ens9 balanced mixed 0 0
        assert_eq ens9 "$prepared_iface" "auto runtime requested interface"
        assert_eq ens9 "$persisted_iface" "auto persisted interface"
    )
}

test_real_linux_fibmatch_and_metric_fallback() (
    local expected normal fibmatch nic0="b7n0$$" nic1="b7n1$$"
    cleanup_real_network_test() {
        ip link del "$nic0" >/dev/null 2>&1 || true
        ip link del "$nic1" >/dev/null 2>&1 || true
    }
    trap cleanup_real_network_test EXIT
    command_exists ip || fail "integration mode requires iproute2"
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "integration mode requires root"
    expected=$(default_route_interface)
    [[ -n "$expected" ]] || fail "integration container has no default interface"

    ip link add "$nic0" type dummy
    ip link add "$nic1" type dummy
    ip link set "$nic0" up
    ip link set "$nic1" up
    ip route add 203.0.113.0/24 nexthop dev "$nic0" weight 1 nexthop dev "$nic1" weight 1
    normal=$(ip -4 route get 203.0.113.10)
    fibmatch=$(ip -4 route get fibmatch 203.0.113.10)
    [[ "$normal" != *nexthop* && "$fibmatch" == *nexthop* ]] || fail "kernel did not expose hashed ECMP through fibmatch as expected"
    if auto_tune_route_guard "$expected" 203.0.113.10 >/dev/null 2>&1; then
        fail "real Linux ECMP route was accepted"
    fi
    ip route del 203.0.113.0/24

    ip route add default dev "$nic0" metric 5000
    auto_tune_route_guard "$expected" 1.1.1.1 || fail "real metric fallback route was rejected despite a unique route-get"
    ip route del default dev "$nic0" metric 5000
)

test_route_dev_token_is_position_independent
test_multiple_metric_defaults_use_target_route
test_target_interface_mismatch_is_rejected
test_fibmatch_interface_mismatch_is_rejected
test_unavailable_fibmatch_does_not_use_cross_interface_fallback
test_every_resolved_address_requires_route_get
test_dual_stack_target_split_is_rejected
test_ecmp_is_rejected
test_hashed_ecmp_is_rejected_from_matching_route
test_no_peer_ambiguous_exit_is_rejected
test_runtime_auto_shaping_is_pinned_on_save
test_legacy_auto_shaping_apply_fails_closed
test_install_does_not_migrate_legacy_auto_rate
test_auto_tune_persists_actual_interface_without_peer
if [[ "${BBRV3_NETWORK_INTEGRATION:-0}" == 1 ]]; then
    test_real_linux_fibmatch_and_metric_fallback
fi

printf 'network v7.2.1 tests: PASS\n'
