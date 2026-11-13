#!/usr/bin/env bash
# Tests must establish iperf protocol readiness, not just a TCP listener.
# An empty TCP connect does not prove an iperf session can be accepted.
# Require one valid low-traffic session instead of two immediate TCP probes.
integration_wait_for_iperf_server() {
    local peer="$1" port="$2" family="$3" source="$4" log_file="$5" attempt
    for ((attempt=1; attempt<=5; attempt++)); do
        if iperf_peer_usable "$peer" "$port" "$family" "$source"; then return 0; fi
        sleep 1
    done
    [[ ! -f "$log_file" ]] || cat "$log_file" >&2
    printf 'FAIL: iperf3 protocol readiness failed: %s:%s / IPv%s\n' "$peer" "$port" "$family" >&2
    return 1
}
