#!/usr/bin/env bash
# Run in a disposable Linux container with CAP_NET_ADMIN, iperf3, jq and ping.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

export BBRV3_CONFIG="$TEST_ROOT/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$TEST_ROOT/state"
export BBRV3_BASELINE_DIR="$TEST_ROOT/state/baseline"
export BBRV3_HISTORY_DIR="$TEST_ROOT/state/history"
export BBRV3_LOCK_FILE="$TEST_ROOT/bbrv3-lite.lock"
export BBRV3_MAX_BACKGROUND_TX_PERCENT=100
export BBRV3_MAX_CPU_STEAL_PERCENT=100
export BBRV3_MAX_CPU_BUSY_PERCENT=100

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"
require_commands iperf3 jq ping timeout

iperf3 -s -p 5209 > "$TEST_ROOT/iperf-server.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5; do
    if peer_port_open 127.0.0.1 5209; then break; fi
    sleep 1
done
peer_port_open 127.0.0.1 5209 || { echo "FAIL: local iperf3 server did not start" >&2; exit 1; }

MEASURE_IFACE=lo
measure_set_latency_baseline 127.0.0.1
row=$(iperf_sample 127.0.0.1 5209 3 1)
[[ "$(awk -F'\t' '{print NF}' <<< "$row")" == 11 ]] || { echo "FAIL: unexpected raw metric field count" >&2; exit 1; }
is_decimal "$(cut -f1 <<< "$row")" || { echo "FAIL: goodput missing" >&2; exit 1; }
is_decimal "$(cut -f5 <<< "$row")" || { echo "FAIL: retrans/GiB missing" >&2; exit 1; }
is_decimal "$(cut -f7 <<< "$row")" || { echo "FAIL: loaded RTT p95 missing" >&2; exit 1; }
is_decimal "$(cut -f9 <<< "$row")" || { echo "FAIL: CPU busy metric missing" >&2; exit 1; }

new_measure_run integration
aggregate=$(sample_repeated 127.0.0.1 5209 3 1 2 integration)
[[ "$(cut -f13 <<< "$aggregate")" == 2 ]] || { echo "FAIL: repeated sample count mismatch" >&2; exit 1; }
[[ "$(wc -l < "$MEASURE_RESULT_FILE")" == 3 ]] || { echo "FAIL: measurement history row count mismatch" >&2; exit 1; }
grep -Fq $'RETRANS_PER_GIB\tIDLE_RTT_MS\tLOADED_RTT_MEDIAN_MS' "$MEASURE_RESULT_FILE" || {
    echo "FAIL: v7.1 measurement history columns missing" >&2
    exit 1
}

apply_shaping lo 1000
measure_verify 127.0.0.1 5209 lo 3
grep -Eq $'^MULTI_FLOWS\t(2|4|8|16)$' "$MEASURE_RUN_DIR/summary.tsv" || {
    echo "FAIL: hardware-adaptive verify flow count missing" >&2
    exit 1
}
grep -Fq $'MULTI_MBIT\t' "$MEASURE_RUN_DIR/summary.tsv" || {
    echo "FAIL: v7.2 multi-flow verification metrics missing" >&2
    exit 1
}
apply_fq lo

echo "measurement integration test: OK"
