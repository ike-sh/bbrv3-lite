#!/usr/bin/env bash
# Install a verified bbrv3-lite release as the local `bbr` command.
set -Eeuo pipefail

REPO="ike-sh/bbrv3-lite"
MODE="install"
CHANNEL="release"
VERSION=""
PREFIX=""

usage() {
    cat <<EOF
Usage: $0 [install|uninstall] [--channel release|main] [--version vX.Y.Z] [--prefix DIR]

Default: install the latest GitHub release after SHA256 verification.
The main channel is intended for testing and still requires the repository SHA256SUMS file.
EOF
}

while (($#)); do
    case "$1" in
        install|uninstall) MODE="$1"; shift ;;
        --channel) CHANNEL="${2:?missing channel}"; shift 2 ;;
        --version) VERSION="${2:?missing version}"; shift 2 ;;
        --prefix) PREFIX="${2:?missing prefix}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$CHANNEL" == release || "$CHANNEL" == main ]] || { echo "channel must be release or main" >&2; exit 1; }
if [[ -z "$PREFIX" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then PREFIX=/usr/local/bin; else PREFIX="${HOME}/.local/bin"; fi
fi
TARGET="$PREFIX/bbr"

if [[ "$MODE" == uninstall ]]; then
    rm -f -- "$TARGET"
    echo "removed: $TARGET"
    exit 0
fi

for command in curl sha256sum awk install; do command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }; done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

if [[ "$CHANNEL" == release ]]; then
    if [[ -z "$VERSION" ]]; then
        VERSION=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://api.github.com/repos/${REPO}/releases/latest" \
            | awk -F'"' '/"tag_name"/ {print $4; exit}')
    fi
    [[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { echo "invalid release version: $VERSION" >&2; exit 1; }
    BASE="https://github.com/${REPO}/releases/download/${VERSION}"
else
    [[ -z "$VERSION" ]] || { echo "--version cannot be used with --channel main" >&2; exit 1; }
    BASE="https://raw.githubusercontent.com/${REPO}/main"
fi

curl -fsSL --connect-timeout 15 --max-time 120 "$BASE/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh"
curl -fsSL --connect-timeout 15 --max-time 30 "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "$tmp/SHA256SUMS")
actual=$(sha256sum "$tmp/net-tcp-tune.sh" | awk '{print $1}')
[[ -n "$expected" && "$actual" == "$expected" ]] || { echo "SHA256 verification failed" >&2; exit 1; }
bash -n "$tmp/net-tcp-tune.sh"
grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$tmp/net-tcp-tune.sh" || { echo "project marker missing" >&2; exit 1; }

mkdir -p -- "$PREFIX"
install -m 0755 "$tmp/net-tcp-tune.sh" "$TARGET"
echo "installed: $TARGET"
if [[ ":$PATH:" != *":$PREFIX:"* ]]; then echo "add $PREFIX to PATH before running: bbr"; fi
