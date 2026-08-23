#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d /var/tmp/bbrv3-dns-systemd.XXXXXX)
PROJECT_DROPIN=/etc/systemd/resolved.conf.d/80-bbrv3-lite-integration.conf
BASE_DROPIN=/etc/systemd/resolved.conf.d/70-bbrv3-lite-integration-base.conf
SPLIT_DROPIN=/etc/systemd/resolved.conf.d/75-bbrv3-lite-integration-split.conf

cleanup() {
    local rc=$?
    set +e
    rm -f -- "$PROJECT_DROPIN" "$BASE_DROPIN" "$SPLIT_DROPIN"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl unmask systemd-resolved >/dev/null 2>&1
    systemctl enable systemd-resolved >/dev/null 2>&1
    systemctl restart systemd-resolved >/dev/null 2>&1
    rm -rf -- "$TEST_ROOT"
    return "$rc"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains_text() { grep -Fq -- "$2" <<< "$1" || fail "$3"; }
assert_not_contains_text() { ! grep -Fq -- "$2" <<< "$1" || fail "$3"; }

[[ $(cat /proc/1/comm) == systemd ]] || fail 'integration_dns_systemd.sh requires systemd as PID 1'
systemctl enable systemd-resolved >/dev/null
systemctl restart systemd-resolved
systemctl is-enabled --quiet systemd-resolved || fail 'systemd-resolved is not enabled in the integration container'
systemctl is-active --quiet systemd-resolved || fail 'systemd-resolved is not active in the integration container'

mkdir -p -- /etc/systemd/resolved.conf.d "$TEST_ROOT/etc" "$TEST_ROOT/state"
[[ -e /run/systemd/resolve/stub-resolv.conf ]] || fail 'systemd-resolved stub resolv.conf is absent'
ln -s /run/systemd/resolve/stub-resolv.conf "$TEST_ROOT/etc/resolv.conf"

export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_DNS_BACKUP_DIR="$TEST_ROOT/state/dns"
export BBRV3_DNS_DROPIN="$PROJECT_DROPIN"
export BBRV3_RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
export BBRV3_DNS_STUB_RESOLV=/run/systemd/resolve/stub-resolv.conf
export BBRV3_DNS_FULL_RESOLV=/run/systemd/resolve/resolv.conf
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"

# shellcheck source=../src/00-header.sh
source "$ROOT_DIR/src/00-header.sh"
# shellcheck source=../src/core.sh
source "$ROOT_DIR/src/core.sh"
# shellcheck source=../src/platform.sh
source "$ROOT_DIR/src/platform.sh"
# shellcheck source=../src/state.sh
source "$ROOT_DIR/src/state.sh"
# shellcheck source=../src/dns.sh
source "$ROOT_DIR/src/dns.sh"
# shellcheck source=../src/dns-policy.sh
source "$ROOT_DIR/src/dns-policy.sh"

# This is a privileged disposable container. Keep the real systemd runtime
# check, but deliberately bypass the production guard that protects a host
# from invoking network-changing code inside an ordinary container.
require_host_network_control() { :; }

# DNS routing, effective-server and service checks remain production code.
# Only the external Internet lookup is stubbed so the release gate does not
# depend on public resolver reachability from a CI runner.
DNS_QUERY_SHOULD_FAIL=0
DNS_QUERY_ENCRYPTED=0
dns_resolvectl_query() {
    (( DNS_QUERY_SHOULD_FAIL == 0 )) || return 1
    printf '%s\n' "${1:-test.invalid}: synthetic integration answer"
    if (( DNS_QUERY_ENCRYPTED )); then
        printf '%s\n' 'Data was acquired via local or encrypted transport: yes'
    fi
}

cat > "$BASE_DROPIN" <<'EOF'
[Resolve]
DNS=192.0.2.53
FallbackDNS=192.0.2.54
EOF
systemctl restart systemd-resolved
initial_dns=$(LC_ALL=C resolvectl dns)
assert_contains_text "$initial_dns" '192.0.2.53' 'lower-priority DNS fixture did not become effective'

plain_plan=$(dns_policy_plan plain)
assert_contains_text "$plain_plan" 'Decision             ready' 'plain policy plan was not ready'
assert_contains_text "$plain_plan" 'Plan mutation        none (read-only)' 'plain policy plan was not marked read-only'
[[ ! -e "$DNS_BACKUP_DIR/baseline" && ! -e "$PROJECT_DROPIN" ]] || fail 'DNS plan mutated files or baseline'
dns_policy_apply plain
[[ -f "$PROJECT_DROPIN" ]] || fail 'plain DNS apply did not install the project drop-in'
grep -Fxq '# Policy: plain' "$PROJECT_DROPIN" || fail 'plain DNS apply omitted canonical policy marker'
[[ -L "$DNS_RESOLV_CONF" ]] || fail 'plain DNS apply did not keep resolv.conf as a symlink'
grep -Fxq $'SCHEMA\t2' "$DNS_BACKUP_DIR/baseline/manifest" || fail 'DNS baseline did not use schema 2'
grep -Fxq $'DNS_UNIT_LIFECYCLE\t1' "$DNS_BACKUP_DIR/baseline/manifest" || fail 'DNS baseline omitted unit lifecycle metadata'
systemctl is-enabled --quiet systemd-resolved || fail 'DNS apply left systemd-resolved disabled'
systemctl is-active --quiet systemd-resolved || fail 'DNS apply left systemd-resolved inactive'

applied_dns=$(LC_ALL=C resolvectl dns)
assert_not_contains_text "$applied_dns" '192.0.2.53' 'empty DNS= reset did not replace a lower-priority server list'
assert_contains_text "$applied_dns" '1.1.1.1' 'effective DNS list omitted Cloudflare'
assert_contains_text "$applied_dns" '9.9.9.9' 'effective DNS list omitted Quad9'
dns_policy_verify plain

dns_policy_apply native
[[ ! -e "$PROJECT_DROPIN" ]] || fail 'DNS restore left the project drop-in behind'
restored_dns=$(LC_ALL=C resolvectl dns)
assert_contains_text "$restored_dns" '192.0.2.53' 'DNS restore did not reveal the original lower-priority list'
systemctl is-enabled --quiet systemd-resolved || fail 'DNS restore changed the original enabled state'
systemctl is-active --quiet systemd-resolved || fail 'DNS restore changed the original active state'

# Load the authenticated IPv4/IPv6 server syntax into a real resolved instance.
# The actual external lookup remains synthetic, while production parsing still
# has to prove Global DNSOverTLS, SNI, fallback and Domains=~. state.
DNS_BACKUP_DIR="$TEST_ROOT/state-dot/dns"
DNS_QUERY_ENCRYPTED=1
dot_plan=$(dns_policy_plan strict-dot)
assert_contains_text "$dot_plan" 'Requested policy     strict-dot' 'DoT plan did not normalize policy'
dns_policy_apply strict-dot
grep -Fxq '# Policy: strict-dot' "$PROJECT_DROPIN" || fail 'DoT apply omitted canonical policy marker'
grep -Fxq 'DNSOverTLS=yes' "$PROJECT_DROPIN" || fail 'DoT apply omitted DNSOverTLS=yes'
dot_status=$(LC_ALL=C resolvectl status)
assert_contains_text "$dot_status" '+DNSOverTLS' 'real systemd-resolved did not load strict DoT mode'
dns_policy_verify strict-dot
dns_policy_apply native
[[ ! -e "$PROJECT_DROPIN" ]] || fail 'DoT restore left the project drop-in behind'
DNS_QUERY_ENCRYPTED=0

# Force a post-write verification failure and prove the real service/file
# transaction restores the pre-operation state.
DNS_BACKUP_DIR="$TEST_ROOT/state-failure/dns"
DNS_QUERY_SHOULD_FAIL=1
if dns_policy_apply plain >/dev/null 2>&1; then
    fail 'synthetic query failure was incorrectly committed'
fi
[[ ! -e "$PROJECT_DROPIN" ]] || fail 'failed DNS apply left its drop-in behind'
rollback_dns=$(LC_ALL=C resolvectl dns)
assert_contains_text "$rollback_dns" '192.0.2.53' 'failed DNS apply did not restore the prior effective list'
systemctl is-enabled --quiet systemd-resolved || fail 'failed DNS apply did not restore enabled state'
systemctl is-active --quiet systemd-resolved || fail 'failed DNS apply did not restore active state'
DNS_QUERY_SHOULD_FAIL=0

# A real Global search/routing domain must block takeover before baseline or
# project files are created.
cat > "$SPLIT_DROPIN" <<'EOF'
[Resolve]
Domains=corp.example
EOF
systemctl restart systemd-resolved
DNS_BACKUP_DIR="$TEST_ROOT/state-split/dns"
if dns_policy_plan plain >/dev/null 2>&1; then
    fail 'real Global split-DNS/search domain produced a ready policy plan'
fi
if dns_policy_apply plain >/dev/null 2>&1; then
    fail 'real Global split-DNS/search domain was overwritten'
fi
[[ ! -e "$DNS_BACKUP_DIR/baseline" ]] || fail 'split-DNS rejection happened after baseline creation'
[[ ! -e "$PROJECT_DROPIN" ]] || fail 'split-DNS rejection installed a project drop-in'
rm -f -- "$SPLIT_DROPIN"
systemctl restart systemd-resolved

# Exercise exact enabled/active restoration against the real service manager in
# both directions without relying on mocks.
active_snapshot="$TEST_ROOT/active.snapshot"
dns_snapshot_current "$active_snapshot"
printf '2\n' > "$active_snapshot/.snapshot.schema"
systemctl disable --now systemd-resolved >/dev/null 2>&1
dns_restore_snapshot "$active_snapshot"
systemctl is-enabled --quiet systemd-resolved || fail 'active snapshot did not restore enabled state'
systemctl is-active --quiet systemd-resolved || fail 'active snapshot did not restore active state'

inactive_snapshot="$TEST_ROOT/inactive.snapshot"
systemctl disable --now systemd-resolved >/dev/null 2>&1
dns_snapshot_current "$inactive_snapshot"
printf '2\n' > "$inactive_snapshot/.snapshot.schema"
systemctl enable --now systemd-resolved >/dev/null 2>&1
dns_restore_snapshot "$inactive_snapshot"
[[ $(dns_unit_enabled_state) == disabled ]] || fail 'inactive snapshot did not restore disabled state'
[[ $(dns_unit_active_state) == inactive ]] || fail 'inactive snapshot did not restore inactive state'

echo "integration systemd-resolved tests passed"
