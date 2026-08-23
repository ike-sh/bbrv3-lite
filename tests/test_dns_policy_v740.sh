#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BBRV3_DNS_DROPIN="$TEST_ROOT/etc/systemd/resolved.conf.d/80-bbrv3-lite.conf"
export BBRV3_RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
export BBRV3_DNS_STUB_RESOLV="$TEST_ROOT/run/systemd/resolve/stub-resolv.conf"
export BBRV3_DNS_FULL_RESOLV="$TEST_ROOT/run/systemd/resolve/resolv.conf"
DNS_BACKUP_DIR="$TEST_ROOT/state/dns"
SCRIPT_VERSION=7.4.0-test
DNS_TRANSACTION_DIR=""

# shellcheck source=../src/dns.sh
source "$ROOT_DIR/src/dns.sh"
# shellcheck source=../src/dns-policy.sh
source "$ROOT_DIR/src/dns-policy.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3: missing '$2'"; }
die() { printf 'ERR %s\n' "$*" >&2; return 1; }
log() { :; }
command_exists() { return 0; }
require_commands() { return 0; }

UNIT_ENABLED=enabled
UNIT_ACTIVE=active
UNIT_LOAD=loaded
DOMAIN_OUTPUT='Global:'
APPLY_CALLS=0
RESTORE_CALLS=0
VERIFY_MODE=""

systemctl() {
    case "${1:-}" in
        cat) return 0 ;;
        is-enabled) printf '%s\n' "$UNIT_ENABLED" ;;
        is-active) printf '%s\n' "$UNIT_ACTIVE" ;;
        show) printf '%s\n' "$UNIT_LOAD" ;;
        *) return 0 ;;
    esac
}

resolvectl() {
    case "${1:-}" in
        domain) printf '%s\n' "$DOMAIN_OUTPUT" ;;
        status) printf '%s\n' 'Global' ;;
        *) return 0 ;;
    esac
}

write_policy() {
    local policy="$1"
    mkdir -p -- "$(dirname "$DNS_DROPIN")"
    if [[ "$policy" == strict-dot ]]; then
        printf '%s\n' \
            '# Policy: strict-dot' \
            '[Resolve]' 'DNS=' 'FallbackDNS=' 'Domains=' \
            'DNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net' \
            'FallbackDNS=8.8.8.8#dns.google 2001:4860:4860::8888#dns.google' \
            'Domains=~.' 'DNSOverTLS=yes' 'DNSSEC=allow-downgrade' > "$DNS_DROPIN"
    else
        printf '%s\n' \
            '# Policy: plain' \
            '[Resolve]' 'DNS=' 'FallbackDNS=' 'Domains=' \
            'DNS=1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe' \
            'FallbackDNS=8.8.8.8 2001:4860:4860::8888' \
            'Domains=~.' 'DNSOverTLS=no' 'DNSSEC=allow-downgrade' > "$DNS_DROPIN"
    fi
}

dns_apply() {
    APPLY_CALLS=$((APPLY_CALLS + 1))
    [[ "$1" == dot ]] && write_policy strict-dot || write_policy plain
    DOMAIN_OUTPUT='Global: ~.'
}
dns_restore() { RESTORE_CALLS=$((RESTORE_CALLS + 1)); rm -f -- "$DNS_DROPIN"; DOMAIN_OUTPUT='Global:'; }
dns_verify_runtime() { VERIFY_MODE="$1"; }
dns_validate_snapshot() { return 0; }
dns_policy_native_matches_baseline() { [[ ! -e "$DNS_DROPIN" && ! -L "$DNS_DROPIN" ]]; }

reset_case() {
    rm -rf -- "${TEST_ROOT:?}/etc" "$TEST_ROOT/run" "$TEST_ROOT/state"
    mkdir -p -- "$(dirname "$DNS_RESOLV_CONF")" "$(dirname "$DNS_STUB_RESOLV")"
    printf 'nameserver 127.0.0.53\n' > "$DNS_STUB_RESOLV"
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=enabled; UNIT_ACTIVE=active; UNIT_LOAD=loaded
    DOMAIN_OUTPUT='Global:'; APPLY_CALLS=0; RESTORE_CALLS=0; VERIFY_MODE=""
}

test_aliases_and_inference() {
    reset_case
    assert_eq strict-dot "$(dns_policy_normalize auto)" 'auto alias'
    assert_eq strict-dot "$(dns_policy_normalize dot)" 'dot alias'
    assert_eq native "$(dns_policy_detect_current)" 'native inference'
    write_policy strict-dot
    assert_eq strict-dot "$(dns_policy_detect_current)" 'strict DoT inference'
    write_policy plain
    assert_eq plain "$(dns_policy_detect_current)" 'plain inference'
    printf 'unmanaged=true\n' > "$DNS_DROPIN"
    assert_eq foreign "$(dns_policy_detect_current)" 'foreign inference'
}

test_plan_is_read_only_and_explains_risk() {
    local before after output
    reset_case
    before=$(find "$TEST_ROOT" -type f -o -type l | sort | xargs -r sha256sum)
    output=$(dns_policy_plan strict-dot)
    after=$(find "$TEST_ROOT" -type f -o -type l | sort | xargs -r sha256sum)
    assert_eq "$before" "$after" 'DNS plan filesystem mutation'
    assert_eq 0 "$APPLY_CALLS" 'DNS plan executor calls'
    assert_contains "$output" 'Decision             ready' 'ready plan'
    assert_contains "$output" 'Plan mutation        none (read-only)' 'read-only marker'

    DOMAIN_OUTPUT=$'Global:\nLink 2 (wg0): ~corp.example'
    if output=$(dns_policy_plan strict-dot 2>&1); then fail 'split DNS plan was accepted'; fi
    assert_contains "$output" 'blocked' 'split DNS decision'
    assert_contains "$output" 'per-link DNS' 'split DNS reason'
}

test_foreign_policy_is_never_overwritten() {
    local before
    reset_case
    mkdir -p -- "$(dirname "$DNS_DROPIN")"
    printf 'foreign=true\n' > "$DNS_DROPIN"
    before=$(sha256sum "$DNS_DROPIN")
    if dns_policy_apply strict-dot >/dev/null 2>&1; then fail 'foreign DNS file was accepted'; fi
    assert_eq "$before" "$(sha256sum "$DNS_DROPIN")" 'foreign DNS file changed'
    assert_eq 0 "$APPLY_CALLS" 'foreign policy reached executor'
    if dns_policy_verify >/dev/null 2>&1; then fail 'foreign DNS state passed inferred verification'; fi
}

test_apply_verify_and_native_restore_dispatch() {
    local output
    reset_case
    dns_policy_apply strict-dot > "$TEST_ROOT/apply.out"
    output=$(<"$TEST_ROOT/apply.out")
    assert_eq 1 "$APPLY_CALLS" 'strict-dot apply dispatch'
    assert_eq strict-dot "$(dns_policy_detect_current)" 'strict-dot apply inference'
    assert_contains "$output" 'install-strict-dot' 'apply plan output'
    dns_policy_verify strict-dot
    assert_eq dot "$VERIFY_MODE" 'strict-dot live verification mode'

    dns_policy_apply plain >/dev/null
    assert_eq 2 "$APPLY_CALLS" 'plain apply dispatch'
    assert_eq plain "$(dns_policy_detect_current)" 'plain apply inference'
    dns_policy_verify plain
    assert_eq plain "$VERIFY_MODE" 'plain live verification mode'

    mkdir -p -- "$DNS_BACKUP_DIR/baseline"
    dns_policy_apply native >/dev/null
    assert_eq 1 "$RESTORE_CALLS" 'native restore dispatch'
    assert_eq native "$(dns_policy_detect_current)" 'native restore inference'
}

test_native_without_baseline_is_noop() {
    reset_case
    dns_policy_apply native >/dev/null
    assert_eq 0 "$RESTORE_CALLS" 'native noop restore calls'
    assert_eq 0 "$APPLY_CALLS" 'native noop apply calls'
}

test_pending_transaction_blocks_native_plan() {
    local output
    reset_case
    mkdir -p -- "$DNS_BACKUP_DIR/.transaction.stale"
    if output=$(dns_policy_plan native 2>&1); then fail 'stale DNS transaction allowed native plan'; fi
    assert_contains "$output" 'blocked' 'stale DNS transaction decision'
    assert_contains "$output" '未完成 DNS 事务' 'stale DNS transaction reason'
}

test_aliases_and_inference
test_plan_is_read_only_and_explains_risk
test_foreign_policy_is_never_overwritten
test_apply_verify_and_native_restore_dispatch
test_native_without_baseline_is_noop
test_pending_transaction_blocks_native_plan
printf 'dns v7.4.0 policy tests: OK\n'
