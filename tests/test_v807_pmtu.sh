#!/usr/bin/env bash
# Deterministic v8.0.7 PMTU evidence and final-profile provenance regressions.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_FINAL_PATH_PROFILE_FILE="$TEST_ROOT/state/final-path-profile.tsv"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/src/00-header.sh"
source "$ROOT_DIR/src/core.sh"
source "$ROOT_DIR/src/config.sh"
source "$ROOT_DIR/src/platform.sh"
source "$ROOT_DIR/src/path.sh"
source "$ROOT_DIR/src/diagnostics.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: '$1' lacks '$2'"; }

set_ipv4_probe_identity() {
    MEASURE_PEER_FAMILY=4; MEASURE_PEER_ADDRESS=23.106.226.75
    MEASURE_PEER_SOURCE=192.0.2.10; MEASURE_PEER_IFACE=eth0
    PATH_INTERFACE_MTU=1500; PATH_ROUTE_MTU=1500
}

test_ipv4_full_mtu_success() (
    local state pmtu mss capped evidence
    set_ipv4_probe_identity
    ping() { return 0; }
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq 1500 "$pmtu" "IPv4 full PMTU"
    assert_eq 1460 "$mss" "IPv4 full MSS"
    assert_eq 0 "$capped" "IPv4 cap flag"
    assert_eq full-mtu-confirmed "$evidence" "IPv4 full evidence"
    PATH_PMTU="$pmtu"; PATH_MSS="$mss"; PATH_PMTU_PROBE_CAPPED="$capped"; PATH_PMTU_EVIDENCE="$evidence"
    PATH_PING_RECEIVED=3; PATH_LOSS_PERCENT=0; PATH_RTT_MEDIAN_MS=20; PATH_RTT_JITTER_P95_MS=1
    path_profile_classify
    [[ "$PATH_RISK_FLAGS" != *reduced-pmtu* ]] || fail "full PMTU was marked reduced"
)

test_single_transient_timeout_recovers() (
    local calls_file="$TEST_ROOT/transient-calls" calls state pmtu mss capped evidence
    set_ipv4_probe_identity
    printf '0\n' > "$calls_file"
    ping() {
        calls=$(<"$calls_file"); calls=$((calls + 1)); printf '%s\n' "$calls" > "$calls_file"
        if (( calls == 1 )); then printf 'Request timeout for icmp_seq 1\n' >&2; return 1; fi
        return 0
    }
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq 1500 "$pmtu" "transient timeout PMTU"
    assert_eq full-mtu-confirmed "$evidence" "transient timeout evidence"
    assert_eq 3 "$(<"$calls_file")" "transient timeout confirmation count"
)

test_definitive_too_large_binary_search() (
    local state pmtu mss capped evidence payload overhead=28
    set_ipv4_probe_identity
    ping() {
        local -a args=("$@"); local i
        for ((i=0; i<${#args[@]}; i++)); do [[ "${args[$i]}" != -s ]] || payload="${args[$((i+1))]}"; done
        if (( payload + overhead <= 1400 )); then return 0; fi
        printf 'ping: local error: message too long, mtu=1400\n' >&2
        return 1
    }
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq 1400 "$pmtu" "confirmed reduced PMTU"
    assert_eq 1360 "$mss" "confirmed reduced MSS"
    assert_eq reduced-mtu-confirmed "$evidence" "confirmed reduced evidence"
)

test_ambiguous_only_is_inconclusive() (
    local state pmtu mss capped evidence
    set_ipv4_probe_identity
    ping() { printf 'Request timeout for icmp_seq 1\n' >&2; return 1; }
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq unknown "$pmtu" "ambiguous PMTU"
    assert_eq unknown "$mss" "ambiguous MSS"
    assert_eq inconclusive "$evidence" "ambiguous PMTU evidence"
    PATH_PMTU="$pmtu"; PATH_MSS="$mss"; PATH_PMTU_PROBE_CAPPED="$capped"; PATH_PMTU_EVIDENCE="$evidence"
    PATH_PING_RECEIVED=3; PATH_LOSS_PERCENT=0; PATH_RTT_MEDIAN_MS=20; PATH_RTT_JITTER_P95_MS=1
    path_profile_classify
    assert_contains "$PATH_RISK_FLAGS" pmtu-probe-inconclusive "inconclusive risk"
)

test_ipv6_overhead_and_packet_too_big() (
    local state pmtu mss capped evidence payload payload_log="$TEST_ROOT/ipv6-payloads"
    MEASURE_PEER_FAMILY=6; MEASURE_PEER_ADDRESS=2001:db8::10
    MEASURE_PEER_SOURCE=2001:db8::20; MEASURE_PEER_IFACE=eth0
    PATH_INTERFACE_MTU=1500; PATH_ROUTE_MTU=1500
    : > "$payload_log"
    ping() {
        local -a args=("$@"); local i
        for ((i=0; i<${#args[@]}; i++)); do [[ "${args[$i]}" != -s ]] || payload="${args[$((i+1))]}"; done
        printf '%s\n' "$payload" >> "$payload_log"
        if (( payload + 48 <= 1280 )); then return 0; fi
        printf 'From 2001:db8::1 icmp_seq=1 Packet Too Big: mtu=1280\n' >&2
        return 1
    }
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq 1280 "$pmtu" "IPv6 PMTU"
    assert_eq 1220 "$mss" "IPv6 TCP MSS"
    assert_eq reduced-mtu-confirmed "$evidence" "IPv6 PTB evidence"
    grep -Fxq 1452 "$payload_log" || fail "IPv6 full-MTU payload did not use 48-byte overhead"
    grep -Fxq 1232 "$payload_log" || fail "IPv6 minimum payload did not use 48-byte overhead"
)

legacy_false_low_fixture() {
    local low=576 high=1500 mid payload best=576
    ping -4 -s 548 >/dev/null 2>&1 || { printf 'unknown\n'; return; }
    while (( low <= high )); do
        mid=$(((low + high) / 2)); payload=$((mid - 28))
        if ping -4 -s "$payload" >/dev/null 2>&1; then best="$mid"; low=$((mid + 1)); else high=$((mid - 1)); fi
    done
    printf '%s\n' "$best"
}

test_tokyo_977_production_regression() (
    local legacy state pmtu mss capped evidence candidate payload
    local count_file="$TEST_ROOT/tokyo-counts"
    set_ipv4_probe_identity
    : > "$count_file"
    ping() {
        local -a args=("$@"); local i count
        for ((i=0; i<${#args[@]}; i++)); do [[ "${args[$i]}" != -s ]] || payload="${args[$((i+1))]}"; done
        candidate=$((payload + 28))
        count=$(awk -F'\t' -v c="$candidate" '$1==c {n=$2} END {print n+0}' "$count_file")
        count=$((count + 1)); printf '%s\t%s\n' "$candidate" "$count" >> "$count_file"
        case "$candidate:$count" in
            1038:1|980:1|978:1|1500:1) printf 'Request timeout for icmp_seq 1\n' >&2; return 1 ;;
            *) return 0 ;;
        esac
    }
    legacy=$(legacy_false_low_fixture)
    assert_eq 977 "$legacy" "legacy Tokyo false-low reproduction"
    : > "$count_file"
    state=$(path_probe_pmtu 1)
    IFS=$'\t' read -r pmtu mss capped evidence <<< "$state"
    assert_eq 1500 "$pmtu" "Tokyo transient-loss regression PMTU"
    assert_eq full-mtu-confirmed "$evidence" "Tokyo transient-loss evidence"
)

write_profile_summary() {
    local file="$1" type="$2" result="$3" endpoint="$4" pmtu="$5" captured="$6" decision="$7" accepted="$8" rtt="$9"
    local route=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    local evidence=full-mtu-confirmed mss=1460 score=100 risk=clean
    [[ "$pmtu" != 977 ]] || { evidence=reduced-mtu-confirmed; mss=937; score=90; risk=reduced-pmtu; }
    mkdir -p "$(dirname "$file")"
    printf 'HISTORY_SCHEMA\t1\nTYPE\t%s\nRESULT\t%s\nCOMPLETED_AT\t%s\nPEER\tspeedtest.tyo11.jp.leaseweb.net\nPORT\t5202\nINTERFACE\teth0\nACCEPTED\t%s\nLOCKED_ADDRESS\t%s\nLOCKED_SOURCE\t192.0.2.10\nLOCKED_INTERFACE\teth0\nLOCKED_FAMILY\t4\nLOCKED_PORT\t5202\nPATH_PROFILE_SCHEMA\t1\nPATH_CAPTURED_AT\t%s\nPATH_ROUTE_FINGERPRINT\t%s\nPATH_ENDPOINT_FINGERPRINT\t%s\nPATH_GATEWAY\t192.0.2.1\nPATH_TABLE\tmain\nPATH_INTERFACE_MTU\t1500\nPATH_ROUTE_MTU\t1500\nPATH_PMTU\t%s\nPATH_MSS\t%s\nPATH_PMTU_PROBE_CAPPED\t0\nPATH_PMTU_EVIDENCE\t%s\nPATH_PING_SENT\t7\nPATH_PING_RECEIVED\t7\nPATH_LOSS_PERCENT\t0.00\nPATH_RTT_MIN_MS\t27\nPATH_RTT_MEDIAN_MS\t28\nPATH_RTT_P95_MS\t%s\nPATH_RTT_MAX_MS\t30\nPATH_RTT_JITTER_P95_MS\t1.00\nPATH_GATEWAY_RTT_MS\t1\nPATH_LATENCY_CLASS\tnear\nPATH_STABILITY\tstable\nPATH_PROFILE_SCORE\t%s\nPATH_PROFILE_GRADE\thigh\nPATH_DECISION\t%s\nPATH_RISK_FLAGS\t%s\n' \
        "$type" "$result" "$captured" "$accepted" "$endpoint" "$captured" "$route" \
        "$(printf '%064x' "$endpoint")" "$pmtu" "$mss" "$evidence" "$rtt" "$score" "$decision" "$risk" > "$file"
}

test_final_verify_provenance_and_immutability() (
    local sweep_id=20260915T100000Z-sweep verify_id=20260915T100100Z-verify
    local failed_id=20260915T100200Z-verify different_id=20260915T100300Z-verify untrusted_id=20260915T100400Z-verify
    local sweep="$HISTORY_DIR/$sweep_id/summary.tsv" verify="$HISTORY_DIR/$verify_id/summary.tsv"
    local failed="$HISTORY_DIR/$failed_id/summary.tsv" different="$HISTORY_DIR/$different_id/summary.tsv"
    local untrusted="$HISTORY_DIR/$untrusted_id/summary.tsv"
    local before_sweep before_verify after_sweep after_verify final_hash output profile
    write_profile_summary "$sweep" sweep SUCCESS 1 977 2026-09-15T10:00:00Z trusted 0 28
    printf 'CAPACITY_RECEIVER_MBIT\t191.38\nLAST_OK\t209\nBROKE_AT\t211\nRECOMMEND\t202\n' >> "$sweep"
    write_profile_summary "$verify" verify SUCCESS 1 1500 2026-09-15T10:01:00Z trusted 1 29
    printf 'SINGLE_RECEIVER_MBIT\t187.55\nMULTI_RECEIVER_MBIT\t188.82\n' >> "$verify"
    before_sweep=$(sha256sum "$sweep" | cut -d' ' -f1); before_verify=$(sha256sum "$verify" | cut -d' ' -f1)
    ensure_state_layout() { mkdir -p "$STATE_DIR" "$HISTORY_DIR"; }
    path_profile_persist_final "$sweep" "$verify" verify
    after_sweep=$(sha256sum "$sweep" | cut -d' ' -f1); after_verify=$(sha256sum "$verify" | cut -d' ' -f1)
    assert_eq "$before_sweep" "$after_sweep" "sweep history immutability"
    assert_eq "$before_verify" "$after_verify" "verify history immutability"
    path_final_profile_valid "$FINAL_PATH_PROFILE_FILE" || fail "persisted final profile is invalid"
    assert_eq verify "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" FINAL_PATH_PROFILE_SOURCE)" "final profile source"
    assert_eq "$verify_id" "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" FINAL_PATH_SOURCE_HISTORY_ID)" "final profile history ID"
    assert_eq 1500 "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" PATH_PMTU)" "promoted final PMTU"
    assert_eq 29 "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" PATH_RTT_P95_MS)" "whole-profile verify RTT"
    assert_eq 100 "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" PATH_PROFILE_SCORE)" "whole-profile verify score"
    assert_eq 191.38 "$(path_summary_value "$sweep" CAPACITY_RECEIVER_MBIT)" "delivered capacity unchanged"
    assert_eq 209 "$(path_summary_value "$sweep" LAST_OK)" "last clean unchanged"
    assert_eq 211 "$(path_summary_value "$sweep" BROKE_AT)" "break unchanged"
    assert_eq 202 "$(path_summary_value "$sweep" RECOMMEND)" "recommendation unchanged"
    assert_eq 187.55 "$(path_summary_value "$verify" SINGLE_RECEIVER_MBIT)" "single verify unchanged"
    assert_eq 188.82 "$(path_summary_value "$verify" MULTI_RECEIVER_MBIT)" "multi verify unchanged"
    output=$(latest_path_brief)
    assert_contains "$output" 'PMTU 1500' "status final PMTU"
    assert_contains "$output" 'source verify' "status final provenance"

    profile=$(path_profile_for_sweep "$sweep")
    assert_eq "$FINAL_PATH_PROFILE_FILE" "$profile" "measurement status authoritative profile"
    path_capture_route_identity() { printf '%s\tendpoint\tgateway\n' "$(path_summary_value "$FINAL_PATH_PROFILE_FILE" PATH_ROUTE_FINGERPRINT)"; }
    output=$(status_measurement_details)
    assert_contains "$output" 'Measurement          verified' "final-profile path consistency"

    final_hash=$(sha256sum "$FINAL_PATH_PROFILE_FILE" | cut -d' ' -f1)
    write_profile_summary "$different" verify SUCCESS 2 1500 2026-09-15T10:03:00Z trusted 1 31
    if path_profile_persist_final "$sweep" "$different" verify >/dev/null 2>&1; then fail "different endpoint replaced final profile"; fi
    assert_eq "$final_hash" "$(sha256sum "$FINAL_PATH_PROFILE_FILE" | cut -d' ' -f1)" "different endpoint final-profile preservation"

    write_profile_summary "$failed" verify FAILURE 1 1500 2026-09-15T10:02:00Z trusted 0 30
    if path_profile_persist_final "$sweep" "$failed" verify >/dev/null 2>&1; then fail "failed verify replaced final profile"; fi
    assert_eq "$final_hash" "$(sha256sum "$FINAL_PATH_PROFILE_FILE" | cut -d' ' -f1)" "failed verify final-profile preservation"

    write_profile_summary "$untrusted" verify SUCCESS 1 1500 2026-09-15T10:04:00Z limited 1 32
    if path_profile_persist_final "$sweep" "$untrusted" verify >/dev/null 2>&1; then fail "untrusted verify replaced final profile"; fi
    assert_eq "$final_hash" "$(sha256sum "$FINAL_PATH_PROFILE_FILE" | cut -d' ' -f1)" "untrusted verify final-profile preservation"

    rm -f "$FINAL_PATH_PROFILE_FILE"
    touch "$failed"
    output=$(latest_path_brief)
    assert_contains "$output" 'PMTU 977' "successful sweep fallback"
    assert_contains "$output" 'source sweep' "failed verify provenance isolation"
)

run_test() { printf '==> %s\n' "$1"; "$1"; }
run_test test_ipv4_full_mtu_success
run_test test_single_transient_timeout_recovers
run_test test_definitive_too_large_binary_search
run_test test_ambiguous_only_is_inconclusive
run_test test_ipv6_overhead_and_packet_too_big
run_test test_tokyo_977_production_regression
run_test test_final_verify_provenance_and_immutability
printf 'v8.0.7 PMTU/provenance tests: PASS\n'
