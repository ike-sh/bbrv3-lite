#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# shellcheck source=../net-tcp-tune.sh
source "$ROOT_DIR/net-tcp-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f "${CASE_DIR:-}/run.log" ]] || cat "$CASE_DIR/run.log" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" || fail "missing $2 in $1"; }
lacks() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in $1"; }
event() { printf '%s\n' "$*" >> "$CASE_DIR/events"; }

setup() {
    CASE_DIR="$TEST_ROOT/$1"; mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/pkg" "$CASE_DIR/commands" "$CASE_DIR/production"
    export TMPDIR="$CASE_DIR/tmp"
    XANMOD_KEYRING_FILE="$CASE_DIR/etc/keyrings/xanmod.gpg"
    XANMOD_SOURCE_FILE="$CASE_DIR/etc/sources/xanmod.list"
    : > "$CASE_DIR/events"
    printf 'bbr\nfq\nexisting-history\ntrusted-baseline\n' > "$CASE_DIR/production/state"
    PRODUCTION_HASH=$(sha256sum "$CASE_DIR/production/state")
    UPDATE_FAIL=0 INSTALL_FAIL=0 SIM_FAIL=0 CURL_FAIL=0 GPG_FAIL=0 BAD_FORMAT=0 BAD_CONVERSION=0
    REMOVE_PACKAGE="" REMOVE_STAGE=deps LEVEL=3 GRUB_FAIL=0 WITH_GRUB=1
    AVAILABLE='linux-xanmod-lts-x64v3 linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1 linux-xanmod-x64v3 linux-xanmod-x64v2'
    MISSING_GPG_AFTER_INSTALL=0 REPO_TERM=0
    require_root() { event ROOT; }; acquire_lock() { event LOCK; }
    os_id() { printf 'debian\n'; }; os_codename() { printf 'trixie\n'; }
    uname() { case "$1" in -m) printf 'x86_64\n' ;; -r) printf '6.12.96+deb13-amd64\n' ;; *) return 1 ;; esac; }
    is_container() { return 1; }; secure_boot_enabled() { return 1; }
    detect_x86_level() { printf '%s\n' "$LEVEL"; }
    command_exists() {
        case "$1" in
            curl|gpg) [[ -f "$CASE_DIR/commands/$1" ]] ;;
            update-grub) (( WITH_GRUB )) ;;
            *) command -v "$1" >/dev/null 2>&1 ;;
        esac
    }
    dpkg-query() { [[ -f "$CASE_DIR/pkg/${!#}" ]] || return 1; printf 'install ok installed'; }
    apt-get() {
        local stage=deps count=0 arg
        [[ "$*" != *linux-xanmod* ]] || stage=kernel
        if [[ " $* " == *' update '* ]]; then
            [[ ! -f "$CASE_DIR/updates" ]] || count=$(<"$CASE_DIR/updates")
            ((count+=1)); printf '%s\n' "$count" > "$CASE_DIR/updates"
            event "UPDATE:$count:$*"
            [[ "$*" == *APT::Update::Error-Mode=any* ]] || fail 'APT partial-update errors were not made fatal'
            if (( UPDATE_FAIL == count )); then printf 'E: fixture repository unavailable\n' >&2; return 100; fi
            if (( REPO_TERM && count == 2 )); then kill -TERM "$BASHPID"; fi
        elif [[ " $* " == *' -s '* ]]; then
            event "SIM:$stage:$*"
            [[ -z "$REMOVE_PACKAGE" || "$REMOVE_STAGE" != "$stage" ]] || printf 'Remv %s [1.0]\n' "$REMOVE_PACKAGE"
            if (( SIM_FAIL )); then printf 'E: fixture package conflict\n' >&2; return 100; fi
        else
            event "INSTALL:$stage:$*"
            [[ " $* " == *' --no-remove '* ]] || fail 'actual APT install could remove a running kernel or network package'
            if [[ "$INSTALL_FAIL" == "$stage" ]]; then printf 'E: fixture no space left on device\n' >&2; return 100; fi
            if [[ "$stage" == deps ]]; then
                for arg in "$@"; do
                    case "$arg" in
                        ca-certificates|curl|gnupg) : > "$CASE_DIR/pkg/$arg" ;;
                    esac
                    case "$arg" in curl) : > "$CASE_DIR/commands/curl" ;; gnupg) (( MISSING_GPG_AFTER_INSTALL )) || : > "$CASE_DIR/commands/gpg" ;; esac
                done
            else printf '%s\n' "$*" > "$CASE_DIR/kernel-package"; fi
        fi
    }
    apt-cache() { event "CACHE:${!#}"; [[ " $AVAILABLE " == *" ${!#} "* ]]; }
    curl() {
        command_exists curl || { event EARLY_CURL; return 127; }
        event DOWNLOAD
        (( CURL_FAIL == 0 )) || { printf 'curl: fixture TLS/download failure\n' >&2; return 22; }
        [[ "$*" == *https://dl.xanmod.org/archive.key* && "$*" == *"--proto =https"* && "$*" == *"--proto-redir =https"* ]] || fail 'non-official/non-HTTPS key retrieval'
        local target=""
        while (($#)); do case "$1" in -o) target="$2"; shift 2 ;; *) shift ;; esac; done
        printf 'fixture-public-key\n' > "$target"
    }
    gpg() {
        command_exists gpg || { event EARLY_GPG; return 127; }
        if [[ "$*" == *--show-keys* ]]; then
            event KEY_CHECK
            if (( BAD_FORMAT )); then printf 'not a public key\n'; return 0; fi
            if [[ "${!#}" == *keyring.gpg ]] && (( BAD_CONVERSION )); then printf 'sec:-:4096:1:fixture\n'; return 0; fi
            printf 'pub:-:4096:1:fixture\n'
        else
            event CONVERT
            local target=""
            while (($#)); do case "$1" in -o) target="$2"; shift 2 ;; *) shift ;; esac; done
            printf 'fixture-keyring\n' > "$target"
            (( GPG_FAIL == 0 )) || { printf 'gpg: fixture conversion failed\n' >&2; return 2; }
        fi
    }
    update-grub() { event GRUB; (( GRUB_FAIL == 0 )); }
    reboot() { event FORBIDDEN_REBOOT; return 99; }
    shutdown() { event FORBIDDEN_REBOOT; return 99; }
    sysctl() { event FORBIDDEN_NETWORK; return 99; }
    tc() { event FORBIDDEN_NETWORK; return 99; }
    persist_current_tuning() { event FORBIDDEN_PERSISTENCE; return 99; }
    auto_tune_wizard() { event FORBIDDEN_AUTO; return 99; }
}

installed() {
    local package
    for package in "$@"; do
        : > "$CASE_DIR/pkg/$package"
        case "$package" in curl) : > "$CASE_DIR/commands/curl" ;; gnupg) : > "$CASE_DIR/commands/gpg" ;; esac
    done
}
existing_repository() {
    mkdir -p "$(dirname "$XANMOD_KEYRING_FILE")" "$(dirname "$XANMOD_SOURCE_FILE")"
    printf 'fixture-keyring\n' > "$XANMOD_KEYRING_FILE"
    printf 'deb [signed-by=%s] http://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING_FILE" > "$XANMOD_SOURCE_FILE"
}
invoke() {
    RC=0
    # Deliberately conditional: Bash errexit cannot make failures safe here.
    kernel_install "${1:-lts}" > "$CASE_DIR/run.log" 2>&1 || RC=$?
    [[ "$PRODUCTION_HASH" == "$(sha256sum "$CASE_DIR/production/state")" ]] || fail 'production fixture was modified'
    lacks "$CASE_DIR/events" FORBIDDEN
    lacks "$CASE_DIR/events" EARLY_
    [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]] || fail 'operation temporary files leaked'
    [[ -z $(find "$CASE_DIR/etc" -name '*.tmp.*' -print -quit 2>/dev/null) ]] || fail 'atomic repository temporary leaked'
}
success() {
    (( RC == 0 )) || fail "installation returned $RC"
    has "$CASE_DIR/run.log" 'bootstrap 依赖可用（不代表内核已安装）'
    has "$CASE_DIR/run.log" '内核包已安装；当前运行内核未切换'
    has "$CASE_DIR/events" INSTALL:kernel
    [[ -f "$XANMOD_KEYRING_FILE" && -f "$XANMOD_SOURCE_FILE" ]] || fail 'valid repository absent after success'
    [[ $(stat -c '%a' "$XANMOD_KEYRING_FILE") == 644 ]] || fail 'APT keyring is not readable'
}
failure() {
    (( RC != 0 )) || fail 'failure reported success'
    lacks "$CASE_DIR/run.log" 'XanMod 内核包已安装；'
}
no_new_repository() { [[ ! -e "$XANMOD_KEYRING_FILE" && ! -e "$XANMOD_SOURCE_FILE" ]] || fail 'failed setup left new repository files'; }

case_missing() (
    setup "$1"; shift; installed "$@"; invoke; success
    has "$CASE_DIR/events" INSTALL:deps
    local dep_line key_line
    dep_line=$(grep -n 'INSTALL:deps' "$CASE_DIR/events" | head -1 | cut -d: -f1)
    key_line=$(grep -n DOWNLOAD "$CASE_DIR/events" | head -1 | cut -d: -f1)
    (( dep_line < key_line )) || fail 'key requested before dependency bootstrap'
)
case_all_installed() ( setup all-installed; installed ca-certificates curl gnupg; invoke; success; lacks "$CASE_DIR/events" INSTALL:deps; )
case_update_failure() ( setup update-failure; UPDATE_FAIL=1; invoke; failure; lacks "$CASE_DIR/events" INSTALL:; lacks "$CASE_DIR/events" DOWNLOAD; no_new_repository; has "$CASE_DIR/run.log" 'E: fixture repository unavailable'; )
case_install_failure() ( setup install-failure; INSTALL_FAIL=deps; invoke; failure; lacks "$CASE_DIR/events" DOWNLOAD; no_new_repository; has "$CASE_DIR/run.log" 'no space left'; )
case_post_install_command_check() ( setup missing-binary; MISSING_GPG_AFTER_INSTALL=1; invoke; failure; lacks "$CASE_DIR/events" DOWNLOAD; no_new_repository; has "$CASE_DIR/run.log" '缺少命令: gpg'; )
case_remove_guard() ( setup "remove-$1-$2"; REMOVE_PACKAGE="$1"; REMOVE_STAGE="$2"; invoke; failure; lacks "$CASE_DIR/events" "INSTALL:$2"; no_new_repository; has "$CASE_DIR/run.log" '关键网络组件'; )
case_simulation_failure() ( setup simulation-failure; SIM_FAIL=1; invoke; failure; lacks "$CASE_DIR/events" INSTALL:; has "$CASE_DIR/run.log" 'fixture package conflict'; no_new_repository; )
case_key_failure() (
    setup "key-$1"; case "$1" in download) CURL_FAIL=1 ;; format) BAD_FORMAT=1 ;; convert) GPG_FAIL=1 ;; converted-data) BAD_CONVERSION=1 ;; esac
    invoke; failure; no_new_repository; lacks "$CASE_DIR/events" INSTALL:kernel
)
case_repo_unavailable() ( setup repo-unavailable; UPDATE_FAIL=2; invoke; failure; no_new_repository; lacks "$CASE_DIR/events" INSTALL:kernel; )
case_lts_selection() ( setup lts-v3; invoke; success; has "$CASE_DIR/kernel-package" linux-xanmod-lts-x64v3; )
case_lts_fallback() ( setup lts-v2; AVAILABLE=linux-xanmod-lts-x64v2; invoke; success; has "$CASE_DIR/kernel-package" linux-xanmod-lts-x64v2; )
case_main_separate() ( setup main; invoke main; success; has "$CASE_DIR/kernel-package" linux-xanmod-x64v3; lacks "$CASE_DIR/kernel-package" lts; )
case_main_no_lts() ( setup main-unavailable; AVAILABLE=linux-xanmod-lts-x64v3; invoke main; failure; no_new_repository; lacks "$CASE_DIR/events" INSTALL:kernel; )
case_main_v1() ( setup main-v1; LEVEL=1; invoke main; failure; no_new_repository; lacks "$CASE_DIR/events" INSTALL:kernel; )
case_kernel_install_failure() ( setup kernel-install-failure; INSTALL_FAIL=kernel; invoke; failure; no_new_repository; has "$CASE_DIR/run.log" 'no space left'; )
case_existing_preserved() (
    setup existing; existing_repository; local before
    before=$(sha256sum "$XANMOD_KEYRING_FILE" "$XANMOD_SOURCE_FILE")
    UPDATE_FAIL=2; invoke; failure
    [[ "$before" == "$(sha256sum "$XANMOD_KEYRING_FILE" "$XANMOD_SOURCE_FILE")" ]] || fail 'pre-existing valid configuration changed'
)
case_existing_reused() ( setup reused; existing_repository; invoke; success; )
case_publish_failure() (
    setup publish-failure; mkdir -p "$CASE_DIR/etc"; printf 'existing\n' > "$CASE_DIR/etc/blocked"
    XANMOD_SOURCE_FILE="$CASE_DIR/etc/blocked/source.list"
    invoke; failure; no_new_repository
    [[ $(<"$CASE_DIR/etc/blocked") == existing ]] || fail 'unrelated parent file changed'
)
case_signal_cleanup() ( setup signal; REPO_TERM=1; invoke; failure; [[ "$RC" == 143 ]] || fail 'TERM status lost'; no_new_repository; )
case_foreign_preserved() (
    setup "foreign-$1"; existing_repository
    if [[ "$1" == source ]]; then printf 'existing alternative source\n' > "$XANMOD_SOURCE_FILE"; else printf 'existing alternative keyring\n' > "$XANMOD_KEYRING_FILE"; fi
    local before; before=$(sha256sum "$XANMOD_KEYRING_FILE" "$XANMOD_SOURCE_FILE")
    invoke; failure
    [[ "$before" == "$(sha256sum "$XANMOD_KEYRING_FILE" "$XANMOD_SOURCE_FILE")" ]] || fail 'different existing configuration was overwritten'
)
case_guard() (
    setup "guard-$1"
    case "$1" in os) os_id() { printf 'other\n'; } ;; arch) uname() { printf 'aarch64\n'; } ;; container) is_container() { return 0; } ;; secure-boot) secure_boot_enabled() { return 0; } ;; codename) os_codename() { printf 'trixie\ndeb injected\n'; } ;; apt) require_commands() { printf 'missing apt-get\n' >&2; return 1; } ;; esac
    invoke; failure; lacks "$CASE_DIR/events" UPDATE:; no_new_repository
)
case_no_reboot_network() ( setup no-reboot-network; invoke; success; has "$CASE_DIR/run.log" '维护窗口自行重启'; lacks "$CASE_DIR/events" FORBIDDEN; )
case_atomic_no_clobber() (
    setup no-clobber; mkdir -p "$CASE_DIR/publish"; printf 'new\n' > "$CASE_DIR/input"; printf 'existing\n' > "$CASE_DIR/publish/target"
    if kernel_create_repository_file "$CASE_DIR/input" "$CASE_DIR/publish/target" > "$CASE_DIR/run.log" 2>&1; then fail 'atomic create overwrote an existing file'; fi
    [[ $(<"$CASE_DIR/publish/target") == existing ]] || fail 'existing target changed'
    [[ -z $(find "$CASE_DIR/publish" -name '*.tmp.*' -print -quit) ]] || fail 'atomic failure leaked temp file'
)
case_work_cleanup_failure() (
    setup cleanup-failure
    rm() {
        if [[ "$1" == -rf && "${!#}" == "$TMPDIR/"* ]]; then printf 'rm: fixture cleanup denied\n' >&2; return 1; fi
        command rm "$@"
    }
    local rc=0
    kernel_install lts > "$CASE_DIR/run.log" 2>&1 || rc=$?
    (( rc != 0 )) || fail 'failed temporary-directory cleanup reported success'
    has "$CASE_DIR/events" INSTALL:kernel
    has "$CASE_DIR/run.log" '内核包已安装'
    has "$CASE_DIR/run.log" '临时目录清理失败'
    unset -f rm
    command rm -rf -- "$TMPDIR"
)
case_atomic_cleanup_failure() (
    setup atomic-cleanup-failure
    rm() {
        if [[ "${!#}" == *'.tmp.'* ]]; then printf 'rm: fixture atomic cleanup denied\n' >&2; return 1; fi
        command rm "$@"
    }
    local rc=0
    kernel_install lts > "$CASE_DIR/run.log" 2>&1 || rc=$?
    (( rc != 0 )) || fail 'failed atomic temporary cleanup reported success'
    has "$CASE_DIR/run.log" '原子临时文件清理失败'
    lacks "$CASE_DIR/events" INSTALL:kernel
    no_new_repository
    unset -f rm
    find "$CASE_DIR/etc" -name '*.tmp.*' -delete
)
case_legacy_order() (
    setup legacy
    installed ca-certificates curl
    # Exact ordering from v8.0.8 kernel.sh:102-105; fixture, not an old runtime copy.
    legacy_bootstrap() {
        require_commands apt-get apt-cache curl gpg || return 1
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    }
    # require_commands uses command_exists in production; gpg must really be absent here.
    require_commands() { local x; for x in "$@"; do command_exists "$x" || return 1; done; }
    if legacy_bootstrap; then fail 'legacy missing-gpg bug did not reproduce'; fi
    lacks "$CASE_DIR/events" UPDATE:; lacks "$CASE_DIR/events" INSTALL:
)

count=0
run_case() { printf '==> fixture %s\n' "$*"; "$@"; ((count+=1)); }
run_case case_legacy_order
run_case case_missing gpg-missing ca-certificates curl
run_case case_missing curl-missing ca-certificates gnupg
run_case case_missing both-missing
run_case case_all_installed
run_case case_update_failure
run_case case_install_failure
run_case case_post_install_command_check
for critical in openssh-server systemd systemd-resolved iproute2 network-manager ifupdown openssh-server:amd64; do run_case case_remove_guard "$critical" deps; done
run_case case_remove_guard openssh-server kernel
run_case case_simulation_failure
for key_case in download format convert converted-data; do run_case case_key_failure "$key_case"; done
run_case case_repo_unavailable
run_case case_lts_selection
run_case case_lts_fallback
run_case case_main_separate
run_case case_main_no_lts
run_case case_main_v1
run_case case_kernel_install_failure
run_case case_existing_preserved
run_case case_existing_reused
run_case case_publish_failure
run_case case_signal_cleanup
run_case case_foreign_preserved source
run_case case_foreign_preserved key
for guard in os arch container secure-boot codename apt; do run_case case_guard "$guard"; done
run_case case_no_reboot_network
run_case case_atomic_no_clobber
run_case case_work_cleanup_failure
run_case case_atomic_cleanup_failure
printf 'v8.0.9 XanMod bootstrap: PASS (%s deterministic fixture cases; no real kernel or reboot)\n' "$count"
