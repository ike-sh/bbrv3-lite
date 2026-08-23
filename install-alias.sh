#!/usr/bin/env bash
# Install a verified bbrv3-lite release as the local `bbr` command.
set -Eeuo pipefail

REPO="ike-sh/bbrv3-lite"
MODE="install"
CHANNEL="release"
VERSION=""
PREFIX=""
RUN_AFTER_INSTALL=0
MODE_EXPLICIT=0
CHANNEL_EXPLICIT=0
VERSION_EXPLICIT=0
RUN_EXPLICIT=0
PREFIX_EXPLICIT=0
LEGACY_SHELL_START='# ================ net-tcp-tune 快捷别名 ================'
LEGACY_SHELL_END='# ================ net-tcp-tune 快捷别名结束 ================'

usage() {
    cat <<EOF
Usage: $0 [install|uninstall] [--channel release|main] [--version vX.Y.Z] [--prefix DIR] [--run]

Default: install the latest GitHub release after SHA256 verification.
If a tag exists but its Release assets are missing, the installer securely falls back to that immutable tag.
The main channel is intended for testing and still requires the repository SHA256SUMS file.
EOF
}

require_value() {
    if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        exit 1
    fi
}

managed_bbr_file() {
    local file="$1" first version_count name_count repo_count header_count
    [[ -f "$file" || -L "$file" ]] || return 1
    IFS= read -r first < "$file" || return 1
    [[ "$first" == '#!/usr/bin/env bash' || "$first" == '#!/bin/bash' ]] || return 1
    header_count=$(grep -Fxc '# BBRv3 Lite - measured TCP tuning for Debian/Ubuntu' "$file" 2>/dev/null || true)
    version_count=$(grep -Ec '^SCRIPT_VERSION="[0-9]+[.][0-9]+[.][0-9]+"$' "$file" 2>/dev/null || true)
    name_count=$(grep -Fxc 'SCRIPT_NAME="bbrv3-lite"' "$file" 2>/dev/null || true)
    repo_count=$(grep -Fxc 'PROJECT_REPO="ike-sh/bbrv3-lite"' "$file" 2>/dev/null || true)
    [[ "$header_count" == 1 && "$version_count" == 1 && "$name_count" == 1 && "$repo_count" == 1 ]]
}

legacy_shell_block_valid() {
    local file="$1" start_count end_count start_line end_line
    start_count=$(grep -Fxc "$LEGACY_SHELL_START" "$file" 2>/dev/null || true)
    end_count=$(grep -Fxc "$LEGACY_SHELL_END" "$file" 2>/dev/null || true)
    [[ "$start_count" == 1 && "$end_count" == 1 ]] || return 1
    start_line=$(grep -Fxn "$LEGACY_SHELL_START" "$file" | cut -d: -f1)
    end_line=$(grep -Fxn "$LEGACY_SHELL_END" "$file" | cut -d: -f1)
    [[ "$start_line" =~ ^[0-9]+$ && "$end_line" =~ ^[0-9]+$ && "$start_line" -lt "$end_line" ]]
}

preserve_reference_owner() {
    local reference="$1" candidate="$2" reference_owner candidate_owner
    if chown --reference="$reference" "$candidate" 2>/dev/null; then return 0; fi
    reference_owner=$(stat -c '%u:%g' "$reference" 2>/dev/null) || return 1
    candidate_owner=$(stat -c '%u:%g' "$candidate" 2>/dev/null) || return 1
    [[ "$reference_owner" == "$candidate_owner" ]]
}

while (($#)); do
    case "$1" in
        install|uninstall)
            (( MODE_EXPLICIT == 0 )) || { echo "install/uninstall may be specified only once" >&2; exit 1; }
            MODE="$1"; MODE_EXPLICIT=1; shift
            ;;
        --channel)
            (( CHANNEL_EXPLICIT == 0 )) || { echo "--channel may be specified only once" >&2; exit 1; }
            require_value "$@"; CHANNEL="$2"; CHANNEL_EXPLICIT=1; shift 2
            ;;
        --version)
            (( VERSION_EXPLICIT == 0 )) || { echo "--version may be specified only once" >&2; exit 1; }
            require_value "$@"; VERSION="$2"; VERSION_EXPLICIT=1; shift 2
            ;;
        --prefix)
            (( PREFIX_EXPLICIT == 0 )) || { echo "--prefix may be specified only once" >&2; exit 1; }
            require_value "$@"; PREFIX="$2"; PREFIX_EXPLICIT=1; shift 2
            ;;
        --run)
            (( RUN_EXPLICIT == 0 )) || { echo "--run may be specified only once" >&2; exit 1; }
            RUN_AFTER_INSTALL=1; RUN_EXPLICIT=1; shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$CHANNEL" == release || "$CHANNEL" == main ]] || { echo "channel must be release or main" >&2; exit 1; }
if [[ "$MODE" == uninstall ]] && (( CHANNEL_EXPLICIT || VERSION_EXPLICIT || RUN_EXPLICIT )); then
    echo "uninstall accepts only --prefix" >&2
    exit 1
fi
INSTALL_HOME="${HOME:-}"
if [[ -z "$INSTALL_HOME" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then INSTALL_HOME=/root
    else echo "HOME is not set; use --prefix explicitly" >&2; exit 1
    fi
fi
if [[ -z "$PREFIX" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then PREFIX=/usr/local/bin; else PREFIX="${INSTALL_HOME}/.local/bin"; fi
fi
command -v readlink >/dev/null 2>&1 || { echo "missing command: readlink" >&2; exit 1; }
[[ "$PREFIX" == /* ]] || { echo "--prefix must be an absolute directory other than /" >&2; exit 1; }
PREFIX=$(readlink -m -- "$PREFIX") || { echo "unable to normalize --prefix" >&2; exit 1; }
[[ -n "$PREFIX" && "$PREFIX" != / ]] || { echo "--prefix must resolve to an absolute directory other than /" >&2; exit 1; }
TARGET="$PREFIX/bbr"

if [[ "$MODE" == uninstall ]]; then
    for command in grep cut sed mktemp mv rm chmod chown stat; do command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }; done
    # Validate every target before deleting either the command or shell data.
    # A truncated legacy block must never turn a range deletion into "to EOF".
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        managed_bbr_file "$TARGET" || { echo "refusing to remove an unmanaged file: $TARGET" >&2; exit 1; }
    fi
    for rc_file in "${INSTALL_HOME}/.bashrc" "${INSTALL_HOME}/.bash_profile" "${INSTALL_HOME}/.zshrc"; do
        [[ -f "$rc_file" ]] || continue
        if grep -Fqx "$LEGACY_SHELL_START" "$rc_file" || grep -Fqx "$LEGACY_SHELL_END" "$rc_file"; then
            legacy_shell_block_valid "$rc_file" || {
                echo "refusing to edit malformed legacy shell block: $rc_file" >&2
                exit 1
            }
        fi
    done
    if [[ -e "$TARGET" || -L "$TARGET" ]]; then
        rm -f -- "$TARGET"
        echo "removed: $TARGET"
    else
        echo "not found: $TARGET"
    fi
    for rc_file in "${INSTALL_HOME}/.bashrc" "${INSTALL_HOME}/.bash_profile" "${INSTALL_HOME}/.zshrc"; do
        [[ -f "$rc_file" ]] || continue
        grep -Fqx "$LEGACY_SHELL_START" "$rc_file" || continue
        temp_rc=$(mktemp "${rc_file}.bbrv3-lite.XXXXXX") || exit 1
        if ! sed '/^# ================ net-tcp-tune 快捷别名 ================/,/^# ================ net-tcp-tune 快捷别名结束 ================/d' "$rc_file" > "$temp_rc"; then
            rm -f -- "$temp_rc"
            exit 1
        fi
        if ! chmod --reference="$rc_file" "$temp_rc"; then rm -f -- "$temp_rc"; echo "unable to preserve permissions: $rc_file" >&2; exit 1; fi
        if ! preserve_reference_owner "$rc_file" "$temp_rc"; then rm -f -- "$temp_rc"; echo "unable to preserve ownership: $rc_file" >&2; exit 1; fi
        if ! mv -f -- "$temp_rc" "$rc_file"; then rm -f -- "$temp_rc"; exit 1; fi
        echo "removed legacy shell function: $rc_file"
    done
    echo "run in the current shell: unset -f bbr 2>/dev/null; hash -r"
    exit 0
fi

for command in curl sha256sum awk install grep sort bash mktemp mv chown stat; do command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }; done

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
managed_bbr_file "$tmp/net-tcp-tune.sh" || { echo "project signature missing or ambiguous" >&2; exit 1; }
if [[ -n "$VERSION" ]]; then
    grep -Fq "SCRIPT_VERSION=\"${VERSION#v}\"" "$tmp/net-tcp-tune.sh" || { echo "version marker mismatch" >&2; exit 1; }
fi

mkdir -p -- "$PREFIX"
TARGET_EXISTED=0
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    managed_bbr_file "$TARGET" || { echo "refusing to overwrite an unmanaged file: $TARGET" >&2; exit 1; }
    TARGET_EXISTED=1
fi
target_temp=$(mktemp "${TARGET}.tmp.XXXXXX")
if ! install -m 0755 "$tmp/net-tcp-tune.sh" "$target_temp"; then rm -f -- "$target_temp"; exit 1; fi
if (( TARGET_EXISTED )) && ! preserve_reference_owner "$TARGET" "$target_temp"; then
    rm -f -- "$target_temp"
    echo "unable to preserve ownership: $TARGET" >&2
    exit 1
fi
if ! mv -f -- "$target_temp" "$TARGET"; then rm -f -- "$target_temp"; exit 1; fi
echo "installed: $TARGET"
echo "source: $BASE"
if [[ ":$PATH:" != *":$PREFIX:"* ]]; then echo "add $PREFIX to PATH before running: bbr"; fi
echo "If an old shell function shadows the command, run: unset -f bbr 2>/dev/null; hash -r"
if (( RUN_AFTER_INSTALL )); then
    if { exec 3</dev/tty; } 2>/dev/null; then exec "$TARGET" <&3
    else exec "$TARGET"; fi
fi
