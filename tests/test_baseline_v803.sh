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

write_sysctl_schema_1_snapshot() {
    local file="$1" key
    : > "$file"
    while IFS= read -r key; do
        printf '%s\t%s\n' "$key" "$(fixture_sysctl_value "$key")" >> "$file"
    done < <(tcp_sysctl_schema_1_keys)
}

write_valid_baseline() {
    local directory="$1" schema="$2" name
    rm -rf -- "$directory"
    mkdir -p -- "$directory"
    if [[ "$schema" == 3 ]]; then
        printf 'SCHEMA\t3\nFORMAT\t%s\nRESTORE_SCOPE\t%s\nROUTE_DUMPS\t%s\nCOMPLETE\t1\nCREATED_AT\t2026-08-29T00:00:00Z\nCREATED_BY\t8.0.3\nPROVENANCE\tnative\nINTERFACE\teth0\nSYSCTL_SCHEMA\t1\nSYSCTL_KEYS\t%s\n' \
            "$TCP_BASELINE_FORMAT" "$TCP_BASELINE_NATIVE_SCOPE" "$TCP_BASELINE_ROUTE_DUMPS" \
            "$(tcp_sysctl_schema_keys_csv 1)" > "$directory/manifest"
    else
        fail "unsupported baseline fixture schema: $schema"
    fi
    write_sysctl_schema_1_snapshot "$directory/sysctl.tsv"
    printf 'qdisc fq 8001: root limit 10000p flow_limit 100p\n' > "$directory/qdisc.txt"
    : > "$directory/class.txt"
    : > "$directory/routes-v4.txt"; : > "$directory/routes-v6.txt"
    printf 'default via 192.0.2.1 dev eth0\n' > "$directory/default-route-v4.txt"
    : > "$directory/default-route-v6.txt"
    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        printf 'absent\n' > "$directory/${name}.state"
    done
    printf 'not-found\tinactive\n' > "$directory/service.unit"
    printf 'not-found\tinactive\n' > "$directory/legacy-service.unit"
    chmod -R go-rwx "$directory"
}

write_v802_schema2_fixture() {
    local directory="$1" name
    rm -rf -- "$directory"
    mkdir -p -- "$directory"

    # Historical fixture derived from tag v8.0.2.
    # Keep every historical field, key, payload and lifecycle token literal:
    # this fixture must not drift with current constants or capture helpers.
    # Because managed payloads are present, the tag's capture path requires
    # explicit adopt-current provenance rather than native first-run capture.
    cat > "$directory/manifest" <<'EOF'
SCHEMA	2
FORMAT	bbrv3-lite-tcp-baseline
RESTORE_SCOPE	managed-paths+tcp-sysctl+qdisc+unit-lifecycle+default-route-windows
ROUTE_DUMPS	diagnostic-only
COMPLETE	1
CREATED_AT	2026-08-25T00:00:00Z
CREATED_BY	8.0.2
PROVENANCE	adopt-current
INTERFACE	eth0
EOF
    cat > "$directory/sysctl.tsv" <<'EOF'
net.core.default_qdisc	fq
net.ipv4.tcp_congestion_control	cubic
net.core.rmem_max	16777216
net.core.wmem_max	16777216
net.ipv4.tcp_rmem	4096 131072 16777216
net.ipv4.tcp_wmem	4096 16384 16777216
net.ipv4.tcp_mtu_probing	0
net.ipv4.tcp_fastopen	1
net.core.somaxconn	4096
net.ipv4.tcp_max_syn_backlog	4096
net.core.netdev_max_backlog	1000
EOF
    printf 'qdisc fq 8001: root limit 10000p flow_limit 100p\n' > "$directory/qdisc.txt"
    : > "$directory/class.txt"
    cat > "$directory/routes-v4.txt" <<'EOF'
default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 12 initrwnd 24
192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.10
EOF
    cat > "$directory/routes-v6.txt" <<'EOF'
default via 2001:db8::1 dev eth0 proto static metric 1024 initcwnd 10 initrwnd 20
2001:db8::/64 dev eth0 proto kernel metric 256
EOF
    printf 'default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 12 initrwnd 24\n' > "$directory/default-route-v4.txt"
    printf 'default via 2001:db8::1 dev eth0 proto static metric 1024 initcwnd 10 initrwnd 20\n' > "$directory/default-route-v6.txt"

    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        printf 'present\n' > "$directory/${name}.state"
    done
    cat > "$directory/config" <<'EOF'
SCHEMA=1
BBR_ENABLED=0
SYSCTL_PROFILE=balanced
ROLE=mixed
EOF
    cat > "$directory/sysctl" <<'EOF'
# historical bbrv3-lite sysctl drop-in
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = cubic
EOF
    cat > "$directory/legacy-sysctl" <<'EOF'
# historical legacy sysctl payload
net.core.somaxconn = 4096
EOF
    cat > "$directory/service" <<'EOF'
[Unit]
Description=Historical bbrv3-lite service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/bbrv3-lite/net-tcp-tune.sh apply
[Install]
WantedBy=multi-user.target
EOF
    cat > "$directory/legacy-service" <<'EOF'
[Unit]
Description=Historical legacy BBR service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/legacy-bbr-apply
[Install]
WantedBy=multi-user.target
EOF
    cat > "$directory/persist-script" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    printf 'enabled\tactive\n' > "$directory/service.unit"
    printf 'disabled\tinactive\n' > "$directory/legacy-service.unit"

    chmod 0700 "$directory"
    chmod 0600 "$directory"/*
    chmod 0700 "$directory/persist-script"
}

write_v802_native_first_install_schema2_fixture() {
    local directory="$1"
    rm -rf -- "$directory"
    mkdir -p -- "$directory"

    # Historical first-install fixture derived from tag v8.0.2.
    # install_base_tuning_steps captured the baseline before migration,
    # sysctl/config persistence, or service installation.  For native
    # provenance, managed_artifacts_exist also required all six managed paths
    # to be absent before capture could proceed.  Keep every historical field,
    # sysctl key, path state, route, qdisc and unit token literal.
    cat > "$directory/manifest" <<'EOF'
SCHEMA	2
FORMAT	bbrv3-lite-tcp-baseline
RESTORE_SCOPE	managed-paths+tcp-sysctl+qdisc+unit-lifecycle+default-route-windows
ROUTE_DUMPS	diagnostic-only
COMPLETE	1
CREATED_AT	2026-08-25T01:02:03Z
CREATED_BY	8.0.2
PROVENANCE	native
INTERFACE	eth0
EOF
    cat > "$directory/sysctl.tsv" <<'EOF'
net.core.default_qdisc	fq_codel
net.ipv4.tcp_congestion_control	cubic
net.core.rmem_max	8388608
net.core.wmem_max	8388608
net.ipv4.tcp_rmem	4096 131072 8388608
net.ipv4.tcp_wmem	4096 16384 8388608
net.ipv4.tcp_mtu_probing	0
net.ipv4.tcp_fastopen	1
net.core.somaxconn	2048
net.ipv4.tcp_max_syn_backlog	2048
net.core.netdev_max_backlog	1000
EOF
    printf 'qdisc fq 8100: root limit 9000p flow_limit 90p\n' > "$directory/qdisc.txt"
    : > "$directory/class.txt"
    cat > "$directory/routes-v4.txt" <<'EOF'
default via 198.51.100.1 dev eth0 proto dhcp metric 100 initcwnd 15 initrwnd 25
198.51.100.0/24 dev eth0 proto kernel scope link src 198.51.100.10
EOF
    cat > "$directory/routes-v6.txt" <<'EOF'
default via 2001:db8:1::1 dev eth0 proto static metric 1024 initcwnd 11 initrwnd 21
2001:db8:1::/64 dev eth0 proto kernel metric 256
EOF
    printf 'default via 198.51.100.1 dev eth0 proto dhcp metric 100 initcwnd 15 initrwnd 25\n' > "$directory/default-route-v4.txt"
    printf 'default via 2001:db8:1::1 dev eth0 proto static metric 1024 initcwnd 11 initrwnd 21\n' > "$directory/default-route-v6.txt"

    printf 'absent\n' > "$directory/config.state"
    printf 'absent\n' > "$directory/sysctl.state"
    printf 'absent\n' > "$directory/legacy-sysctl.state"
    printf 'absent\n' > "$directory/service.state"
    printf 'absent\n' > "$directory/legacy-service.state"
    printf 'absent\n' > "$directory/persist-script.state"
    printf 'not-found\tinactive\n' > "$directory/service.unit"
    printf 'not-found\tinactive\n' > "$directory/legacy-service.unit"

    chmod 0700 "$directory"
    chmod 0600 "$directory"/*
}

test_v802_schema2_baseline_uses_fixed_schema() (
    local baseline="$TEST_ROOT/historical-v802"
    write_v802_schema2_fixture "$baseline"
    tcp_baseline_validate "$baseline" || fail 'v8.0.2 baseline was rejected'
    assert_eq v2 "$TCP_BASELINE_VALIDATED_GENERATION" 'v8.0.2 baseline generation'
    assert_eq 1 "$TCP_BASELINE_VALIDATED_SYSCTL_SCHEMA" 'v8.0.2 sysctl schema'

    # Simulate a future release adding a currently supported sysctl. Historical
    # validity must remain bound to the immutable v8.0.2 schema-1 key set.
    tcp_managed_sysctl_keys() {
        tcp_sysctl_schema_1_keys
        printf 'net.ipv4.tcp_ecn\n'
    }
    tcp_baseline_validate "$baseline" || fail 'future managed key invalidated a v8.0.2 baseline'
)

test_impossible_missing_unit_snapshot_is_rejected_early() (
    local baseline="$TEST_ROOT/impossible-unit-v802"
    write_v802_schema2_fixture "$baseline"
    printf 'not-found\tactive\n' > "$baseline/service.unit"
    if tcp_baseline_validate "$baseline" >/dev/null 2>&1; then
        fail 'baseline accepted an impossible not-found/active lifecycle snapshot'
    fi
)

test_new_schema_metadata_is_strict() (
    local baseline="$TEST_ROOT/schema-v3"
    write_valid_baseline "$baseline" 3
    tcp_baseline_validate "$baseline" || fail 'new schema baseline was rejected'
    assert_eq v3 "$TCP_BASELINE_VALIDATED_GENERATION" 'new baseline generation'

    # Simulate a future release that knows both schema 1 and a new schema 2.
    # The recorded historical schema, not the moving current schema, controls
    # baseline validity; restore compatibility is checked separately.
    tcp_sysctl_schema_keys() {
        case "$1" in
            1) tcp_sysctl_schema_1_keys ;;
            2) tcp_sysctl_schema_1_keys; printf 'net.ipv4.tcp_ecn\n' ;;
            *) return 1 ;;
        esac
    }
    TCP_SYSCTL_SCHEMA=2
    tcp_baseline_validate "$baseline" || fail 'future current schema invalidated a known historical schema-1 baseline'
    assert_eq 1 "$TCP_BASELINE_VALIDATED_SYSCTL_SCHEMA" 'recorded historical sysctl schema'

    sed -i $'/^SYSCTL_KEYS\t/d' "$baseline/manifest"
    if tcp_baseline_validate "$baseline" >/dev/null 2>&1; then fail 'schema missing SYSCTL_KEYS was accepted'; fi

    write_valid_baseline "$baseline" 3
    printf 'UNKNOWN_FIELD\t1\n' >> "$baseline/manifest"
    if tcp_baseline_validate "$baseline" >/dev/null 2>&1; then fail 'unknown manifest field was accepted'; fi

    write_valid_baseline "$baseline" 3
    sed -i 's/^SYSCTL_KEYS\t.*/SYSCTL_KEYS\tnet.core.default_qdisc/' "$baseline/manifest"
    if tcp_baseline_validate "$baseline" >/dev/null 2>&1; then fail 'damaged SYSCTL_KEYS metadata was accepted'; fi
)

test_restore_never_invents_future_sysctl_history() (
    local baseline="$TEST_ROOT/limited-restore" output writes="$TEST_ROOT/sysctl-writes" expected="$TEST_ROOT/expected" restore_steps=0
    write_v802_schema2_fixture "$baseline"
    cp -a -- "$baseline" "$expected"
    : > "$writes"
    tcp_managed_sysctl_keys() {
        tcp_sysctl_schema_1_keys
        printf 'net.ipv4.tcp_ecn\n'
    }
    sysctl() { printf '%s\n' "$*" >> "$writes"; }
    if output=$(restore_tcp_sysctl_snapshot_file "$baseline/sysctl.tsv" 1 2>&1); then
        fail 'restore claimed exact success without a future sysctl historical value'
    fi
    grep -Fq 'net.ipv4.tcp_ecn' <<< "$output" || fail "limited restore did not identify the missing key: $output"
    [[ ! -s "$writes" ]] || fail "limited restore wrote sysctls before refusing: $(<"$writes")"
    diff -r -- "$expected" "$baseline" >/dev/null || fail 'restore modified the immutable baseline'

    BASELINE_DIR="$baseline"
    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { :; }
    tcp_restore_runtime_preflight() { ((restore_steps+=1)); }
    nic_restore_preflight() { ((restore_steps+=1)); }
    remove_persistence() { ((restore_steps+=1)); }
    if output=$(restore_baseline 2>&1); then
        fail 'full restore accepted a baseline without future sysctl history'
    fi
    grep -Fq '未修改运行配置' <<< "$output" || fail "full restore did not report an early refusal: $output"
    assert_eq 0 "$restore_steps" 'full restore steps after incompatible sysctl schema'
    [[ ! -s "$writes" ]] || fail "full restore wrote sysctls before refusing: $(<"$writes")"
    diff -r -- "$expected" "$baseline" >/dev/null || fail 'full restore modified the immutable baseline'

    capture_baseline eth0 || fail 'valid old baseline was not reusable'
    diff -r -- "$expected" "$baseline" >/dev/null || fail 'baseline reuse overwrote historical evidence'
)

test_v802_schema2_exact_full_restore() (
    local root="$TEST_ROOT/exact-v802" baseline="$TEST_ROOT/exact-v802/baseline"
    local baseline_before="$TEST_ROOT/exact-v802-baseline-before" live="$root/live"
    local sysctl_writes="$root/sysctl-writes.tsv" systemd_events="$root/systemd-events"
    local route_writes="$root/route-writes" qdisc_writes="$root/qdisc-writes"
    local qdisc_kind=fq_codel qdisc_handle=9000: qdisc_args='limit 10240'
    local route_v4='default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 99 initrwnd 88'
    local route_v6='default via 2001:db8::1 dev eth0 proto static metric 1024 initcwnd 77 initrwnd 66'
    local verb unit runtime=0 assignment key value line last_reload reload_phase
    local before_reload_lifecycle after_reload_lifecycle expected_after_reload_lifecycle
    local manager_current_loaded=1 manager_legacy_loaded=1 reload_count=0
    local -A runtime_sysctl=() unit_enabled=() unit_active=() unit_file=() unit_link=()

    write_v802_schema2_fixture "$baseline"
    cp -a -- "$baseline" "$baseline_before"
    tcp_baseline_validate "$baseline" || fail 'tag-derived v8.0.2 fixture failed validation'
    assert_eq v2 "$TCP_BASELINE_VALIDATED_GENERATION" 'tag-derived generation'
    assert_eq 1 "$TCP_BASELINE_VALIDATED_SYSCTL_SCHEMA" 'tag-derived sysctl schema'

    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$baseline"
    CONFIG_FILE="$live/etc/bbrv3-lite.conf"
    SYSCTL_FILE="$live/etc/sysctl.d/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$live/etc/sysctl.d/99-bbr-ultimate.conf"
    SERVICE_FILE="$live/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$live/systemd/bbr-optimize-persist.service"
    PERSIST_DIR="$live/lib/bbrv3-lite"; PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
    NIC_POLICY_DIR="$live/etc/bbrv3-lite/interfaces.d"
    BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    mkdir -p -- "$(dirname "$CONFIG_FILE")" "$(dirname "$SYSCTL_FILE")" \
        "$(dirname "$SERVICE_FILE")/multi-user.target.wants" "$PERSIST_DIR" \
        "$BBRV3_SYS_CLASS_NET_ROOT/eth0"
    : > "$sysctl_writes"; : > "$systemd_events"; : > "$route_writes"; : > "$qdisc_writes"

    printf 'mutated config\n' > "$CONFIG_FILE"
    printf 'mutated sysctl\n' > "$SYSCTL_FILE"
    printf 'mutated legacy sysctl\n' > "$LEGACY_SYSCTL_FILE"
    printf 'mutated service\n' > "$SERVICE_FILE"
    printf 'mutated legacy service\n' > "$LEGACY_SERVICE_FILE"
    printf '#!/usr/bin/env bash\nexit 99\n' > "$PERSIST_SCRIPT"
    chmod 0644 "$CONFIG_FILE" "$SYSCTL_FILE" "$LEGACY_SYSCTL_FILE" "$SERVICE_FILE" "$LEGACY_SERVICE_FILE"
    chmod 0755 "$PERSIST_SCRIPT"

    while IFS=$'\t' read -r key value; do
        runtime_sysctl["$key"]="mutated-$key"
    done < "$baseline/sysctl.tsv"

    unit_file["$SERVICE_NAME"]="$SERVICE_FILE"
    unit_file[bbr-optimize-persist.service]="$LEGACY_SERVICE_FILE"
    unit_link["$SERVICE_NAME"]="$(dirname "$SERVICE_FILE")/multi-user.target.wants/$SERVICE_NAME"
    unit_link[bbr-optimize-persist.service]="$(dirname "$SERVICE_FILE")/multi-user.target.wants/bbr-optimize-persist.service"
    unit_enabled["$SERVICE_NAME"]=disabled; unit_active["$SERVICE_NAME"]=inactive
    unit_enabled[bbr-optimize-persist.service]=enabled; unit_active[bbr-optimize-persist.service]=active
    ln -s "$LEGACY_SERVICE_FILE" "${unit_link[bbr-optimize-persist.service]}"

    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { :; }
    nic_restore_preflight() { printf 'nic-preflight\n' >> "$systemd_events"; }
    nic_restore_secondary_baselines() { printf 'nic-secondary-restore\n' >> "$systemd_events"; }
    nic_policy_remove_tree() { printf 'nic-policy-remove\n' >> "$systemd_events"; rm -rf -- "$NIC_POLICY_DIR"; }

    sysctl() {
        if [[ "$1" == -n ]]; then
            printf '%s\n' "${runtime_sysctl[$2]}"
            return 0
        fi
        if [[ "$1" == -q && "$2" == -w ]]; then
            assignment="$3"; key="${assignment%%=*}"; value="${assignment#*=}"
            runtime_sysctl["$key"]="$value"
            printf '%s\t%s\n' "$key" "$value" >> "$sysctl_writes"
            return 0
        fi
        return 1
    }
    tc() {
        if [[ "$1 $2 $3 $4" == 'qdisc show dev eth0' ]]; then
            printf 'qdisc %s %s root%s\n' "$qdisc_kind" "$qdisc_handle" "${qdisc_args:+ $qdisc_args}"
            return 0
        fi
        if [[ "$1 $2 $3 $4" == 'class show dev eth0' ]]; then return 0; fi
        if [[ "$1 $2 $3 $4" == 'filter show dev eth0' && "${5:-}" == parent ]]; then return 0; fi
        if [[ "$1 $2 $3 $4 $5 $6" == 'qdisc replace dev eth0 root handle' ]]; then
            qdisc_handle="$7"; qdisc_kind="$8"; shift 8; qdisc_args="$*"
            printf '%s\t%s\t%s\n' "$qdisc_kind" "$qdisc_handle" "$qdisc_args" >> "$qdisc_writes"
            return 0
        fi
        return 1
    }
    ip() {
        local family="$1" operation="$3"
        if [[ "$2" == route && "$operation" == show && "${4:-}" == default ]]; then
            [[ "$family" == -4 ]] && printf '%s\n' "$route_v4" || printf '%s\n' "$route_v6"
            return 0
        fi
        if [[ "$2" == route && "$operation" == replace ]]; then
            shift 3; line="$*"
            if [[ "$family" == -4 ]]; then route_v4="$line"; else route_v6="$line"; fi
            printf '%s\t%s\n' "$family" "$line" >> "$route_writes"
            return 0
        fi
        return 1
    }
    systemctl() {
        verb="$1"; shift
        case "$verb" in
            show)
                unit="$1"
                if [[ "$unit" == "$SERVICE_NAME" && "$manager_current_loaded" == 1 ]] ||
                   [[ "$unit" == bbr-optimize-persist.service && "$manager_legacy_loaded" == 1 ]]; then
                    printf 'ActiveState=%s\nLoadState=loaded\nUnitFileState=%s\n' \
                        "${unit_active[$unit]}" "${unit_enabled[$unit]}"
                else
                    printf 'ActiveState=inactive\nLoadState=not-found\nUnitFileState=untrusted-missing-token\n'
                fi
                ;;
            enable)
                runtime=0; [[ "${1:-}" != --runtime ]] || { runtime=1; shift; }
                unit="$1"; unit_enabled["$unit"]=$([[ "$runtime" == 1 ]] && printf enabled-runtime || printf enabled)
                ln -sfn "${unit_file[$unit]}" "${unit_link[$unit]}"
                printf 'enable:%s\n' "$unit" >> "$systemd_events"
                ;;
            disable)
                while [[ $# -gt 1 && "$1" == --* ]]; do shift; done
                unit="$1"; unit_enabled["$unit"]=disabled
                rm -f -- "${unit_link[$unit]}"
                printf 'disable:%s\n' "$unit" >> "$systemd_events"
                ;;
            start)
                unit="$1"; unit_active["$unit"]=active
                printf 'start:%s\n' "$unit" >> "$systemd_events"
                ;;
            stop)
                unit="$1"; unit_active["$unit"]=inactive
                printf 'stop:%s\n' "$unit" >> "$systemd_events"
                ;;
            daemon-reload)
                ((reload_count+=1))
                manager_current_loaded=0; manager_legacy_loaded=0
                [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]] && manager_current_loaded=1
                [[ -e "$LEGACY_SERVICE_FILE" || -L "$LEGACY_SERVICE_FILE" ]] && manager_legacy_loaded=1
                reload_phase=other
                if cmp -s "$baseline/service" "$SERVICE_FILE" && cmp -s "$baseline/legacy-service" "$LEGACY_SERVICE_FILE"; then
                    reload_phase=restored
                elif [[ ! -e "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]; then
                    reload_phase=absent
                fi
                printf 'daemon-reload:%s\n' "$reload_phase" >> "$systemd_events"
                ;;
            *) return 1 ;;
        esac
    }

    restore_baseline || fail 'current restore_baseline rejected the tag-derived v8.0.2 fixture'

    diff -r -- "$baseline_before" "$baseline" >/dev/null || fail 'full restore modified the immutable v8.0.2 fixture'
    cmp -s "$baseline/config" "$CONFIG_FILE" || fail 'config payload was not restored exactly'
    cmp -s "$baseline/sysctl" "$SYSCTL_FILE" || fail 'sysctl drop-in was not restored exactly'
    cmp -s "$baseline/legacy-sysctl" "$LEGACY_SYSCTL_FILE" || fail 'legacy sysctl payload was not restored exactly'
    cmp -s "$baseline/service" "$SERVICE_FILE" || fail 'service payload was not restored exactly'
    cmp -s "$baseline/legacy-service" "$LEGACY_SERVICE_FILE" || fail 'legacy service payload was not restored exactly'
    cmp -s "$baseline/persist-script" "$PERSIST_SCRIPT" || fail 'persist script was not restored exactly'
    for target in "$CONFIG_FILE" "$SYSCTL_FILE" "$LEGACY_SYSCTL_FILE" "$SERVICE_FILE" "$LEGACY_SERVICE_FILE"; do
        assert_eq 600 "$(stat -c %a "$target")" "restored mode for $target"
    done
    assert_eq 700 "$(stat -c %a "$PERSIST_SCRIPT")" 'restored persist-script mode'

    diff -u -- "$baseline/sysctl.tsv" "$sysctl_writes" >/dev/null || fail 'restore did not write exactly the historical 11 sysctls'
    while IFS=$'\t' read -r key value; do
        assert_eq "$value" "${runtime_sysctl[$key]}" "restored runtime sysctl $key"
    done < "$baseline/sysctl.tsv"
    assert_eq 'default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 12 initrwnd 24' "$route_v4" 'restored IPv4 default-route windows'
    assert_eq 'default via 2001:db8::1 dev eth0 proto static metric 1024 initcwnd 10 initrwnd 20' "$route_v6" 'restored IPv6 default-route windows'
    assert_eq 2 "$(wc -l < "$route_writes")" 'default-route restore write count'
    assert_eq fq "$qdisc_kind" 'restored qdisc kind'
    assert_eq 8001: "$qdisc_handle" 'restored qdisc handle'
    assert_eq 'limit 10000 flow_limit 100' "$qdisc_args" 'restored qdisc replay arguments'
    assert_eq 1 "$(wc -l < "$qdisc_writes")" 'qdisc restore write count'

    assert_eq enabled "${unit_enabled[$SERVICE_NAME]}" 'restored current unit enablement'
    assert_eq active "${unit_active[$SERVICE_NAME]}" 'restored current unit activity'
    assert_eq disabled "${unit_enabled[bbr-optimize-persist.service]}" 'restored legacy unit enablement'
    assert_eq inactive "${unit_active[bbr-optimize-persist.service]}" 'restored legacy unit activity'
    [[ -L "${unit_link[$SERVICE_NAME]}" ]] || fail 'current enable symlink was not restored'
    [[ ! -e "${unit_link[bbr-optimize-persist.service]}" && ! -L "${unit_link[bbr-optimize-persist.service]}" ]] || fail 'legacy enable symlink was not removed'
    assert_eq 2 "$reload_count" 'systemd daemon-reload count'
    [[ $(grep -Fxc 'daemon-reload:restored' "$systemd_events") == 1 ]] || fail 'service payloads were not published by a final daemon-reload'
    last_reload=$(grep -n '^daemon-reload:restored$' "$systemd_events" | cut -d: -f1)
    [[ "$last_reload" =~ ^[0-9]+$ ]] || fail 'restored service payload reload event was not uniquely identifiable'
    before_reload_lifecycle=$(awk -v reload="$last_reload" 'NR<reload && /^(enable|disable|start|stop):/' "$systemd_events")
    after_reload_lifecycle=$(awk -v reload="$last_reload" 'NR>reload && /^(enable|disable|start|stop):/' "$systemd_events")
    expected_after_reload_lifecycle="enable:${SERVICE_NAME}"$'\n'"start:${SERVICE_NAME}"$'\n'\
"disable:bbr-optimize-persist.service"$'\n'"stop:bbr-optimize-persist.service"
    assert_eq "disable:${SERVICE_NAME}" "$before_reload_lifecycle" 'pre-reload lifecycle must only quiesce the current service'
    assert_eq "$expected_after_reload_lifecycle" "$after_reload_lifecycle" 'all snapshot lifecycle restoration must follow the restored-payload daemon-reload'
)

test_v802_native_first_install_exact_full_restore() (
    local root="$TEST_ROOT/native-first-install" baseline="$TEST_ROOT/native-first-install/baseline"
    local baseline_before="$TEST_ROOT/native-first-install-baseline-before" live="$root/live"
    local sysctl_writes="$root/sysctl-writes.tsv" systemd_events="$root/systemd-events"
    local route_writes="$root/route-writes" qdisc_writes="$root/qdisc-writes"
    local qdisc_kind=fq_codel qdisc_handle=9000: qdisc_args='limit 10240'
    local route_v4='default via 198.51.100.1 dev eth0 proto dhcp metric 100 initcwnd 99 initrwnd 88'
    local route_v6='default via 2001:db8:1::1 dev eth0 proto static metric 1024 initcwnd 77 initrwnd 66'
    local name verb unit runtime=0 stop_now=0 assignment key value line
    local manager_current_loaded=1 manager_legacy_loaded=0 reload_count=0
    local -A runtime_sysctl=() unit_enabled=() unit_active=() unit_file=() unit_link=() live_path=()

    write_v802_native_first_install_schema2_fixture "$baseline"
    cp -a -- "$baseline" "$baseline_before"

    # v8.0.2 native capture could only pass managed_artifacts_exist when every
    # managed path was absent.  Assert the literal fixture itself preserves
    # that historical fact before exercising the current validator.
    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        assert_eq absent "$(<"$baseline/${name}.state")" "native first-install state for $name"
        [[ ! -e "$baseline/$name" && ! -L "$baseline/$name" ]] || fail "native first-install fixture invented a payload for $name"
    done
    assert_eq $'not-found\tinactive' "$(<"$baseline/service.unit")" 'native current service lifecycle'
    assert_eq $'not-found\tinactive' "$(<"$baseline/legacy-service.unit")" 'native legacy service lifecycle'

    tcp_baseline_validate "$baseline" || fail 'tag-derived native v8.0.2 first-install fixture failed validation'
    assert_eq v2 "$TCP_BASELINE_VALIDATED_GENERATION" 'native tag-derived generation'
    assert_eq native "$TCP_BASELINE_VALIDATED_PROVENANCE" 'native tag-derived provenance'
    assert_eq 1 "$TCP_BASELINE_VALIDATED_SYSCTL_SCHEMA" 'native tag-derived sysctl schema'

    STATE_DIR="$root/state"; HISTORY_DIR="$STATE_DIR/history"; BASELINE_DIR="$baseline"
    CONFIG_FILE="$live/etc/bbrv3-lite.conf"
    SYSCTL_FILE="$live/etc/sysctl.d/99-bbrv3-lite.conf"
    LEGACY_SYSCTL_FILE="$live/etc/sysctl.d/99-bbr-ultimate.conf"
    SERVICE_FILE="$live/systemd/bbrv3-lite.service"
    LEGACY_SERVICE_FILE="$live/systemd/bbr-optimize-persist.service"
    PERSIST_DIR="$live/lib/bbrv3-lite"; PERSIST_SCRIPT="$PERSIST_DIR/net-tcp-tune.sh"
    NIC_POLICY_DIR="$live/etc/bbrv3-lite/interfaces.d"
    BBRV3_SYS_CLASS_NET_ROOT="$root/sys/class/net"
    mkdir -p -- "$(dirname "$CONFIG_FILE")" "$(dirname "$SYSCTL_FILE")" \
        "$(dirname "$SERVICE_FILE")/multi-user.target.wants" "$PERSIST_DIR" \
        "$BBRV3_SYS_CLASS_NET_ROOT/eth0"
    : > "$sysctl_writes"; : > "$systemd_events"; : > "$route_writes"; : > "$qdisc_writes"

    # Model the artifacts created by a successful first install.  The legacy
    # paths stay absent because v8.0.2 retired them before publishing the new
    # service and sysctl drop-in.
    printf 'installed config\n' > "$CONFIG_FILE"
    printf 'installed sysctl drop-in\n' > "$SYSCTL_FILE"
    printf 'installed current service\n' > "$SERVICE_FILE"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$PERSIST_SCRIPT"
    chmod 0600 "$CONFIG_FILE" "$SYSCTL_FILE" "$SERVICE_FILE"
    chmod 0755 "$PERSIST_SCRIPT"
    [[ ! -e "$LEGACY_SYSCTL_FILE" && ! -L "$LEGACY_SYSCTL_FILE" ]] || fail 'legacy sysctl unexpectedly existed before native restore'
    [[ ! -e "$LEGACY_SERVICE_FILE" && ! -L "$LEGACY_SERVICE_FILE" ]] || fail 'legacy service unexpectedly existed before native restore'

    live_path[config]="$CONFIG_FILE"
    live_path[sysctl]="$SYSCTL_FILE"
    live_path[legacy-sysctl]="$LEGACY_SYSCTL_FILE"
    live_path[service]="$SERVICE_FILE"
    live_path[legacy-service]="$LEGACY_SERVICE_FILE"
    live_path[persist-script]="$PERSIST_SCRIPT"

    while IFS=$'\t' read -r key value; do
        runtime_sysctl["$key"]="mutated-$key"
    done < "$baseline/sysctl.tsv"

    unit_file["$SERVICE_NAME"]="$SERVICE_FILE"
    unit_file[bbr-optimize-persist.service]="$LEGACY_SERVICE_FILE"
    unit_link["$SERVICE_NAME"]="$(dirname "$SERVICE_FILE")/multi-user.target.wants/$SERVICE_NAME"
    unit_link[bbr-optimize-persist.service]="$(dirname "$LEGACY_SERVICE_FILE")/multi-user.target.wants/bbr-optimize-persist.service"
    unit_enabled["$SERVICE_NAME"]=enabled; unit_active["$SERVICE_NAME"]=active
    unit_enabled[bbr-optimize-persist.service]=not-found; unit_active[bbr-optimize-persist.service]=inactive
    ln -s "$SERVICE_FILE" "${unit_link[$SERVICE_NAME]}"

    require_root() { :; }
    require_host_network_control() { :; }
    require_systemd_runtime() { :; }
    require_commands() { :; }
    acquire_lock() { :; }
    nic_restore_preflight() { :; }
    nic_restore_secondary_baselines() { :; }
    nic_policy_remove_tree() { [[ ! -e "$NIC_POLICY_DIR" && ! -L "$NIC_POLICY_DIR" ]]; }

    sysctl() {
        if [[ "$1" == -n ]]; then
            printf '%s\n' "${runtime_sysctl[$2]}"
            return 0
        fi
        if [[ "$1" == -q && "$2" == -w ]]; then
            assignment="$3"; key="${assignment%%=*}"; value="${assignment#*=}"
            runtime_sysctl["$key"]="$value"
            printf '%s\t%s\n' "$key" "$value" >> "$sysctl_writes"
            return 0
        fi
        return 1
    }
    tc() {
        if [[ "$1 $2 $3 $4" == 'qdisc show dev eth0' ]]; then
            printf 'qdisc %s %s root%s\n' "$qdisc_kind" "$qdisc_handle" "${qdisc_args:+ $qdisc_args}"
            return 0
        fi
        if [[ "$1 $2 $3 $4" == 'class show dev eth0' ]]; then return 0; fi
        if [[ "$1 $2 $3 $4" == 'filter show dev eth0' && "${5:-}" == parent ]]; then return 0; fi
        if [[ "$1 $2 $3 $4 $5 $6" == 'qdisc replace dev eth0 root handle' ]]; then
            qdisc_handle="$7"; qdisc_kind="$8"; shift 8; qdisc_args="$*"
            printf '%s\t%s\t%s\n' "$qdisc_kind" "$qdisc_handle" "$qdisc_args" >> "$qdisc_writes"
            return 0
        fi
        return 1
    }
    ip() {
        local family="$1" operation="$3"
        if [[ "$2" == route && "$operation" == show && "${4:-}" == default ]]; then
            [[ "$family" == -4 ]] && printf '%s\n' "$route_v4" || printf '%s\n' "$route_v6"
            return 0
        fi
        if [[ "$2" == route && "$operation" == replace ]]; then
            shift 3; line="$*"
            if [[ "$family" == -4 ]]; then route_v4="$line"; else route_v6="$line"; fi
            printf '%s\t%s\n' "$family" "$line" >> "$route_writes"
            return 0
        fi
        return 1
    }
    systemctl() {
        verb="$1"; shift
        case "$verb" in
            show)
                unit="$1"
                if [[ "$unit" == "$SERVICE_NAME" && "$manager_current_loaded" == 1 ]] ||
                   [[ "$unit" == bbr-optimize-persist.service && "$manager_legacy_loaded" == 1 ]]; then
                    printf 'UnitFileState=%s\nActiveState=%s\nLoadState=loaded\n' \
                        "${unit_enabled[$unit]}" "${unit_active[$unit]}"
                else
                    printf 'UnitFileState=untrusted-missing-token\nActiveState=inactive\nLoadState=not-found\n'
                fi
                ;;
            disable)
                stop_now=0
                while [[ $# -gt 1 && "$1" == --* ]]; do
                    [[ "$1" != --now ]] || stop_now=1
                    shift
                done
                unit="$1"; unit_enabled["$unit"]=disabled
                (( stop_now == 0 )) || unit_active["$unit"]=inactive
                rm -f -- "${unit_link[$unit]}"
                printf 'disable:%s\n' "$unit" >> "$systemd_events"
                ;;
            enable)
                runtime=0; [[ "${1:-}" != --runtime ]] || { runtime=1; shift; }
                unit="$1"; unit_enabled["$unit"]=$([[ "$runtime" == 1 ]] && printf enabled-runtime || printf enabled)
                ln -sfn "${unit_file[$unit]}" "${unit_link[$unit]}"
                printf 'enable:%s\n' "$unit" >> "$systemd_events"
                ;;
            start)
                unit="$1"; unit_active["$unit"]=active
                printf 'start:%s\n' "$unit" >> "$systemd_events"
                ;;
            stop)
                unit="$1"; unit_active["$unit"]=inactive
                printf 'stop:%s\n' "$unit" >> "$systemd_events"
                ;;
            daemon-reload)
                ((reload_count+=1))
                manager_current_loaded=0; manager_legacy_loaded=0
                [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]] && manager_current_loaded=1
                [[ -e "$LEGACY_SERVICE_FILE" || -L "$LEGACY_SERVICE_FILE" ]] && manager_legacy_loaded=1
                printf 'daemon-reload\n' >> "$systemd_events"
                ;;
            is-enabled|is-active)
                fail "native absent restore used legacy $verb query for ${1:-missing-unit}"
                ;;
            *) return 1 ;;
        esac
    }

    restore_baseline || fail 'current restore_baseline rejected the native v8.0.2 first-install fixture'

    diff -r -- "$baseline_before" "$baseline" >/dev/null || fail 'native full restore modified the immutable v8.0.2 fixture'
    for name in config sysctl legacy-sysctl service legacy-service persist-script; do
        [[ ! -e "${live_path[$name]}" && ! -L "${live_path[$name]}" ]] || fail "native restore did not recreate absent path state: $name"
    done
    [[ ! -e "${unit_link[$SERVICE_NAME]}" && ! -L "${unit_link[$SERVICE_NAME]}" ]] || fail 'native restore left the current service enable link'
    [[ ! -e "${unit_link[bbr-optimize-persist.service]}" && ! -L "${unit_link[bbr-optimize-persist.service]}" ]] || fail 'native restore left the legacy service enable link'
    assert_eq $'not-found\tinactive' "$(query_unit_state "$SERVICE_NAME")" 'restored native current service state'
    assert_eq $'not-found\tinactive' "$(query_unit_state bbr-optimize-persist.service)" 'restored native legacy service state'

    diff -u -- "$baseline/sysctl.tsv" "$sysctl_writes" >/dev/null || fail 'native restore did not write exactly the historical 11 sysctls'
    assert_eq 11 "$(wc -l < "$sysctl_writes")" 'native historical sysctl write count'
    while IFS=$'\t' read -r key value; do
        assert_eq "$value" "${runtime_sysctl[$key]}" "native restored runtime sysctl $key"
    done < "$baseline/sysctl.tsv"
    assert_eq 'default via 198.51.100.1 dev eth0 proto dhcp metric 100 initcwnd 15 initrwnd 25' "$route_v4" 'native restored IPv4 default-route windows'
    assert_eq 'default via 2001:db8:1::1 dev eth0 proto static metric 1024 initcwnd 11 initrwnd 21' "$route_v6" 'native restored IPv6 default-route windows'
    assert_eq 2 "$(wc -l < "$route_writes")" 'native default-route restore write count'
    assert_eq fq "$qdisc_kind" 'native restored qdisc kind'
    assert_eq 8100: "$qdisc_handle" 'native restored qdisc handle'
    assert_eq 'limit 9000 flow_limit 90' "$qdisc_args" 'native restored qdisc replay arguments'
    assert_eq 1 "$(wc -l < "$qdisc_writes")" 'native qdisc restore write count'
    assert_eq 2 "$reload_count" 'native restore daemon-reload count'
    assert_eq "disable:${SERVICE_NAME}" "$(grep -E '^(enable|disable|start|stop):' "$systemd_events")" 'native restore lifecycle writes'
)

test_v802_schema2_baseline_uses_fixed_schema
test_impossible_missing_unit_snapshot_is_rejected_early
test_new_schema_metadata_is_strict
test_restore_never_invents_future_sysctl_history
test_v802_schema2_exact_full_restore
test_v802_native_first_install_exact_full_restore
echo 'baseline v8.0.3 regression tests: OK'
