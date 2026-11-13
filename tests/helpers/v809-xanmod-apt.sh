#!/usr/bin/env bash
# Opt-in, real APT test in a fresh disposable Debian 13 Docker container.
# Never called by the ordinary matrix or on a production VPS.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f /.dockerenv && $(id -u) == 0 ]] || { echo 'requires a disposable Docker container' >&2; exit 1; }
[[ $(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2);print $2}' /etc/os-release) == 13 ]] || exit 1
[[ ! -e /etc/apt/sources.list.d/xanmod-release.list && ! -e /etc/apt/keyrings/xanmod-archive-keyring.gpg ]] || exit 1
if command -v curl >/dev/null || command -v gpg >/dev/null; then echo 'requires minimal image without curl and gpg' >&2; exit 1; fi
# shellcheck source=../../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"
running_before=$(uname -r)
tcp_before=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
printf 'INITIAL_CURL=missing\nINITIAL_GPG=missing\nRUNNING_KERNEL_BEFORE=%s\n' "$running_before"
rc=0
kernel_install lts > /tmp/container-guard.log 2>&1 || rc=$?
(( rc != 0 )) && grep -Fq '容器中不能' /tmp/container-guard.log || { echo 'container safety guard failed' >&2; exit 1; }
printf 'REAL_CONTAINER_GUARD=PASS\n'
require_commands apt-get apt-cache dpkg-query
kernel_bootstrap_dependencies
command -v curl
command -v gpg
dpkg-query -W -f='${Package}\t${Status}\t${Version}\n' ca-certificates curl gnupg
printf 'REAL_BOOTSTRAP_DEPENDENCIES=PASS\nREAL_XANMOD_KERNEL_APT=NOT_RUN_YET\nNEW_KERNEL_RUNNING=NOT_RUN_NO_REBOOT\n'
# Test-only bypass after checking the real guard above. Docker has no host boot,
# module or network mounts and lacks SYS_BOOT/SYS_MODULE/NET_ADMIN capabilities.
# The production guard is unchanged; this is package installation in image /boot.
is_container() { return 1; }
rc=0
kernel_install lts || rc=$?
[[ $(uname -r) == "$running_before" ]] || { echo 'running kernel changed' >&2; exit 1; }
[[ $(cat /proc/sys/net/ipv4/tcp_congestion_control) == "$tcp_before" ]] || { echo 'TCP CC changed' >&2; exit 1; }
printf 'KERNEL_INSTALL_RC=%s\nRUNNING_KERNEL_UNCHANGED=PASS\nTCP_CC_UNCHANGED=PASS\nNEW_KERNEL_RUNNING=NOT_RUN_NO_REBOOT\n' "$rc"
if (( rc == 0 )); then
    dpkg-query -W -f='${Package}\t${Status}\t${Version}\n' 'linux-*xanmod*'
    printf 'REAL_XANMOD_KERNEL_APT=PASS_INSTALLED_ONLY\n'
else
    printf 'REAL_XANMOD_KERNEL_APT=NOT_COMPLETED\n'
fi
exit "$rc"
