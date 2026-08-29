#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced production globals are consumed dynamically
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# Source the modules under test directly: the assembled release artifact is
# intentionally not rebuilt by this focused regression test.
# shellcheck source=../src/00-header.sh
source "$ROOT_DIR/src/00-header.sh"
# shellcheck source=../src/core.sh
source "$ROOT_DIR/src/core.sh"
# shellcheck source=../src/state.sh
source "$ROOT_DIR/src/state.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_no_baseline_or_temp() {
    local state_dir="$1" baseline_dir="$2" temp
    [[ ! -e "$baseline_dir" && ! -L "$baseline_dir" ]] || fail "partial baseline was published: $baseline_dir"
    if [[ -d "$state_dir" ]]; then
        temp=$(find "$state_dir" -mindepth 1 -maxdepth 1 -name '.baseline.*' -print -quit)
        [[ -z "$temp" ]] || fail "partial baseline staging directory was left behind: $temp"
    fi
}

configure_capture_paths() {
    local root="$1"
    STATE_DIR="$root/state"
    BASELINE_DIR="$STATE_DIR/baseline"
    HISTORY_DIR="$STATE_DIR/history"
    LEGACY_BACKUP_DIR="$STATE_DIR/original"
    CONFIG_FILE="$root/live/bbrv3-lite.conf"
    SYSCTL_FILE="$root/live/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/live/99-bbr-ultimate.conf"
    SERVICE_FILE="$root/live/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/live/bbr-optimize-persist.service"
    PERSIST_DIR="$root/live/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
    NIC_POLICY_DIR="$root/live/interfaces.d"
    mkdir -p -- "$root"
}

write_partial_snapshot() {
    printf 'net.core.default_qdisc\tfq\n' > "$1"
}

write_partial_v3_manifest() {
    local directory="$1"
    mkdir -p -- "$directory"
    printf 'SCHEMA\t%s\nFORMAT\t%s\nRESTORE_SCOPE\t%s\nROUTE_DUMPS\t%s\nCOMPLETE\t1\nCREATED_AT\t2026-08-29T00:00:00Z\nCREATED_BY\t8.0.3\nPROVENANCE\tnative\nINTERFACE\teth0\nSYSCTL_SCHEMA\t1\nSYSCTL_KEYS\tnet.core.default_qdisc\n' \
        "$TCP_BASELINE_SCHEMA" "$TCP_BASELINE_FORMAT" "$TCP_BASELINE_NATIVE_SCOPE" \
        "$TCP_BASELINE_ROUTE_DUMPS" > "$directory/manifest"
}

test_schema_csv_discards_partial_provider_output() (
    local output="$TEST_ROOT/schema-csv.out"
    tcp_sysctl_schema_keys() {
        printf 'net.core.default_qdisc\n'
        return 37
    }

    if tcp_sysctl_schema_keys_csv 1 > "$output"; then
        fail 'schema CSV helper accepted a provider that failed after partial output'
    fi
    [[ ! -s "$output" ]] || fail "schema CSV helper exposed partial output: $(<"$output")"
)

test_historical_snapshot_validation_observes_provider_failure() (
    local snapshot="$TEST_ROOT/historical-partial.tsv"
    local provider_parent_subshell=$BASH_SUBSHELL
    write_partial_snapshot "$snapshot"

    # A direct support probe succeeds, while either process substitution or
    # command substitution emits one key and fails. This specifically catches
    # callers that probe once but ignore the status of the provider they parse.
    tcp_sysctl_schema_keys() {
        printf 'net.core.default_qdisc\n'
        (( BASH_SUBSHELL == provider_parent_subshell ))
    }

    if tcp_baseline_sysctl_validate "$snapshot" 1 >/dev/null 2>&1; then
        fail 'historical snapshot validation accepted a partially enumerated schema'
    fi
)

test_managed_provider_failure_reaches_every_consumer() (
    local snapshot="$TEST_ROOT/current-partial.tsv"
    local missing="$TEST_ROOT/current-missing.out" runtime="$TEST_ROOT/runtime.out"
    local sysctl_calls="$TEST_ROOT/sysctl.calls"
    write_partial_snapshot "$snapshot"
    : > "$sysctl_calls"

    tcp_managed_sysctl_keys() {
        printf 'net.core.default_qdisc\n'
        return 37
    }
    sysctl() {
        printf '%s\n' "$*" >> "$sysctl_calls"
        printf 'fq\n'
    }

    if tcp_sysctl_snapshot_missing_current_keys "$snapshot" > "$missing"; then
        fail 'current-key compatibility check accepted a partial managed-key list'
    fi
    [[ ! -s "$missing" ]] || fail "compatibility check exposed a partial result: $(<"$missing")"

    if tcp_baseline_sysctl_validate "$snapshot" current >/dev/null 2>&1; then
        fail 'current snapshot validation accepted a partial managed-key list'
    fi

    if capture_runtime_sysctls > "$runtime" 2>/dev/null; then
        fail 'runtime capture accepted a partial managed-key list'
    fi
    [[ ! -s "$runtime" ]] || fail "runtime capture emitted a partial snapshot: $(<"$runtime")"
    [[ ! -s "$sysctl_calls" ]] || fail "runtime capture read sysctls before key enumeration succeeded: $(<"$sysctl_calls")"
)

test_manifest_validation_observes_csv_helper_failure() (
    local baseline="$TEST_ROOT/partial-manifest"
    write_partial_v3_manifest "$baseline"
    validate_interface_name() { [[ "$1" == eth0 ]]; }
    tcp_sysctl_schema_keys_csv() {
        printf 'net.core.default_qdisc\n'
        return 37
    }

    if tcp_baseline_manifest_validate "$baseline" >/dev/null 2>&1; then
        fail 'manifest validation accepted SYSCTL_KEYS emitted by a failing helper'
    fi
)

test_native_capture_observes_csv_helper_failure_before_staging() (
    local root="$TEST_ROOT/native-csv-failure"
    configure_capture_paths "$root"
    validate_interface_name() { [[ "$1" == eth0 ]]; }
    managed_artifacts_exist() { return 1; }
    tcp_sysctl_schema_keys_csv() {
        printf 'net.core.default_qdisc\n'
        return 37
    }
    qdisc_guard() { fail 'native capture reached qdisc guard after CSV enumeration failed'; }
    ensure_state_layout() { fail 'native capture created state after CSV enumeration failed'; }

    if capture_baseline eth0 adopt-current >/dev/null 2>&1; then
        fail 'native capture accepted a failing SYSCTL_KEYS helper'
    fi
    assert_no_baseline_or_temp "$STATE_DIR" "$BASELINE_DIR"
)

test_legacy_import_observes_csv_helper_failure_before_staging() (
    local root="$TEST_ROOT/legacy-csv-failure"
    configure_capture_paths "$root"
    mkdir -p -- "$LEGACY_BACKUP_DIR" "$PERSIST_DIR"
    printf 'legacy evidence\n' > "$LEGACY_BACKUP_DIR/evidence"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$PERSIST_SCRIPT"
    chmod 0700 "$PERSIST_SCRIPT"
    tcp_sysctl_schema_keys_csv() {
        printf 'net.core.default_qdisc\n'
        return 37
    }
    capture_runtime_sysctls() { fail 'legacy import captured runtime state after CSV enumeration failed'; }

    if import_legacy_baseline eth0 >/dev/null 2>&1; then
        fail 'legacy import accepted a failing SYSCTL_KEYS helper'
    fi
    assert_no_baseline_or_temp "$STATE_DIR" "$BASELINE_DIR"
)

test_native_capture_rejects_runtime_provider_partial_failure() (
    local root="$TEST_ROOT/native-runtime-failure"
    local provider_calls="$root/provider.calls" sysctl_calls="$root/sysctl.calls"
    local count
    configure_capture_paths "$root"
    : > "$provider_calls"
    : > "$sysctl_calls"

    validate_interface_name() { [[ "$1" == eth0 ]]; }
    managed_artifacts_exist() { return 1; }
    qdisc_guard() { :; }
    ensure_state_layout() { mkdir -p -- "$STATE_DIR"; }
    tcp_sysctl_schema_keys() {
        local invocation=0
        [[ ! -s "$provider_calls" ]] || invocation=$(<"$provider_calls")
        (( invocation += 1 ))
        printf '%s\n' "$invocation" > "$provider_calls"
        printf 'net.core.default_qdisc\n'
        (( invocation != 2 ))
    }
    sysctl() {
        printf '%s\n' "$*" >> "$sysctl_calls"
        printf 'fq\n'
    }

    # These mocks make a downstream validator permissive on purpose. The
    # capture stage itself must reject call 2's partial provider output rather
    # than relying on a later validation pass to notice the shrunk key set.
    tc() {
        case "$*" in
            'qdisc show dev eth0') printf 'qdisc fq 8001: root\n' ;;
            'class show dev eth0') : ;;
            *) return 1 ;;
        esac
    }
    ip() {
        case "$*" in
            '-4 route show table all'|'-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
            '-6 route show table all'|'-6 route show default') : ;;
            *) return 1 ;;
        esac
    }
    capture_unit_state() { printf 'not-found\tinactive\n' > "$2"; }
    tcp_baseline_validate() { :; }

    if capture_baseline eth0 adopt-current >/dev/null 2>&1; then
        fail 'native capture published a baseline after runtime key enumeration failed'
    fi
    count=$(<"$provider_calls")
    [[ "$count" == 2 ]] || fail "runtime provider call count was $count instead of 2"
    [[ ! -s "$sysctl_calls" ]] || fail "runtime capture consumed partial keys: $(<"$sysctl_calls")"
    assert_no_baseline_or_temp "$STATE_DIR" "$BASELINE_DIR"
)

test_schema_csv_discards_partial_provider_output
test_historical_snapshot_validation_observes_provider_failure
test_managed_provider_failure_reaches_every_consumer
test_manifest_validation_observes_csv_helper_failure
test_native_capture_observes_csv_helper_failure_before_staging
test_legacy_import_observes_csv_helper_failure_before_staging
test_native_capture_rejects_runtime_provider_partial_failure

echo 'sysctl provider v8.0.3 regression tests: OK'
