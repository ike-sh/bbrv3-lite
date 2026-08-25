#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
export BBRV3_SYS_CLASS_NET_ROOT="$TEST_ROOT/sys/class/net"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export TMPDIR="$TEST_ROOT/tmp"
mkdir -p "$TMPDIR" "$BBRV3_SYS_CLASS_NET_ROOT"

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

cleanup() {
    remove_tree_within "$TEST_ROOT" "$(dirname "$TEST_ROOT")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
expect_failure() { if "$@" >/dev/null 2>&1; then fail "command unexpectedly succeeded: $*"; fi; }

nic_test_sysctl_value() {
    case "$1" in
        net.core.default_qdisc) printf 'fq\n' ;;
        net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
        net.core.rmem_max|net.core.wmem_max) printf '16777216\n' ;;
        net.ipv4.tcp_rmem) printf '4096\t131072\t16777216\n' ;;
        net.ipv4.tcp_wmem) printf '4096\t16384\t16777216\n' ;;
        net.ipv4.tcp_mtu_probing) printf '0\n' ;;
        net.ipv4.tcp_fastopen) printf '1\n' ;;
        net.core.somaxconn|net.ipv4.tcp_max_syn_backlog) printf '4096\n' ;;
        net.core.netdev_max_backlog) printf '1000\n' ;;
        *) return 1 ;;
    esac
}

make_iface() {
    local iface="$1" mac="$2" root
    root="$BBRV3_SYS_CLASS_NET_ROOT/$iface"
    mkdir -p "$root/queues/rx-0" "$root/queues/tx-0"
    printf '%s\n' "$mac" > "$root/address"
    printf '1500\n' > "$root/mtu"
    printf '1000\n' > "$root/speed"
}

make_iface eth0 02:00:00:00:00:10
make_iface eth1 02:00:00:00:00:11
make_iface eth2 02:00:00:00:00:12
make_iface eth3 02:00:00:00:00:13

test_strict_policy_layout_and_identity() {
    nic_policy_write eth0 fq 0 0 3 balanced proxy 0 0
    nic_policy_set_validate
    assert_eq fq "$NIC_POLICY_MODE" "policy mode"

    ln -s "$(nic_policy_path eth0)" "$NIC_POLICY_DIR/evil.conf"
    expect_failure nic_policy_set_validate
    rm -f -- "$NIC_POLICY_DIR/evil.conf"

    printf 'foreign\n' > "$NIC_POLICY_DIR/README"
    expect_failure nic_policy_set_validate
    rm -f -- "$NIC_POLICY_DIR/README"

    printf '02:00:00:00:00:ff\n' > "$BBRV3_SYS_CLASS_NET_ROOT/eth0/address"
    nic_policy_load_file "$(nic_policy_path eth0)"
    expect_failure nic_policy_validate_identity
    printf '02:00:00:00:00:10\n' > "$BBRV3_SYS_CLASS_NET_ROOT/eth0/address"
}

test_immutable_baseline_rejects_reused_interface_identity() (
    STATE_DIR="$TEST_ROOT/baseline-identity/state"
    BASELINE_DIR="$STATE_DIR/baseline"
    NIC_STATE_DIR="$STATE_DIR/interfaces"
    qdisc_guard() { :; }
    managed_htb() { return 1; }
    action_qdisc_snapshot() {
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    nic_baseline_capture eth3
    cp -- "$(nic_baseline_dir eth3)/qdisc.snapshot" "$(nic_baseline_dir eth3)/qdisc.snapshot.good"
    printf 'KIND\tcake\nRATE\t\nARGS\t\n' > "$(nic_baseline_dir eth3)/qdisc.snapshot"
    chmod 0600 "$(nic_baseline_dir eth3)/qdisc.snapshot"
    expect_failure nic_baseline_validate eth3
    mv -- "$(nic_baseline_dir eth3)/qdisc.snapshot.good" "$(nic_baseline_dir eth3)/qdisc.snapshot"
    printf 'foreign\n' > "$(nic_baseline_dir eth3)/unexpected"
    expect_failure nic_baseline_validate eth3
    rm -f -- "$(nic_baseline_dir eth3)/unexpected"
    printf '02:00:00:00:00:ff\n' > "$BBRV3_SYS_CLASS_NET_ROOT/eth3/address"
    expect_failure nic_baseline_capture eth3
    printf '02:00:00:00:00:13\n' > "$BBRV3_SYS_CLASS_NET_ROOT/eth3/address"
)

test_global_model_and_config_invariants() {
    nic_policy_write eth0 fq 0 0 3 balanced proxy 0 0
    nic_policy_write eth1 shape 200 220 3 adaptive mixed 500 100
    nic_policy_write eth2 shape 300 320 3 adaptive bulk 1000 60
    nic_sync_global_model
    assert_eq adaptive "$SYSCTL_PROFILE" "aggregate profile"
    assert_eq bulk "$ROLE" "aggregate role"
    assert_eq 1000 "$BANDWIDTH_MBIT" "largest BDP bandwidth"
    assert_eq 60 "$RTT_MS" "largest BDP RTT"
    assert_eq eth2 "$NIC_MODEL_INTERFACE" "largest BDP representative interface"

    MULTI_NIC_ENABLED=0; TC_INTERFACE=eth0; NIC_MODEL_INTERFACE=eth2
    assert_eq eth0 "$(sysctl_model_interface)" "single-NIC model ignores stale aggregate interface"
    MULTI_NIC_ENABLED=1
    assert_eq eth2 "$(sysctl_model_interface)" "multi-NIC model uses aggregate interface"

    nic_finalize_multi_config
    BBR_ENABLED=1
    save_config
    reset_config
    load_config
    assert_eq 1 "$MULTI_NIC_ENABLED" "multi-NIC config flag"
    assert_eq auto "$TC_INTERFACE" "legacy interface reset"
    assert_eq 0 "$TC_ENABLED" "legacy shaping reset"

    TC_ENABLED=1
    TC_INTERFACE=eth0
    TC_RATE_MBIT=100
    expect_failure save_config
    load_config
}

test_auto_stage_uses_global_aggregate_but_persists_target_model() (
    local stage_dir="$TEST_ROOT/auto-stage/interfaces.d"
    NIC_POLICY_DIR="$stage_dir"
    MULTI_NIC_ENABLED=1
    nic_reset_legacy_tc_fields
    nic_policy_write eth2 shape 300 320 3 adaptive bulk 1000 60

    nic_stage_candidate_global_model eth0 balanced proxy 0 100
    assert_eq balanced "$AUTO_POLICY_PROFILE" "staged target profile"
    assert_eq proxy "$AUTO_POLICY_ROLE" "staged target role"
    assert_eq 0 "$AUTO_POLICY_RTT_MS" "zero-bandwidth balanced RTT normalization"
    assert_eq adaptive "$SYSCTL_PROFILE" "other adaptive NIC keeps global profile during staging"
    assert_eq bulk "$ROLE" "other bulk NIC keeps global resource role during staging"
    assert_eq eth2 "$NIC_MODEL_INTERFACE" "other NIC remains global model representative"

    nic_stage_candidate_global_model eth0 adaptive proxy 2000 40
    assert_eq proxy "$AUTO_POLICY_ROLE" "target role remains distinct from aggregate role"
    assert_eq 2000 "$AUTO_POLICY_BANDWIDTH_MBIT" "target bandwidth remains distinct"
    assert_eq bulk "$ROLE" "aggregate role includes existing bulk NIC"
    assert_eq 2000 "$BANDWIDTH_MBIT" "larger candidate BDP becomes global model"
    assert_eq 40 "$RTT_MS" "candidate RTT becomes global model"
    assert_eq eth0 "$NIC_MODEL_INTERFACE" "candidate becomes representative interface"

    TC_INTERFACE=eth0; TC_ENABLED=1; TC_RATE_MBIT=250; TC_KNEE_MBIT=270; TC_MARGIN_PERCENT=3
    apply_sysctl_profile() { :; }
    save_config() { :; }
    install_persistence() { :; }
    restart_and_verify_persistence() { :; }
    verify_system_state() { :; }
    persist_current_tuning
    nic_policy_load_file "$(nic_policy_path eth0)"
    assert_eq proxy "$NIC_POLICY_ROLE" "persisted target policy did not inherit aggregate role"
    assert_eq 2000 "$NIC_POLICY_BANDWIDTH_MBIT" "persisted target bandwidth"
    assert_eq bulk "$ROLE" "global role remains aggregated after commit"
)

test_tc_enable_does_not_copy_another_nic_global_model() (
    local captured=""
    load_config() {
        MULTI_NIC_ENABLED=1
        SYSCTL_PROFILE=adaptive; ROLE=bulk; BANDWIDTH_MBIT=10000; RTT_MS=200
    }
    detect_interface() { printf 'eth3\n'; }
    auto_tune_route_guard() { :; }
    nic_policy_exists() { return 1; }
    nic_manage() { captured="$*"; }
    tc_enable 500 eth3 520 3
    assert_eq 'eth3 shape 500 520 3 balanced mixed 0 0' "$captured" "qdisc compatibility command copied aggregate model"
)

test_read_only_plan_includes_aggregate_effect() (
    local before after output
    load_config
    before=$(sha256sum "$NIC_POLICY_DIR"/*.conf)
    nic_policy_ownership_preflight() { :; }
    output=$(nic_plan eth0 shape 150 170 4 adaptive proxy 2000 40)
    grep -Fq 'adaptive/bulk/2000/40/eth0' <<< "$output" || fail "plan did not show aggregate model after apply"
    grep -Fq 'none (read-only)' <<< "$output" || fail "plan did not state read-only behavior"
    after=$(sha256sum "$NIC_POLICY_DIR"/*.conf)
    assert_eq "$before" "$after" "plan mutated policy files"
)

test_ownership_gate() {
    (
        managed_htb_interfaces_strict() { printf 'orphan0\n'; }
        qdisc_guard() { :; }
        expect_failure nic_policy_ownership_preflight eth0
    )
    (
        managed_htb_interfaces_strict() { printf 'eth0\neth1\neth2\n'; }
        qdisc_guard() { :; }
        nic_policy_ownership_preflight
    )
}

test_restore_preflight_rejects_external_filter_before_writes() (
    local root="$TEST_ROOT/restore-filter-preflight" events="$TEST_ROOT/restore-filter-preflight.events"
    BASELINE_DIR="$root/baseline"
    : > "$events"
    mkdir -p "$BASELINE_DIR"

    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { :; }
    tcp_baseline_validate() {
        TCP_BASELINE_VALIDATED_PROVENANCE=native
        TCP_BASELINE_VALIDATED_INTERFACE=eth0
        TCP_BASELINE_VALIDATED_GENERATION=v2
    }
    tcp_restore_runtime_preflight() { :; }
    nic_policy_layout_state() { printf 'managed\n'; }
    nic_policy_set_validate() { :; }
    nic_policy_interface_list() { printf 'eth0\neth1\n'; }
    nic_baseline_validate() { :; }
    nic_interface_exists() { :; }
    nic_baseline_identity_validate() { :; }
    tc() {
        case "$*" in
            'qdisc show dev eth0'|'qdisc show dev eth1') printf 'qdisc fq 123: root\n' ;;
            'class show dev eth0'|'class show dev eth1') : ;;
            'filter show dev eth0 parent 123:') : ;;
            'filter show dev eth1 parent 123:') printf 'filter protocol ip pref 10 u32 chain 0\n' ;;
            *) fail "unexpected restore-preflight tc invocation: $*" ;;
        esac
    }

    remove_persistence() { printf 'WRITE:remove-persistence\n' >> "$events"; }
    nic_restore_secondary_baselines() { printf 'WRITE:restore-secondary\n' >> "$events"; }
    restore_backed_path() { printf 'WRITE:restore-path\n' >> "$events"; }
    restore_runtime_sysctls() { printf 'WRITE:restore-sysctl\n' >> "$events"; }
    restore_baseline_route_windows() { printf 'WRITE:restore-routes\n' >> "$events"; }
    restore_baseline_qdisc() { printf 'WRITE:restore-qdisc\n' >> "$events"; }
    nic_policy_remove_tree() { printf 'WRITE:remove-policy\n' >> "$events"; }
    systemctl() { printf 'WRITE:systemctl\n' >> "$events"; }
    restore_unit_state() { printf 'WRITE:restore-unit\n' >> "$events"; }

    expect_failure restore_baseline
    [[ ! -s "$events" ]] || fail "external-filter preflight allowed restore writes: $(<"$events")"
)

test_restore_preflight_rejects_mq_queue_drift_before_writes() (
    local root="$TEST_ROOT/restore-mq-preflight" events="$TEST_ROOT/restore-mq-preflight.events"
    BASELINE_DIR="$root/baseline"
    NIC_STATE_DIR="$root/interfaces"
    BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    : > "$events"
    mkdir -p "$BASELINE_DIR" "$NIC_STATE_DIR/eth0" "$NIC_STATE_DIR/eth1"
    mkdir -p "$BBRV3_SYS_CLASS_NET_ROOT/eth1/queues/tx-0" \
        "$BBRV3_SYS_CLASS_NET_ROOT/eth1/queues/tx-1" \
        "$BBRV3_SYS_CLASS_NET_ROOT/eth1/queues/tx-2"
    printf 'SOURCE\tglobal\n' > "$NIC_STATE_DIR/eth0/manifest"
    printf 'SOURCE\tsnapshot\n' > "$NIC_STATE_DIR/eth1/manifest"
    printf '%s\n' \
        $'KIND\tmq' \
        $'RATE\t' \
        $'ARGS\t' \
        'qdisc mq 8003: root' \
        'qdisc fq 8004: parent 8003:1 limit 10000p' \
        'qdisc fq 8005: parent 8003:2 limit 10000p' \
        'class mq :1 root leaf 8004:' \
        'class mq :2 root leaf 8005:' > "$NIC_STATE_DIR/eth1/qdisc.snapshot"

    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { :; }
    tcp_baseline_validate() {
        TCP_BASELINE_VALIDATED_PROVENANCE=native
        TCP_BASELINE_VALIDATED_INTERFACE=eth0
        TCP_BASELINE_VALIDATED_GENERATION=v2
    }
    tcp_restore_runtime_preflight() { :; }
    nic_policy_layout_state() { printf 'managed\n'; }
    nic_policy_set_validate() { :; }
    nic_policy_interface_list() { printf 'eth0\neth1\n'; }
    nic_baseline_validate() { :; }
    nic_interface_exists() { :; }
    nic_baseline_identity_validate() { :; }
    tc() {
        case "$*" in
            'qdisc show dev eth0'|'qdisc show dev eth1') printf 'qdisc fq 123: root\n' ;;
            'class show dev eth0'|'class show dev eth1') : ;;
            'filter show dev eth0 parent 123:'|'filter show dev eth1 parent 123:') : ;;
            *) fail "unexpected MQ restore-preflight tc invocation: $*" ;;
        esac
    }

    remove_persistence() { printf 'WRITE:remove-persistence\n' >> "$events"; }
    nic_restore_secondary_baselines() { printf 'WRITE:restore-secondary\n' >> "$events"; }
    restore_backed_path() { printf 'WRITE:restore-path\n' >> "$events"; }
    restore_runtime_sysctls() { printf 'WRITE:restore-sysctl\n' >> "$events"; }
    restore_baseline_route_windows() { printf 'WRITE:restore-routes\n' >> "$events"; }
    restore_baseline_qdisc() { printf 'WRITE:restore-qdisc\n' >> "$events"; }
    nic_policy_remove_tree() { printf 'WRITE:remove-policy\n' >> "$events"; }
    systemctl() { printf 'WRITE:systemctl\n' >> "$events"; }
    restore_unit_state() { printf 'WRITE:restore-unit\n' >> "$events"; }

    expect_failure restore_baseline
    [[ ! -s "$events" ]] || fail "MQ queue-drift preflight allowed restore writes: $(<"$events")"
)

test_apply_failure_rolls_back_every_interface_and_global_runtime() (
    local events="$TEST_ROOT/apply-events"
    : > "$events"
    nic_sync_global_model
    MULTI_NIC_ENABLED=1
    event() { printf '%s\n' "$*" >> "$events"; }
    managed_htb_interfaces_strict() { :; }
    qdisc_guard() { :; }
    qdisc_filter_guard() { :; }
    capture_runtime_sysctls() {
        local key
        while IFS= read -r key; do printf '%s\t%s\n' "$key" "$(nic_test_sysctl_value "$key")"; done < <(tcp_baseline_sysctl_keys)
    }
    action_qdisc_snapshot() {
        event "snapshot:$1"
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    apply_sysctl_profile() { [[ "$1" == runtime ]] || return 1; event apply-sysctl; }
    apply_fq() { event "apply-fq:$1"; }
    apply_shaping() { event "apply-shape:$1:$2"; [[ "$1" != eth2 ]]; }
    apply_initial_windows() { event apply-routes; }
    sysctl() { event "restore-sysctl:$*"; }
    restore_default_route_windows_snapshot() { event restore-routes; }
    restore_action_qdisc() { event "restore-qdisc:$1"; }
    ip() { return 0; }

    expect_failure nic_apply_runtime_policies
    for iface in eth0 eth1 eth2; do
        grep -Fxq "snapshot:$iface" "$events" || fail "missing qdisc snapshot for $iface"
        grep -Fxq "restore-qdisc:$iface" "$events" || fail "missing qdisc rollback for $iface"
    done
    grep -Fq 'restore-sysctl:-q -w net.core.somaxconn=4096' "$events" || fail "sysctl rollback missing"
    grep -Fxq restore-routes "$events" || fail "route-window rollback missing"
    if grep -Fxq apply-routes "$events"; then fail "route mutation continued after qdisc failure"; fi
)

test_apply_rollback_failure_preserves_snapshot() (
    local events="$TEST_ROOT/apply-rollback-failure.events" output_file="$TEST_ROOT/apply-rollback-failure.output" output snapshot_dir rollback_fail=1
    : > "$events"
    NIC_RUNTIME_TRANSACTION_DIR=""
    NIC_RUNTIME_TRANSACTION_PARENT=""
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    nic_sync_global_model
    MULTI_NIC_ENABLED=1
    managed_htb_interfaces_strict() { :; }
    qdisc_guard() { :; }
    qdisc_filter_guard() { :; }
    capture_runtime_sysctls() {
        local key
        while IFS= read -r key; do printf '%s\t%s\n' "$key" "$(nic_test_sysctl_value "$key")"; done < <(tcp_baseline_sysctl_keys)
    }
    action_qdisc_snapshot() {
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    apply_sysctl_profile() { [[ "$1" == runtime ]]; }
    apply_fq() { :; }
    apply_shaping() { [[ "$1" != eth2 ]]; }
    apply_initial_windows() { :; }
    nic_restore_runtime_snapshot() { printf 'restore-runtime\n' >> "$events"; }
    restore_action_qdisc() {
        printf 'restore-qdisc:%s\n' "$1" >> "$events"
        [[ "$rollback_fail" == 0 || "$1" != eth0 ]]
    }
    ip() { return 0; }

    if nic_apply_runtime_policies > "$output_file" 2>&1; then
        fail "multi-NIC apply reported success after an injected mutation failure"
    fi
    output=$(<"$output_file")
    grep -Fq '回滚不完整' <<< "$output" || fail "rollback failure was reported as fully restored: $output"
    [[ "$output" != *'已恢复本轮'* ]] || fail "rollback failure used a false restored message: $output"
    snapshot_dir="$NIC_RUNTIME_TRANSACTION_DIR"
    [[ -n "$snapshot_dir" && -d "$snapshot_dir" && -f "$snapshot_dir/sysctl.tsv" ]] ||
        fail "rollback failure destroyed its runtime snapshot"
    for iface in eth0 eth1 eth2; do
        [[ -f "$snapshot_dir/$iface.snapshot" ]] || fail "rollback failure lost $iface qdisc snapshot"
    done
    [[ -f "$snapshot_dir/interfaces.list" ]] || fail "rollback failure lost the stable interface manifest"
    assert_eq $'eth0\neth1\neth2' "$(<"$snapshot_dir/interfaces.list")" "runtime interface manifest"

    rollback_fail=0
    nic_runtime_transaction_rollback || fail "retained multi-NIC snapshot could not be retried"
    [[ -z "$NIC_RUNTIME_TRANSACTION_DIR" && ! -e "$snapshot_dir" ]] ||
        fail "successful rollback retry did not clear the retained transaction"
)

test_runtime_transaction_rejects_late_filter_before_global_writes() (
    local root="$TEST_ROOT/runtime-late-filter" events="$TEST_ROOT/runtime-late-filter.events"
    local late_filter=0 snapshot_dir iface interfaces=$'eth0\neth1'
    mkdir -p "$root"
    : > "$events"
    NIC_RUNTIME_TRANSACTION_DIR=""
    NIC_RUNTIME_TRANSACTION_PARENT=""
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
    NIC_RUNTIME_TRANSACTION_READY=0

    capture_runtime_sysctls() {
        local key
        while IFS= read -r key; do
            printf '%s\t%s\n' "$key" "$(nic_test_sysctl_value "$key")"
        done < <(tcp_baseline_sysctl_keys)
    }
    ip() {
        case "$*" in
            '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
            '-6 route show default') : ;;
            *) return 1 ;;
        esac
    }
    qdisc_filter_guard() {
        [[ "$1" != eth1 || "$late_filter" == 0 ]]
    }
    nic_restore_runtime_snapshot() { printf 'WRITE:runtime\n' >> "$events"; }
    restore_action_qdisc() { printf 'WRITE:qdisc:%s\n' "$1" >> "$events"; }

    nic_runtime_transaction_begin "$root" || fail "could not create late-filter NIC transaction"
    snapshot_dir="$NIC_RUNTIME_TRANSACTION_DIR"
    capture_runtime_sysctls > "$snapshot_dir/sysctl.tsv"
    ip -4 route show default > "$snapshot_dir/default-route-v4.txt"
    ip -6 route show default > "$snapshot_dir/default-route-v6.txt"
    for iface in eth0 eth1; do
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$snapshot_dir/$iface.snapshot"
    done
    nic_runtime_transaction_write_interfaces "$interfaces" || fail "could not write NIC transaction interface manifest"
    nic_runtime_transaction_mark_mutated || fail "valid NIC transaction was not marked mutable"

    late_filter=1
    if nic_runtime_transaction_rollback >/dev/null 2>&1; then
        fail "NIC rollback accepted a root-tree filter added after mutation began"
    fi
    [[ ! -s "$events" ]] || fail "late NIC filter allowed rollback writes: $(<"$events")"
    [[ "$NIC_RUNTIME_TRANSACTION_DIR" == "$snapshot_dir" && -d "$snapshot_dir" && -f "$snapshot_dir/COMPLETE" ]] ||
        fail "late NIC filter did not retain the runtime transaction evidence"

    late_filter=0
    nic_runtime_transaction_rollback || fail "NIC rollback could not be retried after the external filter was removed"
    assert_eq $'WRITE:runtime\nWRITE:qdisc:eth0\nWRITE:qdisc:eth1' "$(<"$events")" "retry rollback order"
    [[ -z "$NIC_RUNTIME_TRANSACTION_DIR" && ! -e "$snapshot_dir" ]] ||
        fail "successful late-filter rollback retry did not clear the transaction"
)

test_snapshot_failure_is_write_free() (
    local events="$TEST_ROOT/snapshot-events"
    : > "$events"
    nic_sync_global_model
    MULTI_NIC_ENABLED=1
    managed_htb_interfaces_strict() { :; }
    qdisc_guard() { :; }
    capture_runtime_sysctls() {
        local key
        while IFS= read -r key; do printf '%s\t%s\n' "$key" "$(nic_test_sysctl_value "$key")"; done < <(tcp_baseline_sysctl_keys)
    }
    action_qdisc_snapshot() {
        printf 'snapshot:%s\n' "$1" >> "$events"
        [[ "$1" != eth1 ]] || return 1
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    apply_sysctl_profile() { printf 'WRITE:sysctl\n' >> "$events"; }
    restore_action_qdisc() { printf 'WRITE:qdisc\n' >> "$events"; }
    nic_restore_runtime_snapshot() { printf 'WRITE:runtime\n' >> "$events"; }
    ip() { return 0; }
    expect_failure nic_apply_runtime_policies
    if grep -Fq 'WRITE:' "$events"; then fail "snapshot-stage failure performed runtime writes"; fi
)

test_policy_enumerator_failure_is_write_free() (
    local events="$TEST_ROOT/policy-enumerator-failure.events" valid_policy
    : > "$events"
    valid_policy=$(nic_policy_path eth0)
    MULTI_NIC_ENABLED=1
    NIC_RUNTIME_TRANSACTION_DIR=""
    NIC_RUNTIME_TRANSACTION_PARENT=""
    NIC_RUNTIME_TRANSACTION_MUTATED=0
    NIC_RUNTIME_TRANSACTION_READY=0

    # The valid prefix must remain hidden when the producer ultimately fails.
    nic_policy_files() {
        printf '%s\n' "$valid_policy"
        return 9
    }
    expect_failure nic_policy_set_validate

    nic_runtime_transaction_begin() { printf 'WRITE:transaction-begin\n' >> "$events"; }
    capture_runtime_sysctls() { printf 'WRITE:sysctl-snapshot\n' >> "$events"; }
    action_qdisc_snapshot() { printf 'WRITE:qdisc-snapshot:%s\n' "$1" >> "$events"; }
    apply_sysctl_profile() { printf 'WRITE:sysctl\n' >> "$events"; }
    apply_fq() { printf 'WRITE:fq:%s\n' "$1" >> "$events"; }
    apply_shaping() { printf 'WRITE:shape:%s\n' "$1" >> "$events"; }
    apply_initial_windows() { printf 'WRITE:route-window\n' >> "$events"; }

    expect_failure nic_apply_runtime_policies
    [[ ! -s "$events" ]] || fail "partial policy enumeration reached transaction/runtime writes: $(<"$events")"
    [[ -z "$NIC_RUNTIME_TRANSACTION_DIR" ]] || fail "partial policy enumeration created a runtime transaction"
)

test_route_snapshot_failure_is_write_free() (
    local fail_family events snapshot_parent snapshot_dir
    for fail_family in 4 6; do
        events="$TEST_ROOT/route-snapshot-failure-$fail_family.events"
        : > "$events"
        NIC_RUNTIME_TRANSACTION_DIR=""
        NIC_RUNTIME_TRANSACTION_PARENT=""
        NIC_RUNTIME_TRANSACTION_MUTATED=0
        NIC_RUNTIME_TRANSACTION_ROLLING_BACK=0
        nic_sync_global_model
        MULTI_NIC_ENABLED=1
        managed_htb_interfaces_strict() { :; }
        qdisc_guard() { :; }
        capture_runtime_sysctls() {
            local key
            while IFS= read -r key; do printf '%s\t%s\n' "$key" "$(nic_test_sysctl_value "$key")"; done < <(tcp_baseline_sysctl_keys)
        }
        ip() {
            case "$*" in
                '-4 route show default')
                    [[ "$fail_family" != 4 ]] || return 1
                    printf 'default via 192.0.2.1 dev eth0\n'
                    ;;
                '-6 route show default') [[ "$fail_family" != 6 ]] ;;
                *) return 1 ;;
            esac
        }
        action_qdisc_snapshot() { printf 'WRITE:qdisc-snapshot\n' >> "$events"; }
        apply_sysctl_profile() { printf 'WRITE:sysctl\n' >> "$events"; }
        apply_fq() { printf 'WRITE:fq\n' >> "$events"; }
        apply_shaping() { printf 'WRITE:shape\n' >> "$events"; }
        apply_initial_windows() { printf 'WRITE:route-window\n' >> "$events"; }
        restore_action_qdisc() { printf 'WRITE:restore-qdisc\n' >> "$events"; }
        nic_restore_runtime_snapshot() { printf 'WRITE:restore-runtime\n' >> "$events"; }

        expect_failure nic_apply_runtime_policies
        [[ ! -s "$events" ]] || fail "IPv$fail_family route snapshot failure allowed runtime/qdisc work: $(<"$events")"
        [[ -z "$NIC_RUNTIME_TRANSACTION_DIR" ]] || fail "IPv$fail_family route failure retained an otherwise removable transaction"
        snapshot_parent="${TMPDIR:-/tmp}"
        snapshot_dir=$(find "$snapshot_parent" -maxdepth 1 -type d -name "${SCRIPT_NAME}.multi-nic.*" -print -quit 2>/dev/null || true)
        [[ -z "$snapshot_dir" ]] || fail "IPv$fail_family route failure left a temporary transaction: $snapshot_dir"
    done
)

test_multi_transaction_snapshots_policy_and_legacy_interfaces() (
    local events="$TEST_ROOT/transaction-events"
    : > "$events"
    action_transaction_begin() {
        ACTION_TRANSACTION_DIR="$STATE_DIR/.transaction.mock"
        ACTION_TRANSACTION_IFACE="$1"
        ACTION_TRANSACTION_INTERFACES="$1"
        mkdir -p "$ACTION_TRANSACTION_DIR/qdiscs"
        printf '%s\n' "$1" >> "$events"
    }
    action_qdisc_snapshot() {
        printf '%s\n' "$1" >> "$events"
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    action_transaction_rollback() { fail "unexpected transaction rollback"; }
    MULTI_NIC_ENABLED=0
    TC_INTERFACE=eth3
    action_transaction_begin_multi eth0
    for iface in eth0 eth1 eth2 eth3; do
        assert_eq 1 "$(grep -Fxc "$iface" "$events")" "transaction snapshot count for $iface"
    done
    action_transaction_discard_snapshot
)

test_multi_transaction_snapshot_failure_is_write_free() (
    local writes="$TEST_ROOT/transaction-failure-writes"
    : > "$writes"
    action_transaction_begin() {
        ACTION_TRANSACTION_DIR="$STATE_DIR/.transaction.mock-failure"
        ACTION_TRANSACTION_IFACE="$1"
        ACTION_TRANSACTION_INTERFACES="$1"
        mkdir -p "$ACTION_TRANSACTION_DIR/qdiscs"
    }
    action_qdisc_snapshot() {
        [[ "$1" != eth2 ]] || return 1
        printf 'KIND\tnoqueue\nRATE\t\nARGS\t\nqdisc noqueue 0: root\n' > "$2"
    }
    action_transaction_rollback() { printf 'WRITE:rollback\n' >> "$writes"; }
    MULTI_NIC_ENABLED=1
    TC_INTERFACE=auto
    expect_failure action_transaction_begin_multi eth0
    [[ ! -e "$STATE_DIR/.transaction.mock-failure" ]] || fail "failed transaction snapshot was not discarded"
    [[ ! -s "$writes" ]] || fail "snapshot failure invoked mutating rollback"
)

test_legacy_single_nic_migration() (
    NIC_POLICY_DIR="$TEST_ROOT/legacy/etc/interfaces.d"
    NIC_STATE_DIR="$TEST_ROOT/legacy/state/interfaces"
    MULTI_NIC_ENABLED=0
    TC_ENABLED=1
    TC_INTERFACE=eth0
    TC_RATE_MBIT=321
    TC_KNEE_MBIT=340
    TC_MARGIN_PERCENT=4
    SYSCTL_PROFILE=adaptive
    ROLE=mixed
    BANDWIDTH_MBIT=330
    RTT_MS=100
    nic_baseline_capture() { :; }
    managed_htb() { [[ "$1" == eth0 ]]; }
    managed_rate_mbit() { printf '321\n'; }
    nic_migrate_legacy_policy
    nic_policy_load_file "$(nic_policy_path eth0)"
    assert_eq shape "$NIC_POLICY_MODE" "legacy migration mode"
    assert_eq 321 "$NIC_POLICY_RATE_MBIT" "legacy migration rate"
    assert_eq 340 "$NIC_POLICY_KNEE_MBIT" "legacy migration knee"
)

test_legacy_delegate_restores_v8_interfaces_first() (
    local events="" BASELINE_DIR="$TEST_ROOT/delegated-baseline" LEGACY_BACKUP_DIR="$TEST_ROOT/delegated-original"
    mkdir -p "$BASELINE_DIR" "$LEGACY_BACKUP_DIR"
    : > "$BASELINE_DIR/legacy-tool.sh"
    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { events+=" acquire"; }
    tcp_baseline_validate() {
        TCP_BASELINE_VALIDATED_PROVENANCE=legacy-reference
        TCP_BASELINE_VALIDATED_INTERFACE=eth0
        TCP_BASELINE_VALIDATED_GENERATION=legacy-reference
    }
    tcp_restore_runtime_preflight() { :; }
    nic_restore_preflight() { :; }
    remove_persistence() { events+=" persistence"; }
    nic_restore_secondary_baselines() { events+=" nic"; }
    release_lock() { events+=" release"; }
    bash() { events+=" delegate"; }
    nic_policy_remove_tree() { events+=" policy"; }
    restore_baseline
    assert_eq ' acquire persistence nic release delegate acquire policy' "$events" "delegated restore order"
)

test_cli_contract() {
    local captured=""
    nic_manage() { captured="$*"; }
    apply_configured_state() { captured=apply-configured-state; }
    cmd_nic manage --interface eth0 --mode shape --rate 100 --knee 110 --margin 4 --profile adaptive --role proxy --bandwidth 120 --rtt 80
    assert_eq 'eth0 shape 100 110 4 adaptive proxy 120 80' "$captured" "nic manage CLI mapping"
    captured=""
    cmd_nic apply
    assert_eq apply-configured-state "$captured" "nic apply uses the canonical persistence entry"
    expect_failure cmd_nic apply ignored
    expect_failure cmd_nic manage --interface eth0 --mode fq --rate 10
    expect_failure cmd_nic manage --interface auto --mode fq
    expect_failure cmd_nic manage --interface eth0 --mode shape --rate 100 --unknown value
}

for test_name in \
    test_strict_policy_layout_and_identity \
    test_immutable_baseline_rejects_reused_interface_identity \
    test_global_model_and_config_invariants \
    test_auto_stage_uses_global_aggregate_but_persists_target_model \
    test_tc_enable_does_not_copy_another_nic_global_model \
    test_read_only_plan_includes_aggregate_effect \
    test_ownership_gate \
    test_restore_preflight_rejects_external_filter_before_writes \
    test_restore_preflight_rejects_mq_queue_drift_before_writes \
    test_apply_failure_rolls_back_every_interface_and_global_runtime \
    test_apply_rollback_failure_preserves_snapshot \
    test_runtime_transaction_rejects_late_filter_before_global_writes \
    test_snapshot_failure_is_write_free \
    test_policy_enumerator_failure_is_write_free \
    test_route_snapshot_failure_is_write_free \
    test_multi_transaction_snapshots_policy_and_legacy_interfaces \
    test_multi_transaction_snapshot_failure_is_write_free \
    test_legacy_single_nic_migration \
    test_legacy_delegate_restores_v8_interfaces_first \
    test_cli_contract; do
    printf '==> %s\n' "$test_name"
    "$test_name"
done

printf 'multi-NIC v8.0.0 tests: OK\n'
