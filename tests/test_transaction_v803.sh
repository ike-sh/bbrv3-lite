#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are consumed by sourced production functions
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" <<< "$1" || fail "$3: missing '$2'"; }

write_stale_transaction() {
    local directory="$1" state="$2" iface="$3"
    mkdir -p -- "$directory/qdiscs"
    printf 'CREATED_AT\t2026-08-29T05:00:00Z\n' > "$directory/transaction.meta"
    printf '%s\n' "$state" > "$directory/transaction.state"
    printf 'KIND\tfq\nRATE\t\nARGS\tlimit 10000 flow_limit 100\nqdisc fq 8001: root limit 10000p flow_limit 100p\n' \
        > "$directory/qdiscs/$iface.snapshot"
    chmod -R go-rwx "$directory"
}

test_stale_transactions_are_diagnostic_and_immutable() (
    local root="$TEST_ROOT/stale" readonly="$TEST_ROOT/stale/state/.transaction.readonly"
    local mutated="$TEST_ROOT/stale/state/.transaction.mutated" legacy="$TEST_ROOT/stale/state/.transaction.legacy"
    local corrupt="$TEST_ROOT/stale/state/.transaction.corrupt" expected="$TEST_ROOT/stale-before"
    local output_file="$TEST_ROOT/stale-output" output writes=0
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""
    write_stale_transaction "$readonly" readonly eth0
    write_stale_transaction "$mutated" mutated eth1
    mkdir -p -- "$legacy/qdiscs" "$corrupt/qdiscs"
    printf 'KIND\tfq\nRATE\t\nARGS\tlimit 10000 flow_limit 100\nqdisc fq 8002: root limit 10000p flow_limit 100p\n' > "$legacy/qdiscs/eth2.snapshot"
    printf 'CREATED_AT\tnot-a-time\n' > "$corrupt/transaction.meta"
    printf 'garbled\n' > "$corrupt/transaction.state"
    ln -s "$readonly/qdiscs/eth0.snapshot" "$corrupt/qdiscs/eth3.snapshot"
    chmod -R go-rwx "$legacy" "$corrupt"
    cp -a -- "$STATE_DIR" "$expected"
    ensure_state_layout() { ((writes+=1)); }
    action_qdisc_snapshot() { ((writes+=1)); }
    capture_runtime_sysctls() { ((writes+=1)); }

    if action_transaction_begin eth4 > "$output_file" 2>&1; then
        fail 'stale transactions allowed a new write transaction'
    fi
    output=$(<"$output_file")
    assert_contains "$output" '检测到未完成事务' 'stale transaction heading'
    assert_contains "$output" "$readonly" 'readonly transaction path'
    assert_contains "$output" "$mutated" 'mutated transaction path'
    assert_contains "$output" "$legacy" 'legacy transaction path'
    assert_contains "$output" "$corrupt" 'corrupt transaction path'
    assert_contains "$output" '创建时间: 2026-08-29T05:00:00Z' 'stale transaction creation time'
    assert_contains "$output" '受影响接口: eth0' 'readonly affected interface'
    assert_contains "$output" '受影响接口: eth1' 'mutated affected interface'
    assert_contains "$output" '事务状态: readonly' 'readonly state diagnosis'
    assert_contains "$output" '事务状态: mutated' 'mutated state diagnosis'
    assert_contains "$output" '旧事务没有可信状态 metadata' 'legacy stale diagnosis'
    assert_contains "$output" 'metadata/state 不完整或损坏' 'corrupt stale diagnosis'
    assert_contains "$output" '建议只读检查命令:' 'read-only inspection command'
    assert_contains "$output" '不会自动恢复、删除或覆盖' 'non-mutating stale policy'
    [[ -d "$readonly" && -d "$mutated" && -d "$legacy" && -d "$corrupt" ]] || fail 'stale transaction evidence was deleted'
    (( writes == 0 )) || fail "stale diagnosis entered a write stage: $writes"
    diff -r -- "$expected" "$STATE_DIR" >/dev/null || fail 'stale diagnosis modified transaction evidence'
)

run_auto_helper_case() (
    local mode="$1" expected_rc="$2" expected_events="$3" events="" rc=0
    ACTION_TRANSACTION_DIR=""
    action_transaction_begin_multi() {
        events+="${events:+|}begin:$1"
        [[ "$mode" != begin-fail ]] || return 41
        ACTION_TRANSACTION_DIR="$TEST_ROOT/$mode-evidence"
        mkdir -p -- "$ACTION_TRANSACTION_DIR"
    }
    action_transaction_mark_mutated() {
        events+="|mark"
        [[ "$mode" != mark-fail ]] || return 42
    }
    auto_tune_execute() {
        events+="|execute:$(IFS=,; printf '%s' "$*")"
        [[ "$mode" == success ]] && return 0
        return 7
    }
    action_transaction_commit() {
        events+="|commit"
        rm -rf -- "$ACTION_TRANSACTION_DIR"; ACTION_TRANSACTION_DIR=""
    }
    action_transaction_rollback() {
        events+="|rollback"
        [[ "$mode" != rollback-fail ]] || return 23
        rm -rf -- "$ACTION_TRANSACTION_DIR"; ACTION_TRANSACTION_DIR=""
    }
    action_transaction_discard_snapshot() {
        events+="|discard"
        ACTION_TRANSACTION_DIR=""
        return 19
    }

    if auto_tune_run_transaction eth0 balanced mixed 0 100 0 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == "$expected_rc" ]] || fail "$mode helper rc: expected $expected_rc, got $rc"
    [[ "$events" == "$expected_events" ]] || fail "$mode helper events: expected '$expected_events', got '$events'"
    if [[ "$mode" == rollback-fail ]]; then
        [[ -d "$ACTION_TRANSACTION_DIR" ]] || fail 'rollback failure deleted transaction evidence'
    else
        [[ -z "$ACTION_TRANSACTION_DIR" ]] || fail "$mode left an unexpected active transaction"
    fi
)

test_auto_tune_transaction_control_flow() {
    local execute='execute:eth0,balanced,mixed,0,100,0'
    run_auto_helper_case success 0 "begin:eth0|mark|$execute|commit"
    run_auto_helper_case execute-fail 7 "begin:eth0|mark|$execute|rollback"
    run_auto_helper_case begin-fail 1 'begin:eth0'
    run_auto_helper_case mark-fail 1 'begin:eth0|mark|discard'
    run_auto_helper_case rollback-fail 23 "begin:eth0|mark|$execute|rollback"
}

write_minimal_transaction_metadata() {
    local directory="$1" state="${2:-readonly}"
    mkdir -p -- "$directory"
    printf 'CREATED_AT\t2026-08-29T06:00:00Z\n' > "$directory/transaction.meta"
    printf '%s\n' "$state" > "$directory/transaction.state"
    chmod 0600 "$directory/transaction.meta" "$directory/transaction.state"
}

test_persisted_readonly_to_mutated_and_commit_cleanup() (
    local dir="$TEST_ROOT/state-transition/state/.transaction.success" body_calls=0
    STATE_DIR="$TEST_ROOT/state-transition/state"
    write_minimal_transaction_metadata "$dir" readonly
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0
    action_transaction_begin_multi() { :; }
    action_transaction_snapshot_validate() { :; }
    auto_tune_execute() {
        ((body_calls+=1))
        [[ "$ACTION_TRANSACTION_MUTATED" == 1 ]] || fail 'body ran before the in-memory mutated flag'
        [[ $(<"$ACTION_TRANSACTION_DIR/transaction.state") == mutated ]] || fail 'body ran before persisted state became mutated'
    }

    auto_tune_run_transaction eth0 balanced mixed 0 100 0
    [[ "$body_calls" == 1 ]] || fail 'successful auto transaction body count'
    [[ -z "$ACTION_TRANSACTION_DIR" && ! -e "$dir" ]] || fail 'successful commit left transaction metadata/snapshot behind'
)

test_transaction_state_atomic_replace_failure_blocks_body() (
    local dir="$TEST_ROOT/state-write-failure/state/.transaction.fail" body_calls=0 rc=0
    STATE_DIR="$TEST_ROOT/state-write-failure/state"
    write_minimal_transaction_metadata "$dir" readonly
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0
    action_transaction_begin_multi() { :; }
    action_transaction_snapshot_validate() { :; }
    auto_tune_execute() { ((body_calls+=1)); }
    mv() {
        [[ "${*: -1}" != "$ACTION_TRANSACTION_DIR/transaction.state" ]] || return 70
        command mv "$@"
    }

    if auto_tune_run_transaction eth0 balanced mixed 0 100 0 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == 1 ]] || fail "state write failure returned $rc instead of 1"
    [[ "$body_calls" == 0 ]] || fail 'state write failure allowed the auto body to run'
    [[ -z "$ACTION_TRANSACTION_DIR" && ! -e "$dir" ]] || fail 'failed readonly state transition was not safely discarded'
)

test_impossible_unit_snapshot_blocks_mutation_and_body() (
    local dir="$TEST_ROOT/impossible-unit/state/.transaction.bad-unit" body_calls=0 rc=0
    STATE_DIR="$TEST_ROOT/impossible-unit/state"
    write_minimal_transaction_metadata "$dir" readonly
    printf 'not-found\tactive\n' > "$dir/service.unit"
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0
    action_transaction_begin_multi() { :; }
    action_transaction_snapshot_validate() { unit_state_snapshot_validate "$ACTION_TRANSACTION_DIR/service.unit"; }
    auto_tune_execute() { ((body_calls+=1)); }

    if auto_tune_run_transaction eth0 balanced mixed 0 100 0 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == 1 ]] || fail "impossible unit snapshot returned $rc instead of 1"
    [[ "$body_calls" == 0 ]] || fail 'impossible unit snapshot allowed the auto body to run'
    [[ -z "$ACTION_TRANSACTION_DIR" && ! -e "$dir" ]] || fail 'rejected read-only snapshot was not discarded'
)

test_completed_snapshot_with_untrusted_state_is_never_discarded() {
    local scenario dir outside="$TEST_ROOT/outside-readonly"
    printf 'readonly\n' > "$outside"
    for scenario in missing corrupt symlink memory-mutated; do
        (
            STATE_DIR="$TEST_ROOT/discard-$scenario/state"
            dir="$STATE_DIR/.transaction.$scenario"
            write_minimal_transaction_metadata "$dir" readonly
            case "$scenario" in
                missing) rm -f -- "$dir/transaction.state" ;;
                corrupt) printf 'garbled\n' > "$dir/transaction.state" ;;
                symlink) rm -f -- "$dir/transaction.state"; ln -s "$outside" "$dir/transaction.state" ;;
                memory-mutated) : ;;
            esac
            ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
            ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0
            [[ "$scenario" != memory-mutated ]] || ACTION_TRANSACTION_MUTATED=1
            if action_transaction_discard_snapshot >/dev/null 2>&1; then
                fail "untrusted completed snapshot was discarded: $scenario"
            fi
            [[ "$ACTION_TRANSACTION_DIR" == "$dir" && -d "$dir" ]] || fail "transaction evidence was lost: $scenario"
        )
    done

    (
        STATE_DIR="$TEST_ROOT/discard-valid/state"
        dir="$STATE_DIR/.transaction.valid"
        write_minimal_transaction_metadata "$dir" readonly
        ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
        ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0
        action_transaction_discard_snapshot
        [[ -z "$ACTION_TRANSACTION_DIR" && ! -e "$dir" ]] || fail 'trusted readonly snapshot was not discarded'
    )
}

test_rollback_failure_retains_mutated_evidence() (
    local dir="$TEST_ROOT/rollback-validation/state/.transaction.mutated" snapshot_calls=0 body_calls=0 rc=0
    STATE_DIR="$TEST_ROOT/rollback-validation/state"; LOCK_HELD=0
    write_minimal_transaction_metadata "$dir" readonly
    mkdir -p -- "$dir/qdiscs"
    printf 'rollback-validation-snapshot\n' > "$dir/qdiscs/eth0.snapshot"
    printf 'complete\n' > "$dir/COMPLETE"
    ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
    ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0; ACTION_TRANSACTION_ROLLING_BACK=0
    ACTION_TRANSACTION_ROLLBACK_FAILED=0
    action_transaction_begin_multi() { :; }
    action_transaction_snapshot_validate() { ((snapshot_calls+=1)); (( snapshot_calls == 1 )); }
    auto_tune_execute() { ((body_calls+=1)); return 7; }

    if auto_tune_run_transaction eth0 balanced mixed 0 100 0 >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == 1 ]] || fail "rollback validation failure returned $rc instead of rollback rc 1"
    [[ "$body_calls" == 1 ]] || fail 'rollback evidence test did not execute the body once'
    [[ "$ACTION_TRANSACTION_DIR" == "$dir" && -d "$dir" ]] || fail 'rollback validation failure deleted evidence'
    [[ $(<"$dir/transaction.meta") == $'CREATED_AT\t2026-08-29T06:00:00Z' ]] || fail 'rollback validation failure lost transaction.meta'
    [[ $(<"$dir/transaction.state") == mutated && $(<"$dir/COMPLETE") == complete ]] || fail 'rollback validation failure lost state/completion evidence'
    [[ $(<"$dir/qdiscs/eth0.snapshot") == rollback-validation-snapshot ]] || fail 'rollback validation failure lost snapshot evidence'
    [[ "$ACTION_TRANSACTION_ROLLBACK_FAILED" == 1 ]] || fail 'rollback validation failure did not latch the failed rollback'
)

test_failed_explicit_rollback_is_not_retried_by_exit_cleanup() (
    local dir="$TEST_ROOT/rollback-latch/state/.transaction.mutated"
    local validation_calls="$TEST_ROOT/rollback-latch.validation-calls"
    local result="$TEST_ROOT/rollback-latch.result" child_rc=0 helper_rc=0 count
    STATE_DIR="$TEST_ROOT/rollback-latch/state"
    write_minimal_transaction_metadata "$dir" readonly
    mkdir -p -- "$dir/qdiscs"
    printf 'latched-rollback-snapshot\n' > "$dir/qdiscs/eth0.snapshot"
    printf 'complete\n' > "$dir/COMPLETE"
    printf '0\n' > "$validation_calls"
    : > "$result"

    if (
        set -Eeuo pipefail
        STATE_DIR="$TEST_ROOT/rollback-latch/state"
        ACTION_TRANSACTION_DIR="$dir"; ACTION_TRANSACTION_IFACE=eth0; ACTION_TRANSACTION_INTERFACES=eth0
        ACTION_TRANSACTION_READY=1; ACTION_TRANSACTION_MUTATED=0; ACTION_TRANSACTION_ROLLING_BACK=0
        ACTION_TRANSACTION_ROLLBACK_FAILED=0; LOCK_HELD=0
        QDISC_DEFAULT_TRANSACTION_ACTIVE=0; NIC_RUNTIME_TRANSACTION_DIR=""
        TC_TRIAL_IFACE=""; TC_TRIAL_SNAPSHOT=""; MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        DNS_TRANSACTION_DIR=""; IPV6_TRANSACTION_DIR=""
        action_transaction_begin_multi() { :; }
        action_transaction_snapshot_validate() {
            local current
            current=$(<"$validation_calls")
            ((current+=1))
            printf '%s\n' "$current" > "$validation_calls"
            (( current == 1 ))
        }
        auto_tune_execute() { return 7; }
        log() { :; }
        # cleanup_core calls release_lock after its action rollback attempt, so
        # this records the latch after the real EXIT cleanup path has run.
        release_lock() {
            printf 'latch-after-exit-cleanup\t%s\n' "$ACTION_TRANSACTION_ROLLBACK_FAILED" >> "$result"
        }
        trap cleanup_core_exit EXIT
        if auto_tune_run_transaction eth0 balanced mixed 0 100 0; then helper_rc=0; else helper_rc=$?; fi
        printf 'helper-rc\t%s\nlatch-before-exit\t%s\n' \
            "$helper_rc" "$ACTION_TRANSACTION_ROLLBACK_FAILED" >> "$result"
        exit "$helper_rc"
    ); then
        child_rc=0
    else
        child_rc=$?
    fi

    [[ "$child_rc" == 1 ]] || fail "latched rollback child returned $child_rc instead of 1"
    count=$(<"$validation_calls")
    [[ "$count" == 2 ]] || fail "EXIT cleanup retried failed rollback validation (calls=$count, expected 2 total/1 failure)"
    grep -Fxq $'helper-rc\t1' "$result" || fail 'explicit rollback did not return its rollback failure'
    grep -Fxq $'latch-before-exit\t1' "$result" || fail 'explicit rollback failure was not latched before EXIT'
    grep -Fxq $'latch-after-exit-cleanup\t1' "$result" || fail 'EXIT cleanup cleared the rollback failure latch'
    [[ -d "$dir" ]] || fail 'EXIT cleanup deleted the latched transaction directory'
    [[ $(<"$dir/transaction.meta") == $'CREATED_AT\t2026-08-29T06:00:00Z' ]] || fail 'EXIT cleanup lost latched transaction.meta'
    [[ $(<"$dir/transaction.state") == mutated ]] || fail 'EXIT cleanup lost the latched mutated state'
    [[ $(<"$dir/COMPLETE") == complete ]] || fail 'EXIT cleanup lost the latched COMPLETE marker'
    [[ $(<"$dir/qdiscs/eth0.snapshot") == latched-rollback-snapshot ]] || fail 'EXIT cleanup lost the latched snapshot evidence'
)

test_disable_failure_makes_rollback_incomplete_and_retains_evidence() (
    local dir="$TEST_ROOT/rollback-disable/state/.transaction.mutated" disable_calls=0 rc=0
    STATE_DIR="$TEST_ROOT/rollback-disable/state"; PERSIST_DIR="$TEST_ROOT/rollback-disable/persist"
    LOCK_HELD=0
    write_minimal_transaction_metadata "$dir" mutated
    mkdir -p -- "$dir/qdiscs"
    printf 'disable-failure-snapshot\n' > "$dir/qdiscs/eth0.snapshot"
    printf 'complete\n' > "$dir/COMPLETE"
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
        local verb="$1" unit="${2:-}"
        case "$verb" in
            show)
                if [[ "$unit" == "$SERVICE_NAME" ]]; then
                    printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n'
                else
                    printf 'LoadState=not-found\nUnitFileState=untrusted\nActiveState=inactive\n'
                fi
                ;;
            disable) ((disable_calls+=1)); return 9 ;;
            daemon-reload) : ;;
            *) return 1 ;;
        esac
    }

    if action_transaction_rollback >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == 1 ]] || fail "disable failure returned $rc instead of incomplete rollback"
    [[ "$disable_calls" == 1 ]] || fail "missing unit was unnecessarily disabled (calls=$disable_calls)"
    [[ "$ACTION_TRANSACTION_DIR" == "$dir" && -d "$dir" ]] || fail 'disable failure deleted transaction evidence'
    [[ $(<"$dir/transaction.meta") == $'CREATED_AT\t2026-08-29T06:00:00Z' ]] || fail 'disable failure lost transaction.meta'
    [[ $(<"$dir/transaction.state") == mutated && $(<"$dir/COMPLETE") == complete ]] || fail 'disable failure lost transaction state/completion metadata'
    [[ $(<"$dir/qdiscs/eth0.snapshot") == disable-failure-snapshot ]] || fail 'disable failure lost snapshot evidence'
    [[ "$ACTION_TRANSACTION_ROLLBACK_FAILED" == 1 ]] || fail 'incomplete rollback did not latch its failure'
)

test_stale_transactions_are_diagnostic_and_immutable
test_auto_tune_transaction_control_flow
test_persisted_readonly_to_mutated_and_commit_cleanup
test_transaction_state_atomic_replace_failure_blocks_body
test_impossible_unit_snapshot_blocks_mutation_and_body
test_completed_snapshot_with_untrusted_state_is_never_discarded
test_rollback_failure_retains_mutated_evidence
test_failed_explicit_rollback_is_not_retried_by_exit_cleanup
test_disable_failure_makes_rollback_incomplete_and_retains_evidence
echo 'transaction v8.0.3 regression tests: OK'
