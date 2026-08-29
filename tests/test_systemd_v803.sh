#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are consumed by sourced production functions
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

fixture_sysctl_value() {
    case "$1" in
        net.core.default_qdisc) printf 'fq\n' ;;
        net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
        net.core.rmem_max|net.core.wmem_max) printf '16777216\n' ;;
        net.ipv4.tcp_rmem) printf '4096 131072 16777216\n' ;;
        net.ipv4.tcp_wmem) printf '4096 16384 16777216\n' ;;
        net.ipv4.tcp_mtu_probing) printf '0\n' ;;
        net.ipv4.tcp_fastopen) printf '1\n' ;;
        net.core.somaxconn|net.ipv4.tcp_max_syn_backlog) printf '4096\n' ;;
        net.core.netdev_max_backlog) printf '1000\n' ;;
        *) return 1 ;;
    esac
}

install_missing_unit_transaction_fixture() {
    local root="$1"
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/etc/legacy.conf"; SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/systemd/legacy.service"; PERSIST_DIR="$root/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; NIC_POLICY_DIR="$root/etc/interfaces.d"
    LEGACY_BACKUP_DIR="$root/legacy-backup"
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
    ACTION_TRANSACTION_READY=0; ACTION_TRANSACTION_MUTATED=0; ACTION_TRANSACTION_ROLLING_BACK=0
    ACTION_TRANSACTION_ROLLBACK_FAILED=0
    MULTI_NIC_ENABLED=0; TC_INTERFACE=auto
    sysctl() { [[ "$1" == -n ]] || return 1; fixture_sysctl_value "$2"; }
    tc() {
        case "$*" in
            'qdisc show dev eth0') printf 'qdisc fq 8001: root limit 10000p flow_limit 100p\n' ;;
            'class show dev eth0') : ;;
            'filter show dev eth0 parent 8001:') : ;;
            *) return 1 ;;
        esac
    }
    ip() {
        case "$*" in
            '-4 route show default'|'-4 route show table all') printf 'default via 192.0.2.1 dev eth0\n' ;;
            '-6 route show default'|'-6 route show table all') : ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        case "$1" in
            show) printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' ;;
            is-enabled|is-active) fail "missing-unit fixture called legacy query: $*" ;;
            *) : ;;
        esac
    }
}

test_missing_unit_uses_load_state_without_is_enabled() {
    local state_file="$TEST_ROOT/missing.unit" is_enabled_calls=0
    systemctl() {
        case "$1" in
            show)
                printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive'
                ;;
            is-enabled)
                ((is_enabled_calls+=1))
                printf '%s\n' 'Failed to get unit file state for bbrv3-lite.service: No such file or directory' >&2
                return 1
                ;;
            *) fail "unexpected systemctl call: $*" ;;
        esac
    }

    capture_unit_state bbrv3-lite.service "$state_file"
    assert_eq $'not-found\tinactive' "$(<"$state_file")" 'missing unit snapshot'
    assert_eq 0 "$is_enabled_calls" 'missing unit is-enabled calls'
}

test_machine_readable_unit_states_and_manager_failure() (
    local load=loaded enabled=enabled active=active state_file="$TEST_ROOT/state.unit" mode=normal
    systemctl() {
        [[ "$1" == show ]] || fail "state parser called non-show command: $*"
        [[ "$mode" == normal ]] || { printf 'Failed to connect to bus: Host is down\n' >&2; return 1; }
        printf 'LoadState=%s\nUnitFileState=%s\nActiveState=%s\n' "$load" "$enabled" "$active"
    }
    for enabled in enabled disabled static; do
        capture_unit_state example.service "$state_file"
        assert_eq "$enabled" "${enabled}" 'fixture state'
        assert_eq "$enabled" "$(cut -f1 "$state_file")" "$enabled unit-file state"
        assert_eq active "$(cut -f2 "$state_file")" "$enabled active state"
    done
    load=masked; enabled=masked; active=inactive
    capture_unit_state example.service "$state_file"
    assert_eq $'masked\tinactive' "$(<"$state_file")" 'masked unit state'

    mode=manager-failure
    rm -f -- "$state_file"
    if capture_unit_state example.service "$state_file" >/dev/null 2>&1; then
        fail 'systemd manager failure was captured as a valid state'
    fi
    [[ ! -e "$state_file" ]] || fail 'manager failure wrote a unit snapshot'
)

test_query_unit_state_parser_is_strict_and_order_independent() (
    local payload state active state_file="$TEST_ROOT/impossible.unit"
    systemctl() {
        [[ "$1" == show ]] || fail "parser called a non-show command: $*"
        printf '%s\n' "$payload"
    }

    payload=$'ActiveState=active\nUnitFileState=enabled\nLoadState=loaded'
    state=$(query_unit_state example.service) || fail 'field reordering was rejected'
    assert_eq $'enabled\tactive' "$state" 'reordered machine fields'

    payload=$'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nLoadState=loaded'
    if query_unit_state example.service >/dev/null 2>&1; then fail 'duplicate field was accepted'; fi
    payload=$'LoadState=loaded\nUnitFileState=enabled'
    if query_unit_state example.service >/dev/null 2>&1; then fail 'missing field was accepted'; fi
    payload=$'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nDescription=unexpected'
    if query_unit_state example.service >/dev/null 2>&1; then fail 'unknown field was accepted'; fi

    payload=$'UnitFileState=this-token-is-not-trusted\nActiveState=inactive\nLoadState=not-found'
    state=$(query_unit_state missing.service) || fail 'missing unit required a trusted UnitFileState'
    assert_eq $'not-found\tinactive' "$state" 'missing-unit normalization'
    payload=$'LoadState=not-found\nUnitFileState=enabled\nActiveState=active'
    if query_unit_state missing.service >/dev/null 2>&1; then fail 'not-found/active pair was accepted'; fi

    for active in activating deactivating failed reloading maintenance; do
        payload=$'LoadState=loaded\nUnitFileState=disabled\nActiveState='"$active"
        if query_unit_state example.service >/dev/null 2>&1; then
            fail "non-restorable transient/failed ActiveState was accepted: $active"
        fi
    done

    printf 'not-found\tactive\n' > "$state_file"
    if unit_state_snapshot_validate "$state_file"; then
        fail 'impossible not-found/active transaction snapshot was accepted'
    fi
)

test_current_and_legacy_missing_combinations() (
    local current_load=loaded legacy_load=not-found state
    systemctl() {
        local unit="$2" load enabled active
        if [[ "$unit" == "$SERVICE_NAME" ]]; then load="$current_load"; else load="$legacy_load"; fi
        if [[ "$load" == not-found ]]; then enabled=""; active=inactive
        else enabled=disabled; active=inactive
        fi
        printf 'LoadState=%s\nUnitFileState=%s\nActiveState=%s\n' "$load" "$enabled" "$active"
    }
    state=$(query_unit_state "$SERVICE_NAME"); assert_eq $'disabled\tinactive' "$state" 'current present/legacy missing current state'
    state=$(query_unit_state bbr-optimize-persist.service); assert_eq $'not-found\tinactive' "$state" 'current present/legacy missing legacy state'
    current_load=not-found; legacy_load=loaded
    state=$(query_unit_state "$SERVICE_NAME"); assert_eq $'not-found\tinactive' "$state" 'current missing/legacy present current state'
    state=$(query_unit_state bbr-optimize-persist.service); assert_eq $'disabled\tinactive' "$state" 'current missing/legacy present legacy state'
)

test_missing_unit_quiesce_cleans_and_verifies_dangling_enable_link() (
    local root="$TEST_ROOT/quiesce-missing" enable_link="$TEST_ROOT/quiesce-missing/multi-user.target.wants/example.service"
    local mode=pure-missing disable_calls=0 last_disable=""
    SERVICE_NAME=example.service; SERVICE_FILE="$root/example.service"
    LEGACY_SERVICE_FILE="$root/bbr-optimize-persist.service"
    mkdir -p -- "$(dirname "$enable_link")"
    assert_eq "$enable_link" "$(action_transaction_unit_enable_link_path "$SERVICE_NAME")" 'managed enable-link path'
    if action_transaction_unit_enable_link_path unrelated.service >/dev/null 2>&1; then
        fail 'non-project unit was accepted by the managed enable-link resolver'
    fi
    systemctl() {
        case "$1" in
            show) printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' ;;
            disable)
                ((disable_calls+=1)); last_disable="$*"
                case "$mode" in
                    clean) rm -f -- "$enable_link" ;;
                    command-failure) return 9 ;;
                    false-success) : ;;
                    *) fail "pure missing unexpectedly called disable: $*" ;;
                esac
                ;;
            is-enabled|is-active) fail "missing quiesce called legacy query: $*" ;;
            *) fail "unexpected missing quiesce systemctl call: $*" ;;
        esac
    }

    action_transaction_quiesce_unit_for_restore "$SERVICE_NAME"
    assert_eq 0 "$disable_calls" 'pure missing disable calls'

    ln -s "$root/missing-unit-file" "$enable_link"
    mode=clean
    action_transaction_quiesce_unit_for_restore "$SERVICE_NAME"
    assert_eq 1 "$disable_calls" 'dangling enable-link cleanup calls'
    assert_eq "disable $SERVICE_NAME" "$last_disable" 'missing-unit cleanup command'
    [[ ! -e "$enable_link" && ! -L "$enable_link" ]] || fail 'dangling enable link was not removed'

    ln -s "$root/missing-unit-file" "$enable_link"
    mode=command-failure
    if action_transaction_quiesce_unit_for_restore "$SERVICE_NAME" >/dev/null 2>&1; then
        fail 'failed dangling enable-link cleanup was accepted'
    fi
    [[ -L "$enable_link" ]] || fail 'command-failure fixture unexpectedly lost its dangling link'

    rm -f -- "$enable_link"
    ln -s "$root/missing-unit-file" "$enable_link"
    mode=false-success
    if action_transaction_quiesce_unit_for_restore "$SERVICE_NAME" >/dev/null 2>&1; then
        fail 'dangling enable link surviving a successful command was accepted'
    fi
    [[ -L "$enable_link" ]] || fail 'verification-failure fixture unexpectedly lost its dangling link'
)

test_quiesce_query_failure_is_write_free_and_present_uses_disable_now() (
    local root="$TEST_ROOT/quiesce-query-failure" enable_link="$TEST_ROOT/quiesce-query-failure/multi-user.target.wants/example.service"
    local mode=query-failure disable_calls=0 stop_requests=0 last_disable="" original_target
    SERVICE_NAME=example.service; SERVICE_FILE="$root/example.service"
    LEGACY_SERVICE_FILE="$root/bbr-optimize-persist.service"
    mkdir -p -- "$(dirname "$enable_link")"
    printf 'managed-unit-file\n' > "$SERVICE_FILE"
    ln -s "$SERVICE_FILE" "$enable_link"
    original_target=$(readlink -- "$enable_link")
    systemctl() {
        case "$1" in
            show)
                if [[ "$mode" == query-failure ]]; then
                    printf 'Failed to connect to bus: Host is down\n' >&2
                    return 17
                fi
                printf '%s\n' 'LoadState=loaded' 'UnitFileState=enabled' 'ActiveState=active'
                ;;
            disable)
                disable_calls=$((disable_calls + 1)); last_disable="$*"
                if [[ "$*" == "disable --now $SERVICE_NAME" ]]; then
                    stop_requests=$((stop_requests + 1))
                fi
                rm -f -- "$enable_link"
                ;;
            is-enabled|is-active) fail "quiesce manager-failure test called legacy query: $*" ;;
            *) fail "unexpected quiesce manager-failure systemctl call: $*" ;;
        esac
    }

    if action_transaction_quiesce_unit_for_restore "$SERVICE_NAME" >/dev/null 2>&1; then
        fail 'manager query failure was accepted by transaction quiesce'
    fi
    assert_eq 0 "$disable_calls" 'manager query failure disable calls'
    assert_eq 0 "$stop_requests" 'manager query failure stop requests'
    assert_eq managed-unit-file "$(<"$SERVICE_FILE")" 'manager query failure unit-file content'
    [[ -L "$enable_link" ]] || fail 'manager query failure removed the enable link'
    assert_eq "$original_target" "$(readlink -- "$enable_link")" 'manager query failure enable-link target'

    mode=present
    action_transaction_quiesce_unit_for_restore "$SERVICE_NAME"
    assert_eq 1 "$disable_calls" 'present unit disable calls'
    assert_eq 1 "$stop_requests" 'present unit stop requests'
    assert_eq "disable --now $SERVICE_NAME" "$last_disable" 'present unit quiesce command'
    assert_eq managed-unit-file "$(<"$SERVICE_FILE")" 'present unit quiesce unit-file content'
    [[ ! -e "$enable_link" && ! -L "$enable_link" ]] || fail 'present unit quiesce retained the enable link'
)

test_not_found_restore_rejects_managed_dangling_enable_link() (
    local root="$TEST_ROOT/not-found-final-verify" state_file="$TEST_ROOT/not-found-final-verify.unit"
    local enable_link="$TEST_ROOT/not-found-final-verify/multi-user.target.wants/example.service"
    SERVICE_NAME=example.service; SERVICE_FILE="$root/example.service"
    LEGACY_SERVICE_FILE="$root/bbr-optimize-persist.service"
    mkdir -p -- "$(dirname "$enable_link")"
    printf 'not-found\tinactive\n' > "$state_file"
    ln -s "$SERVICE_FILE" "$enable_link"
    systemctl() {
        case "$1" in
            show) printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' ;;
            is-enabled|is-active) fail "not-found final verification called legacy query: $*" ;;
            *) fail "unexpected not-found final verification systemctl call: $*" ;;
        esac
    }

    if restore_unit_state "$SERVICE_NAME" "$state_file" >/dev/null 2>&1; then
        fail 'managed not-found restore accepted a dangling enable link'
    fi
    [[ -L "$enable_link" ]] || fail 'final verification unexpectedly mutated the dangling enable link'
    rm -f -- "$enable_link"
    restore_unit_state "$SERVICE_NAME" "$state_file"

    # restore_unit_state remains generic for non-project units; the managed
    # link guard must not inspect or remove an arbitrary service.
    ln -s "$root/unrelated.service" "$root/multi-user.target.wants/unrelated.service"
    restore_unit_state unrelated.service "$state_file"
    [[ -L "$root/multi-user.target.wants/unrelated.service" ]] || fail 'generic unit restore removed an unrelated enable link'
)

test_remove_persistence_uses_machine_state_for_missing_unit() (
    local root="$TEST_ROOT/remove-persistence-missing" enable_link="$TEST_ROOT/remove-persistence-missing/multi-user.target.wants/example.service"
    local disable_calls=0 reload_calls=0
    SERVICE_NAME=example.service; SERVICE_FILE="$root/example.service"
    PERSIST_DIR="$root/persist"; PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
    LEGACY_SERVICE_FILE="$root/bbr-optimize-persist.service"
    mkdir -p -- "$(dirname "$enable_link")" "$PERSIST_DIR"
    ln -s "$SERVICE_FILE" "$enable_link"
    systemctl() {
        case "$1" in
            show) printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' ;;
            disable) ((disable_calls+=1)); rm -f -- "$enable_link" ;;
            daemon-reload) ((reload_calls+=1)) ;;
            is-enabled|is-active) fail "remove_persistence called legacy missing-unit query: $*" ;;
            *) fail "unexpected remove_persistence systemctl call: $*" ;;
        esac
    }

    remove_persistence
    assert_eq 1 "$disable_calls" 'remove_persistence dangling cleanup calls'
    assert_eq 1 "$reload_calls" 'remove_persistence daemon reload calls'
    [[ ! -e "$enable_link" && ! -L "$enable_link" ]] || fail 'remove_persistence retained a dangling enable link'
)

test_dangling_enable_cleanup_failure_retains_transaction_evidence() (
    local root="$TEST_ROOT/dangling-rollback" dir="$TEST_ROOT/dangling-rollback/state/.transaction.mutated"
    local enable_link="$TEST_ROOT/dangling-rollback/multi-user.target.wants/$SERVICE_NAME" disable_calls=0 rc=0
    STATE_DIR="$root/state"; PERSIST_DIR="$root/persist"; LOCK_HELD=0
    SERVICE_FILE="$root/bbrv3-lite.service"; LEGACY_SERVICE_FILE="$root/legacy/bbr-optimize-persist.service"
    mkdir -p -- "$dir/qdiscs" "$(dirname "$enable_link")"
    printf 'CREATED_AT\t2026-08-29T09:30:00Z\n' > "$dir/transaction.meta"
    printf 'mutated\n' > "$dir/transaction.state"
    printf 'complete\n' > "$dir/COMPLETE"
    printf 'dangling-rollback-snapshot\n' > "$dir/qdiscs/eth0.snapshot"
    ln -s "$root/missing-unit-file" "$enable_link"
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=1; ACTION_TRANSACTION_ROLLING_BACK=0
    ACTION_TRANSACTION_ROLLBACK_FAILED=0
    action_transaction_snapshot_validate() { :; }
    action_transaction_restore_path() { :; }
    action_transaction_restore_tree() { :; }
    restore_tcp_sysctl_snapshot_file() { :; }
    action_transaction_restore_routes() { :; }
    restore_action_qdisc() { :; }
    action_transaction_restore_unit() { :; }
    release_lock() { :; }
    systemctl() {
        case "$1" in
            show) printf '%s\n' 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' ;;
            disable) ((disable_calls+=1)); return 9 ;;
            daemon-reload) : ;;
            is-enabled|is-active) fail "dangling rollback called legacy query: $*" ;;
            *) return 1 ;;
        esac
    }

    if action_transaction_rollback >/dev/null 2>&1; then rc=0; else rc=$?; fi
    assert_eq 1 "$rc" 'dangling cleanup rollback result'
    assert_eq 1 "$disable_calls" 'dangling cleanup rollback disable calls'
    [[ -L "$enable_link" ]] || fail 'failed dangling cleanup unexpectedly removed the fixture link'
    [[ "$ACTION_TRANSACTION_DIR" == "$dir" && -d "$dir" ]] || fail 'dangling cleanup failure deleted transaction evidence'
    assert_eq 1 "$ACTION_TRANSACTION_ROLLBACK_FAILED" 'dangling cleanup rollback failure latch'
    assert_eq $'CREATED_AT\t2026-08-29T09:30:00Z' "$(<"$dir/transaction.meta")" 'dangling rollback transaction.meta'
    assert_eq mutated "$(<"$dir/transaction.state")" 'dangling rollback transaction.state'
    assert_eq complete "$(<"$dir/COMPLETE")" 'dangling rollback completion marker'
    assert_eq dangling-rollback-snapshot "$(<"$dir/qdiscs/eth0.snapshot")" 'dangling rollback snapshot evidence'
)

test_tcp_baseline_capture_with_missing_units() (
    local root="$TEST_ROOT/baseline-missing"
    install_missing_unit_transaction_fixture "$root"
    capture_baseline eth0 adopt-current
    assert_eq $'not-found\tinactive' "$(<"$BASELINE_DIR/service.unit")" 'TCP baseline current service state'
    assert_eq $'not-found\tinactive' "$(<"$BASELINE_DIR/legacy-service.unit")" 'TCP baseline legacy service state'
    grep -Fxq $'SCHEMA\t3' "$BASELINE_DIR/manifest" || fail 'TCP baseline did not use schema 3'
)

test_action_transaction_and_first_entry_paths_with_missing_units() (
    local root="$TEST_ROOT/action-missing" install_steps=0 auto_steps=0
    install_missing_unit_transaction_fixture "$root"
    action_transaction_begin_multi eth0
    assert_eq $'not-found\tinactive' "$(<"$ACTION_TRANSACTION_DIR/service.unit")" 'action transaction current service state'
    assert_eq $'not-found\tinactive' "$(<"$ACTION_TRANSACTION_DIR/legacy-service.unit")" 'action transaction legacy service state'
    action_transaction_discard_snapshot

    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { :; }; detect_interface() { printf 'eth0\n'; }
    load_config() { reset_config; }; nic_policy_ownership_preflight() { :; }; network_tuning_preflight() { :; }
    install_base_tuning_steps() { ((install_steps+=1)); }
    install_base_tuning auto balanced mixed 0 0
    assert_eq 1 "$install_steps" 'first install transaction body calls'

    auto_tune_execute() { ((auto_steps+=1)); }
    auto_tune_run_transaction eth0 balanced mixed 0 100 0
    assert_eq 1 "$auto_steps" 'first auto transaction body calls'
)

test_restore_absent_service_removes_presence_and_enablement() (
    local root="$TEST_ROOT/restore-absent" state_file="$TEST_ROOT/restore-absent.unit"
    local active=active enable_link="$root/systemd/multi-user.target.wants/bbrv3-lite.service"
    SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    ACTION_TRANSACTION_DIR="$root/transaction"
    mkdir -p -- "$(dirname "$enable_link")" "$ACTION_TRANSACTION_DIR/files"
    printf '[Service]\nExecStart=/bin/true\n' > "$SERVICE_FILE"
    ln -s "$SERVICE_FILE" "$enable_link"
    printf 'absent\n' > "$ACTION_TRANSACTION_DIR/service.state"
    printf 'not-found\tinactive\n' > "$state_file"
    systemctl() {
        local verb="$1"
        case "$verb" in
            show)
                if [[ -e "$SERVICE_FILE" ]]; then
                    if [[ -L "$enable_link" ]]; then
                        printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=%s\n' "$active"
                    else
                        printf 'LoadState=loaded\nUnitFileState=disabled\nActiveState=%s\n' "$active"
                    fi
                else
                    printf 'LoadState=not-found\nUnitFileState=\nActiveState=inactive\n'
                fi
                ;;
            disable) rm -f -- "$enable_link"; active=inactive ;;
            daemon-reload) : ;;
            is-enabled|is-active) fail "absent restore called legacy query: $*" ;;
            *) fail "unexpected restore systemctl call: $*" ;;
        esac
    }
    action_transaction_quiesce_unit_for_restore "$SERVICE_NAME"
    action_transaction_restore_path "$SERVICE_FILE" service
    systemctl daemon-reload
    restore_unit_state "$SERVICE_NAME" "$state_file"
    [[ ! -e "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]] || fail 'absent restore left the service file present'
    [[ ! -e "$enable_link" && ! -L "$enable_link" ]] || fail 'absent restore left an enable symlink present'
    assert_eq $'not-found\tinactive' "$(query_unit_state "$SERVICE_NAME")" 'restored absent service state'
)

test_missing_unit_uses_load_state_without_is_enabled
test_machine_readable_unit_states_and_manager_failure
test_query_unit_state_parser_is_strict_and_order_independent
test_current_and_legacy_missing_combinations
test_missing_unit_quiesce_cleans_and_verifies_dangling_enable_link
test_quiesce_query_failure_is_write_free_and_present_uses_disable_now
test_not_found_restore_rejects_managed_dangling_enable_link
test_remove_persistence_uses_machine_state_for_missing_unit
test_dangling_enable_cleanup_failure_retains_transaction_evidence
test_tcp_baseline_capture_with_missing_units
test_action_transaction_and_first_entry_paths_with_missing_units
test_restore_absent_service_removes_presence_and_enablement
echo 'systemd v8.0.3 regression tests: OK'
