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
export BBRV3_NIC_POLICY_DIR="$TEST_ROOT/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$TEST_ROOT/state/interfaces"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_file_contains() { grep -Fq "$2" "$1" || fail "$1 does not contain: $2"; }

tcp_baseline_test_sysctl_value() {
    case "$1" in
        net.core.default_qdisc) printf 'fq\n' ;;
        net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
        net.core.rmem_max|net.core.wmem_max) printf '16777216\n' ;;
        net.ipv4.tcp_rmem) printf '4096 131072 16777216\n' ;;
        net.ipv4.tcp_wmem) printf '4096 16384 16777216\n' ;;
        net.ipv4.tcp_mtu_probing) printf '0\n' ;;
        net.ipv4.tcp_fastopen) printf '1\n' ;;
        net.core.somaxconn) printf '4096\n' ;;
        net.ipv4.tcp_max_syn_backlog) printf '4096\n' ;;
        net.core.netdev_max_backlog) printf '1000\n' ;;
        *) return 1 ;;
    esac
}

write_valid_v1_tcp_baseline() {
    local directory="$1" iface="${2:-eth0}" key name
    rm -rf -- "$directory"
    mkdir -p -- "$directory"
    printf 'SCHEMA\t1\nCREATED_AT\t2026-08-23T00:00:00Z\nCREATED_BY\t7.0.7\nPROVENANCE\tnative\nINTERFACE\t%s\n' "$iface" > "$directory/manifest"
    while IFS= read -r key; do
        printf '%s\t%s\n' "$key" "$(tcp_baseline_test_sysctl_value "$key")"
    done < <(tcp_baseline_sysctl_keys) > "$directory/sysctl.tsv"
    printf 'qdisc fq 8001: root refcnt 2 limit 10000p flow_limit 100p\n' > "$directory/qdisc.txt"
    : > "$directory/class.txt"
    : > "$directory/routes-v4.txt"; : > "$directory/routes-v6.txt"
    printf 'default via 192.0.2.1 dev %s\n' "$iface" > "$directory/default-route-v4.txt"
    : > "$directory/default-route-v6.txt"
    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        printf 'absent\n' > "$directory/${name}.state"
    done
    printf 'present\n' > "$directory/config.state"
    printf 'baseline-config\n' > "$directory/config"
    printf 'not-found\tinactive\n' > "$directory/service.unit"
    printf 'not-found\tinactive\n' > "$directory/legacy-service.unit"
    chmod -R go-rwx "$directory"
}

test_config_parser() {
    local marker="$TEST_ROOT/injected"
    validate_interface_name auto || fail "auto interface selector was rejected"
    validate_interface_name eth0.100 || fail "valid VLAN interface was rejected"
    for invalid_iface in . .. abcdefghijklmnop 'bad/name'; do
        if validate_interface_name "$invalid_iface"; then
            fail "invalid or path-like interface was accepted: $invalid_iface"
        fi
    done
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

    printf 'SCHEMA_VERSION=1\nBBR_ENABLED=1\nBBR_ENABLED=0\n' > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    if load_config >/dev/null 2>&1; then fail "duplicate config key accepted"; fi
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
    (( BUFFER_MAX >= 4194304 && BUFFER_MAX <= 16777216 )) || fail "balanced buffer outside hardware-safe range"
    buffer_profile_values adaptive proxy 500 200
    (( BUFFER_MAX >= 4194304 )) || fail "adaptive buffer below hardware floor"
    (( BUFFER_MAX <= 2147483647 )) || fail "adaptive buffer above absolute cap"
    assert_eq 100 "$(recommended_tuning_rtt mixed 1)" "mixed tuning RTT floor"
    assert_eq 150 "$(recommended_tuning_rtt proxy 1)" "proxy tuning RTT floor"
    assert_eq 220 "$(recommended_tuning_rtt proxy 220)" "observed RTT above role floor"
    local burst capped
    detect_kernel_hz() { printf '250\n'; }
    burst=$(calc_htb_burst 100 1500)
    assert_eq 50000 "$burst" "HTB burst uses kernel HZ"
    capped=$(calc_htb_burst 1000000 1500)
    assert_eq 500000000 "$capped" "HTB burst supports 1 Tbit at 250Hz"
    detect_kernel_hz() { printf '100\n'; }
    capped=$(calc_htb_burst 1000000 1500)
    assert_eq 1250000000 "$capped" "HTB burst supports 1 Tbit at 100Hz"
}

test_bbr_compatibility_guard_and_generation_reporting() {
    (
        local mock_current=bbr2 mock_available='reno cubic bbr bbr2' output
        sysctl() {
            [[ "$1" == -n ]] || return 1
            case "$2" in
                net.ipv4.tcp_congestion_control) printf '%s\n' "$mock_current" ;;
                net.ipv4.tcp_available_congestion_control) printf '%s\n' "$mock_available" ;;
                *) return 1 ;;
            esac
        }
        modprobe() { :; }
        if ensure_bbr_available >/dev/null 2>&1; then fail "third-party BBR variant was silently replaced"; fi
        output=$(bbr_compatibility_status "$mock_current" "$mock_available")
        [[ "$output" == conflict:*bbr2* ]] || fail "third-party BBR conflict was not reported: $output"

        mock_current=cubic
        ensure_bbr_available || fail "standard BBR availability was rejected"
        assert_eq 'ready: standard bbr is available' "$(bbr_compatibility_status "$mock_current" "$mock_available")" "standard BBR readiness"

        modinfo() { printf 'version: 3.7-vendor\n'; }
        uname() { [[ "$1" == -r ]] && printf '6.12.0-generic\n'; }
        output=$(bbr_generation_status bbr)
        [[ "$output" == unknown*'not BBR generation proof'* ]] || fail "vendor module version was treated as BBRv3 proof: $output"
        uname() { [[ "$1" == -r ]] && printf '6.12.0-x64v3-xanmod1\n'; }
        output=$(bbr_generation_status bbr)
        [[ "$output" == 'v3 expected'* ]] || fail "XanMod BBRv3 expectation missing: $output"
    )
}

test_xanmod_cpu_level_and_track_selection() {
    (
        local mock_cpu_flags
        uname() { [[ "$1" == -m ]] && printf 'x86_64\n'; }
        cpu_flags_line() { printf '%s\n' "$mock_cpu_flags"; }

        mock_cpu_flags='flags : cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma movbe xsave abm'
        assert_eq 3 "$(detect_x86_level)" "complete x86-64-v3 feature set"
        mock_cpu_flags='flags : cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 fma movbe xsave abm'
        assert_eq 2 "$(detect_x86_level)" "missing F16C must downgrade x86-64-v3"
        mock_cpu_flags='flags : cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3'
        assert_eq 1 "$(detect_x86_level)" "missing SSE3 must downgrade x86-64-v2"

        assert_eq $'linux-xanmod-x64v3\nlinux-xanmod-x64v2' "$(xanmod_candidates 3 main)" "XanMod Main candidates"
        assert_eq $'linux-xanmod-lts-x64v2\nlinux-xanmod-lts-x64v1' "$(xanmod_candidates 2 lts)" "XanMod LTS fallback candidates"
        assert_eq '' "$(xanmod_candidates 1 main)" "XanMod Main must not silently fall back to LTS"
    )
}

test_hardware_aware_model() {
    (
        cpu_count() { printf '1\n'; }; memory_mb() { printf '256\n'; }
        detect_interface() { printf 'eth0\n'; }; detect_link_speed() { printf '100\n'; }
        detect_rx_queues() { printf '1\n'; }; detect_tx_queues() { printf '1\n'; }
        detect_mtu() { printf '1500\n'; }; detect_driver() { printf 'virtio_net\n'; }; virtualization_type() { printf 'kvm\n'; }
        TC_INTERFACE=eth0
        buffer_profile_values adaptive mixed 100 100 eth0
        assert_eq micro "$HARDWARE_CLASS" "micro hardware class"
        assert_eq 4194304 "$BUFFER_MAX" "micro adaptive floor"
        assert_eq 4096 "$NETDEV_BACKLOG" "micro backlog cap"
        assert_eq 5000 "$(recommended_scan_cap eth0 0)" "slow link scan floor"
        assert_eq 2 "$(recommended_verify_flows eth0 100)" "single-core verify flows"
    )
    (
        cpu_count() { printf '16\n'; }; memory_mb() { printf '16384\n'; }
        detect_interface() { printf 'eth0\n'; }; detect_link_speed() { printf '25000\n'; }
        detect_rx_queues() { printf '16\n'; }; detect_tx_queues() { printf '16\n'; }
        detect_mtu() { printf '9000\n'; }; detect_driver() { printf 'mlx5_core\n'; }; virtualization_type() { printf 'none\n'; }
        assert_eq 31250 "$(recommended_scan_cap eth0 0)" "25G dynamic scan cap"
        assert_eq 18000 "$(expanded_scan_cap 5000 12000)" "measured scan cap expansion"
        assert_eq 100000 "$(expanded_scan_cap 100000 12000)" "larger explicit planning cap retained"
        assert_eq 1000000 "$(expanded_scan_cap 5000 900000)" "measured scan cap absolute bound"
        assert_eq 4 "$(recommended_measure_duration eth0 25000)" "25G sample duration"
        assert_eq 8 "$(recommended_verify_flows eth0 25000)" "25G verify flows"
        buffer_profile_values adaptive bulk 25000 150 eth0
        assert_eq 16384 "$NETDEV_BACKLOG" "25G backlog budget"
        (( BUFFER_MAX > 268435456 )) || fail "high-BDP host remained capped at v7.1 ceiling"
    )
    (
        cpu_count() { printf '64\n'; }; memory_mb() { printf '65536\n'; }
        detect_interface() { printf 'eth0\n'; }; detect_link_speed() { printf '100000\n'; }
        detect_rx_queues() { printf '32\n'; }; detect_tx_queues() { printf '32\n'; }
        detect_mtu() { printf '9000\n'; }; detect_driver() { printf 'mlx5_core\n'; }; virtualization_type() { printf 'none\n'; }
        buffer_profile_values adaptive bulk 100000 200 eth0
        assert_eq extreme "$HARDWARE_CLASS" "extreme hardware class"
        assert_eq 2147483647 "$BUFFER_MAX" "extreme absolute buffer cap"
        assert_eq 32768 "$NETDEV_BACKLOG" "extreme backlog budget"
        assert_eq 16 "$(recommended_verify_flows eth0 100000)" "100G verify flows"
    )
    (
        cpu_count() { printf '4\n'; }; memory_mb() { printf '4096\n'; }
        detect_interface() { printf 'eth0\n'; }; detect_link_speed() { printf 'unknown\n'; }
        detect_rx_queues() { printf '1\n'; }; detect_tx_queues() { printf '1\n'; }
        detect_mtu() { printf '1500\n'; }; detect_driver() { printf 'virtio_net\n'; }; virtualization_type() { printf 'kvm\n'; }
        assert_eq 5000 "$(recommended_scan_cap eth0 0)" "unknown-link conservative scan cap"
    )
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
            [net.core.somaxconn]="$SOMAXCONN"
            [net.ipv4.tcp_max_syn_backlog]="$TCP_MAX_SYN_BACKLOG"
            [net.core.netdev_max_backlog]="$NETDEV_BACKLOG"
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
    cp "$ROOT_DIR/net-tcp-tune.sh" "$PERSIST_SCRIPT"
    chmod 0755 "$PERSIST_SCRIPT"
    printf 'legacy\n' > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    sysctl() { [[ "$1" == -n ]] || return 1; tcp_baseline_test_sysctl_value "$2"; }
    tc() { [[ "$1 $2 $3 $4" == 'qdisc show dev eth0' ]] || return 1; echo 'qdisc fq 0: root refcnt 2'; }
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

test_mq_child_guard_and_restore() {
    (
        local rows mock_child=fq_codel snapshot="$TEST_ROOT/mq.snapshot" events=""
        rows=$(printf '%s\n' \
            'qdisc mq 0: root' \
            'qdisc fq_codel 0: parent :1 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms refcnt 2' \
            'qdisc fq 0: parent :2 limit 10000p flow_limit 100p bands 3 priomap 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 weights 1 1 1' |
            mq_child_replay_rows_from_stream)
        [[ "$rows" == *$':1\tfq_codel\tlimit 10240 flows 1024 quantum 1514 target 5ms interval 100ms'* ]] ||
            fail "mq fq_codel replay row malformed: $rows"
        [[ "$rows" == *$':2\tfq\tlimit 10000 flow_limit 100'* && "$rows" != *priomap* && "$rows" != *weights* ]] ||
            fail "mq fq replay row retained runtime fields: $rows"

        tc() {
            case "$*" in
                'qdisc show dev eth0')
                    printf 'qdisc mq 0: root\nqdisc %s 0: parent :1 limit 10240p\n' "$mock_child"
                    ;;
                'class show dev eth0') : ;;
                *) events+=" [$*]" ;;
            esac
        }
        qdisc_guard eth0 || fail "restorable mq hierarchy was rejected"
        mock_child=cake
        if qdisc_guard eth0 >/dev/null 2>&1; then fail "unrestorable mq child was accepted"; fi

        printf '%s\n' \
            $'KIND\tmq' $'RATE\t' $'ARGS\t' \
            'qdisc mq 0: root' \
            'qdisc fq_codel 0: parent :1 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms' > "$snapshot"
        restore_mq_qdisc_snapshot eth0 "$snapshot" || fail "mq hierarchy restore failed"
        [[ "$events" == *'[qdisc replace dev eth0 root mq]'* &&
            "$events" == *'[qdisc replace dev eth0 parent :1 fq_codel limit 10240 flows 1024 quantum 1514 target 5ms interval 100ms]'* ]] ||
            fail "mq hierarchy restore calls missing: $events"
    )
}

test_managed_rate_unit_parsing() {
    (
        tc() { echo 'class htb 1:10 root prio 0 rate 1Tbit ceil 1Tbit'; }
        assert_eq 1000000 "$(managed_rate_mbit eth0)" "Tbit managed rate parsing"
    )
    (
        tc() { echo 'class htb 1:10 root prio 0 rate 25Gbit ceil 25Gbit'; }
        assert_eq 25000 "$(managed_rate_mbit eth0)" "Gbit managed rate parsing"
    )
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

test_v71_measurement_metrics_and_confidence() {
    (
        local latency_file="$TEST_ROOT/latency-samples" stats confidence
        printf '%s\n' \
            '64 bytes from 192.0.2.1: icmp_seq=1 ttl=64 time=10.0 ms' \
            '64 bytes from 192.0.2.1: icmp_seq=2 ttl=64 time=20.0 ms' \
            '64 bytes from 192.0.2.1: icmp_seq=3 ttl=64 time=30.0 ms' > "$latency_file"
        stats=$(latency_stats_from_file "$latency_file")
        assert_eq 20.0 "$(cut -f1 <<< "$stats")" "loaded RTT median"
        assert_eq 30.0 "$(cut -f2 <<< "$stats")" "loaded RTT p95"
        assert_eq 10.00 "$(bufferbloat_delta_ms 20 30)" "bufferbloat delta"
        assert_eq 0.00 "$(background_tx_percent 1000 1101000 1000000)" "protocol overhead allowance"
        assert_eq 1.47 "$(relative_spread_percent 100 110 101)" "robust adaptive spread"
        confidence=$(measurement_confidence 3 1.47 30 0 0)
        assert_eq 100 "$(cut -f1 <<< "$confidence")" "measurement confidence score"
        assert_eq high "$(cut -f2 <<< "$confidence")" "measurement confidence grade"
        assert_eq improved "$(compare_verdict 100 98 40 10 10 2)" "A/B improvement verdict"
        assert_eq regressed "$(compare_verdict 100 80 40 10 10 2)" "A/B throughput regression verdict"
    )
}

test_peak_core_cpu_detection() {
    local metrics
    metrics=$(cpu_core_delta_metrics $'cpu0\t100\t50\t0\ncpu1\t100\t50\t0' $'cpu0\t200\t50\t0\ncpu1\t200\t140\t2')
    assert_eq $'100.00\t2.00' "$metrics" "peak per-core CPU/steal metrics"
}

test_adaptive_sampling_and_contamination_guard() {
    (
        local calls_file="$TEST_ROOT/adaptive-calls" row rc=0
        printf '0\n' > "$calls_file"
        MEASURE_RESULT_FILE="$TEST_ROOT/adaptive-samples.tsv"; MEASURE_IDLE_RTT_MS=10
        sleep() { :; }
        iperf_sample() {
            local call goodput
            call=$(( $(<"$calls_file") + 1 )); printf '%s\n' "$call" > "$calls_file"
            case "$call" in 1) goodput=100 ;; 2) goodput=110 ;; *) goodput=101 ;; esac
            printf '%s\t0\t1000000\t0.00000\t0.000\t20\t30\t0\t20\t0\t0\n' "$goodput"
        }
        row=$(sample_repeated example.com 5201 3 1 2 adaptive 3 6)
        assert_eq 3 "$(cut -f13 <<< "$row")" "adaptive third sample"
        assert_eq 1.47 "$(cut -f12 <<< "$row")" "adaptive final spread"
        assert_eq 20.00 "$(cut -f14 <<< "$row")" "adaptive bufferbloat result"

        printf '0\n' > "$calls_file"; BBRV3_CONTAMINATION_RETRIES=1
        iperf_sample() {
            printf '%s\n' "$(( $(<"$calls_file") + 1 ))" > "$calls_file"
            printf '100\t0\t1000000\t0.00000\t0.000\t20\t30\t25\t20\t20\t1\n'
        }
        if sample_repeated example.com 5201 3 1 1 contaminated >/dev/null 2>&1; then
            fail "persistently contaminated sample was accepted"
        else
            rc=$?
        fi
        assert_eq "$IPERF_CONTAMINATED_RC" "$rc" "contaminated sample exit status"
        assert_eq 2 "$(<"$calls_file")" "contaminated sample retry count"
    )
}

test_measure_compare_is_temporary_and_auditable() {
    (
        local restore_file="$TEST_ROOT/compare-restored" summary
        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        peer_port_open() { :; }; detect_interface() { printf 'eth0\n'; }; qdisc_guard() { :; }
        # This unit test exercises only the temporary/interleaved A/B state
        # machine.  Keep route locking hermetic: a CI runner may resolve
        # example.com to an IPv6 address even when that runner has no IPv6
        # route, which must not make this unrelated unit test depend on the
        # host network.  Route-lock behaviour has dedicated mocked and real
        # integration coverage in test_measure_v721.sh.
        measure_lock_peer() {
            MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10
            MEASURE_PEER_SOURCE=192.0.2.10; MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE="$2"
            path_state_reset
            PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
        }
        measure_require_locked_port() { :; }
        detect_link_speed() { printf '100\n'; }; measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=10; }
        measure_begin() { MEASURE_IFACE=eth0; MEASURE_TX_START=0; MEASURE_RX_START=0; }
        measure_restore() { printf restored > "$restore_file"; MEASURE_IFACE=""; }
        traffic_report() { :; }; apply_fq() { :; }; apply_shaping() { :; }; sleep() { :; }
        sample_repeated() {
            if [[ "$6" == *-fq-* ]]; then
                printf '100\t10\t1000000\t0.01000\t10.000\t20\t50\t0\t20\t0\t0\t0\t1\t40\n'
            else
                printf '98\t2\t1000000\t0.00200\t2.000\t15\t20\t0\t20\t0\t0\t0\t1\t10\n'
            fi
        }
        measure_compare example.com 5201 auto 95 3 2
        summary="$MEASURE_RUN_DIR/summary.tsv"
        [[ -f "$restore_file" ]] || fail "A/B comparison did not restore original qdisc"
        assert_eq improved "$(summary_value "$summary" VERDICT)" "A/B summary verdict"
        assert_eq 0 "$(summary_value "$summary" PERSISTED)" "A/B unexpectedly persisted state"
        assert_eq interleaved "$(summary_value "$summary" ORDER)" "A/B execution order"
        assert_eq 203.0.113.10 "$(summary_value "$summary" LOCKED_ADDRESS)" "A/B locked peer audit"
    )
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
        local service_enabled=enabled service_active=active
        STATE_DIR="$lifecycle_root/state"; BASELINE_DIR="$STATE_DIR/baseline"; HISTORY_DIR="$STATE_DIR/history"
        CONFIG_FILE="$lifecycle_root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$lifecycle_root/etc/99-bbrv3-lite.conf"
        LEGACY_SYSCTL_FILE="$lifecycle_root/etc/legacy.conf"; SERVICE_FILE="$lifecycle_root/systemd/bbrv3-lite.service"
        LEGACY_SERVICE_FILE="$lifecycle_root/systemd/legacy.service"; PERSIST_DIR="$lifecycle_root/persist"
        PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; LEGACY_BACKUP_DIR="$lifecycle_root/legacy-backup"
        mkdir -p "$PERSIST_DIR"
        cp "$ROOT_DIR/net-tcp-tune.sh" "$PERSIST_SCRIPT"; chmod 0755 "$PERSIST_SCRIPT"
        sysctl() { [[ "$1" == -n ]] || return 1; tcp_baseline_test_sysctl_value "$2"; }
        tc() {
            case "$1 $2 $3 $4" in
                'qdisc show dev eth0') printf 'qdisc fq 0: root\n' ;;
                'class show dev eth0') return 0 ;;
                *) return 1 ;;
            esac
        }
        ip() { :; }
        systemctl() {
            local verb="$1" unit="${2:-}"
            case "$verb:$unit" in
                is-enabled:bbrv3-lite.service)
                    printf '%s\n' "$service_enabled"
                    [[ "$service_enabled" == enabled ]]
                    ;;
                is-active:bbrv3-lite.service)
                    printf '%s\n' "$service_active"
                    [[ "$service_active" == active ]]
                    ;;
                is-enabled:*) printf 'not-found\n'; return 1 ;;
                is-active:*) printf 'inactive\n'; return 1 ;;
                enable:bbrv3-lite.service)
                    events+=" enable:$unit"
                    service_enabled=enabled
                    ;;
                start:bbrv3-lite.service)
                    events+=" start:$unit"
                    service_active=active
                    ;;
                *) events+=" $verb:$unit" ;;
            esac
        }
        capture_baseline eth0 adopt-current
        assert_eq present "$(<"$BASELINE_DIR/persist-script.state")" "persistent script baseline state"
        cmp -s "$PERSIST_SCRIPT" "$BASELINE_DIR/persist-script" || fail "persistent script content not captured"
        assert_eq $'enabled\tactive' "$(<"$BASELINE_DIR/service.unit")" "service lifecycle baseline"

        rm -rf -- "$PERSIST_DIR"
        restore_backed_path "$PERSIST_SCRIPT" persist-script
        [[ -x "$PERSIST_SCRIPT" ]] || fail "persistent script parent/content not restored"
        service_enabled=disabled; service_active=inactive
        restore_unit_state "$SERVICE_NAME" "$BASELINE_DIR/service.unit"
        [[ "$events" == *' enable:bbrv3-lite.service'* && "$events" == *' start:bbrv3-lite.service'* ]] ||
            fail "service enabled/active state not restored: $events"
    )
}

test_systemd_lifecycle_strict_queries_and_runtime_states() {
    (
        local state_file="$TEST_ROOT/systemd-lifecycle.unit"
        local mock_enabled=disabled mock_active=inactive mock_unmasked_enabled=disabled
        local query_mode=normal events="" operation_effect=1 fail_operation=""
        systemctl() {
            local verb="$1" runtime=0 unit label
            shift
            case "$verb" in
                is-enabled)
                    case "$query_mode" in
                        manager-enabled) return 1 ;;
                        unknown-enabled) printf 'mystery-state\n'; return 1 ;;
                    esac
                    printf '%s\n' "$mock_enabled"
                    case "$mock_enabled" in
                        enabled|enabled-runtime|linked|linked-runtime|alias|static|indirect|generated|transient) return 0 ;;
                        *) return 1 ;;
                    esac
                    ;;
                is-active)
                    case "$query_mode" in
                        manager-active) return 1 ;;
                        unknown-active) printf 'maintenance\n'; return 1 ;;
                    esac
                    printf '%s\n' "$mock_active"
                    [[ "$mock_active" == active ]]
                    ;;
                enable|disable|mask|unmask)
                    if [[ "${1:-}" == --runtime ]]; then runtime=1; shift; fi
                    unit="${1:-}"
                    label="$verb"; (( runtime == 0 )) || label+="-runtime"
                    events+=" $label:$unit"
                    [[ "$fail_operation" != "$label" ]] || return 1
                    (( operation_effect )) || return 0
                    case "$label" in
                        enable) mock_enabled=enabled ;;
                        enable-runtime) mock_enabled=enabled-runtime ;;
                        disable)
                            [[ "$mock_enabled" != enabled ]] || mock_enabled=disabled
                            ;;
                        disable-runtime)
                            [[ "$mock_enabled" != enabled-runtime ]] || mock_enabled=disabled
                            ;;
                        mask) mock_enabled=masked ;;
                        mask-runtime) mock_enabled=masked-runtime ;;
                        unmask)
                            [[ "$mock_enabled" != masked ]] || mock_enabled="$mock_unmasked_enabled"
                            ;;
                        unmask-runtime)
                            [[ "$mock_enabled" != masked-runtime ]] || mock_enabled="$mock_unmasked_enabled"
                            ;;
                    esac
                    ;;
                start|stop)
                    unit="${1:-}"; label="$verb"; events+=" $label:$unit"
                    [[ "$fail_operation" != "$label" ]] || return 1
                    (( operation_effect )) || return 0
                    if [[ "$verb" == start ]]; then mock_active=active; else mock_active=inactive; fi
                    ;;
                *) return 0 ;;
            esac
        }

        query_mode=manager-enabled
        rm -f -- "$state_file"
        if capture_unit_state example.service "$state_file" >/dev/null 2>&1; then
            fail "manager/D-Bus is-enabled failure was captured as a valid state"
        fi
        [[ ! -e "$state_file" ]] || fail "failed unit query wrote a lifecycle snapshot"

        query_mode=unknown-enabled
        if capture_unit_state example.service "$state_file" >/dev/null 2>&1; then
            fail "unknown unit-file state was accepted"
        fi
        [[ ! -e "$state_file" ]] || fail "unknown unit-file state wrote a lifecycle snapshot"

        query_mode=manager-active; mock_enabled=disabled
        if capture_unit_state example.service "$state_file" >/dev/null 2>&1; then
            fail "manager/D-Bus is-active failure was captured as inactive"
        fi
        [[ ! -e "$state_file" ]] || fail "failed active query wrote a lifecycle snapshot"

        # Non-zero status from is-enabled/is-active is expected for the known
        # disabled/inactive states and must not be confused with a query error.
        query_mode=normal; mock_enabled=disabled; mock_active=inactive
        capture_unit_state example.service "$state_file"
        assert_eq $'disabled\tinactive' "$(<"$state_file")" "known negative systemd states"

        printf 'enabled-runtime\tactive\n' > "$state_file"
        mock_enabled=enabled; mock_active=inactive; events=""; operation_effect=1
        restore_unit_state example.service "$state_file"
        assert_eq enabled-runtime "$mock_enabled" "runtime enable restoration"
        assert_eq active "$mock_active" "active restoration after runtime enable"
        [[ "$events" == *' disable:example.service'* && "$events" == *' enable-runtime:example.service'* && "$events" == *' start:example.service'* ]] ||
            fail "enabled-runtime was not restored with --runtime: $events"
        [[ "$events" != *' enable:example.service'* ]] || fail "enabled-runtime was restored as permanent enable: $events"

        printf 'masked-runtime\tinactive\n' > "$state_file"
        mock_enabled=enabled; mock_active=active; events=""
        restore_unit_state example.service "$state_file"
        assert_eq masked-runtime "$mock_enabled" "runtime mask restoration"
        assert_eq inactive "$mock_active" "inactive restoration before runtime mask"
        [[ "$events" == *' stop:example.service'* && "$events" == *' mask-runtime:example.service'* ]] ||
            fail "masked-runtime was not restored with --runtime: $events"
        [[ "$events" != *' mask:example.service'* ]] || fail "masked-runtime was restored as permanent mask: $events"

        printf 'static\tinactive\n' > "$state_file"
        mock_enabled=disabled; mock_active=inactive; events=""
        if restore_unit_state example.service "$state_file" >/dev/null 2>&1; then
            fail "static unit-file state was synthesized from disabled"
        fi
        assert_eq '' "$events" "unsafe static-state synthesis side effects"
        mock_enabled=static
        restore_unit_state example.service "$state_file"
        assert_eq '' "$events" "already-matching static lifecycle"

        # A successful systemctl exit is insufficient: the observed final
        # state must match the snapshot.
        printf 'enabled\tinactive\n' > "$state_file"
        mock_enabled=disabled; mock_active=inactive; events=""; operation_effect=0
        if restore_unit_state example.service "$state_file" >/dev/null 2>&1; then
            fail "unit-file postcondition mismatch was reported as restored"
        fi
        [[ "$events" == *' enable:example.service'* ]] || fail "postcondition test did not exercise enable"
        operation_effect=1

        # The transaction wrapper must propagate a manager query failure and
        # discard the unusable transaction directory.
        (
            local tx_root="$TEST_ROOT/systemd-manager-failure"
            STATE_DIR="$tx_root/state"; HISTORY_DIR="$STATE_DIR/history"
            ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
            query_mode=manager-enabled
            ensure_state_layout() { mkdir -p -- "$STATE_DIR" "$HISTORY_DIR"; }
            action_qdisc_snapshot() { printf 'none\n' > "$2"; }
            capture_runtime_sysctls() { :; }
            ip() { :; }
            action_transaction_snapshot_path() { :; }
            if action_transaction_begin eth0 >/dev/null 2>&1; then
                fail "transaction began after systemd manager query failure"
            fi
            assert_eq '' "$ACTION_TRANSACTION_DIR" "manager-failure transaction state"
            [[ -z "$(find "$STATE_DIR" -maxdepth 1 -name '.transaction.*' -print -quit 2>/dev/null)" ]] ||
                fail "failed transaction left an unusable lifecycle snapshot"
        )
    )
}

test_persistent_artifact_consistency_verifier() {
    (
        local verify_root="$TEST_ROOT/persistence-verify" mock_link=10000 mock_rx=2 mock_ram=4096
        CONFIG_FILE="$verify_root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$verify_root/etc/99-bbrv3-lite.conf"
        LEGACY_SYSCTL_FILE="$verify_root/etc/99-bbr-ultimate.conf"
        SERVICE_FILE="$verify_root/systemd/bbrv3-lite.service"; PERSIST_DIR="$verify_root/persist"
        PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
        cpu_count() { printf '4\n'; }; memory_mb() { printf '%s\n' "$mock_ram"; }
        detect_interface() { printf 'eth0\n'; }; detect_link_speed() { printf '%s\n' "$mock_link"; }
        detect_rx_queues() { printf '%s\n' "$mock_rx"; }; detect_tx_queues() { printf '2\n'; }
        detect_mtu() { printf '1500\n'; }; detect_driver() { printf 'virtio_net\n'; }; virtualization_type() { printf 'kvm\n'; }
        mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR"
        reset_config; save_config
        render_sysctl_profile > "$SYSCTL_FILE"
        cp "$ROOT_DIR/net-tcp-tune.sh" "$PERSIST_SCRIPT"; chmod 0755 "$PERSIST_SCRIPT"
        printf '[Service]\nExecStart=%s apply\n' "$PERSIST_SCRIPT" > "$SERVICE_FILE"
        current_script_path() { printf '%s\n' "$ROOT_DIR/net-tcp-tune.sh"; }
        # Runtime-only NIC telemetry may drift between installation and a
        # consistency check; the applied key/value profile must remain valid.
        mock_link=unknown; mock_rx=8
        verify_persistence_artifacts || fail "matching persistent artifacts rejected"
        mock_ram=256
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "hardware change affecting managed sysctls was accepted"; fi
        mock_ram=4096
        grep -v '^# hardware=' "$SYSCTL_FILE" > "$SYSCTL_FILE.without-hardware"
        mv -- "$SYSCTL_FILE.without-hardware" "$SYSCTL_FILE"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "missing hardware telemetry line accepted"; fi
        render_sysctl_profile > "$SYSCTL_FILE"
        sed -i 's/net.core.somaxconn = 4096/net.core.somaxconn = 8192/' "$SYSCTL_FILE"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "drifted managed sysctl value accepted"; fi
        render_sysctl_profile > "$SYSCTL_FILE"
        printf '# legacy project profile\n' > "$LEGACY_SYSCTL_FILE"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "coexisting legacy sysctl was accepted"; fi
        rm -f -- "$LEGACY_SYSCTL_FILE"
        printf '# drift\n' >> "$SYSCTL_FILE"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "drifted sysctl file accepted"; fi
        render_sysctl_profile > "$SYSCTL_FILE"
        printf '# local drift\n' >> "$PERSIST_SCRIPT"
        if verify_persistence_artifacts >/dev/null 2>&1; then fail "drifted persistence script accepted"; fi
    )
}

test_legacy_sysctl_retirement_requires_baseline_and_transaction() (
    local root="$TEST_ROOT/legacy-sysctl-retire"
    local BASELINE_DIR="$root/baseline" SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    local LEGACY_SYSCTL_FILE="$root/etc/99-bbr-ultimate.conf" ACTION_TRANSACTION_DIR="$root/transaction"
    mkdir -p "$ACTION_TRANSACTION_DIR" "$(dirname "$LEGACY_SYSCTL_FILE")"
    printf 'present\n' > "$ACTION_TRANSACTION_DIR/legacy-sysctl.state"
    printf 'legacy-live\n' > "$LEGACY_SYSCTL_FILE"
    if retire_legacy_sysctl >/dev/null 2>&1; then fail "legacy sysctl retired without a valid baseline"; fi
    assert_eq 'legacy-live' "$(<"$LEGACY_SYSCTL_FILE")" "legacy sysctl preserved without baseline"

    write_valid_v1_tcp_baseline "$BASELINE_DIR" eth0
    printf 'present\n' > "$BASELINE_DIR/legacy-sysctl.state"
    printf 'legacy-baseline\n' > "$BASELINE_DIR/legacy-sysctl"
    tcp_baseline_validate "$BASELINE_DIR" >/dev/null || fail "legacy retirement test baseline invalid"
    retire_legacy_sysctl >/dev/null || fail "transactional legacy sysctl retirement failed"
    [[ ! -e "$LEGACY_SYSCTL_FILE" && ! -L "$LEGACY_SYSCTL_FILE" ]] || fail "legacy sysctl still exists after retirement"

    printf 'legacy-live\n' > "$LEGACY_SYSCTL_FILE"
    ACTION_TRANSACTION_DIR=""
    if retire_legacy_sysctl >/dev/null 2>&1; then fail "legacy sysctl retired without transaction snapshot"; fi
    assert_eq 'legacy-live' "$(<"$LEGACY_SYSCTL_FILE")" "legacy sysctl preserved without transaction"
)

test_self_update_rolls_back_split_install() {
    (
        local update_root="$TEST_ROOT/self-update" installed_path candidate valid_candidate output_path="" url="" update_output="" fail_persist=1
        mkdir -p "$update_root"
        installed_path="$update_root/bbr"; candidate="$update_root/new.sh"; valid_candidate="$update_root/new.valid.sh"; PERSIST_SCRIPT="$update_root/persist.sh"
        sed 's/^SCRIPT_VERSION="8.0.0"$/SCRIPT_VERSION="7.0.6"/' "$ROOT_DIR/net-tcp-tune.sh" > "$installed_path"
        cp "$installed_path" "$PERSIST_SCRIPT"; chmod 0755 "$installed_path" "$PERSIST_SCRIPT"
        sed 's/^SCRIPT_VERSION="8.0.0"$/SCRIPT_VERSION="8.0.1"/' "$ROOT_DIR/net-tcp-tune.sh" > "$candidate"
        cp "$candidate" "$valid_candidate"
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
                */releases/latest) printf '{"tag_name":"v8.0.1"}\n' ;;
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
        printf '#!/usr/bin/env bash\nSCRIPT_VERSION="8.0.1"\nSCRIPT_NAME="bbrv3-lite"\necho forged\n' > "$candidate"
        if self_update >/dev/null 2>&1; then fail "checksum-matching false-marker update was accepted"; fi
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$installed_path" || fail "rejected false-marker update changed current command"
        cp "$valid_candidate" "$candidate"
        if update_output=$(self_update 2>&1); then fail "split self-update failure reported success"; fi
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$installed_path" || fail "current command was not rolled back"
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$PERSIST_SCRIPT" || fail "persistent copy changed after failed update"
        grep -Fq 'SCRIPT_VERSION="7.0.6"' "$installed_path.previous" || fail "previous-version backup missing: $update_output"

        fail_persist=0
        self_update >/dev/null
        grep -Fq 'SCRIPT_VERSION="8.0.1"' "$installed_path" || fail "successful update did not replace current command"
        grep -Fq 'SCRIPT_VERSION="8.0.1"' "$PERSIST_SCRIPT" || fail "successful update did not synchronize persistent copy"
    )
}

test_cli_command_removal_is_scoped() {
    local old_home="$HOME" cli="$TEST_ROOT/bin/bbr" rc_file before
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

    # A single easy-to-forge marker is not sufficient ownership proof.
    printf '#!/usr/bin/env bash\nSCRIPT_NAME="bbrv3-lite"\necho foreign\n' > "$cli"; chmod 0755 "$cli"
    remove_cli_command
    [[ -e "$cli" ]] || fail "false-marker bbr command was removed"

    # Validate every rc file before deleting the command. A missing end marker
    # must leave both files byte-for-byte intact.
    cp "$ROOT_DIR/net-tcp-tune.sh" "$cli"; chmod 0755 "$cli"
    printf 'keep-before\n%s\nkeep-after\n' "$LEGACY_SHELL_START" > "$rc_file"
    before=$(sha256sum "$rc_file" | awk '{print $1}')
    if remove_cli_command >/dev/null 2>&1; then fail "truncated legacy shell block allowed command removal"; fi
    [[ -e "$cli" ]] || fail "managed command was removed before rc preflight completed"
    assert_eq "$before" "$(sha256sum "$rc_file" | awk '{print $1}')" "truncated rc remained immutable"
    BBRV3_CLI_PATH=""; HOME="$old_home"
}

test_uninstall_purge_preflight_is_write_free() (
    local root="$TEST_ROOT/not-a-standard-state" events=""
    STATE_DIR="$root"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    HOME="$TEST_ROOT/purge-home"; mkdir -p "$HOME" "$STATE_DIR"
    printf 'recovery-evidence\n' > "$STATE_DIR/marker"
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { events+=" lock"; }
    restore_baseline() { events+=" restore"; }
    remove_cli_command() { events+=" cli"; }
    if uninstall_managed 1 >/dev/null 2>&1; then fail "purge accepted a non-standard state directory"; fi
    assert_eq '' "$events" "purge path validation before mutations"
    assert_eq recovery-evidence "$(<"$STATE_DIR/marker")" "rejected purge preserved state"
)

test_uninstall_restores_before_removal() (
    local events=""
    mkdir -p "$BASELINE_DIR" "$DNS_BACKUP_DIR/baseline" "$IPV6_BACKUP_DIR/baseline"
    : > "$BASELINE_DIR/manifest"; : > "$DNS_BACKUP_DIR/baseline/manifest"; : > "$IPV6_BACKUP_DIR/baseline/sysctl.tsv"
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { :; }
    tcp_baseline_validate() { TCP_BASELINE_VALIDATED_PROVENANCE=native; TCP_BASELINE_VALIDATED_INTERFACE=eth0; }
    managed_htb_interfaces_strict() { :; }
    restore_baseline() { events+=" tcp"; }
    dns_restore() { events+=" dns"; }
    ipv6_restore() { events+=" ipv6"; }
    remove_cli_command() { events+=" cli"; }
    uninstall_managed 0
    assert_eq ' tcp dns ipv6 cli' "$events" "uninstall restore/delete order"
)

test_tcp_baseline_validation_is_write_free() (
    local root="$TEST_ROOT/tcp-baseline-invalid" case_name expected events=""
    local live_config='live-config' live_sysctl='live-sysctl' live_service='live-service' live_persist='live-persist'
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/etc/legacy.conf"; SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/systemd/legacy.service"; PERSIST_DIR="$root/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; LEGACY_BACKUP_DIR="$root/legacy-backup"
    BBRV3_CLI_PATH="$root/bin/bbr"; DNS_BACKUP_DIR="$root/dns"; IPV6_BACKUP_DIR="$root/ipv6"
    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR" "$(dirname "$BBRV3_CLI_PATH")"

    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { :; }
    systemctl() { events+=" systemctl:$*"; return 1; }
    sysctl() { events+=" sysctl:$*"; return 1; }
    tc() { events+=" tc:$*"; return 1; }
    ip() { events+=" ip:$*"; return 1; }
    remove_cli_command() { events+=" cli"; }

    for case_name in manifest-only missing-qdisc state-payload-mismatch duplicate-sysctl illegal-sysctl; do
        write_valid_v1_tcp_baseline "$BASELINE_DIR" eth0
        case "$case_name" in
            manifest-only)
                cp "$BASELINE_DIR/manifest" "$root/manifest.saved"
                rm -rf -- "$BASELINE_DIR"; mkdir -p "$BASELINE_DIR"
                cp "$root/manifest.saved" "$BASELINE_DIR/manifest"
                ;;
            missing-qdisc) rm -f -- "$BASELINE_DIR/qdisc.txt" ;;
            state-payload-mismatch) printf 'absent\n' > "$BASELINE_DIR/config.state" ;;
            duplicate-sysctl) printf 'net.core.somaxconn\t8192\n' >> "$BASELINE_DIR/sysctl.tsv" ;;
            illegal-sysctl) sed -i 's/^net.core.somaxconn\t.*/net.core.somaxconn\tnot-a-number/' "$BASELINE_DIR/sysctl.tsv" ;;
        esac
        rm -rf -- "$root/expected"; cp -a -- "$BASELINE_DIR" "$root/expected"
        printf '%s\n' "$live_config" > "$CONFIG_FILE"
        printf '%s\n' "$live_sysctl" > "$SYSCTL_FILE"
        printf '%s\n' "$live_service" > "$SERVICE_FILE"
        printf '%s\n' "$live_persist" > "$PERSIST_SCRIPT"
        events=""
        if restore_baseline >/dev/null 2>&1; then fail "$case_name baseline was restored"; fi
        assert_eq '' "$events" "$case_name restore side effects"
        assert_eq "$live_config" "$(<"$CONFIG_FILE")" "$case_name live config"
        assert_eq "$live_sysctl" "$(<"$SYSCTL_FILE")" "$case_name live sysctl file"
        assert_eq "$live_service" "$(<"$SERVICE_FILE")" "$case_name live service"
        assert_eq "$live_persist" "$(<"$PERSIST_SCRIPT")" "$case_name live persistence script"
        diff -r -- "$root/expected" "$BASELINE_DIR" >/dev/null || fail "$case_name immutable baseline was altered"
        if capture_baseline eth0 >/dev/null 2>&1; then fail "$case_name baseline was silently replaced"; fi
        assert_eq '' "$events" "$case_name capture reuse side effects"
        diff -r -- "$root/expected" "$BASELINE_DIR" >/dev/null || fail "$case_name capture changed immutable evidence"
    done

    # A legacy-reference manifest is not trusted unless both the original
    # backup and the exact signed executable captured during migration survive.
    rm -rf -- "$BASELINE_DIR"; mkdir -p "$BASELINE_DIR/legacy-original"
    printf 'SCHEMA\t1\nCREATED_AT\t2026-08-23T00:00:00Z\nCREATED_BY\t7.0.7\nPROVENANCE\tlegacy-reference\nINTERFACE\teth0\n' > "$BASELINE_DIR/manifest"
    printf 'original\n' > "$BASELINE_DIR/legacy-original/marker"
    printf '#!/usr/bin/env bash\necho unsigned\n' > "$BASELINE_DIR/legacy-tool.sh"; chmod 0755 "$BASELINE_DIR/legacy-tool.sh"
    while IFS= read -r case_name; do
        printf '%s\t%s\n' "$case_name" "$(tcp_baseline_test_sysctl_value "$case_name")"
    done < <(tcp_baseline_sysctl_keys) > "$BASELINE_DIR/migration-current-sysctl.tsv"
    printf 'qdisc fq 0: root\n' > "$BASELINE_DIR/migration-current-qdisc.txt"
    rm -rf -- "$root/expected"; cp -a -- "$BASELINE_DIR" "$root/expected"
    events=""
    if restore_baseline >/dev/null 2>&1; then fail "damaged legacy reference was restored"; fi
    assert_eq '' "$events" "damaged legacy restore side effects"
    diff -r -- "$root/expected" "$BASELINE_DIR" >/dev/null || fail "damaged legacy reference was altered"

    # Uninstall must make the same trust decision before removing the CLI or
    # any recovery component.
    printf '#!/usr/bin/env bash\nSCRIPT_NAME="bbrv3-lite"\n' > "$BBRV3_CLI_PATH"; chmod 0755 "$BBRV3_CLI_PATH"
    events=""
    if uninstall_managed 0 >/dev/null 2>&1; then fail "malformed TCP baseline allowed uninstall"; fi
    assert_eq '' "$events" "malformed uninstall side effects"
    [[ -e "$BBRV3_CLI_PATH" && -e "$CONFIG_FILE" && -e "$SERVICE_FILE" ]] || fail "malformed uninstall removed management components"
    diff -r -- "$root/expected" "$BASELINE_DIR" >/dev/null || fail "malformed uninstall changed the baseline"
)

test_tcp_baseline_capture_is_atomic_and_replayable() (
    local root="$TEST_ROOT/tcp-baseline-capture" qdisc_mode=htb key
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/etc/legacy.conf"; SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/systemd/legacy.service"; PERSIST_DIR="$root/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; LEGACY_BACKUP_DIR="$root/legacy-backup"
    sysctl() { [[ "$1" == -n ]] || return 1; tcp_baseline_test_sysctl_value "$2"; }
    tc() {
        case "$1 $2 $3 $4:$qdisc_mode" in
            'qdisc show dev eth0:htb') printf 'qdisc htb 1: root\nqdisc fq 10: parent 1:10\n' ;;
            'class show dev eth0:htb') printf 'class htb 1:10 root rate 100Mbit ceil 100Mbit\n' ;;
            'qdisc show dev eth0:fq') printf 'qdisc fq 8001: root refcnt 2 limit 10000p\n' ;;
            'class show dev eth0:fq') return 0 ;;
            *) return 1 ;;
        esac
    }
    ip() {
        case "$*" in
            '-4 route show table all'|'-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
            '-6 route show table all'|'-6 route show default') return 0 ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        case "$1" in
            is-enabled) printf 'not-found\n'; return 1 ;;
            is-active) printf 'inactive\n'; return 3 ;;
            *) return 0 ;;
        esac
    }

    if capture_baseline eth0 adopt-current >/dev/null 2>&1; then fail "managed HTB was captured as a replayable baseline"; fi
    [[ ! -e "$BASELINE_DIR" && ! -L "$BASELINE_DIR" ]] || fail "unrestorable HTB baseline was published"
    [[ -z "$(find "$STATE_DIR" -maxdepth 1 -name '.baseline.*' -print -quit 2>/dev/null)" ]] || fail "failed baseline capture left a publish candidate"

    qdisc_mode=fq
    capture_baseline eth0 adopt-current
    grep -Fxq $'SCHEMA\t2' "$BASELINE_DIR/manifest" || fail "new TCP baseline schema missing"
    grep -Fxq $'COMPLETE\t1' "$BASELINE_DIR/manifest" || fail "new TCP baseline completion marker missing"
    tcp_baseline_validate "$BASELINE_DIR" || fail "new atomic TCP baseline did not self-validate"
    assert_eq v2 "$TCP_BASELINE_VALIDATED_GENERATION" "new TCP baseline generation"
    for key in FORMAT RESTORE_SCOPE ROUTE_DUMPS; do grep -q "^${key}"$'\t' "$BASELINE_DIR/manifest" || fail "new baseline missing $key"; done
)

test_valid_v1_tcp_baseline_restores() (
    local root="$TEST_ROOT/tcp-baseline-restore" events="" verb unit
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/etc/legacy.conf"; SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/systemd/legacy.service"; PERSIST_DIR="$root/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; LEGACY_BACKUP_DIR="$root/legacy-backup"
    BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    mkdir -p "$BBRV3_SYS_CLASS_NET_ROOT/eth0" "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR"
    write_valid_v1_tcp_baseline "$BASELINE_DIR" eth0
    printf 'live-config\n' > "$CONFIG_FILE"; printf 'live-sysctl\n' > "$SYSCTL_FILE"
    printf 'live-service\n' > "$SERVICE_FILE"; printf 'live-persist\n' > "$PERSIST_SCRIPT"

    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { LOCK_HELD=1; }; release_lock() { LOCK_HELD=0; }
    command_exists() { return 0; }
    sysctl() {
        if [[ "$1" == -n ]]; then tcp_baseline_test_sysctl_value "$2"; return; fi
        [[ "$1" == -q && "$2" == -w ]] || return 1
        events+=" sysctl:${3}"
    }
    tc() {
        case "$1 $2 $3 $4" in
            'qdisc show dev eth0') printf 'qdisc fq 8002: root\n' ;;
            'class show dev eth0') return 0 ;;
            'qdisc replace dev eth0') events+=" tc:$*" ;;
            *) return 0 ;;
        esac
    }
    ip() {
        case "$*" in
            '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;;
            '-6 route show default') return 0 ;;
            *) events+=" ip:$*" ;;
        esac
    }
    systemctl() {
        verb="$1"; shift; unit="${*: -1}"
        case "$verb" in
            is-enabled)
                if [[ "$unit" == "$SERVICE_NAME" && -e "$SERVICE_FILE" ]]; then printf 'enabled\n'; return 0; fi
                printf 'not-found\n'; return 1
                ;;
            is-active)
                if [[ "$unit" == "$SERVICE_NAME" && -e "$SERVICE_FILE" ]]; then printf 'active\n'; return 0; fi
                printf 'inactive\n'; return 3
                ;;
            disable|daemon-reload|stop|start|enable|mask|unmask) events+=" systemctl:$verb $*"; return 0 ;;
            *) return 0 ;;
        esac
    }

    tcp_baseline_validate "$BASELINE_DIR" || fail "supported v1 native baseline rejected"
    assert_eq legacy-v1 "$TCP_BASELINE_VALIDATED_GENERATION" "valid old baseline generation"
    restore_baseline
    assert_eq baseline-config "$(<"$CONFIG_FILE")" "valid old baseline config restore"
    [[ ! -e "$SERVICE_FILE" && ! -e "$PERSIST_SCRIPT" ]] || fail "valid old baseline did not restore absent persistence"
    [[ "$events" == *' sysctl:net.core.default_qdisc=fq'* && "$events" == *' tc:qdisc replace dev eth0 root fq'* ]] ||
        fail "valid old baseline did not restore sysctl/qdisc: $events"
)

test_uninstall_scans_all_interfaces_before_removal() (
    local root="$TEST_ROOT/uninstall-all-ifaces" output writes=0
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$root/etc/legacy.conf"; SERVICE_FILE="$root/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$root/systemd/legacy.service"; PERSIST_DIR="$root/persist"
    PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"; BBRV3_CLI_PATH="$root/bin/bbr"
    DNS_BACKUP_DIR="$root/dns"; IPV6_BACKUP_DIR="$root/ipv6"; BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    mkdir -p "$BBRV3_SYS_CLASS_NET_ROOT/eth-new" "$BBRV3_SYS_CLASS_NET_ROOT/eth-old" \
        "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR" "$(dirname "$BBRV3_CLI_PATH")"
    printf 'live-config\n' > "$CONFIG_FILE"; printf 'live-sysctl\n' > "$SYSCTL_FILE"
    printf 'live-service\n' > "$SERVICE_FILE"; printf 'live-persist\n' > "$PERSIST_SCRIPT"
    printf '#!/usr/bin/env bash\nSCRIPT_NAME="bbrv3-lite"\n' > "$BBRV3_CLI_PATH"; chmod 0755 "$BBRV3_CLI_PATH"
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { :; }
    detect_interface() { fail "uninstall guessed the current default interface"; }
    tc() {
        case "$*" in
            'qdisc show dev eth-old') printf 'qdisc htb 1: root\nqdisc fq 10: parent 1:10\n' ;;
            'class show dev eth-old') printf 'class htb 1:10 root rate 100Mbit ceil 100Mbit\n' ;;
            'qdisc show dev eth-new') printf 'qdisc fq 0: root\n' ;;
            'class show dev eth-new') return 0 ;;
            *) ((writes+=1)); return 1 ;;
        esac
    }
    output=$(uninstall_managed 0 2>&1) && fail "uninstall removed management while old NIC still had HTB"
    grep -Fq 'tc disable --interface eth-old' <<< "$output" || fail "uninstall did not give per-interface recovery command: $output"
    assert_eq 0 "$writes" "uninstall all-interface scan mutations"
    [[ -e "$CONFIG_FILE" && -e "$SYSCTL_FILE" && -e "$SERVICE_FILE" && -e "$PERSIST_SCRIPT" && -e "$BBRV3_CLI_PATH" ]] ||
        fail "uninstall removed management despite old-NIC HTB"
)

test_apply_preflight_and_stale_transaction_are_write_free() (
    local root="$TEST_ROOT/apply-preflight" output writes=0 preflight_calls=0
    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$STATE_DIR/baseline"
    CONFIG_FILE="$root/etc/bbrv3-lite.conf"; SYSCTL_FILE="$root/etc/99-bbrv3-lite.conf"
    SERVICE_FILE="$root/systemd/bbrv3-lite.service"; PERSIST_DIR="$root/persist"; PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
    BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    mkdir -p "$BBRV3_SYS_CLASS_NET_ROOT/eth-new" "$BBRV3_SYS_CLASS_NET_ROOT/eth-old" "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<'EOF'
SCHEMA_VERSION=1
BBR_ENABLED=1
SYSCTL_PROFILE=balanced
ROLE=mixed
BANDWIDTH_MBIT=100
RTT_MS=100
TC_ENABLED=1
TC_INTERFACE=eth-new
TC_RATE_MBIT=95
TC_KNEE_MBIT=100
TC_MARGIN_PERCENT=3
INITCWND=0
INITRWND=0
EOF
    chmod 0600 "$CONFIG_FILE"
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    require_commands() { :; }; acquire_lock() { :; }
    detect_interface() { printf 'eth-new\n'; }
    tc() {
        case "$*" in
            'qdisc show dev eth-old') printf 'qdisc htb 1: root\nqdisc fq 10: parent 1:10\n' ;;
            'class show dev eth-old') printf 'class htb 1:10 root rate 95Mbit ceil 95Mbit\n' ;;
            'qdisc show dev eth-new') printf 'qdisc fq 0: root\n' ;;
            'class show dev eth-new') return 0 ;;
            *) ((writes+=1)); return 1 ;;
        esac
    }
    sysctl() { [[ "$1" == -n ]] && tcp_baseline_test_sysctl_value "$2" && return; ((writes+=1)); }
    output=$(apply_configured_state 2>&1) && fail "apply ignored HTB on another interface"
    grep -Fq 'eth-old' <<< "$output" || fail "apply cross-interface refusal was not explicit: $output"
    assert_eq 0 "$writes" "apply preflight mutations"

    configured_state_target_preflight() { :; }
    network_tuning_preflight() { ((preflight_calls+=1)); return 1; }
    apply_sysctl_profile() { ((writes+=1)); }
    apply_shaping() { ((writes+=1)); }
    writes=0
    if apply_configured_state >/dev/null 2>&1; then fail "apply ignored failed hardware/qdisc preflight"; fi
    assert_eq 1 "$preflight_calls" "apply hardware/qdisc preflight call count"
    assert_eq 0 "$writes" "failed apply hardware/qdisc preflight mutations"

    mkdir -p "$STATE_DIR/.transaction.power-loss"
    ensure_state_layout() { ((writes+=1)); }
    action_qdisc_snapshot() { ((writes+=1)); }
    capture_runtime_sysctls() { ((writes+=1)); }
    writes=0; ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""
    if action_transaction_begin eth-new >/dev/null 2>&1; then fail "new transaction stacked over stale transaction"; fi
    assert_eq 0 "$writes" "stale transaction rejection side effects"
    [[ -d "$STATE_DIR/.transaction.power-loss" ]] || fail "stale transaction evidence was removed"
)

test_tcp_mutations_require_safe_environment() (
    local events=""
    require_root() { :; }
    require_host_network_control() { events+=" host"; return 1; }
    require_systemd_runtime() { events+=" systemd"; return 1; }
    require_commands() { events+=" commands"; return 1; }
    acquire_lock() { events+=" lock"; return 1; }
    baseline_adopt auto >/dev/null 2>&1 || true
    restore_baseline >/dev/null 2>&1 || true
    uninstall_managed 0 >/dev/null 2>&1 || true
    assert_eq ' host host host' "$events" "host-control guards before TCP mutation writes"

    events=""
    require_host_network_control() { events+=" host"; }
    require_systemd_runtime() { events+=" systemd"; }
    restore_baseline >/dev/null 2>&1 || true
    assert_eq ' host systemd commands' "$events" "dependency preflight before TCP restore lock"
)

test_submenu_stays_until_explicit_return() {
    local output count
    dns_policy_status() { printf 'dns-ok\n'; }
    output=$(dns_menu <<< $'1\n0\n')
    count=$(grep -c '^DNS 独立策略$' <<< "$output")
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
    assert_eq 5203 "$(public_peer_ports example.com 1)" "public iperf preflight"
}

test_public_peer_pool_and_formal_failover() {
    (
        local events="" rc=0
        require_commands() { :; }
        PUBLIC_PEER_POOL=$'near.example|近端|ProviderA\nbackup.example|备用|ProviderB'
        median_ping_ms() { [[ "$1" == near.example ]] && printf '1\n' || printf '8\n'; }
        public_peer_ports() {
            if [[ "$1" == near.example ]]; then printf '5201\n5202\n'; else printf '5203\n5204\n'; fi
        }
        BBRV3_PUBLIC_PEER_CANDIDATES=4 BBRV3_PUBLIC_PORTS_PER_HOST=2 auto_pick_peer
        assert_eq 4 "${#PUBLIC_PEER_CANDIDATES[@]}" "public peer reserve count"
        assert_eq 'near.example|5201|1|近端|ProviderA' "${PUBLIC_PEER_CANDIDATES[0]}" "primary public candidate"
        assert_eq 'backup.example|5203|8|备用|ProviderB' "${PUBLIC_PEER_CANDIDATES[1]}" "public pool host diversity"
        assert_eq 'near.example|5202|1|近端|ProviderA' "${PUBLIC_PEER_CANDIDATES[2]}" "same-host fallback ordering"

        WIZARD_PUBLIC_PEER=1; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0
        activate_public_peer_candidate 0
        measure_sweep() {
            events+=" $1:$2"
            case "$1:$2" in near.example:5201|self.example:5201) return "$IPERF_UNAVAILABLE_RC" ;; *) return 0 ;; esac
        }
        auto_measure_with_peer_failover eth0 0
        assert_eq ' near.example:5201 backup.example:5203' "$events" "formal public peer failover order"
        assert_eq backup.example "$WIZARD_PEER" "failover host"
        assert_eq 5203 "$WIZARD_PORT" "failover port"
        assert_eq 1 "$WIZARD_FAILOVERS" "failover counter"
        assert_eq backup.example "$WIZARD_SWEEP_PEER" "sweep host identity"

        events=""
        measure_verify() {
            events+=" $1:$2"
            [[ "$1:$2" != backup.example:5203 ]] || return "$IPERF_UNAVAILABLE_RC"
        }
        auto_verify_with_peer_failover eth0 6 100 0.94 0
        assert_eq ' backup.example:5203 backup.example:5204' "$events" "same-host final verification failover order"
        assert_eq backup.example "$WIZARD_PEER" "final verification backup host"
        assert_eq 5204 "$WIZARD_PORT" "final verification backup port"

        activate_public_peer_candidate 0
        WIZARD_SWEEP_PEER=near.example; WIZARD_SWEEP_PORT=5201; events=""
        measure_verify() {
            events+=" $1:$2"
            [[ "$1" == backup.example ]] && return 0
            return "$IPERF_UNAVAILABLE_RC"
        }
        if auto_verify_with_peer_failover eth0 6 100 0.94 0 >/dev/null 2>&1; then
            fail "final verification crossed to a different host"
        else
            rc=$?
        fi
        assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "same-path verification failure status"
        assert_eq ' near.example:5201 near.example:5202' "$events" "final verification attempted a different host"

        WIZARD_PUBLIC_PEER=0; WIZARD_PEER=self.example; WIZARD_PORT=5201; events=""
        if auto_measure_with_peer_failover eth0 0 >/dev/null 2>&1; then fail "private peer failure reported success"; else rc=$?; fi
        assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "private peer unavailable status"
        assert_eq ' self.example:5201' "$events" "private peer unexpectedly failed over"
    )
}

test_repeated_sample_classifies_peer_unavailable() {
    (
        local rc=0 calls_file="$TEST_ROOT/iperf-sample-calls"
        printf '0\n' > "$calls_file"
        BBRV3_IPERF_ATTEMPTS=1
        iperf_sample() { printf '%s\n' "$(( $(<"$calls_file") + 1 ))" > "$calls_file"; return "$IPERF_UNAVAILABLE_RC"; }
        if sample_repeated busy.example 5201 5 1 1 unshaped >/dev/null 2>&1; then
            fail "unavailable peer sample reported success"
        else
            rc=$?
        fi
        assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "unavailable peer status"
        assert_eq 1 "$(<"$calls_file")" "unavailable peer attempt count"

        printf '0\n' > "$calls_file"; BBRV3_IPERF_ATTEMPTS=3
        iperf_sample() { printf '%s\n' "$(( $(<"$calls_file") + 1 ))" > "$calls_file"; return "$IPERF_DATA_RC"; }
        if sample_repeated malformed.example 5201 5 1 1 unshaped >/dev/null 2>&1; then
            fail "malformed iperf result reported success"
        else
            rc=$?
        fi
        assert_eq "$IPERF_DATA_RC" "$rc" "iperf data error status"
        assert_eq 1 "$(<"$calls_file")" "local data error was retried"
        iperf_failure_is_unavailable 'the server is busy running a test. try again later' || fail "busy error was not classified as unavailable"
        iperf_failure_is_unavailable 'unable to connect to server: Connection refused' || fail "connection error was not classified as unavailable"
        if iperf_failure_is_unavailable 'invalid JSON output'; then fail "local parse error was classified as unavailable"; fi

        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        detect_interface() { printf 'eth0\n'; }
        measure_lock_peer() {
            MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10
            MEASURE_PEER_SOURCE=192.0.2.10; MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE="$2"
        }
        peer_port_open() { return 1; }
        measure_require_locked_port() {
            peer_port_open "$MEASURE_PEER_ADDRESS" "$2" || {
                measure_clear_peer_lock
                return "$IPERF_UNAVAILABLE_RC"
            }
        }
        if measure_sweep closed.example 5201 auto 0 0 0 0 5 1 3 0.1 0 5000 >/dev/null 2>&1; then
            fail "closed public port reported sweep success"
        else
            rc=$?
        fi
        assert_eq "$IPERF_UNAVAILABLE_RC" "$rc" "closed peer status"
    )
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
    # Sweep arithmetic is a pure unit test here.  Freeze a synthetic route so
    # GitHub-hosted runners with DNS AAAA answers but no IPv6 route cannot
    # change the result or prevent the intended assertions from running.
    measure_lock_peer() {
        MEASURE_PEER_HOST="$1"; MEASURE_PEER_ADDRESS=203.0.113.10
        MEASURE_PEER_SOURCE=192.0.2.10; MEASURE_PEER_FAMILY=4; MEASURE_PEER_IFACE="$2"
        path_state_reset
        PATH_PROFILE_SCORE=100; PATH_PROFILE_GRADE=high; PATH_DECISION=trusted; PATH_RISK_FLAGS=clean
    }
    measure_require_locked_port() { :; }
    measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
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
    assert_eq 203.0.113.10 "$(summary_value "$summary" LOCKED_ADDRESS)" "sweep locked peer audit"
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
    local output="$TEST_ROOT/sweep-baseline-failure.log" restore_count=0 rc=0
    sample_repeated() { return 7; }
    measure_restore() { ((restore_count+=1)); }
    if measure_sweep example.com 5201 auto 0 0 0 0 3 1 3 0.1 1 5000 >"$output" 2>&1; then
        fail "failed baseline sample reported sweep success"
    else
        rc=$?
    fi
    assert_eq 7 "$rc" "baseline sample failure status"
    assert_eq 1 "$restore_count" "qdisc restore after baseline failure"
    if grep -Fqi 'division by 0' "$output"; then fail "baseline failure reached invalid sweep arithmetic"; fi
}

test_sweep_hard_cap_and_setup_failure_restore() {
    (
        local restore_count=0 max_rate=0 summary rc=0
        require_root() { :; }; acquire_lock() { :; }; tc_dependencies() { :; }; require_commands() { :; }
        peer_port_open() { :; }; detect_interface() { printf 'eth0\n'; }; qdisc_guard() { :; }
        hardware_profile_values() {
            HARDWARE_CLASS=standard; HARDWARE_LINK_MBIT=1000; HARDWARE_RX_QUEUES=1; HARDWARE_TX_QUEUES=1
        }
        measure_set_latency_baseline() { MEASURE_IDLE_RTT_MS=1; }
        measure_begin() { MEASURE_IFACE=eth0; }
        measure_restore() { ((restore_count+=1)); }
        traffic_report() { :; }; apply_fq() { :; }
        apply_shaping() { (( $2 > max_rate )) && max_rate="$2"; }
        sample_repeated() {
            local label="$6" rate=300
            [[ "$label" =~ (rate|refine|confirm)-([0-9]+) ]] && rate="${BASH_REMATCH[2]}"
            printf '%s\t0\t1000000\t0\t0\t0\tna\t0\t0\t0\t0\t0\t1\tna\n' "$rate"
        }

        measure_sweep example.com 5201 auto 300 100 1000 100 3 1 3 0.1 1 400
        summary="$MEASURE_RUN_DIR/summary.tsv"
        assert_eq 400 "$(summary_value "$summary" HIGH)" "explicit sweep cap clamps high"
        assert_eq 400 "$max_rate" "no shaping sample exceeds explicit cap"
        assert_eq 1 "$restore_count" "qdisc restore after capped sweep"

        restore_count=0
        expanded_scan_cap() { return 9; }
        if measure_sweep example.com 5201 auto 0 0 0 0 3 1 3 0.1 1 5000 auto >/dev/null 2>&1; then
            fail "scan-cap setup failure reported success"
        else
            rc=$?
        fi
        assert_eq 9 "$rc" "scan-cap setup failure status"
        assert_eq 1 "$restore_count" "qdisc restore after scan-cap setup failure"
    )
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

test_install_failure_is_not_success() (
    local output="$TEST_ROOT/install-failure.log"
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    acquire_lock() { :; }; require_commands() { :; }
    detect_interface() { printf 'eth0\n'; }; capture_baseline() { :; }; migrate_legacy_config() { :; }
    auto_tune_route_guard() { :; }; shaping_target_preflight() { :; }
    qdisc_guard() { :; }; network_tuning_preflight() { :; }; run_action_transaction_multi() { shift; "$@"; }
    nic_policy_ownership_preflight() { :; }; retire_legacy_sysctl() { :; }; nic_migrate_legacy_policy() { :; }
    nic_baseline_capture() { :; }; nic_policy_exists() { return 1; }; nic_policy_write() { :; }
    nic_finalize_multi_config() { SYSCTL_PROFILE=balanced; ROLE=mixed; BANDWIDTH_MBIT=0; RTT_MS=0; }
    load_config() { reset_config; }; apply_sysctl_profile() { :; }; apply_fq() { :; }; apply_initial_windows() { :; }
    save_config() { :; }; install_persistence() { return 9; }; systemctl() { fail "systemctl called after persistence failure"; }
    if install_base_tuning auto balanced mixed 0 0 >"$output" 2>&1; then fail "persistence failure reported success"; fi
    if grep -Fq '基础调优已安装' "$output"; then fail "success message printed after failure"; fi
    grep -Fq '持久化安装失败' "$output" || fail "partial-runtime failure was not explained"
)

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
    local events="" config_before='config-before' sysctl_before='sysctl-before' legacy_sysctl_before='legacy-sysctl-before'
    local service_before='service-before' persist_before='persist-before'
    local verb unit
    declare -A unit_enabled=(
        [bbrv3-lite.service]=enabled
        [bbr-optimize-persist.service]=enabled
    )
    declare -A unit_active=(
        [bbrv3-lite.service]=active
        [bbr-optimize-persist.service]=active
    )
    local LEGACY_SYSCTL_FILE="$TEST_ROOT/etc/legacy-sysctl.conf"
    local LEGACY_SERVICE_FILE="$TEST_ROOT/systemd/legacy.service"
    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$SERVICE_FILE")" "$PERSIST_DIR"
    printf '%s\n' "$config_before" > "$CONFIG_FILE"
    printf '%s\n' "$sysctl_before" > "$SYSCTL_FILE"
    printf '%s\n' "$legacy_sysctl_before" > "$LEGACY_SYSCTL_FILE"
    printf '%s\n' "$service_before" > "$SERVICE_FILE"
    printf '%s\n' "$persist_before" > "$PERSIST_SCRIPT"
    ACTION_TRANSACTION_DIR=""; ACTION_TRANSACTION_IFACE=""; ACTION_TRANSACTION_INTERFACES=""; ACTION_TRANSACTION_ROLLING_BACK=0; LOCK_HELD=1
    MULTI_NIC_ENABLED=0; TC_INTERFACE=auto
    action_qdisc_snapshot() { printf 'KIND\tfq\nRATE\t\nARGS\t\n' > "$2"; }
    restore_action_qdisc() { events+=" qdisc:$1"; }
    capture_runtime_sysctls() { printf 'net.test.key\tbefore\n'; }
    sysctl() { [[ "$1" == -q && "$2" == -w ]] && events+=" sysctl:${3}"; }
    ip() { case "$*" in '-4 route show default') printf 'default via 192.0.2.1 dev eth0\n' ;; '-6 route show default') : ;; *) events+=" ip:$*" ;; esac; }
    systemctl() {
        verb="$1"; shift
        case "$verb" in
            is-enabled)
                unit="$1"; printf '%s\n' "${unit_enabled[$unit]:-not-found}"
                [[ "${unit_enabled[$unit]:-not-found}" == enabled ]]
                ;;
            is-active)
                unit="$1"; printf '%s\n' "${unit_active[$unit]:-inactive}"
                [[ "${unit_active[$unit]:-inactive}" == active ]]
                ;;
            disable)
                events+=" systemctl:$verb $*"; unit="${*: -1}"
                unit_enabled[$unit]=disabled
                [[ " $* " != *' --now '* ]] || unit_active[$unit]=inactive
                ;;
            enable)
                events+=" systemctl:$verb $*"; unit="${*: -1}"; unit_enabled[$unit]=enabled
                ;;
            start)
                events+=" systemctl:$verb $*"; unit="${*: -1}"; unit_active[$unit]=active
                ;;
            stop)
                events+=" systemctl:$verb $*"; unit="${*: -1}"; unit_active[$unit]=inactive
                ;;
            *) events+=" systemctl:$verb $*"; return 0 ;;
        esac
    }
    release_lock() { LOCK_HELD=0; events+=" release"; }
    acquire_lock() { LOCK_HELD=1; events+=" acquire"; }
    transaction_failure() {
        printf 'changed\n' > "$CONFIG_FILE"
        printf 'changed\n' > "$SYSCTL_FILE"
        rm -f -- "$LEGACY_SYSCTL_FILE"
        printf 'changed\n' > "$SERVICE_FILE"
        printf 'changed\n' > "$PERSIST_SCRIPT"
        return 7
    }
    if run_action_transaction_multi eth0 transaction_failure; then fail "failed transaction reported success"; fi
    assert_eq "$config_before" "$(<"$CONFIG_FILE")" "transaction config restore"
    assert_eq "$sysctl_before" "$(<"$SYSCTL_FILE")" "transaction sysctl file restore"
    assert_eq "$legacy_sysctl_before" "$(<"$LEGACY_SYSCTL_FILE")" "transaction legacy sysctl restore"
    assert_eq "$service_before" "$(<"$SERVICE_FILE")" "transaction service restore"
    assert_eq "$persist_before" "$(<"$PERSIST_SCRIPT")" "transaction persistent script restore"
    [[ "$events" == *'sysctl:net.test.key=before'* && "$events" == *'qdisc:eth0'* && "$events" == *'systemctl:start bbrv3-lite.service'* ]] ||
        fail "transaction runtime/service restore events missing: $events"
    assert_eq '' "$ACTION_TRANSACTION_DIR" "transaction snapshot cleanup"
}

test_auto_tune_commits_only_after_final_verify() {
    local events="" verify_fail=0 verify_path_drift=0 verify_endpoint_drift=0 candidate_rejected=0 summary_dir="$TEST_ROOT/auto-summary"
    local path_fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local endpoint_fp=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    mkdir -p "$summary_dir"
    WIZARD_PEER=example.com; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=0; WIZARD_PEER_RTT=0; WIZARD_FAILOVERS=0
    WIZARD_SWEEP_PEER=""; WIZARD_SWEEP_PORT=0
    prepare_auto_tuning_runtime() { events+=" prepare"; }
    measure_sweep() {
        events+=" sweep"; MEASURE_RUN_DIR="$summary_dir"
        if (( candidate_rejected )); then
            printf '%s\n' \
                $'RECOMMEND\t' $'BROKE_AT\t105' $'UNSHAPED_MBIT\t110' $'NO_KNEE\t0' \
                $'CONFIRMED\t0' $'REJECT_REASON\tconfirmation-failed' $'MIN_EFFICIENCY_RATIO\t0.94' \
                $'CLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t0' $'PATH_ROUTE_FINGERPRINT\t'"$path_fp" $'PATH_ENDPOINT_FINGERPRINT\t'"$endpoint_fp" \
                $'PATH_RTT_P95_MS\t1' $'CONFIDENCE_SCORE\t100' $'CONFIDENCE_GRADE\thigh' $'CONFIDENCE_REASONS\tclean' > "$summary_dir/summary.tsv"
        else
            printf '%s\n' \
                $'RECOMMEND\t100' $'BROKE_AT\t105' $'UNSHAPED_MBIT\t110' $'NO_KNEE\t0' \
                $'CONFIRMED\t1' $'REJECT_REASON\t' $'MIN_EFFICIENCY_RATIO\t0.94' \
                $'CLEAN_BASE_RETRANS_RATIO_EST_PERCENT\t0' $'PATH_ROUTE_FINGERPRINT\t'"$path_fp" $'PATH_ENDPOINT_FINGERPRINT\t'"$endpoint_fp" \
                $'PATH_RTT_P95_MS\t1' $'CONFIDENCE_SCORE\t100' $'CONFIDENCE_GRADE\thigh' $'CONFIDENCE_REASONS\tclean' > "$summary_dir/summary.tsv"
        fi
    }
    apply_sysctl_profile() { events+=" sysctl"; }
    apply_shaping() { events+=" shape"; }
    verify_runtime_tuning() { events+=" runtime"; }
    measure_verify() {
        events+=" verify"
        (( verify_fail == 0 )) || return 1
        if (( verify_path_drift )); then
            sed -i 's/^PATH_ROUTE_FINGERPRINT.*/PATH_ROUTE_FINGERPRINT\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' "$summary_dir/summary.tsv"
        fi
        if (( verify_endpoint_drift )); then
            sed -i 's/^PATH_ENDPOINT_FINGERPRINT.*/PATH_ENDPOINT_FINGERPRINT\tdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' "$summary_dir/summary.tsv"
        fi
    }
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
    assert_eq ' prepare sweep sysctl shape runtime verify persist' "$events" "auto commit order"
    assert_eq 100 "$RTT_MS" "path-aware auto tuning RTT"
    assert_eq 1 "$(summary_value "$summary_dir/summary.tsv" PEER_RTT_MS)" "auto peer RTT history"
    assert_eq 100 "$(summary_value "$summary_dir/summary.tsv" TUNING_RTT_MS)" "auto tuning RTT history"
    assert_eq role-floor "$(summary_value "$summary_dir/summary.tsv" TUNING_RTT_SOURCE)" "path-aware RTT source"
    assert_eq example.com "$(summary_value "$summary_dir/summary.tsv" SWEEP_PEER)" "auto sweep peer history"
    assert_eq 5201 "$(summary_value "$summary_dir/summary.tsv" SWEEP_PORT)" "auto sweep port history"
    assert_eq 0 "$(summary_value "$summary_dir/summary.tsv" TOTAL_PUBLIC_PEER_FAILOVERS)" "auto failover history"

    events=""; verify_path_drift=1
    if auto_tune_execute eth0 balanced mixed 0 150 1; then fail "cross-path final verify reported auto success"; fi
    assert_eq ' prepare sweep sysctl shape runtime verify' "$events" "cross-path result was persisted"

    events=""; verify_path_drift=0; verify_endpoint_drift=1
    if auto_tune_execute eth0 balanced mixed 0 150 1; then fail "cross-endpoint final verify reported auto success"; fi
    assert_eq ' prepare sweep sysctl shape runtime verify' "$events" "cross-endpoint result was persisted"

    events=""; verify_endpoint_drift=0; verify_fail=1
    if auto_tune_execute eth0 balanced mixed 0 150 1; then fail "failed final verify reported auto success"; fi
    assert_eq ' prepare sweep sysctl shape runtime verify' "$events" "auto persisted before failed verify"
}

test_cli_rejects_missing_and_ignored_options() {
    local called=0
    detect_profile() { called=1; }
    tc_trial() { called=1; }
    measure_probe() { called=1; }
    measure_path_profile() { called=1; }
    measure_verify() { called=1; }
    measure_compare() { called=1; }
    kernel_status() { called=1; }
    kernel_install() { called=1; }
    dns_policy_status() { called=1; }
    dns_policy_plan() { called=1; }
    dns_policy_apply() { called=1; }
    dns_policy_verify() { called=1; }
    ipv6_policy_status() { called=1; }
    ipv6_policy_plan() { called=1; }
    ipv6_policy_apply() { called=1; }
    ipv6_policy_verify() { called=1; }

    if cmd_install --profile >/dev/null 2>&1; then fail "missing install option value accepted"; fi
    if parse_common_profile_options --bandwidth 100 >/dev/null 2>&1; then fail "unpaired install bandwidth accepted"; fi
    if parse_common_profile_options --rtt 100 >/dev/null 2>&1; then fail "unpaired install RTT accepted"; fi
    if cmd_detect --target >/dev/null 2>&1; then fail "missing detect option value accepted"; fi
    if cmd_tc trial 100 --margin 3 >/dev/null 2>&1; then fail "ignored tc trial option accepted"; fi
    if cmd_tc trial 08 >/dev/null 2>&1; then fail "ambiguous leading-zero integer accepted"; fi
    if cmd_tc trial 18446744073709551617 >/dev/null 2>&1; then fail "overflowing integer accepted"; fi
    if cmd_tc enable 100 --knee 90 >/dev/null 2>&1; then fail "knee below rate accepted"; fi
    if cmd_measure probe --peer example.com --low 50 >/dev/null 2>&1; then fail "ignored probe option accepted"; fi
    if cmd_measure path --peer example.com --port 5201 >/dev/null 2>&1; then fail "ignored path port accepted"; fi
    if cmd_measure probe --peer example.com --samples 5 >/dev/null 2>&1; then fail "ignored probe samples accepted"; fi
    if cmd_measure verify --peer example.com --parallel 2 >/dev/null 2>&1; then fail "ignored verify parallel accepted"; fi
    if cmd_measure compare --peer example.com --rate 100 --parallel 2 >/dev/null 2>&1; then fail "ignored compare parallel accepted"; fi
    if cmd_measure probe --peer example.com --rounds 2 >/dev/null 2>&1; then fail "ignored probe rounds accepted"; fi
    if cmd_measure compare --peer example.com >/dev/null 2>&1; then fail "missing compare rate accepted"; fi
    if cmd_measure compare --peer example.com --rate 08 >/dev/null 2>&1; then fail "ambiguous compare rate accepted"; fi
    if cmd_kernel status --track lts >/dev/null 2>&1; then fail "ignored kernel status option accepted"; fi
    if cmd_kernel install --track edge >/dev/null 2>&1; then fail "invalid kernel track accepted"; fi
    if cmd_dns status plain >/dev/null 2>&1; then fail "extra DNS status argument accepted"; fi
    if cmd_dns apply bogus >/dev/null 2>&1; then fail "invalid DNS policy accepted"; fi
    if cmd_ipv6 status permanent >/dev/null 2>&1; then fail "extra IPv6 status argument accepted"; fi
    if cmd_ipv6 disable forever >/dev/null 2>&1; then fail "invalid IPv6 compatibility mode accepted"; fi
    assert_eq 0 "$called" "invalid CLI reached implementation"
}

test_dns_apply_failure_restores_action_snapshot() (
    local restart_count=0
    rm -rf -- "$DNS_BACKUP_DIR"
    rm -f -- "$DNS_DROPIN" "$DNS_RESOLV_CONF"
    mkdir -p -- "$(dirname "$DNS_DROPIN")" "$(dirname "$DNS_RESOLV_CONF")" "$(dirname "$DNS_STUB_RESOLV")" "$DNS_BACKUP_DIR/baseline"
    printf 'incomplete\n' > "$DNS_BACKUP_DIR/baseline/partial"
    printf 'nameserver 127.0.0.53\n' > "$DNS_STUB_RESOLV"
    ln -s "$DNS_STUB_RESOLV" "$DNS_RESOLV_CONF"
    DNS_TRANSACTION_DIR=""
    require_root() { :; }; require_host_network_control() { :; }; require_systemd_runtime() { :; }
    acquire_lock() { :; }; require_commands() { :; }
    systemctl() {
        case "$1" in
            cat) return 0 ;;
            is-enabled) printf 'enabled\n' ;;
            is-active) printf 'active\n' ;;
            show) printf 'loaded\n' ;;
            restart) ((restart_count+=1)); return 0 ;;
            daemon-reload|enable|disable|stop|unmask|mask) return 0 ;;
            *) return 0 ;;
        esac
    }
    resolvectl() {
        case "$1" in
            domain)
                if [[ -f "$DNS_DROPIN" ]]; then printf 'Global: ~.\n'; else printf 'Global:\n'; fi
                ;;
            dns) printf 'Global: 1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe\n' ;;
            status)
                printf '%s\n' $'Global\n       Protocols: -DNSOverTLS\n       DNS Servers 1.1.1.1 2606:4700:4700::1111 9.9.9.9 2620:fe::fe\nFallback DNS Servers 8.8.8.8 2001:4860:4860::8888\n        DNS Domain ~.\nLink 2 (eth0)'
                ;;
            flush-caches) return 0 ;;
            query) return 1 ;;
            *) return 1 ;;
        esac
    }

    # A pre-existing incomplete baseline is immutable evidence, not something
    # a later run may silently replace with the already-modified current state.
    if dns_apply plain >/dev/null 2>&1; then fail "incomplete DNS baseline was silently replaced"; fi
    [[ -f "$DNS_BACKUP_DIR/baseline/partial" && ! -e "$DNS_BACKUP_DIR/baseline/manifest" ]] || fail "incomplete DNS baseline was altered"
    [[ ! -e "$DNS_DROPIN" && -L "$DNS_RESOLV_CONF" ]] || fail "invalid-baseline rejection modified DNS files"
    assert_eq '' "$DNS_TRANSACTION_DIR" "invalid-baseline transaction isolation"

    rm -rf -- "$DNS_BACKUP_DIR/baseline"
    if dns_apply plain >/dev/null 2>&1; then fail "failed DNS verification reported success"; fi
    [[ -L "$DNS_RESOLV_CONF" && $(readlink "$DNS_RESOLV_CONF") == "$DNS_STUB_RESOLV" ]] || fail "DNS resolv.conf rollback"
    [[ ! -e "$DNS_DROPIN" ]] || fail "DNS drop-in rollback"
    grep -Fxq $'SCHEMA\t2' "$DNS_BACKUP_DIR/baseline/manifest" || fail "DNS baseline schema was not recorded"
    grep -Fxq $'DNS_UNIT_LIFECYCLE\t1' "$DNS_BACKUP_DIR/baseline/manifest" || fail "DNS baseline lifecycle was not recorded"
    assert_eq '' "$DNS_TRANSACTION_DIR" "DNS transaction cleanup"
    (( restart_count >= 2 )) || fail "DNS apply/rollback did not restart resolved"

    rm -rf -- "$DNS_BACKUP_DIR/baseline"
    mkdir -p -- "$DNS_BACKUP_DIR/baseline"
    printf 'CREATED_AT\tlegacy\n' > "$DNS_BACKUP_DIR/baseline/manifest"
    printf 'present\n' > "$DNS_BACKUP_DIR/baseline/resolv.state"
    printf 'nameserver 198.51.100.53\n' > "$DNS_BACKUP_DIR/baseline/resolv.conf"
    printf 'absent\n' > "$DNS_BACKUP_DIR/baseline/dropin.state"
    printf 'active\n' > "$DNS_BACKUP_DIR/baseline/service.active"
    printf 'current\n' > "$DNS_RESOLV_CONF"
    printf 'current-dropin\n' > "$DNS_DROPIN"
    dns_restore_snapshot "$DNS_BACKUP_DIR/baseline" >/dev/null 2>&1 || fail "legacy DNS baseline restore failed"
    assert_eq 'nameserver 198.51.100.53' "$(<"$DNS_RESOLV_CONF")" "legacy DNS baseline content"
    [[ ! -e "$DNS_DROPIN" ]] || fail "legacy DNS baseline did not remove absent drop-in"
)

test_ipv6_malformed_baseline_is_immutable_and_write_free() {
    local assignment key value writes=0
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
            ((writes+=1))
            assignment="$3"; key="${assignment%%=*}"; value="${assignment#*=}"
            ipv6_values[$key]="$value"
            return 0
        fi
        return 1
    }
    if ipv6_disable permanent >/dev/null 2>&1; then fail "malformed immutable IPv6 baseline was accepted"; fi
    assert_eq 0 "$writes" "malformed IPv6 baseline caused runtime writes"
    assert_eq 0 "${ipv6_values[net.ipv6.conf.all.disable_ipv6]}" "IPv6 all remained unchanged"
    assert_eq 0 "${ipv6_values[net.ipv6.conf.default.disable_ipv6]}" "IPv6 default remained unchanged"
    assert_eq 0 "${ipv6_values[net.ipv6.conf.lo.disable_ipv6]}" "IPv6 lo remained unchanged"
    assert_eq 'pre-existing-policy' "$(<"$IPV6_SYSCTL_FILE")" "malformed baseline changed IPv6 persistent policy"
    [[ -f "$IPV6_BACKUP_DIR/baseline/partial" && ! -e "$IPV6_BACKUP_DIR/baseline/manifest" ]] || fail "malformed immutable IPv6 baseline was overwritten"
    assert_eq '' "$IPV6_TRANSACTION_DIR" "IPv6 transaction cleanup"
}

run_test() {
    printf '==> %s\n' "$1"
    "$1"
}

run_test test_config_parser
run_test test_legacy_migration
run_test test_profile_math
run_test test_bbr_compatibility_guard_and_generation_reporting
run_test test_xanmod_cpu_level_and_track_selection
run_test test_hardware_aware_model
run_test test_managed_sysctl_runtime_verifier
run_test test_legacy_baseline_reference
run_test test_qdisc_replay_filters_kernel_runtime_fields
run_test test_mq_child_guard_and_restore
run_test test_managed_rate_unit_parsing
run_test test_tc_transaction
run_test test_measurement_math_and_history
run_test test_v71_measurement_metrics_and_confidence
run_test test_peak_core_cpu_detection
run_test test_adaptive_sampling_and_contamination_guard
run_test test_measure_compare_is_temporary_and_auditable
run_test test_systemd_generation
run_test test_baseline_captures_persistence_lifecycle
run_test test_systemd_lifecycle_strict_queries_and_runtime_states
run_test test_persistent_artifact_consistency_verifier
run_test test_legacy_sysctl_retirement_requires_baseline_and_transaction
run_test test_cli_command_removal_is_scoped
run_test test_uninstall_purge_preflight_is_write_free
run_test test_uninstall_restores_before_removal
run_test test_tcp_baseline_validation_is_write_free
run_test test_tcp_baseline_capture_is_atomic_and_replayable
run_test test_valid_v1_tcp_baseline_restores
run_test test_uninstall_scans_all_interfaces_before_removal
run_test test_apply_preflight_and_stale_transaction_are_write_free
run_test test_tcp_mutations_require_safe_environment
run_test test_submenu_stays_until_explicit_return
run_test test_menu_exits_after_uninstall_signal
run_test test_peer_parser
run_test test_public_peer_requires_real_iperf_preflight
run_test test_public_peer_pool_and_formal_failover
run_test test_repeated_sample_classifies_peer_unavailable
run_test test_sweep_without_knee_does_not_recommend_ceiling
run_test test_refine_preserves_throughput_stall_and_confirmation_gate
run_test test_sweep_baseline_failure_stops_and_restores
run_test test_sweep_hard_cap_and_setup_failure_restore
run_test test_persistence_restart_hands_off_lock
run_test test_dependency_install_is_minimal
run_test test_process_substitution_source_resolution
run_test test_self_update_rolls_back_split_install
run_test test_action_transaction_rolls_back_failed_step
run_test test_container_mutation_guard
run_test test_install_failure_is_not_success
run_test test_force_scan_requires_explicit_flag
run_test test_measurement_acceptance_gate
run_test test_auto_tune_commits_only_after_final_verify
run_test test_dns_apply_failure_restores_action_snapshot
run_test test_ipv6_malformed_baseline_is_immutable_and_write_free
run_test test_cli_rejects_missing_and_ignored_options
echo "core tests: OK"
