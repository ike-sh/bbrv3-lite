#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3: missing '$2'"; }
assert_not_contains() { ! grep -Fq -- "$2" <<< "$1" || fail "$3: unexpectedly contains '$2'"; }

test_ipv6_permanent_confirmation_warns_about_future_interfaces() {
    local output
    confirm() { printf 'PROMPT:%s\n' "$1"; return 1; }
    if output=$(confirm_ipv6_policy_apply disabled-persistent 2>&1); then
        fail 'declined persistent IPv6 confirmation was accepted'
    fi
    for text in \
        'net.ipv6.conf.default.disable_ipv6=1' \
        'Docker veth' WireGuard TUN/TAP Tailscale '新增 NIC' '虚拟接口' '未来接口'; do
        assert_contains "$output" "$text" 'persistent IPv6 future-interface warning'
    done

    if output=$(confirm_ipv6_policy_apply disabled-temporary 2>&1); then
        fail 'declined temporary IPv6 confirmation was accepted'
    fi
    assert_contains "$output" '临时禁用非回环 IPv6' 'temporary IPv6 confirmation'
    assert_not_contains "$output" 'net.ipv6.conf.default.disable_ipv6=1' 'temporary permanent-only warning'
    assert_not_contains "$output" 'Docker veth' 'temporary future-interface warning'
}

test_ipv6_permanent_confirmation_warns_about_future_interfaces
echo 'IPv6 warning v8.0.3 regression tests: OK'
