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
grep -Fq 'SCRIPT_VERSION="7.0.6"' net-tcp-tune.sh
grep -Fq 'Configuration is data and is never sourced' net-tcp-tune.sh
grep -Fq 'tc qdisc replace dev "$iface" root handle 1: htb default 10' net-tcp-tune.sh
grep -Fq 'tc qdisc replace dev "$iface" parent 1:10 handle 10: fq' net-tcp-tune.sh
grep -Fq 'iperf3 -c "$peer" -p "$port" -t "$duration" -P "$parallel" -J' net-tcp-tune.sh
if grep -Eq 'source[[:space:]]+.*bbrv3-lite\.conf' net-tcp-tune.sh; then echo "unsafe config source detected" >&2; exit 1; fi

echo "==> Core tests"
bash tests/test_core.sh
bash tests/test_installer.sh

if [[ "${SKIP_RELEASE_CHECKSUM:-0}" != 1 && -f SHA256SUMS ]]; then
    echo "==> Release checksums"
    sha256sum -c SHA256SUMS --ignore-missing
fi

echo "==> ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
    # load_config/migrate_legacy_config intentionally accept optional paths used by sourced tests.
    shellcheck -S warning -e SC2120 net-tcp-tune.sh scripts/build.sh scripts/release.sh scripts/validate.sh tests/test_core.sh tests/test_installer.sh tests/integration_tc.sh install-alias.sh
else
    echo "shellcheck unavailable; skipped"
fi

echo "==> All checks passed"
