#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Build single-file release"
bash scripts/build.sh

echo "==> Bash syntax"
for file in src/*.sh scripts/*.sh tests/*.sh install-alias.sh; do bash -n "$file"; done
bash -n net-tcp-tune.sh

echo "==> Generated artifact markers"
grep -Fq 'SCRIPT_VERSION="8.0.3"' net-tcp-tune.sh
grep -Fq 'Configuration is data and is never sourced' net-tcp-tune.sh
grep -Fq 'MEASURE_PEER_PORT=""' net-tcp-tune.sh
grep -Fq 'LOCKED_PORT' net-tcp-tune.sh
grep -Fq 'preferred_address' net-tcp-tune.sh
grep -Fq 'tc qdisc replace dev "$iface" root handle 1: htb default 10' net-tcp-tune.sh
grep -Fq 'tc qdisc replace dev "$iface" parent 1:10 handle 10: fq' net-tcp-tune.sh
grep -Fq 'measure_lock_peer' net-tcp-tune.sh
grep -Fq 'LOCKED_ADDRESS' net-tcp-tune.sh
grep -Fq 'iperf3 "${family_arg[@]}" -c "$MEASURE_PEER_ADDRESS" -B "$MEASURE_PEER_SOURCE"' net-tcp-tune.sh
grep -Fq 'ping "${family_arg[@]}" -I "$MEASURE_PEER_IFACE" -I "$MEASURE_PEER_SOURCE"' net-tcp-tune.sh
grep -Fq 'TUNING_RTT_MS' net-tcp-tune.sh
grep -Fq 'verify_sysctl_profile_runtime' net-tcp-tune.sh
grep -Fq 'CONFIG_HZ' net-tcp-tune.sh
grep -Fq 'verify_persistence_artifacts' net-tcp-tune.sh
grep -Fq 'capture_unit_state' net-tcp-tune.sh
grep -Fq 'auto_measure_with_peer_failover' net-tcp-tune.sh
grep -Fq 'measure_compare' net-tcp-tune.sh
grep -Fq 'RETRANS_PER_GIB' net-tcp-tune.sh
grep -Fq 'LOADED_RTT_P95_MS' net-tcp-tune.sh
grep -Fq 'hardware_profile_values' net-tcp-tune.sh
grep -Fq 'recommended_scan_cap' net-tcp-tune.sh
grep -Fq 'MULTI_FLOWS' net-tcp-tune.sh
grep -Fq 'auto_tune_route_guard' net-tcp-tune.sh
grep -Fq 'path_capture_route_identity' net-tcp-tune.sh
grep -Fq 'PATH_ROUTE_FINGERPRINT' net-tcp-tune.sh
grep -Fq 'PATH_ENDPOINT_FINGERPRINT' net-tcp-tune.sh
grep -Fq 'SWEEP_ENDPOINT_FINGERPRINT' net-tcp-tune.sh
grep -Fq 'path_profile_tuning_gate' net-tcp-tune.sh
grep -Fq 'dns_preflight_takeover' net-tcp-tune.sh
grep -Fq 'dns_policy_plan' net-tcp-tune.sh
grep -Fq 'dns_policy_verify' net-tcp-tune.sh
grep -Fq 'dns_apply dot' net-tcp-tune.sh
grep -Fq 'FORMAT\tinterface-values-v2' net-tcp-tune.sh
grep -Fq 'ipv6_policy_plan' net-tcp-tune.sh
grep -Fq 'ipv6_policy_verify' net-tcp-tune.sh
grep -Fq 'nic_policy_ownership_preflight' net-tcp-tune.sh
grep -Fq 'run_action_transaction_multi' net-tcp-tune.sh
grep -Fq 'NIC_POLICY_FORMAT="bbrv3-lite-nic-policy"' net-tcp-tune.sh
grep -Fq 'nic_policy_candidate_global_model' net-tcp-tune.sh
grep -Fq 'nic_restore_runtime_snapshot' net-tcp-tune.sh
grep -Fq 'action_transaction_discard_snapshot' net-tcp-tune.sh
grep -Fq 'root_qdisc_snapshot_matches' net-tcp-tune.sh
grep -Fq 'qdisc_filter_guard' net-tcp-tune.sh
grep -Fq 'mq_snapshot_queue_preflight' net-tcp-tune.sh
grep -Fq 'mq_class_rows_validate' net-tcp-tune.sh
grep -Fq 'managed_htb_topology_from_stream' net-tcp-tune.sh
grep -Fq 'all write-trigger (observed; not aggregate state)' net-tcp-tune.sh
grep -Fq 'refusing to overwrite an unmanaged file' install-alias.sh
if grep -Eq 'source[[:space:]]+.*bbrv3-lite\.conf' net-tcp-tune.sh; then echo "unsafe config source detected" >&2; exit 1; fi

echo "==> Core tests"
for test_file in tests/test_*.sh; do
    printf '==> %s\n' "$test_file"
    bash "$test_file"
done

if [[ "${SKIP_RELEASE_CHECKSUM:-0}" != 1 && -f SHA256SUMS ]]; then
    echo "==> Release checksums"
    sha256sum -c SHA256SUMS --ignore-missing
fi

echo "==> ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
    # load_config/migrate_legacy_config intentionally accept optional paths used by sourced tests.
    shellcheck -S warning -e SC2120 net-tcp-tune.sh scripts/*.sh tests/*.sh install-alias.sh
else
    echo "shellcheck unavailable; skipped"
fi

echo "==> All checks passed"
