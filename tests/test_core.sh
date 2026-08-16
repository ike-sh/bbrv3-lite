#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_CONFIG="$TEST_ROOT/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_PERSIST_DIR="$TEST_ROOT/persist"
export BBRV3_PERSIST_SCRIPT="$TEST_ROOT/persist/net-tcp-tune.sh"
export BBRV3_SERVICE_FILE="$TEST_ROOT/systemd/bbrv3-lite.service"
export BBRV3_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite.conf"
export BBRV3_LEGACY_SYSCTL_FILE="$TEST_ROOT/etc/99-bbr-ultimate.conf"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_file_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain: $2"; }

test_config_parser() {
    local marker="$TEST_ROOT/injected"
    reset_config
    SYSCTL_PROFILE=adaptive; ROLE=proxy; BANDWIDTH_MBIT=500; RTT_MS=180
    TC_ENABLED=1; TC_INTERFACE=eth0; TC_RATE_MBIT=420; TC_KNEE_MBIT=450; TC_MARGIN_PERCENT=3
    save_config
    reset_config; load_config
    assert_eq adaptive "$SYSCTL_PROFILE" "profile round-trip"
    assert_eq 420 "$TC_RATE_MBIT" "TC rate round-trip"
    assert_eq 450 "$TC_KNEE_MBIT" "knee round-trip"

    printf 'TC_RATE_MBIT=$(touch %s)\n' "$marker" > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    if load_config >/dev/null 2>&1; then fail "malicious config accepted"; fi
    [[ ! -e "$marker" ]] || fail "config content executed"
}

test_legacy_migration() {
    cat > "$CONFIG_FILE" <<'EOF'
BBR_ENABLED=1
DEFAULT_QDISC=fq
TC_ENABLED=1
TC_INTERFACE=eth0
TC_RATE_MBIT=315
TC_BASELINE_MBIT=350
TC_PERCENT=90
INITCWND=0
INITRWND=0
SYSCTL_PROFILE=balanced-minimal
EOF
    chmod 0600 "$CONFIG_FILE"
    migrate_legacy_config
    load_config
    assert_eq balanced "$SYSCTL_PROFILE" "legacy profile migration"
    assert_eq 350 "$BANDWIDTH_MBIT" "legacy baseline migration"
    assert_eq 10 "$TC_MARGIN_PERCENT" "legacy percent migration"
}

test_profile_math() {
    buffer_profile_values balanced mixed 0 0
    assert_eq 16777216 "$BUFFER_MAX" "balanced buffer"
    buffer_profile_values adaptive proxy 500 200
    (( BUFFER_MAX >= 4194304 )) || fail "adaptive buffer below floor"
    (( BUFFER_MAX <= 268435456 )) || fail "adaptive buffer above absolute cap"
    local burst hz minimum
    burst=$(calc_htb_burst 100 1500)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    minimum=$((100 * 1000000 / 8 / hz))
    (( burst >= minimum )) || fail "HTB burst smaller than rate/HZ"
}

test_legacy_baseline_reference() {
    rm -rf "$BASELINE_DIR" "$LEGACY_BACKUP_DIR" "$PERSIST_DIR"
    mkdir -p "$LEGACY_BACKUP_DIR" "$PERSIST_DIR"
    printf 'old-original\n' > "$LEGACY_BACKUP_DIR/marker"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$PERSIST_SCRIPT"
    chmod 0755 "$PERSIST_SCRIPT"
    printf 'legacy\n' > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    sysctl() { [[ "$1" == -n ]] && printf 'value\n' || true; }
    tc() { [[ "$1 $2 $3 $4" == 'qdisc show dev eth0' ]] && echo 'qdisc fq 0: root refcnt 2' || true; }
    capture_baseline eth0
    assert_eq legacy-reference "$(baseline_provenance)" "legacy baseline provenance"
    [[ -f "$BASELINE_DIR/legacy-original/marker" ]] || fail "legacy original not preserved"
    [[ -x "$BASELINE_DIR/legacy-tool.sh" ]] || fail "legacy restore tool not preserved"
    rm -rf "$BASELINE_DIR" "$LEGACY_BACKUP_DIR" "$PERSIST_DIR"
}

test_tc_transaction() {
    local MOCK_ROOT=fq MOCK_CLASS=0 MOCK_LEAF=0 MOCK_RATE=0 MOCK_FAIL_LEAF=0
    tc_dependencies() { :; }
    qdisc_guard() { [[ "$MOCK_ROOT" != cake ]]; }
    detect_mtu() { echo 1500; }
    tc() {
        case "$*" in
            'qdisc show dev eth0')
                case "$MOCK_ROOT" in
                    fq) echo 'qdisc fq 0: root refcnt 2' ;;
                    cake) echo 'qdisc cake 8001: root refcnt 2 bandwidth 1Gbit' ;;
                    htb) echo 'qdisc htb 1: root refcnt 2 default 0x10'; ((MOCK_LEAF)) && echo 'qdisc fq 10: parent 1:10 limit 10000p' ;;
                esac ;;
            'class show dev eth0') ((MOCK_CLASS)) && echo "class htb 1:10 root rate ${MOCK_RATE}Mbit ceil ${MOCK_RATE}Mbit" || true ;;
            'qdisc replace dev eth0 root handle 1: htb default 10') MOCK_ROOT=htb; MOCK_CLASS=0; MOCK_LEAF=0 ;;
            class\ replace\ dev\ eth0\ parent\ 1:\ classid\ 1:10\ htb*) MOCK_CLASS=1; MOCK_RATE=300 ;;
            'qdisc replace dev eth0 parent 1:10 handle 10: fq') ((MOCK_FAIL_LEAF==0)) || return 1; MOCK_LEAF=1 ;;
            'qdisc replace dev eth0 root fq') MOCK_ROOT=fq; MOCK_CLASS=0; MOCK_LEAF=0 ;;
            'qdisc del dev eth0 root') MOCK_ROOT=fq; MOCK_CLASS=0; MOCK_LEAF=0 ;;
            *) fail "unexpected tc invocation: $*" ;;
        esac
    }
    apply_shaping eth0 300
    assert_eq htb "$MOCK_ROOT" "HTB root"
    assert_eq 1 "$MOCK_CLASS" "HTB class"
    assert_eq 1 "$MOCK_LEAF" "FQ leaf"

    MOCK_ROOT=fq; MOCK_CLASS=0; MOCK_LEAF=0; MOCK_FAIL_LEAF=1
    if apply_shaping eth0 300; then fail "failed leaf reported success"; fi
    assert_eq fq "$MOCK_ROOT" "transaction rollback"

    MOCK_ROOT=cake; MOCK_FAIL_LEAF=0
    if qdisc_guard eth0; then fail "unknown qdisc accepted"; fi
}

test_measurement_math_and_history() {
    loss_spike 0.2 0.1 0.01 || fail "spike not detected"
    if loss_spike 0.05 0.1 0; then fail "clean sample marked spike"; fi
    if loss_spike 0.2 0.1 0.1; then fail "sample below 5x baseline marked spike"; fi
    new_measure_run sweep
    [[ -f "$MEASURE_RESULT_FILE" ]] || fail "measurement history not created"
    [[ "$MEASURE_RUN_DIR" == *-sweep ]] || fail "measurement directory label"
}

test_systemd_generation() {
    require_root() { :; }
    systemctl() { :; }
    current_script_path() { printf '%s\n' "$ROOT_DIR/net-tcp-tune.sh"; }
    reset_config; save_config
    install_persistence
    [[ -x "$PERSIST_SCRIPT" ]] || fail "persistent script not installed"
    assert_file_contains "$SERVICE_FILE" "ExecStart=$PERSIST_SCRIPT apply"
    assert_file_contains "$SERVICE_FILE" "ConditionPathExists=$CONFIG_FILE"
    if grep -Eq 'TC_RATE_MBIT|TC_INTERFACE' "$SERVICE_FILE"; then fail "parameters hard-coded into unit"; fi
}

test_cli_command_removal_is_scoped() {
    local old_home="$HOME" cli="$TEST_ROOT/bin/bbr" rc_file
    HOME="$TEST_ROOT/home"; rc_file="$HOME/.bashrc"
    mkdir -p "$(dirname "$cli")" "$HOME"
    cp "$ROOT_DIR/net-tcp-tune.sh" "$cli"; chmod 0755 "$cli"
    cat > "$rc_file" <<'EOF'
keep-before
# ================ net-tcp-tune 快捷别名 ================
bbr() { echo legacy; }
# ================ net-tcp-tune 快捷别名结束 ================
keep-after
EOF
    BBRV3_CLI_PATH="$cli"
    remove_cli_command
    [[ ! -e "$cli" ]] || fail "managed bbr command was not removed"
    grep -Fq keep-before "$rc_file" || fail "shell rc content before legacy block was lost"
    grep -Fq keep-after "$rc_file" || fail "shell rc content after legacy block was lost"
    if grep -Fq 'net-tcp-tune 快捷别名' "$rc_file"; then fail "legacy shell function block was not removed"; fi

    printf '#!/bin/sh\necho unrelated\n' > "$cli"; chmod 0755 "$cli"
    remove_cli_command
    [[ -e "$cli" ]] || fail "unrelated bbr command was removed"
    BBRV3_CLI_PATH=""; HOME="$old_home"
}

test_uninstall_restores_before_removal() {
    local events=""
    mkdir -p "$BASELINE_DIR" "$DNS_BACKUP_DIR/baseline" "$IPV6_BACKUP_DIR/baseline"
    : > "$BASELINE_DIR/manifest"; : > "$DNS_BACKUP_DIR/baseline/manifest"; : > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    require_root() { :; }; acquire_lock() { :; }
    restore_baseline() { events+=" tcp"; }
    dns_restore() { events+=" dns"; }
    ipv6_restore() { events+=" ipv6"; }
    remove_cli_command() { events+=" cli"; }
    uninstall_managed 0
    assert_eq ' tcp dns ipv6 cli' "$events" "uninstall restore/delete order"
}

test_menu_exits_after_uninstall_signal() {
    maintenance_menu() { return 90; }
    if menu_run maintenance_menu; then fail "menu ignored uninstall exit signal"; fi
}

test_peer_parser() {
    parse_peer_spec 'iperf.example.com:5202'
    assert_eq iperf.example.com "$PEER_HOST" "peer host parser"
    assert_eq 5202 "$PEER_PORT" "peer port parser"
    parse_peer_spec '[2001:db8::1]:5203'
    assert_eq '2001:db8::1' "$PEER_HOST" "IPv6 peer parser"
    assert_eq 5203 "$PEER_PORT" "IPv6 peer port parser"
    if parse_peer_spec 'bad peer:5201' >/dev/null 2>&1; then fail "unsafe peer accepted"; fi
}

test_process_substitution_source_resolution() {
    local downloaded="$TEST_ROOT/downloaded.sh" resolved
    rm -f -- "$PERSIST_SCRIPT"
    current_script_path() { return 1; }
    verified_download_current_script() { cp "$ROOT_DIR/net-tcp-tune.sh" "$1"; }
    resolved=$(resolve_install_source "$downloaded")
    assert_eq "$downloaded" "$resolved" "downloaded install source"
    [[ -f "$downloaded" ]] || fail "downloaded source not materialized"
}

test_sweep_without_knee_does_not_recommend_ceiling() {
    local summary
    require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
    peer_port_open() { :; }; detect_interface() { printf 'eth0\n'; }; qdisc_guard() { :; }
    measure_begin() { MEASURE_IFACE=eth0; }; measure_restore() { :; }; traffic_report() { :; }
    apply_fq() { :; }; apply_shaping() { :; }
    sample_repeated() {
        local label="$6" rate=100
        [[ "$label" =~ (rate|refine|confirm)-([0-9]+) ]] && rate="${BASH_REMATCH[2]}"
        printf '%s\t0\t1000000\t0.00000\n' "$rate"
    }
    measure_sweep example.com 5201 auto 100 80 130 10 3 1 3 0.1 1 5000
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq 1 "$(summary_value "$summary" NO_KNEE)" "no-knee marker"
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" "no-knee recommendation"
}

test_persistence_restart_hands_off_lock() {
    local events=""
    LOCK_HELD=1
    release_lock() { events+=" release"; LOCK_HELD=0; }
    acquire_lock() { events+=" acquire:${1:-0}"; LOCK_HELD=1; }
    systemctl() {
        case "$1" in
            restart) assert_eq 0 "$LOCK_HELD" "service restart while parent lock released"; events+=" restart" ;;
            is-enabled) events+=" enabled" ;;
            is-active) events+=" active" ;;
            *) fail "unexpected systemctl call: $*" ;;
        esac
    }
    restart_and_verify_persistence
    assert_eq ' release restart enabled active acquire:30' "$events" "persistence lock handoff order"
    assert_eq 1 "$LOCK_HELD" "parent lock reacquired"
}

test_dependency_install_is_minimal() {
    local apt_calls=""
    command_exists() { [[ "$1" != iperf3 && "$1" != jq ]]; }
    os_id() { printf 'debian\n'; }
    apt-get() { apt_calls+=" [$*]"; }
    install_measure_dependencies
    [[ "$apt_calls" == *'[update -qq]'* ]] || fail "apt update not called"
    [[ "$apt_calls" == *'[install -y --no-install-recommends iperf3 jq]'* ]] || fail "missing packages were not installed"
    [[ "$apt_calls" != *util-linux* && "$apt_calls" != *iproute2* ]] || fail "already-present packages were unnecessarily requested"
}

test_install_failure_is_not_success() {
    local output="$TEST_ROOT/install-failure.log"
    require_root() { :; }; acquire_lock() { :; }; require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }; capture_baseline() { :; }; migrate_legacy_config() { :; }
    load_config() { reset_config; }; apply_sysctl_profile() { :; }; apply_fq() { :; }; apply_initial_windows() { :; }
    save_config() { :; }; install_persistence() { return 9; }; systemctl() { fail "systemctl called after persistence failure"; }
    if install_base_tuning auto balanced mixed 0 0 >"$output" 2>&1; then fail "persistence failure reported success"; fi
    if grep -Fq '基础调优已安装' "$output"; then fail "success message printed after failure"; fi
    grep -Fq '持久化安装失败' "$output" || fail "partial-runtime failure was not explained"
}

test_config_parser
test_legacy_migration
test_profile_math
test_legacy_baseline_reference
test_tc_transaction
test_measurement_math_and_history
test_systemd_generation
test_cli_command_removal_is_scoped
test_uninstall_restores_before_removal
test_menu_exits_after_uninstall_signal
test_peer_parser
test_sweep_without_knee_does_not_recommend_ceiling
test_persistence_restart_hands_off_lock
test_dependency_install_is_minimal
test_process_substitution_source_resolution
test_install_failure_is_not_success
echo "core tests: OK"
