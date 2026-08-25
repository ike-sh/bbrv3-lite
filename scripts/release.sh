#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SKIP_RELEASE_CHECKSUM=1 bash scripts/validate.sh

temp=$(mktemp "$ROOT_DIR/.SHA256SUMS.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
sha256sum net-tcp-tune.sh install-alias.sh > "$temp"
mv -f -- "$temp" "$ROOT_DIR/SHA256SUMS"
trap - EXIT
echo "release checksums written: $ROOT_DIR/SHA256SUMS"
