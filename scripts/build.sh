#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT_DIR/net-tcp-tune.sh"
TEMP=$(mktemp)
trap 'rm -f -- "$TEMP"' EXIT

MODULES=(
    00-header.sh
    core.sh
    config.sh
    platform.sh
    state.sh
    sysctl.sh
    tc.sh
    measure.sh
    systemd.sh
    kernel.sh
    dns.sh
    ipv6.sh
    update.sh
    cli.sh
)

for module in "${MODULES[@]}"; do
    source_file="$ROOT_DIR/src/$module"
    [[ -f "$source_file" ]] || { echo "missing module: $source_file" >&2; exit 1; }
    if [[ "$module" == 00-header.sh ]]; then
        sed 's/$//' "$source_file" >> "$TEMP"
    else
        printf '\n' >> "$TEMP"
        sed 's/$//' "$source_file" >> "$TEMP"
    fi
done

bash -n "$TEMP"
chmod 0755 "$TEMP"
mv -f -- "$TEMP" "$OUTPUT"
trap - EXIT
echo "built: $OUTPUT"
