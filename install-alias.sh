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
If a tag exists but its Release assets are missing, the installer securely falls back to that immutable tag.
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

download_release_or_tag() {
    local version="$1" release_base raw_base
    release_base="https://github.com/${REPO}/releases/download/${version}"
    raw_base="https://raw.githubusercontent.com/${REPO}/${version}"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$release_base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" &&
       curl -fsSL --connect-timeout 15 --max-time 30 "$release_base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
        BASE="$release_base"
        return 0
    fi
    echo "release assets for $version are unavailable; falling back to immutable tag" >&2
    if curl -fsSL --connect-timeout 15 --max-time 120 "$raw_base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" &&
       curl -fsSL --connect-timeout 15 --max-time 30 "$raw_base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
        BASE="$raw_base"
        return 0
    fi
    return 1
}

if [[ "$CHANNEL" == release ]]; then
    if [[ -z "$VERSION" ]]; then
        VERSION=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
            | awk -F'"' '/"tag_name"/ {print $4; exit}' || true)
        if [[ -z "$VERSION" ]]; then
            VERSION=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://api.github.com/repos/${REPO}/tags?per_page=100" \
                | awk -F'"' '/"name"[[:space:]]*:/ && $4 ~ /^v[0-9]+[.][0-9]+[.][0-9]+$/ {print $4}' \
                | sort -V | tail -n1)
        fi
    fi
    [[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { echo "invalid release version: $VERSION" >&2; exit 1; }
    download_release_or_tag "$VERSION" || { echo "unable to download $VERSION from release assets or tag" >&2; exit 1; }
else
    [[ -z "$VERSION" ]] || { echo "--version cannot be used with --channel main" >&2; exit 1; }
    BASE="https://raw.githubusercontent.com/${REPO}/main"
    curl -fsSL --connect-timeout 15 --max-time 120 "$BASE/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh"
    curl -fsSL --connect-timeout 15 --max-time 30 "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
fi
expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "$tmp/SHA256SUMS")
actual=$(sha256sum "$tmp/net-tcp-tune.sh" | awk '{print $1}')
[[ -n "$expected" && "$actual" == "$expected" ]] || { echo "SHA256 verification failed" >&2; exit 1; }
bash -n "$tmp/net-tcp-tune.sh"
grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$tmp/net-tcp-tune.sh" || { echo "project marker missing" >&2; exit 1; }
if [[ -n "$VERSION" ]]; then
    grep -Fq "SCRIPT_VERSION=\"${VERSION#v}\"" "$tmp/net-tcp-tune.sh" || { echo "version marker mismatch" >&2; exit 1; }
fi

mkdir -p -- "$PREFIX"
install -m 0755 "$tmp/net-tcp-tune.sh" "$TARGET"
echo "installed: $TARGET"
echo "source: $BASE"
if [[ ":$PATH:" != *":$PREFIX:"* ]]; then echo "add $PREFIX to PATH before running: bbr"; fi
echo "If an old shell function shadows the command, run: unset -f bbr 2>/dev/null; hash -r"
