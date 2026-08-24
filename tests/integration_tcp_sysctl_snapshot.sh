#!/usr/bin/env bash
# Exercise the snapshot codec with the container kernel's real procfs TCP
# triplets.  Other managed keys are fixture-backed because Docker Desktop does
# not expose every net.core sysctl inside a container.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
REAL_SYSCTL=$(command -v sysctl)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fixture_value() {
    case "$1" in
        net.core.default_qdisc) printf 'fq\n' ;;
        net.ipv4.tcp_congestion_control) printf 'cubic\n' ;;
        net.core.rmem_max|net.core.wmem_max) printf '16777216\n' ;;
        net.ipv4.tcp_mtu_probing) printf '0\n' ;;
        net.ipv4.tcp_fastopen) printf '1\n' ;;
        net.core.somaxconn|net.ipv4.tcp_max_syn_backlog) printf '4096\n' ;;
        net.core.netdev_max_backlog) printf '1000\n' ;;
        *) return 1 ;;
    esac
}

sysctl() {
    [[ "$1" == -n ]] || return 1
    case "$2" in
        net.ipv4.tcp_rmem|net.ipv4.tcp_wmem) "$REAL_SYSCTL" -n "$2" ;;
        *) fixture_value "$2" ;;
    esac
}

snapshot="$TEST_ROOT/sysctl.tsv"
capture_runtime_sysctls > "$snapshot"
tcp_baseline_sysctl_validate "$snapshot"
awk -F '\t' 'NF != 2 {exit 1}' "$snapshot"

for key in net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    raw=$("$REAL_SYSCTL" -n "$key")
    first=""; second=""; third=""; extra=""
    read -r first second third extra <<< "$raw"
    [[ -n "$first" && -n "$second" && -n "$third" && -z "$extra" ]]
    grep -Fxq "$key"$'\t'"$first $second $third" "$snapshot"
done

printf 'real sysctl snapshot integration: OK\n'
