#!/usr/bin/env bash
# Proposed P3-RC1 qualification check for review; not executed in this campaign.
# Run in an uploaded payload root made with mktemp -d /tmp/bbr-v808-p3-rc1.XXXXXX.
# No real iperf, auto, measure command, sysctl write, tc write or service change.
set -Eeuo pipefail
RC1_ROOT="${1:?pass the independent uploaded payload directory}"
RC1_OLD="${2:-/tmp/bbr-v808-p3.HhaVI6/sandbox/state/history/20261112T220549Z-sweep}"
RC1_EXPECTED_SHA=f14e7e5c82c3ed5356ce9883dd1792e2477625fca2de072dc651f20e0102f33d
[[ "$EUID" == 0 && "$RC1_ROOT" =~ ^/tmp/bbr-v808-p3-rc1\.[[:alnum:]]+$ && -d "$RC1_ROOT" && ! -L "$RC1_ROOT" ]]
RC1_DEV="$RC1_ROOT/net-tcp-tune.sh"
[[ "$(sha256sum "$RC1_DEV" | awk '{print $1}')" == "$RC1_EXPECTED_SHA" ]]
[[ ! -e "$RC1_ROOT/readonly" && ! -L "$RC1_ROOT/readonly" ]]
for RC1_FILE in summary.tsv failure.tsv; do
    if [[ ! -f "$RC1_OLD/$RC1_FILE" || -L "$RC1_OLD/$RC1_FILE" ]]; then
        printf 'ORIGINAL_P3_EVIDENCE=NOT_RUN (missing or unsafe source file)\n'
        exit 4
    fi
done
printf '%s  %s\n' \
    7cbfe3d76bc81f533742a91b10889c655c497fa69829bcdaa46b7fe78c559138 "$RC1_OLD/summary.tsv" \
    7fe4c17772ec8d6eef79297044b9c4ff2b2195626dfde659911c629c7cc312e8 "$RC1_OLD/failure.tsv" | sha256sum -c -
mkdir -p "$RC1_ROOT/evidence" "$RC1_ROOT/readonly/history/20261112T220549Z-sweep" "$RC1_ROOT/tmp"
chmod 0700 "$RC1_ROOT" "$RC1_ROOT/evidence" "$RC1_ROOT/readonly" "$RC1_ROOT/tmp"

rc1_snapshot() {
    local prefix="$1" path
    date -u +%FT%TZ > "$prefix.time"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc > "$prefix.sysctl"
    tc qdisc show dev eth0 > "$prefix.qdisc"
    tc class show dev eth0 > "$prefix.class"
    tc filter show dev eth0 root > "$prefix.filter-root"
    tc filter show dev eth0 ingress > "$prefix.filter-ingress"
    ip -4 route show default > "$prefix.route4"
    ip -6 route show default > "$prefix.route6"
    systemctl show bbrv3-lite.service -p LoadState -p ActiveState -p SubState -p UnitFileState -p FragmentPath > "$prefix.service"
    /usr/local/bin/bbr --version > "$prefix.official-version"
    if [[ -d /var/lib/bbrv3-lite ]]; then
        find /var/lib/bbrv3-lite -xdev -type f -print0 | sort -z | xargs -0 -r sha256sum > "$prefix.state-sha256"
        find /var/lib/bbrv3-lite -xdev -printf '%y\t%m\t%U:%G\t%p\t%l\n' | LC_ALL=C sort > "$prefix.state-metadata"
    else
        printf 'ABSENT\n' > "$prefix.state-sha256"
        printf 'ABSENT\n' > "$prefix.state-metadata"
    fi
    for path in /usr/local/bin/bbr /etc/bbrv3-lite.conf /etc/sysctl.d/99-bbrv3-lite.conf /etc/systemd/system/bbrv3-lite.service /usr/local/lib/bbrv3-lite/net-tcp-tune.sh; do
        if [[ -e "$path" || -L "$path" ]]; then
            stat -c '%a %u:%g %F %n' "$path"
            if [[ -L "$path" ]]; then readlink "$path"; elif [[ -f "$path" ]]; then sha256sum "$path"; fi
        else printf 'ABSENT %s\n' "$path"; fi
    done > "$prefix.protected-paths"
}
rc1_snapshot "$RC1_ROOT/evidence/before"
sha256sum "$RC1_OLD/summary.tsv" "$RC1_OLD/failure.tsv" > "$RC1_ROOT/evidence/original-before.sha256"
rc1_finish() {
    local result=$? name
    trap - EXIT
    rc1_snapshot "$RC1_ROOT/evidence/after" || result=1
    for name in sysctl qdisc class filter-root filter-ingress route4 route6 service official-version state-sha256 state-metadata protected-paths; do
        cmp "$RC1_ROOT/evidence/before.$name" "$RC1_ROOT/evidence/after.$name" || result=1
    done
    sha256sum -c "$RC1_ROOT/evidence/original-before.sha256" || result=1
    printf 'READONLY_QUALIFICATION_RC=%s\nREAL_IPERF_EXECUTED=no\n' "$result"
    exit "$result"
}
trap rc1_finish EXIT

cp "$RC1_OLD/summary.tsv" "$RC1_OLD/failure.tsv" "$RC1_ROOT/readonly/history/20261112T220549Z-sweep/"
export BBRV3_CONFIG="$RC1_ROOT/readonly/etc/bbrv3-lite.conf"
export BBRV3_STATE_DIR="$RC1_ROOT/readonly/state"
export BBRV3_HISTORY_DIR="$RC1_ROOT/readonly/history"
export BBRV3_PEER_HEALTH_DIR="$RC1_ROOT/readonly/state/peer-health"
export BBRV3_BASELINE_DIR="$RC1_ROOT/readonly/state/baseline"
export BBRV3_LEGACY_BACKUP_DIR="$RC1_ROOT/readonly/state/original"
export BBRV3_FINAL_PATH_PROFILE_FILE="$RC1_ROOT/readonly/state/final-path-profile.tsv"
export BBRV3_NIC_POLICY_DIR="$RC1_ROOT/readonly/etc/interfaces.d"
export BBRV3_NIC_STATE_DIR="$RC1_ROOT/readonly/state/interfaces"
export BBRV3_DNS_BACKUP_DIR="$RC1_ROOT/readonly/state/dns"
export BBRV3_IPV6_BACKUP_DIR="$RC1_ROOT/readonly/state/ipv6"
export BBRV3_SYSCTL_FILE="$RC1_ROOT/readonly/etc/99-bbrv3-lite.conf"
export BBRV3_LEGACY_SYSCTL_FILE="$RC1_ROOT/readonly/etc/99-bbr-ultimate.conf"
export BBRV3_SERVICE_FILE="$RC1_ROOT/readonly/etc/bbrv3-lite.service"
export BBRV3_LEGACY_SERVICE_FILE="$RC1_ROOT/readonly/etc/bbr-optimize-persist.service"
export BBRV3_PERSIST_DIR="$RC1_ROOT/readonly/persist"
export BBRV3_PERSIST_SCRIPT="$RC1_ROOT/readonly/persist/net-tcp-tune.sh"
export BBRV3_LOCK_FILE="$RC1_ROOT/readonly/run/lock"
export TMPDIR="$RC1_ROOT/tmp"
bash "$RC1_DEV" --version > "$RC1_ROOT/evidence/new-version.txt"
bash "$RC1_DEV" history > "$RC1_ROOT/evidence/history-list.txt"
bash "$RC1_DEV" history latest > "$RC1_ROOT/evidence/history-latest.txt"
bash "$RC1_DEV" history show 20261112T220549Z-sweep > "$RC1_ROOT/evidence/history-show.txt"
(
    # Existing sourced diagnostic function, not an invented CLI option.
    # shellcheck source=/dev/null
    source "$RC1_DEV"
    failure_summary_print "$BBRV3_HISTORY_DIR/20261112T220549Z-sweep/summary.tsv"
) > "$RC1_ROOT/evidence/failure-summary.txt"
cmp "$RC1_ROOT/evidence/history-latest.txt" "$RC1_ROOT/evidence/history-show.txt"
for RC1_FILE in history-list.txt history-latest.txt history-show.txt failure-summary.txt; do
    grep -Fq feasibility-rejected "$RC1_ROOT/evidence/$RC1_FILE"
    if grep -Fq 已耗尽 "$RC1_ROOT/evidence/$RC1_FILE"; then exit 1; fi
done
nice -n 10 timeout 180s env BBRV3_RC1_EVIDENCE_DIR="$RC1_ROOT/evidence/new-records" \
    unshare -n -- bash "$RC1_ROOT/tests/test_v808_budget_failure_semantics.sh" > "$RC1_ROOT/evidence/isolated-fixture.log" 2>&1
