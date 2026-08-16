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
export BBRV3_DNS_BACKUP_DIR="$TEST_ROOT/state/dns"
export BBRV3_DNS_DROPIN="$TEST_ROOT/etc/resolved.conf.d/80-bbrv3-lite.conf"
export BBRV3_RESOLV_CONF="$TEST_ROOT/etc/resolv.conf"
export BBRV3_DNS_STUB_RESOLV="$TEST_ROOT/run/systemd/resolve/stub-resolv.conf"
export BBRV3_IPV6_BACKUP_DIR="$TEST_ROOT/state/ipv6"
export BBRV3_IPV6_SYSCTL_FILE="$TEST_ROOT/etc/99-bbrv3-lite-ipv6.conf"
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
    (( BUFFER_MAX >= 16777216 )) || fail "adaptive buffer below balanced floor"
    (( BUFFER_MAX <= 268435456 )) || fail "adaptive buffer above absolute cap"
    assert_eq 100 "$(recommended_tuning_rtt mixed 1)" "mixed tuning RTT floor"
    assert_eq 150 "$(recommended_tuning_rtt proxy 1)" "proxy tuning RTT floor"
    assert_eq 220 "$(recommended_tuning_rtt proxy 220)" "observed RTT above role floor"
    local burst capped
    detect_kernel_hz() { printf '250\n'; }
    burst=$(calc_htb_burst 100 1500)
    assert_eq 50000 "$burst" "HTB burst uses kernel HZ"
    capped=$(calc_htb_burst 1000000 1500)
    assert_eq 8388608 "$capped" "HTB burst absolute cap"
}

test_managed_sysctl_runtime_verifier() {
    (
        SYSCTL_PROFILE=adaptive; ROLE=proxy; BANDWIDTH_MBIT=500; RTT_MS=150
        buffer_profile_values "$SYSCTL_PROFILE" "$ROLE" "$BANDWIDTH_MBIT" "$RTT_MS"
        declare -A values=(
            [net.core.default_qdisc]=fq
            [net.ipv4.tcp_congestion_control]=bbr
            [net.core.rmem_max]="$BUFFER_MAX"
            [net.core.wmem_max]="$BUFFER_MAX"
            [net.ipv4.tcp_rmem]="4096 $BUFFER_R_DEFAULT $BUFFER_MAX"
            [net.ipv4.tcp_wmem]="4096 $BUFFER_W_DEFAULT $BUFFER_MAX"
            [net.ipv4.tcp_mtu_probing]=1
            [net.ipv4.tcp_fastopen]=3
            [net.core.somaxconn]=4096
            [net.core.netdev_max_backlog]=4096
        )
        sysctl() { [[ "$1" == -n && -n "${values[$2]+x}" ]] || return 1; printf '%s\n' "${values[$2]}"; }
        verify_sysctl_profile_runtime || fail "matching managed sysctls rejected"
        values[net.core.wmem_max]=1
        if verify_sysctl_profile_runtime >/dev/null 2>&1; then fail "mismatched managed sysctl accepted"; fi
    )
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

test_qdisc_replay_filters_kernel_runtime_fields() {
    local args
    tc() {
        [[ "$*" == 'qdisc show dev eth0' ]] || return 0
        echo 'qdisc fq 8001: root refcnt 2 limit 10000p flow_limit 100p bands 3 priomap 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 weights 589824 196608 65536 quantum 3028b horizon 10s horizon_drop'
    }
    args=$(root_qdisc_replay_args eth0)
    [[ "$args" == *'limit 10000'* && "$args" == *'flow_limit 100'* && "$args" == *'quantum 3028b'* ]] || fail "stable FQ arguments were not retained: $args"
    [[ "$args" != *bands* && "$args" != *priomap* && "$args" != *weights* ]] || fail "kernel runtime FQ fields were replayed: $args"
}

test_tc_transaction() {
    local MOCK_ROOT=fq MOCK_CLASS=0 MOCK_LEAF=0 MOCK_RATE=0 MOCK_FAIL_LEAF=0
    TC_SESSION_HTB_IFACE=""
    tc_dependencies() { :; }
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
            'qdisc replace dev eth0 root handle 1: htb default 10')
                [[ "$MOCK_ROOT" != htb ]] || return 95
                MOCK_ROOT=htb; MOCK_CLASS=0; MOCK_LEAF=0
                ;;
            class\ replace\ dev\ eth0\ parent\ 1:\ classid\ 1:10\ htb*)
                local arg next_is_rate=0
                MOCK_CLASS=1
                for arg in "$@"; do
                    if (( next_is_rate )); then MOCK_RATE="${arg%mbit}"; break; fi
                    [[ "$arg" == rate ]] && next_is_rate=1
                done
                ;;
            'qdisc replace dev eth0 parent 1:10 handle 10: fq') ((MOCK_FAIL_LEAF==0)) || return 1; MOCK_LEAF=1 ;;
            'qdisc replace dev eth0 root fq') MOCK_ROOT=fq; MOCK_CLASS=0; MOCK_LEAF=0 ;;
            'qdisc del dev eth0 root') MOCK_ROOT=fq; MOCK_CLASS=0; MOCK_LEAF=0 ;;
            *) fail "unexpected tc invocation: $*" ;;
        esac
        return 0
    }
    apply_shaping eth0 300
    assert_eq htb "$MOCK_ROOT" "HTB root"
    assert_eq 1 "$MOCK_CLASS" "HTB class"
    assert_eq 1 "$MOCK_LEAF" "FQ leaf"

    apply_shaping eth0 320
    assert_eq htb "$MOCK_ROOT" "HTB root after in-place rate update"
    assert_eq 320 "$MOCK_RATE" "in-place HTB class rate update"
    assert_eq 1 "$MOCK_LEAF" "FQ leaf after in-place rate update"

    MOCK_LEAF=0
    apply_shaping eth0 340
    assert_eq 340 "$MOCK_RATE" "session-owned HTB class repair rate"
    assert_eq 1 "$MOCK_LEAF" "session-owned FQ leaf repair"

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

test_baseline_captures_persistence_lifecycle() {
    (
        local lifecycle_root="$TEST_ROOT/lifecycle" events=""
        STATE_DIR="$lifecycle_root/state"; BASELINE_DIR="$STATE_DIR/baseline"; HISTORY_DIR="$STATE_DIR/history"
        CONFIG_FILE="$lifecycle_root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$lifecycle_root/etc/99-bbrv3-lite.conf"
        LEGACY_SYSCTL_FILE="$lifecycle_root/etc/legacy.conf"; SERVICE_FILE="$lifecycle_root/systemd/bbrv3-lite.service"
        LEGACY_SERVICE_FILE="$lifecycle_root/systemd/legacy.service"; PERSIST_DIR="$lifecycle_root/persist"
        PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; LEGACY_BACKUP_DIR="$lifecycle_root/legacy-backup"
        mkdir -p "$PERSIST_DIR"
        cp "$ROOT_DIR/net-tcp-tune.sh" "$PERSIST_SCRIPT"; chmod 0755 "$PERSIST_SCRIPT"
        sysctl() { [[ "$1" == -n ]] && printf '1\n'; }
        tc() { [[ "$1 $2 $3 $4" == 'qdisc show dev eth0' ]] && printf 'qdisc fq 0: root\n'; }
        ip() { :; }
        systemctl() {
            case "$1:$2" in
                is-enabled:bbrv3-lite.service) printf 'enabled\n' ;;
                is-active:bbrv3-lite.service) printf 'active\n' ;;
                is-enabled:*|is-active:*) printf 'inactive\n'; return 1 ;;
                *) events+=" $1:$2" ;;
            esac
        }
        capture_baseline eth0 adopt-current
        assert_eq present "$(<"$BASELINE_DIR/persist-script.state")" "persistent script baseline state"
        cmp -s "$PERSIST_SCRIPT" "$BASELINE_DIR/persist-script" || fail "persistent script content not captured"
        assert_eq $'enabled\tactive' "$(<"$BASELINE_DIR/service.unit")" "service lifecycle baseline"

        rm -rf -- "$PERSIST_DIR"
        restore_backed_path "$PERSIST_SCRIPT" persist-script
        [[ -x "$PERSIST_SCRIPT" ]] || fail "persistent script parent/content not restored"
        restore_unit_state "$SERVICE_NAME" "$BASELINE_DIR/service.unit"
        [[ "$events" == *' enable:bbrv3-lite.service'* && "$events" == *' start:bbrv3-lite.service'* ]] ||
            fail "service enabled/active state not restored: $events"
    )
}

test_persistent_artifact_consistency_verifier() {
    (
        local verify_root="$TEST_ROOT/persistence-verify"
        CONFIG_FILE="$verify_root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$verify_root/etc/99-bbrv3-lite.conf"
        SERVICE_FILE="$verify_root/systemd/bbrv3-lite.service"; PERSIST_DIR="$verify_root/persist"
        PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
        mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR"
        reset_config; save_config
        render_sysctl_profile > "$SYSCTL_FILE"
        cp "$ROOT_DIR/net-tcp-tune.sh" "$PERSIST_SCRIPT"; chmod 0755 "$PERSIST_SCRIPT"
        printf '[Service]\nExecStart=%s apply\n' "$PERSIST_SCRIPT" > "$SERVICE_FILE"
        current_script_path() { printf '%s\n' "$ROOT_DIR/net-tcp-tune.sh"; }
        verify_persistence_artifacts || fail "matching persistent artifacts rejected"
        printf '# drift\n' >> "$SYSCTL_FILE"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "drifted sysctl file accepted"; fi
        render_sysctl_profile > "$SYSCTL_FILE"
        printf '# local drift\n' >> "$PERSIST_SCRIPT"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "drifted persistence script accepted"; fi
    )
}

test_self_update_rolls_back_split_install() {
    (
        local update_root="$TEST_ROOT/self-update" installed_path candidate output_path="" url="" update_output="" fail_persist=1
        mkdir -p "$update_root"
        installed_path="$update_root/bbr"; candidate="$update_root/new.sh"; PERSIST_SCRIPT="$update_root/persist.sh"
        printf '#!/usr/bin/env bash\nSCRIPT_VERSION="7.0.6"\nSCRIPT_NAME="bbrv3-lite"\nprintf old\\n\n' > "$installed_path"
        cp "$installed_path" "$PERSIST_SCRIPT"; chmod 0755 "$installed_path" "$PERSIST_SCRIPT"
        printf '#!/usr/bin/env bash\nSCRIPT_VERSION="7.0.8"\nSCRIPT_NAME="bbrv3-lite"\nprintf new\\n\n' > "$candidate"
        require_root() { :; }; acquire_lock() { :; }; require_commands() { :; }
        current_script_path() { printf '%s\n' "$installed_path"; }
        curl() {
            output_path=""; url=""
            while (($#)); do
                case "$1" in
                    -o) output_path="$2"; shift 2 ;;
                    --connect-timeout|--max-time) shift 2 ;;
                    -*) shift ;;
                    *) url="$1"; shift ;;
                esac
            done
            case "$url" in
                */releases/latest) printf '{"tag_name":"v7.0.8"}\n' ;;
                */net-tcp-tune.sh) cp "$candidate" "$output_path" ;;
                */SHA256SUMS)
                    printf '%s  net-tcp-tune.sh\n' "$(sha256sum "$candidate" | awk '{print $1}')" > "$output_path"
                    ;;
                *) return 1 ;;
            esac
        }
        atomic_install() {
            local source="$1" target="$2"
            [[ "$target" != "$PERSIST_SCRIPT" || "$fail_persist" == 0 ]] || return 9
            cp "$source" "$target"; chmod 0755 "$target"
        }
        if update_output=$(self_update 2>&1); then fail "split self-update failure reported success"; fi
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$installed_path" || fail "current command was not rolled back"
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$PERSIST_SCRIPT" || fail "persistent copy changed after failed update"
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$installed_path.previous" || fail "previous-version backup missing: $update_output"

        fail_persist=0
        self_update >/dev/null
        grep -Fq 'SCRIPT_VERSION="7.0.8"' "$installed_path" || fail "successful update did not replace current command"
        grep -Fq 'SCRIPT_VERSION="7.0.8"' "$PERSIST_SCRIPT" || fail "successful update did not synchronize persistent copy"
    )
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

test_submenu_stays_until_explicit_return() {
    local output count
    dns_status() { printf 'dns-ok\n'; }
    output=$(dns_menu <<< $'1\n0\n')
    count=$(grep -c '^DNS 管理$' <<< "$output")
    assert_eq 2 "$count" "submenu render count"
    grep -Fq dns-ok <<< "$output" || fail "submenu action did not run"
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

test_public_peer_requires_real_iperf_preflight() {
    peer_port_open() { :; }
    iperf_peer_usable() { [[ "$2" == 5203 ]]; }
    assert_eq 5203 "$(public_peer_port example.com)" "public iperf preflight"
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

test_refine_preserves_throughput_stall_and_confirmation_gate() {
    local summary
    MOCK_CONFIRM_FAIL=0
    sample_repeated() {
        local label="$6" rate goodput loss=0
        if [[ "$label" == unshaped ]]; then
            printf '300\t0\t1000000\t0.00000\n'
            return
        fi
        [[ "$label" =~ (rate|refine|confirm)-([0-9]+) ]] || fail "unexpected sample label: $label"
        rate="${BASH_REMATCH[2]}"
        if (( rate <= 300 )); then goodput=$(awk -v r="$rate" 'BEGIN {printf "%.2f", r*0.96}'); else goodput=288.00; fi
        [[ "$label" != confirm-* || "$MOCK_CONFIRM_FAIL" == 0 ]] || loss=1.00000
        printf '%s\t0\t1000000\t%s\n' "$goodput" "$loss"
    }
    measure_sweep example.com 5201 auto 300 240 360 15 3 1 3 0.1 0 5000
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq 306 "$(summary_value "$summary" LAST_OK)" "fine scan last clean"
    assert_eq 309 "$(summary_value "$summary" BROKE_AT)" "fine scan throughput break"
    assert_eq 296 "$(summary_value "$summary" RECOMMEND)" "confirmed recommendation"
    assert_eq 1 "$(summary_value "$summary" CONFIRMED)" "confirmation marker"

    MOCK_CONFIRM_FAIL=1
    measure_sweep example.com 5201 auto 300 240 360 15 3 1 3 0.1 0 5000
    summary="$MEASURE_RUN_DIR/summary.tsv"
    assert_eq '' "$(summary_value "$summary" RECOMMEND)" "failed confirmation recommendation"
    assert_eq 0 "$(summary_value "$summary" CONFIRMED)" "failed confirmation marker"
    assert_eq confirmation-failed "$(summary_value "$summary" REJECT_REASON)" "failed confirmation reason"
}

test_sweep_baseline_failure_stops_and_restores() {
    local output="$TEST_ROOT/sweep-baseline-failure.log" restore_count=0
    sample_repeated() { return 7; }
    measure_restore() { ((restore_count+=1)); }
    if measure_sweep example.com 5201 auto 0 0 0 0 3 1 3 0.1 1 5000 >"$output" 2>&1; then
        fail "failed baseline sample reported sweep success"
    fi
    assert_eq 1 "$restore_count" "qdisc restore after baseline failure"
    if grep -Fqi 'division by 0' "$output"; then fail "baseline failure reached invalid sweep arithmetic"; fi
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
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    acquire_lock() { :; }; require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }; capture_baseline() { :; }; migrate_legacy_config() { :; }
    qdisc_guard() { :; }; run_action_transaction() { shift; "$@"; }
    load_config() { reset_config; }; apply_sysctl_profile() { :; }; apply_fq() { :; }; apply_initial_windows() { :; }
    save_config() { :; }; install_persistence() { return 9; }; systemctl() { fail "systemctl called after persistence failure"; }
    if install_base_tuning auto balanced mixed 0 0 >"$output" 2>&1; then fail "persistence failure reported success"; fi
    if grep -Fq '基础调优已安装' "$output"; then fail "success message printed after failure"; fi
    grep -Fq '持久化安装失败' "$output" || fail "partial-runtime failure was not explained"
}

test_container_mutation_guard() {
    (
        command_exists() { return 1; }
        virtualization_type() { printf 'docker\n'; }
        if require_host_network_control >/dev/null 2>&1; then fail "container mutation guard accepted Docker"; fi
    )
    (
        command_exists() { return 1; }
        virtualization_type() { printf 'none\n'; }
        require_host_network_control || fail "host mutation guard rejected a non-container"
    )
}

test_force_scan_requires_explicit_flag() {
    FORCE_SEEN=""
    measure_sweep() { FORCE_SEEN="${12}"; }
    cmd_measure sweep --peer example.com --low 100 --high 200
    assert_eq 0 "$FORCE_SEEN" "custom range unexpectedly forced scan"
    cmd_measure sweep --peer example.com --low 100 --high 200 --force-scan
    assert_eq 1 "$FORCE_SEEN" "explicit force scan flag"
}

test_measurement_acceptance_gate() {
    measurement_sample_acceptable 95 0.01 100 0.94 0.1 0 || fail "clean confirmation rejected"
    if measurement_sample_acceptable 90 0.01 100 0.94 0.1 0; then fail "low-throughput confirmation accepted"; fi
    if measurement_sample_acceptable 95 1.0 100 0.94 0.1 0; then fail "high-retrans confirmation accepted"; fi
}

test_action_transaction_rolls_back_failed_step() {
    local events="" config_before='config-before' sysctl_before='sysctl-before' service_before='service-before' persist_before='persist-before'
    LEGACY_SERVICE_FILE="$TEST_ROOT/systemd/legacy.service"
    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR"
    printf '%s\n' "$config_before" > "$CONFIG_FILE"
    printf '%s\n' "$sysctl_before" > "$SYSCTL_FILE"
    printf '%s\n' "$service_before" > "$SERVICE_FILE"
    printf '%s\n' "$persist_before" > "$PERSIST_SCRIPT"
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_ROLLING_BACK=0; LOCK_HELD=1
    action_qdisc_snapshot() { printf 'KIND\tfq\nRATE\t\nARGS\t\n' > "$2"; }
    restore_action_qdisc() { events+=" qdisc:$1"; }
    capture_runtime_sysctls() { printf 'net.test.key\tbefore\n'; }
    sysctl() { [[ "$1" == -q && "$2" == -w ]] && events+=" sysctl:${3}"; }
    ip() { case "$*" in '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;; '-6 route show default') : ;; *) events+=" ip:$*" ;; esac; }
    systemctl() {
        case "$1" in
            is-enabled) printf 'enabled\n'; return 0 ;;
            is-active) printf 'active\n'; return 0 ;;
            *) events+=" systemctl:$*"; return 0 ;;
        esac
    }
    release_lock() { LOCK_HELD=0; events+=" release"; }
    acquire_lock() { LOCK_HELD=1; events+=" acquire"; }
    transaction_failure() {
        printf 'changed\n' > "$CONFIG_FILE"
        printf 'changed\n' > "$SYSCTL_FILE"
        printf 'changed\n' > "$SERVICE_FILE"
        printf 'changed\n' > "$PERSIST_SCRIPT"
        return 7
    }
    if run_action_transaction eth0 transaction_failure; then fail "failed transaction reported success"; fi
    assert_eq "$config_before" "$(<"$CONFIG_FILE")" "transaction config restore"
    assert_eq "$sysctl_before" "$(<"$SYSCTL_FILE")" "transaction sysctl file restore"
    assert_eq "$service_before" "$(<"$SERVICE_FILE")" "transaction service restore"
    assert_eq "$persist_before" "$(<"$PERSIST_SCRIPT")" "transaction persistent script restore"
    [[ "$events" == *'sysctl:net.test.key=before'* && "$events" == *'qdisc:eth0'* && "$events" == *'systemctl:start bbrv3-lite.service'* ]] ||
        fail "transaction runtime/service restore events missing: $events"
    assert_eq '' "$ACTION_TRANSACTION_DIR" "transaction snapshot cleanup"
}

test_auto_tune_commits_only_after_final_verify() {
    local events="" verify_fail=0 candidate_rejected=0 summary_dir="$TEST_ROOT/auto-summary"
    mkdir -p "$summary_dir"
    WIZARD_PEER=example.com; WIZARD_PORT=5201
    prepare_auto_tuning_runtime() { events+=" prepare"; }
    measure_sweep() {
        events+=" sweep"; MEASURE_RUN_DIR="$summary_dir"
        if (( candidate_rejected )); then
            printf '%s\n' \
                $'RECOMMEND\t' $'BROKE_AT\t105' $'UNSHAPED_MBIT\t110' $'NO_KNEE\t0' \
                $'CONFIRMED\t0' $'REJECT_REASON\tconfirmation-failed' $'MIN_EFFICIENCY_RATIO\t0.94' \
                $'CLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t0' > "$summary_dir/summary.tsv"
        else
            printf '%s\n' \
                $'RECOMMEND\t100' $'BROKE_AT\t105' $'UNSHAPED_MBIT\t110' $'NO_KNEE\t0' \
                $'CONFIRMED\t1' $'REJECT_REASON\t' $'MIN_EFFICIENCY_RATIO\t0.94' \
                $'CLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t0' > "$summary_dir/summary.tsv"
        fi
    }
    apply_shaping() { events+=" shape"; }
    verify_runtime_tuning() { events+=" runtime"; }
    measure_verify() { events+=" verify"; (( verify_fail == 0 )); }
    persist_current_tuning() { events+=" persist"; }
    show_status() { :; }

    WIZARD_PEER=""
    auto_tune_execute eth0 balanced mixed 0 0
    assert_eq ' prepare runtime persist' "$events" "no-measurement auto commit order"

    events=""; WIZARD_PEER=example.com; candidate_rejected=1
    if auto_tune_execute eth0 balanced mixed 0 0; then fail "rejected candidate reported auto success"; fi
    assert_eq ' prepare sweep' "$events" "rejected candidate was applied or persisted"

    events=""; candidate_rejected=0
    auto_tune_execute eth0 balanced mixed 0 150 1
    assert_eq ' prepare sweep shape runtime verify persist' "$events" "auto commit order"
    assert_eq 150 "$RTT_MS" "auto tuning RTT"
    assert_eq 1 "$(summary_value "$summary_dir/summary.tsv" PEER_RTT_MS)" "auto peer RTT history"
    assert_eq 150 "$(summary_value "$summary_dir/summary.tsv" TUNING_RTT_MS)" "auto tuning RTT history"

    events=""; verify_fail=1
    if auto_tune_execute eth0 balanced mixed 0 150 1; then fail "failed final verify reported auto success"; fi
    assert_eq ' prepare sweep shape runtime verify' "$events" "auto persisted before failed verify"
}

test_cli_rejects_missing_and_ignored_options() {
    local called=0
    detect_profile() { called=1; }
    tc_trial() { called=1; }
    measure_probe() { called=1; }
    measure_verify() { called=1; }
    kernel_status() { called=1; }
    kernel_install() { called=1; }
    dns_status() { called=1; }
    dns_apply() { called=1; }
    ipv6_status() { called=1; }
    ipv6_disable() { called=1; }

    if cmd_install --profile >/dev/null 2>&1; then fail "missing install option value accepted"; fi
    if cmd_detect --target >/dev/null 2>&1; then fail "missing detect option value accepted"; fi
    if cmd_tc trial 100 --margin 3 >/dev/null 2>&1; then fail "ignored tc trial option accepted"; fi
    if cmd_tc trial 08 >/dev/null 2>&1; then fail "ambiguous leading-zero integer accepted"; fi
    if cmd_tc trial 18446744073709551617 >/dev/null 2>&1; then fail "overflowing integer accepted"; fi
    if cmd_tc enable 100 --knee 90 >/dev/null 2>&1; then fail "knee below rate accepted"; fi
    if cmd_measure probe --peer example.com --low 50 >/dev/null 2>&1; then fail "ignored probe option accepted"; fi
    if cmd_measure verify --peer example.com --parallel 2 >/dev/null 2>&1; then fail "ignored verify parallel accepted"; fi
    if cmd_kernel status --track lts >/dev/null 2>&1; then fail "ignored kernel status option accepted"; fi
    if cmd_kernel install --track edge >/dev/null 2>&1; then fail "invalid kernel track accepted"; fi
    if cmd_dns status plain >/dev/null 2>&1; then fail "extra DNS status argument accepted"; fi
    if cmd_dns apply bogus >/dev/null 2>&1; then fail "invalid DNS mode accepted"; fi
    if cmd_ipv6 status permanent >/dev/null 2>&1; then fail "extra IPv6 status argument accepted"; fi
    if cmd_ipv6 disable forever >/dev/null 2>&1; then fail "invalid IPv6 mode accepted"; fi
    assert_eq 0 "$called" "invalid CLI reached implementation"
}

test_dns_apply_failure_restores_action_snapshot() {
    local restart_count=0
    rm -rf -- "$DNS_BACKUP_DIR"
    rm -f -- "$DNS_DROPIN" "$DNS_RESOLV_CONF"
    mkdir -p -- "$(dirname "$DNS_DROPIN")" "$(dirname "$DNS_RESOLV_CONF")" "$DNS_BACKUP_DIR/baseline"
    printf 'incomplete\n' > "$DNS_BACKUP_DIR/baseline/partial"
    printf 'nameserver 192.0.2.53\n' > "$DNS_RESOLV_CONF"
    printf 'old-dropin\n' > "$DNS_DROPIN"
    DNS_TRANSACTION_DIR=""
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    acquire_lock() { :; }; require_commands() { :; }
    systemctl() {
        case "$1" in
            cat) return 0 ;; is-active) printf 'active\n' ;; restart) ((restart_count+=1)); return 0 ;; stop) return 0 ;;
            *) return 0 ;;
        esac
    }
    resolvectl() { return 1; }
    if dns_apply plain >/dev/null 2>&1; then fail "failed DNS verification reported success"; fi
    assert_eq 'nameserver 192.0.2.53' "$(<"$DNS_RESOLV_CONF")" "DNS resolv.conf rollback"
    assert_eq 'old-dropin' "$(<"$DNS_DROPIN")" "DNS drop-in rollback"
    [[ ! -L "$DNS_RESOLV_CONF" ]] || fail "DNS rollback left resolv.conf symlink"
    [[ -f "$DNS_BACKUP_DIR/baseline/manifest" && ! -e "$DNS_BACKUP_DIR/baseline/partial" ]] || fail "DNS baseline was not atomically rebuilt"
    assert_eq '' "$DNS_TRANSACTION_DIR" "DNS transaction cleanup"
    (( restart_count >= 2 )) || fail "DNS apply/rollback did not restart resolved"

    rm -rf -- "$DNS_BACKUP_DIR/baseline"
    mkdir -p -- "$DNS_BACKUP_DIR/baseline"
    printf 'CREATED_AT\tlegacy\n' > "$DNS_BACKUP_DIR/baseline/manifest"
    printf 'present\n' > "$DNS_BACKUP_DIR/baseline/resolv.state"
    printf 'nameserver 198.51.100.53\n' > "$DNS_BACKUP_DIR/baseline/resolv.conf"
    printf 'absent\n' > "$DNS_BACKUP_DIR/baseline/dropin.state"
    printf 'current\n' > "$DNS_RESOLV_CONF"
    printf 'current-dropin\n' > "$DNS_DROPIN"
    dns_restore_snapshot "$DNS_BACKUP_DIR/baseline" >/dev/null 2>&1 || fail "legacy DNS baseline restore failed"
    assert_eq 'nameserver 198.51.100.53' "$(<"$DNS_RESOLV_CONF")" "legacy DNS baseline content"
    [[ ! -e "$DNS_DROPIN" ]] || fail "legacy DNS baseline did not remove absent drop-in"
}

test_ipv6_failure_restores_runtime_and_persistent_file() {
    local fail_key="net.ipv6.conf.default.disable_ipv6" assignment key value
    declare -A ipv6_values=(
        [net.ipv6.conf.all.disable_ipv6]=0
        [net.ipv6.conf.default.disable_ipv6]=0
        [net.ipv6.conf.lo.disable_ipv6]=0
    )
    rm -rf -- "$IPV6_BACKUP_DIR"
    mkdir -p -- "$IPV6_BACKUP_DIR/baseline" "$(dirname "$IPV6_SYSCTL_FILE")"
    printf 'incomplete\n' > "$IPV6_BACKUP_DIR/baseline/partial"
    printf 'pre-existing-policy\n' > "$IPV6_SYSCTL_FILE"
    IPV6_TRANSACTION_DIR=""
    require_root() { :; }; require_host_network_control() { :; }; acquire_lock() { :; }; require_commands() { :; }
    sysctl() {
        if [[ "$1" == -n ]]; then printf '%s\n' "${ipv6_values[$2]}"; return 0; fi
        if [[ "$1" == -q && "$2" == -w ]]; then
            assignment="$3"; key="${assignment%%=*}"; value="${assignment#*=}"
            [[ "$key" != "$fail_key" || "$value" != 1 ]] || return 1
            ipv6_values[$key]="$value"
            return 0
        fi
        return 1
    }
    if ipv6_disable permanent >/dev/null 2>&1; then fail "partial IPv6 sysctl failure reported success"; fi
    assert_eq 0 "${ipv6_values[net.ipv6.conf.all.disable_ipv6]}" "IPv6 all rollback"
    assert_eq 0 "${ipv6_values[net.ipv6.conf.default.disable_ipv6]}" "IPv6 default rollback"
    assert_eq 0 "${ipv6_values[net.ipv6.conf.lo.disable_ipv6]}" "IPv6 lo rollback"
    assert_eq 'pre-existing-policy' "$(<"$IPV6_SYSCTL_FILE")" "IPv6 persistent policy rollback"
    [[ -f "$IPV6_BACKUP_DIR/baseline/manifest" && ! -e "$IPV6_BACKUP_DIR/baseline/partial" ]] || fail "IPv6 baseline was not atomically rebuilt"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "IPv6 transaction cleanup"
}

test_config_parser
test_legacy_migration
test_profile_math
test_managed_sysctl_runtime_verifier
test_legacy_baseline_reference
test_qdisc_replay_filters_kernel_runtime_fields
test_tc_transaction
test_measurement_math_and_history
test_systemd_generation
test_baseline_captures_persistence_lifecycle
test_persistent_artifact_consistency_verifier
test_cli_command_removal_is_scoped
test_uninstall_restores_before_removal
test_submenu_stays_until_explicit_return
test_menu_exits_after_uninstall_signal
test_peer_parser
test_public_peer_requires_real_iperf_preflight
test_sweep_without_knee_does_not_recommend_ceiling
test_refine_preserves_throughput_stall_and_confirmation_gate
test_sweep_baseline_failure_stops_and_restores
test_persistence_restart_hands_off_lock
test_dependency_install_is_minimal
test_process_substitution_source_resolution
test_self_update_rolls_back_split_install
test_action_transaction_rolls_back_failed_step
test_container_mutation_guard
test_install_failure_is_not_success
test_force_scan_requires_explicit_flag
test_measurement_acceptance_gate
test_auto_tune_commits_only_after_final_verify
test_dns_apply_failure_restores_action_snapshot
test_ipv6_failure_restores_runtime_and_persistent_file
test_cli_rejects_missing_and_ignored_options
echo "core tests: OK"
