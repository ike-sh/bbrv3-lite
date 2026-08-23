#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export BBRV3_DNS_DROPIN="$TEST_ROOT/etc/resolved.conf.d/80-bbrv3-lite.conf"
export BBRV3_RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
export BBRV3_DNS_STUB_RESOLV="$TEST_ROOT/run/systemd/resolve/stub-resolv.conf"
export BBRV3_DNS_FULL_RESOLV="$TEST_ROOT/run/systemd/resolve/resolv.conf"
DNS_BACKUP_DIR="$TEST_ROOT/state/dns"
export SCRIPT_VERSION=7.2.1-test
DNS_TRANSACTION_DIR=""

# shellcheck source=../src/dns.sh
source "$ROOT_DIR/src/dns.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain '$2'"; }
LOG_OUTPUT=""
log() { LOG_OUTPUT+="${1:-} ${2:-}"$'\n'; }
die() { return 1; }
command_exists() { return 0; }
require_root() { :; }
require_host_network_control() { :; }
require_systemd_runtime() { :; }
acquire_lock() { :; }
require_commands() { :; }
ensure_state_layout() { mkdir -p -- "$DNS_BACKUP_DIR"; }
utc_now() { printf '2026-08-23T00:00:00Z\n'; }
remove_tree_within() { rm -rf -- "$1"; }
atomic_install() { APPLIED_CONTENT=$(<"$1"); mkdir -p -- "$(dirname "$2")"; install -m "$3" "$1" "$2"; }

UNIT_ENABLED=enabled
UNIT_ACTIVE=active
UNIT_LOAD=loaded
UNMASK_REVEALS=disabled
SYSTEMCTL_FAIL_COMMAND=""
SYSTEMCTL_QUERY_FAIL=""
DOMAIN_BEFORE='Global:'
DOMAIN_AFTER='Global: ~.'
DOMAIN_FAIL=0
STATUS_FAIL=0
QUERY_FAIL=0
APPLIED_CONTENT=""
EVENTS=""
QUERY_OUTPUT='Data was acquired via local or encrypted transport: yes'
QUERY_LOG="$TEST_ROOT/query.log"
STATUS_OUTPUT='__AUTO__'
DNS_OUTPUT=""

systemctl() {
    local command="$1" runtime=0
    shift
    if [[ "$command" == "$SYSTEMCTL_QUERY_FAIL" ]]; then return 1; fi
    if [[ "$command" == "$SYSTEMCTL_FAIL_COMMAND" ]]; then EVENTS+=" fail-$command"; return 1; fi
    case "$command" in
        is-enabled) printf '%s\n' "$UNIT_ENABLED"; [[ "$UNIT_ENABLED" != disabled ]] ;;
        is-active) printf '%s\n' "$UNIT_ACTIVE"; [[ "$UNIT_ACTIVE" == active ]] ;;
        show) printf '%s\n' "$UNIT_LOAD" ;;
        cat) return 0 ;;
        enable)
            [[ "${1:-}" == --runtime ]] && { runtime=1; shift; }
            if (( runtime )); then UNIT_ENABLED='enabled-runtime'; else UNIT_ENABLED='enabled'; fi
            EVENTS+=" enable"
            ;;
        disable) UNIT_ENABLED=disabled; EVENTS+=" disable" ;;
        unmask)
            [[ "$UNIT_ENABLED" == masked* ]] && UNIT_ENABLED="$UNMASK_REVEALS"
            EVENTS+=" unmask"
            ;;
        mask)
            [[ "${1:-}" == --runtime ]] && UNIT_ENABLED=masked-runtime || UNIT_ENABLED=masked
            EVENTS+=" mask"
            ;;
        restart) UNIT_ACTIVE=active; EVENTS+=" restart" ;;
        stop) UNIT_ACTIVE=inactive; EVENTS+=" stop" ;;
        daemon-reload) EVENTS+=" reload" ;;
        *) return 0 ;;
    esac
}

resolvectl() {
    local command="$1"
    shift
    case "$command" in
        domain)
            (( DOMAIN_FAIL == 0 )) || return 1
            if [[ -f "$DNS_DROPIN" ]]; then printf '%s\n' "$DOMAIN_AFTER"; else printf '%s\n' "$DOMAIN_BEFORE"; fi
            ;;
        status)
            (( STATUS_FAIL == 0 )) || return 1
            if [[ "$STATUS_OUTPUT" != __AUTO__ ]]; then
                printf '%s\n' "$STATUS_OUTPUT"
            elif grep -Fxq 'DNSOverTLS=yes' "$DNS_DROPIN" 2>/dev/null; then
                printf '%s\n' $'Global\n       Protocols: -LLMNR -mDNS +DNSOverTLS DNSSEC=allow-downgrade\n       DNS Servers 1.1.1.1#cloudflare-dns.com [2606:4700:4700::1111]:53#cloudflare-dns.com\n                   9.9.9.9#dns.quad9.net [2620:fe::fe]:53#dns.quad9.net\nFallback DNS Servers 8.8.8.8#dns.google\n                     [2001:4860:4860::8888]:53#dns.google\n        DNS Domain ~.\nLink 2 (eth0)\n       Protocols: -DNSOverTLS'
            elif grep -Fxq 'DNSOverTLS=no' "$DNS_DROPIN" 2>/dev/null; then
                printf '%s\n' $'Global\n       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=allow-downgrade\n       DNS Servers 1.1.1.1 [2606:4700:4700::1111]:53\n                   9.9.9.9 [2620:fe::fe]:53\nFallback DNS Servers 8.8.8.8\n                     [2001:4860:4860::8888]:53\n        DNS Domain ~.\nLink 2 (eth0)\n       Protocols: -DNSOverTLS'
            else
                printf '%s\n' $'Global\n       Protocols: -LLMNR -mDNS -DNSOverTLS\nLink 2 (eth0)'
            fi
            ;;
        dns)
            if [[ -n "$DNS_OUTPUT" ]]; then
                printf '%s\n' "$DNS_OUTPUT"
            elif grep -Fxq 'DNSOverTLS=yes' "$DNS_DROPIN" 2>/dev/null; then
                printf '%s\n' 'Global: 1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net'
            else
                printf '%s\n' 'Global: 1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe'
            fi
            ;;
        flush-caches) return 0 ;;
        query)
            printf '%s\n' "${1:-unknown}" >> "$QUERY_LOG"
            (( QUERY_FAIL == 0 )) || return 1
            printf '%s\n' "$QUERY_OUTPUT"
            ;;
        *) return 1 ;;
    esac
}

reset_case() {
    rm -rf -- "${TEST_ROOT:?}/etc" "$TEST_ROOT/run" "$TEST_ROOT/state"
    mkdir -p -- "$(dirname "$DNS_DROPIN")" "$(dirname "$DNS_RESOLV_CONF")" "$(dirname "$DNS_STUB_RESOLV")"
    printf 'nameserver 127.0.0.53\n' > "$DNS_STUB_RESOLV"
    printf 'nameserver 127.0.0.53\n' > "$DNS_FULL_RESOLV"
    : > "$QUERY_LOG"
    DNS_TRANSACTION_DIR=""
    UNIT_ENABLED=enabled
    UNIT_ACTIVE=active
    UNIT_LOAD=loaded
    UNMASK_REVEALS=disabled
    SYSTEMCTL_FAIL_COMMAND=""
    SYSTEMCTL_QUERY_FAIL=""
    DOMAIN_BEFORE='Global:'
    DOMAIN_AFTER='Global: ~.'
    DOMAIN_FAIL=0
    STATUS_FAIL=0
    QUERY_FAIL=0
    QUERY_OUTPUT='Data was acquired via local or encrypted transport: yes'
    STATUS_OUTPUT='__AUTO__'
    DNS_OUTPUT=""
    APPLIED_CONTENT=""
    EVENTS=""
    LOG_OUTPUT=""
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
}

write_manifest() {
    local directory="$1"
    printf 'CREATED_AT\t2026-08-23T00:00:00Z\nCREATED_BY\t7.2.0\n' > "$directory/manifest"
}

create_legacy_baseline() {
    local active="${1:-active}" base="$DNS_BACKUP_DIR/baseline"
    mkdir -p -- "$base"
    write_manifest "$base"
    if [[ -e "$DNS_RESOLV_CONF" || -L "$DNS_RESOLV_CONF" ]]; then
        cp -a -- "$DNS_RESOLV_CONF" "$base/resolv.conf"
        printf 'present\n' > "$base/resolv.state"
    else
        printf 'absent\n' > "$base/resolv.state"
    fi
    if [[ -e "$DNS_DROPIN" || -L "$DNS_DROPIN" ]]; then
        cp -a -- "$DNS_DROPIN" "$base/dropin.conf"
        printf 'present\n' > "$base/dropin.state"
    else
        printf 'absent\n' > "$base/dropin.state"
    fi
    printf '%s\n' "$active" > "$base/service.active"
}

create_project_plain_dropin() {
    cat > "$DNS_DROPIN" <<'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=8.8.8.8
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
}

create_unit_snapshot() {
    local directory="$1" enabled="$2" active="$3" load="${4:-loaded}"
    mkdir -p -- "$directory"
    printf 'absent\n' > "$directory/resolv.state"
    printf 'absent\n' > "$directory/dropin.state"
    printf '%s\t%s\t%s\n' "$enabled" "$active" "$load" > "$directory/service.unit"
    printf '%s\n' "$active" > "$directory/service.active"
}

test_unmanaged_regular_files_are_rejected() {
    reset_case
    printf 'nameserver 192.0.2.53\n' > "$DNS_RESOLV_CONF"
    if dns_apply plain >/dev/null 2>&1; then fail 'unmanaged regular resolv.conf was accepted'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'ownership refusal changed the drop-in'

    reset_case
    printf '# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).\nnameserver 127.0.0.53\n' > "$DNS_RESOLV_CONF"
    if dns_apply plain >/dev/null 2>&1; then fail 'copied resolved stub was treated as an owned symlink'; fi
}

test_resolved_symlink_requires_exact_target() {
    reset_case
    local fake="$TEST_ROOT/fake/run/systemd/resolve/stub-resolv.conf"
    mkdir -p -- "$(dirname "$fake")"
    printf 'nameserver 127.0.0.53\n' > "$fake"
    ln -s "$fake" "$DNS_RESOLV_CONF"
    if dns_apply dot >/dev/null 2>&1; then fail 'lookalike systemd-resolved symlink was accepted'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'lookalike symlink refusal changed the drop-in'
}

test_split_dns_domain_and_status_are_rejected() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_BEFORE='Link 2 (eth0): ~corp.example'
    if dns_apply dot >/dev/null 2>&1; then fail 'per-link split DNS was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_BEFORE='Global: corp.example'
    if dns_apply dot >/dev/null 2>&1; then fail 'ordinary Global search domain was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_FAIL=1
    STATUS_OUTPUT=$'Global\n       DNS Domain: corp.example\nLink 2 (eth0)'
    if dns_apply dot >/dev/null 2>&1; then fail 'status fallback missed a Global search domain'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_FAIL=1
    STATUS_OUTPUT=$'Global\n       DNS Domain corp.example\nLink 2 (eth0)'
    if dns_apply dot >/dev/null 2>&1; then fail 'no-colon status fixture missed a Global search domain'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    create_project_plain_dropin
    DOMAIN_FAIL=1
    STATUS_OUTPUT=$'Global\n       DNS Domain: ~.\n                   corp.example\nLink 2 (eth0)'
    if dns_apply plain >/dev/null 2>&1; then fail 'status fallback missed a wrapped Global search domain'; fi
}

test_other_owner_wins_over_project_artifacts() {
    reset_case
    printf '# Generated by NetworkManager\nnameserver 192.0.2.53\n' > "$DNS_RESOLV_CONF"
    create_legacy_baseline active
    create_project_plain_dropin
    if dns_apply plain >/dev/null 2>&1; then fail 'NetworkManager ownership was hidden by project artifacts'; fi
    assert_contains "$DNS_RESOLV_CONF" '# Generated by NetworkManager'
}

test_regular_file_is_never_taken_over() {
    reset_case
    printf 'nameserver 192.0.2.53\n' > "$DNS_RESOLV_CONF"
    create_project_plain_dropin
    if dns_apply plain >/dev/null 2>&1; then fail 'drop-in signature without baseline proved ownership'; fi

    reset_case
    printf 'nameserver 192.0.2.53\n' > "$DNS_RESOLV_CONF"
    create_legacy_baseline active
    create_project_plain_dropin
    if dns_apply plain >/dev/null 2>&1; then fail 'baseline and signed drop-in authorized takeover of a regular file'; fi
    assert_eq 'nameserver 192.0.2.53' "$(<"$DNS_RESOLV_CONF")" 'regular file was modified'
}

test_v2_snapshot_requires_exact_unit_metadata() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_capture_baseline || fail 'could not create v2 baseline for corruption test'
    rm -f -- "$DNS_BACKUP_DIR/baseline/service.unit"
    if dns_validate_snapshot "$DNS_BACKUP_DIR/baseline" 1; then fail 'v2 baseline missing service.unit was accepted as legacy'; fi
    if dns_apply plain >/dev/null 2>&1; then fail 'corrupt v2 baseline was accepted by apply'; fi

    reset_case
    local snapshot="$TEST_ROOT/multiline-unit"
    create_unit_snapshot "$snapshot" enabled active
    printf 'disabled\tinactive\tloaded\n' >> "$snapshot/service.unit"
    if dns_validate_snapshot "$snapshot" 0; then fail 'multiline service.unit was accepted'; fi
}

test_manifest_rejects_duplicates_and_unknown_fields() {
    local base

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_capture_baseline || fail 'could not create DNS baseline for manifest tests'
    base="$DNS_BACKUP_DIR/baseline"
    printf 'CREATED_AT\t2026-08-23T00:00:01Z\n' >> "$base/manifest"
    if dns_validate_snapshot "$base" 1; then fail 'duplicate CREATED_AT was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_capture_baseline || fail 'could not recreate DNS baseline for unknown-field test'
    base="$DNS_BACKUP_DIR/baseline"
    printf 'UNTRUSTED_FIELD\t1\n' >> "$base/manifest"
    if dns_validate_snapshot "$base" 1; then fail 'unknown DNS manifest field was accepted'; fi
    if dns_restore >/dev/null 2>&1; then fail 'restore accepted an unknown DNS manifest field'; fi
}

test_nonpersistent_unit_is_rejected() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=static
    if dns_apply dot >/dev/null 2>&1; then fail 'static resolved unit was accepted as reboot-persistent'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'static-unit refusal changed the drop-in'
}

test_unit_state_queries_fail_closed() {
    local query
    for query in is-enabled is-active show; do
        reset_case
        ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
        SYSTEMCTL_QUERY_FAIL="$query"
        if dns_snapshot_current "$TEST_ROOT/snapshot-$query" >/dev/null 2>&1; then
            fail "$query failure was accepted by DNS snapshot"
        fi
    done
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=unknown
    if dns_snapshot_current "$TEST_ROOT/snapshot-unknown" >/dev/null 2>&1; then fail 'unknown unit state was captured'; fi
}

test_legacy_baseline_blocks_lifecycle_changes() {
    local state
    for state in disabled enabled-runtime; do
        reset_case
        ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
        create_legacy_baseline active
        UNIT_ENABLED="$state"
        UNIT_ACTIVE=active
        if dns_apply plain >/dev/null 2>&1; then fail "legacy baseline allowed lifecycle change from $state"; fi
        [[ "$EVENTS" != *' enable'* ]] || fail "legacy baseline changed unit state from $state"
        [[ ! -e "$DNS_DROPIN" ]] || fail 'legacy lifecycle refusal changed the drop-in'
    done

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    create_legacy_baseline active
    dns_apply plain >/dev/null 2>&1 || fail 'legacy baseline with no lifecycle change was rejected'
}

test_corrupt_baseline_is_never_overwritten() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    mkdir -p -- "$DNS_BACKUP_DIR/baseline"
    write_manifest "$DNS_BACKUP_DIR/baseline"
    printf 'keep-me\n' > "$DNS_BACKUP_DIR/baseline/corrupt-marker"
    if dns_apply plain >/dev/null 2>&1; then fail 'corrupt baseline was accepted'; fi
    assert_eq keep-me "$(<"$DNS_BACKUP_DIR/baseline/corrupt-marker")" 'corrupt baseline was overwritten'
}

test_inactive_resolver_without_domain_inspection_fails_closed() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=disabled
    UNIT_ACTIVE=inactive
    DOMAIN_FAIL=1
    STATUS_FAIL=1
    if dns_apply plain >/dev/null 2>&1; then fail 'inactive unresolved routing domains were accepted'; fi
    [[ ! -e "$DNS_BACKUP_DIR/baseline" && ! -e "$DNS_DROPIN" ]] || fail 'failed preflight modified DNS state'
    [[ "$EVENTS" != *' enable'* ]] || fail 'failed preflight enabled resolved'

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=disabled
    UNIT_ACTIVE=inactive
    DOMAIN_BEFORE='Global:'
    if dns_apply plain >/dev/null 2>&1; then fail 'inactive resolved was accepted when domains were parseable'; fi
    [[ ! -e "$DNS_BACKUP_DIR/baseline" && ! -e "$DNS_DROPIN" ]] || fail 'inactive preflight created files or a baseline'
    assert_eq '' "$EVENTS" 'inactive preflight changed the unit lifecycle'
    assert_eq "$DNS_STUB_RESOLV" "$(readlink "$DNS_RESOLV_CONF")" 'inactive preflight changed resolv.conf'
}

test_unknown_and_unowned_global_domains_fail_closed() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_BEFORE=''
    STATUS_FAIL=1
    if dns_apply plain >/dev/null 2>&1; then fail 'empty domain output was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_BEFORE='unexpected resolver output'
    STATUS_FAIL=1
    if dns_apply plain >/dev/null 2>&1; then fail 'unknown non-empty domain output was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_BEFORE='Global: ~.'
    if dns_apply plain >/dev/null 2>&1; then fail 'unowned Global ~. was accepted'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    cat > "$DNS_DROPIN" <<'EOF'
[Resolve]
DNS=192.0.2.53 1.1.1.1
FallbackDNS=8.8.8.8
Domains=~.
DNSOverTLS=no
DNSSEC=allow-downgrade
EOF
    DOMAIN_BEFORE='Global: ~.'
    if dns_apply plain >/dev/null 2>&1; then fail 'drop-in path with a forged signature authorized Global ~.'; fi

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DOMAIN_FAIL=1
    STATUS_OUTPUT='unrecognized status output'
    if dns_apply plain >/dev/null 2>&1; then fail 'status output without Global section was accepted'; fi
}

test_auto_dot_failure_rolls_back_without_plain_fallback() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    UNIT_ENABLED=disabled
    UNIT_ACTIVE=active
    QUERY_FAIL=1
    if dns_apply auto >/dev/null 2>&1; then fail 'failed DoT auto mode reported success'; fi
    assert_contains "$DNS_BACKUP_DIR/baseline/service.unit" $'disabled\tactive\tloaded'
    assert_eq disabled "$UNIT_ENABLED" 'rollback did not restore disabled unit state'
    assert_eq active "$UNIT_ACTIVE" 'rollback did not restore active unit state'
    [[ ! -e "$DNS_DROPIN" ]] || fail 'failed DoT left its drop-in installed'
    [[ "$APPLIED_CONTENT" == *'DNSOverTLS=yes'* ]] || fail 'auto mode did not try strict DoT'
    [[ "$APPLIED_CONTENT" != *'DNSOverTLS=no'* ]] || fail 'auto mode silently fell back to plain DNS'
    assert_eq '' "$DNS_TRANSACTION_DIR" 'failed DoT left a transaction behind'
}

test_legacy_uninspectable_routing_cannot_commit() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    create_legacy_baseline active
    create_project_plain_dropin
    DOMAIN_FAIL=1
    STATUS_FAIL=1
    if dns_apply plain >/dev/null 2>&1; then fail 'uninspectable legacy routing domains were committed'; fi
    assert_contains "$DNS_DROPIN" 'DNSOverTLS=no'
    assert_eq "$DNS_STUB_RESOLV" "$(readlink "$DNS_RESOLV_CONF")" 'legacy routing failure did not rollback resolv.conf'
}

test_dot_verification_uses_only_global_and_encrypted_evidence() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    STATUS_OUTPUT=$'Global\n       Protocols: -DNSOverTLS\n       DNS Servers: 192.0.2.53\n        DNS Domain: corp.example\nLink 2 (eth0)\n       Protocols: +DNSOverTLS\n       DNS Servers: 1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net\nFallback DNS Servers: 8.8.8.8#dns.google\n        DNS Domain: ~.'
    if dns_apply dot >/dev/null 2>&1; then fail 'Link-level DoT was mistaken for Global DoT'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'false Global verification did not rollback'

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    QUERY_OUTPUT='Data was acquired via local or encrypted transport: no'
    if dns_apply dot >/dev/null 2>&1; then fail 'DoT query without encrypted evidence was accepted'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'unencrypted query evidence did not rollback'

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DNS_OUTPUT='Global: 1.1.1.1#cloudflare-dns.com 192.0.2.53#attacker.example'
    if dns_apply dot >/dev/null 2>&1; then fail 'unexpected effective Global server was accepted'; fi
}

test_dot_success_commits_complete_dual_stack_policy() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_apply dot >/dev/null 2>&1 || fail 'verified DoT application failed'
    assert_contains "$DNS_DROPIN" 'DNSOverTLS=yes'
    grep -Fxq 'DNS=' "$DNS_DROPIN" || fail 'DoT policy did not reset DNS list'
    grep -Fxq 'FallbackDNS=' "$DNS_DROPIN" || fail 'DoT policy did not reset fallback list'
    grep -Fxq 'Domains=' "$DNS_DROPIN" || fail 'DoT policy did not reset domain list'
    assert_contains "$DNS_DROPIN" '2606:4700:4700::1111#cloudflare-dns.com'
    assert_contains "$DNS_DROPIN" '2620:fe::fe#dns.quad9.net'
    assert_contains "$DNS_DROPIN" '2001:4860:4860::8888#dns.google'
    assert_eq 2 "$(wc -l < "$QUERY_LOG" | tr -d ' ')" 'DoT did not verify two queries'
    assert_eq "$DNS_STUB_RESOLV" "$(readlink "$DNS_RESOLV_CONF")" 'DoT did not select the resolved stub'
    assert_eq '' "$DNS_TRANSACTION_DIR" 'successful DoT left a transaction behind'
}

test_plain_effective_servers_are_strictly_verified() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DNS_OUTPUT='Global: 1.1.1.1 9.9.9.9 192.0.2.53'
    if dns_apply plain >/dev/null 2>&1; then fail 'plain mode accepted an inherited effective DNS server'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'plain effective-server failure did not rollback'

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    STATUS_OUTPUT=$'Global\n       Protocols: -DNSOverTLS\n       DNS Servers: 1.1.1.1 9.9.9.9\nFallback DNS Servers: 8.8.8.8 192.0.2.53\n        DNS Domain: ~.\nLink 2 (eth0)'
    if dns_apply plain >/dev/null 2>&1; then fail 'plain mode accepted an inherited fallback DNS server'; fi
    [[ ! -e "$DNS_DROPIN" ]] || fail 'plain fallback-server failure did not rollback'
}

test_restore_operation_failures_are_never_reported_success() {
    local snapshot="$TEST_ROOT/restore-snapshot"

    reset_case
    create_unit_snapshot "$snapshot" enabled inactive
    UNIT_ENABLED=disabled; UNIT_ACTIVE=inactive; SYSTEMCTL_FAIL_COMMAND=enable
    if dns_restore_snapshot "$snapshot" >/dev/null 2>&1; then fail 'enable failure reported restore success'; fi

    reset_case
    create_unit_snapshot "$snapshot" enabled inactive
    UNIT_ENABLED=masked; UNIT_ACTIVE=inactive; SYSTEMCTL_FAIL_COMMAND=unmask
    if dns_restore_snapshot "$snapshot" >/dev/null 2>&1; then fail 'unmask failure reported restore success'; fi

    reset_case
    create_unit_snapshot "$snapshot" enabled-runtime inactive
    UNIT_ENABLED=enabled; UNIT_ACTIVE=inactive; SYSTEMCTL_FAIL_COMMAND=disable
    if dns_restore_snapshot "$snapshot" >/dev/null 2>&1; then fail 'disable failure reported restore success'; fi

    reset_case
    create_unit_snapshot "$snapshot" masked inactive masked
    UNIT_ENABLED=enabled; UNIT_ACTIVE=active; SYSTEMCTL_FAIL_COMMAND=mask
    if dns_restore_snapshot "$snapshot" >/dev/null 2>&1; then fail 'mask failure reported restore success'; fi

    reset_case
    create_unit_snapshot "$snapshot" disabled inactive
    UNIT_ENABLED=disabled; UNIT_ACTIVE=inactive; SYSTEMCTL_FAIL_COMMAND=stop
    if dns_restore_snapshot "$snapshot" >/dev/null 2>&1; then fail 'stop failure reported restore success despite matching postcondition'; fi
}

test_masked_lifecycle_restore_and_postcondition() {
    reset_case
    local snapshot="$TEST_ROOT/masked-snapshot"
    create_unit_snapshot "$snapshot" masked inactive masked
    UNIT_ENABLED=enabled
    UNIT_ACTIVE=active
    dns_restore_snapshot "$snapshot" >/dev/null 2>&1 || fail 'masked lifecycle restore failed'
    assert_eq masked "$UNIT_ENABLED" 'masked unit-file state was not restored'
    assert_eq inactive "$UNIT_ACTIVE" 'masked unit was not stopped'

    reset_case
    snapshot="$TEST_ROOT/masked-active-snapshot"
    create_unit_snapshot "$snapshot" masked active masked
    UNIT_ENABLED=enabled
    UNIT_ACTIVE=inactive
    dns_restore_snapshot "$snapshot" >/dev/null 2>&1 || fail 'masked+active lifecycle restore failed'
    assert_eq masked "$UNIT_ENABLED" 'masked+active unit-file state was not restored'
    assert_eq active "$UNIT_ACTIVE" 'masked+active service state was not restored'
    [[ "$EVENTS" == *' restart'* && "$EVENTS" == *' mask'* ]] || fail 'masked+active restore did not start before masking'
}

test_transaction_schema_prevents_lifecycle_downgrade() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_transaction_begin || fail 'could not create strict DNS transaction'
    rm -f -- "$DNS_TRANSACTION_DIR/service.unit"
    if dns_transaction_rollback >/dev/null 2>&1; then fail 'transaction missing service.unit rolled back as legacy'; fi
    [[ -n "$DNS_TRANSACTION_DIR" && -e "$DNS_TRANSACTION_DIR/.snapshot.schema" ]] || fail 'corrupt transaction was not retained'
}

test_pending_transaction_blocks_new_work_and_is_visible() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    mkdir -p -- "$DNS_BACKUP_DIR"
    dns_snapshot_current "$DNS_BACKUP_DIR/.transaction.crash"
    if dns_apply plain >/dev/null 2>&1; then fail 'pending transaction allowed a new DNS operation'; fi
    local output
    output=$(dns_status)
    [[ "$output" == *'Pending transaction: valid:'* ]] || fail 'status did not report pending transaction'
}

test_restore_requires_host_network_and_systemd() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_capture_baseline
    require_host_network_control() { return 1; }
    if dns_restore >/dev/null 2>&1; then fail 'restore bypassed host-network guard'; fi
    assert_eq "$DNS_STUB_RESOLV" "$(readlink "$DNS_RESOLV_CONF")" 'guarded restore modified resolv.conf'

    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    dns_capture_baseline
    require_systemd_runtime() { return 1; }
    if dns_restore >/dev/null 2>&1; then fail 'restore bypassed systemd-runtime guard'; fi
    assert_eq "$DNS_STUB_RESOLV" "$(readlink "$DNS_RESOLV_CONF")" 'systemd-guarded restore modified resolv.conf'
}

test_legacy_restore_warns_about_lifecycle_limit() {
    reset_case
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    create_legacy_baseline active
    dns_restore >/dev/null 2>&1 || fail 'legacy DNS restore failed'
    [[ "$LOG_OUTPUT" == *'旧基线未记录 unit-file 生命周期'* ]] || fail 'legacy restore did not warn about lifecycle limitation'
}

test_unmanaged_regular_files_are_rejected
test_resolved_symlink_requires_exact_target
test_split_dns_domain_and_status_are_rejected
test_other_owner_wins_over_project_artifacts
test_regular_file_is_never_taken_over
test_v2_snapshot_requires_exact_unit_metadata
test_manifest_rejects_duplicates_and_unknown_fields
test_nonpersistent_unit_is_rejected
test_unit_state_queries_fail_closed
test_legacy_baseline_blocks_lifecycle_changes
test_corrupt_baseline_is_never_overwritten
test_inactive_resolver_without_domain_inspection_fails_closed
test_unknown_and_unowned_global_domains_fail_closed
test_auto_dot_failure_rolls_back_without_plain_fallback
test_legacy_uninspectable_routing_cannot_commit
test_dot_verification_uses_only_global_and_encrypted_evidence
test_dot_success_commits_complete_dual_stack_policy
test_plain_effective_servers_are_strictly_verified
test_restore_operation_failures_are_never_reported_success
test_masked_lifecycle_restore_and_postcondition
test_transaction_schema_prevents_lifecycle_downgrade
test_pending_transaction_blocks_new_work_and_is_visible
test_restore_requires_host_network_and_systemd
test_legacy_restore_warns_about_lifecycle_limit
printf 'dns v7.2.1 tests passed\n'
