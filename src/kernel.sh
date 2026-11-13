# -----------------------------------------------------------------------------
# XanMod kernel lifecycle: official repository, conservative CPU level choice.
# -----------------------------------------------------------------------------

XANMOD_KEYRING_FILE="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_SOURCE_FILE="/etc/apt/sources.list.d/xanmod-release.list"

secure_boot_enabled() {
    command_exists mokutil || return 1
    # Do not use grep -q in a pipe while pipefail is active: an early match can
    # close the pipe, give mokutil SIGPIPE, and turn a true result into false.
    mokutil --sb-state 2>/dev/null | grep -i 'SecureBoot enabled' >/dev/null
}

cpu_flags_line() {
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true
}

cpu_has_any_flag() {
    local flags="$1" flag; shift
    for flag in "$@"; do grep -qw "$flag" <<< "$flags" && return 0; done
    return 1
}

detect_x86_level() {
    local flags
    [[ "$(uname -m)" == x86_64 ]] || { printf 'unknown\n'; return 1; }
    flags=$(cpu_flags_line)
    # x86-64-v3 additionally requires F16C and LZCNT. Linux commonly exposes
    # BMI1 as bmi/bmi1, LZCNT as abm/lzcnt, and SSE3 as pni. AVX is hidden by
    # Linux when the OS has not enabled the XSAVE state, so avx+xsave is the
    # practical /proc/cpuinfo proxy for the psABI OSXSAVE requirement.
    if all_cpu_flags "$flags" avx avx2 bmi2 f16c fma movbe xsave &&
        cpu_has_any_flag "$flags" bmi bmi1 && cpu_has_any_flag "$flags" abm lzcnt; then
        printf '3\n'
    elif all_cpu_flags "$flags" cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 &&
        cpu_has_any_flag "$flags" pni sse3; then
        printf '2\n'
    else printf '1\n'; fi
}

all_cpu_flags() {
    local flags="$1" flag; shift
    for flag in "$@"; do grep -qw "$flag" <<< "$flags" || return 1; done
}

xanmod_candidates() {
    local level="$1" track="$2"
    if [[ "$track" == lts ]]; then
        case "$level" in
            3) printf '%s\n' linux-xanmod-lts-x64v3 linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1 ;;
            2) printf '%s\n' linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1 ;;
            *) printf '%s\n' linux-xanmod-lts-x64v1 ;;
        esac
    else
        # XanMod Main currently has x64v2/x64v3 packages only. Never satisfy a
        # Main request with an LTS package: that silently changes the lifecycle
        # track the operator explicitly selected.
        case "$level" in
            3) printf '%s\n' linux-xanmod-x64v3 linux-xanmod-x64v2 ;;
            2) printf '%s\n' linux-xanmod-x64v2 ;;
            *) return 0 ;;
        esac
    fi
}

select_xanmod_package() {
    local level="$1" track="$2" candidate
    while IFS= read -r candidate; do
        apt-cache show "$candidate" >/dev/null 2>&1 && { printf '%s\n' "$candidate"; return 0; }
    done < <(xanmod_candidates "$level" "$track")
    die "XanMod 仓库中没有适合 x86-64-v${level} / ${track} 的包"
}

apt_network_guard() {
    local simulation rc=0
    simulation=$(LC_ALL=C apt-get -s install "$@" 2>&1) || rc=$?
    if grep -E '^Remv (ifupdown|network-manager|systemd|systemd-resolved|iproute2|openssh-server)(:[^[:space:]]+)?([[:space:]]|$)' <<< "$simulation" >&2; then
        die "APT 模拟显示会移除关键网络组件，已中止"
        return 1
    fi
    if (( rc != 0 )); then
        printf '%s\n' "$simulation" >&2
        die "APT 安装模拟失败（exit $rc）；不会继续安装"
        return "$rc"
    fi
}

kernel_bootstrap_dependencies() {
    local package status
    local -a missing=()
    # curl/gpg are outputs of bootstrap, never its prerequisites. An index
    # failure (including a partially unavailable source) must stop this stage.
    apt-get -o APT::Update::Error-Mode=any update -qq || { die "APT 索引更新失败；尚未安装 XanMod 依赖"; return 1; }
    for package in ca-certificates curl gnupg; do
        status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
        if [[ "$status" != 'install ok installed' ]] ||
           { [[ "$package" == curl ]] && ! command_exists curl; } ||
           { [[ "$package" == gnupg ]] && ! command_exists gpg; }; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]})); then
        apt_network_guard "${missing[@]}" || return $?
        DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y "${missing[@]}" || {
            die "XanMod 依赖安装失败；不会下载公钥或安装内核"
            return 1
        }
    fi
    require_commands curl gpg || return 1
    log OK "XanMod bootstrap 依赖可用（不代表内核已安装）"
}

kernel_validate_public_key() {
    local file="$1" home="$2" listing
    listing=$(gpg --no-options --homedir "$home" --batch --with-colons --show-keys "$file") || {
        die "XanMod 公钥格式验证失败"
        return 1
    }
    awk -F: '$1=="pub" {pub=1} $1=="sec" || $1=="ssb" {secret=1} END {exit !(pub && !secret)}' <<< "$listing" || {
        die "XanMod 下载内容不是有效公钥"
        return 1
    }
}

kernel_create_repository_file() (
    local source="$1" target="$2" temp="" rc
    # A same-directory hard link publishes a complete file atomically and
    # cannot overwrite a configuration created concurrently by another actor.
    trap 'rc=$?; if [[ -n "$temp" ]] && ! rm -f -- "$temp"; then log ERR "XanMod 原子临时文件清理失败: $temp"; (( rc != 0 )) || rc=1; fi; exit "$rc"' EXIT
    [[ -d "$(dirname "$target")" ]] || install -d -m 0755 "$(dirname "$target")" || return 1
    temp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    install -m 0644 "$source" "$temp" || return 1
    ln -T -- "$temp" "$target" || { die "拒绝覆盖已有 XanMod 配置: $target"; return 1; }
    stat -c '%d:%i' "$target"
)

kernel_install_cleanup() {
    local rc="$1" work="$2" created_keyring="$3" created_source="$4"
    # No old configuration is copied. Existing files are never overwritten;
    # on failure remove only files this invocation created and still owns.
    if (( rc != 0 )); then
        if [[ -n "$created_source" && ! -L "$XANMOD_SOURCE_FILE" ]] &&
           [[ "$(stat -c '%d:%i' "$XANMOD_SOURCE_FILE" 2>/dev/null)" == "$created_source" ]] && cmp -s "$work/source.list" "$XANMOD_SOURCE_FILE"; then
            rm -f -- "$XANMOD_SOURCE_FILE" || log WARN "无法清理本次新增的 XanMod source: $XANMOD_SOURCE_FILE"
        fi
        if [[ -n "$created_keyring" && ! -L "$XANMOD_KEYRING_FILE" ]] &&
           [[ "$(stat -c '%d:%i' "$XANMOD_KEYRING_FILE" 2>/dev/null)" == "$created_keyring" ]] && cmp -s "$work/keyring.gpg" "$XANMOD_KEYRING_FILE"; then
            rm -f -- "$XANMOD_KEYRING_FILE" || log WARN "无法清理本次新增的 XanMod keyring: $XANMOD_KEYRING_FILE"
        fi
    fi
    if ! rm -rf -- "$work"; then
        log ERR "XanMod 临时目录清理失败: $work"
        (( rc != 0 )) || rc=1
    fi
    exit "$rc"
}

kernel_install_repository() (
    local track="$1" codename="$2" level package work created_keyring="" created_source="" file
    work=$(mktemp -d) || return 1
    # This subshell scopes cleanup to this operation, preserving the caller's
    # product EXIT/rollback trap and configuration lock.
    trap 'kernel_install_cleanup "$?" "$work" "$created_keyring" "$created_source"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -m 0700 "$work/gnupg" || return 1
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 \
        https://dl.xanmod.org/archive.key -o "$work/archive.key" || { die "XanMod 官方公钥下载失败"; return 1; }
    kernel_validate_public_key "$work/archive.key" "$work/gnupg" || return 1
    gpg --no-options --homedir "$work/gnupg" --batch --dearmor --yes -o "$work/keyring.gpg" "$work/archive.key" || {
        die "XanMod GPG 转换失败；不会写入 keyring"
        return 1
    }
    kernel_validate_public_key "$work/keyring.gpg" "$work/gnupg" || return 1
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$XANMOD_KEYRING_FILE" "$codename" > "$work/source.list" || return 1
    # Check both destinations before publishing either file. Different existing
    # configuration requires review, not a backup or an automatic replacement.
    for file in "$XANMOD_KEYRING_FILE" "$XANMOD_SOURCE_FILE"; do
        if [[ -e "$file" || -L "$file" ]]; then
            [[ -f "$file" && ! -L "$file" ]] || { die "XanMod 配置路径类型不安全: $file"; return 1; }
            if [[ "$file" == "$XANMOD_KEYRING_FILE" ]]; then
                cmp -s "$work/keyring.gpg" "$file" || { die "已有 XanMod keyring 不同；保留原文件，请人工审查"; return 1; }
            else
                cmp -s "$work/source.list" "$file" || { die "已有 XanMod source 不同；保留原文件，请人工审查"; return 1; }
            fi
        fi
    done
    if [[ ! -e "$XANMOD_KEYRING_FILE" ]]; then
        created_keyring=$(kernel_create_repository_file "$work/keyring.gpg" "$XANMOD_KEYRING_FILE") || return 1
    fi
    if [[ ! -e "$XANMOD_SOURCE_FILE" ]]; then
        created_source=$(kernel_create_repository_file "$work/source.list" "$XANMOD_SOURCE_FILE") || return 1
    fi
    # signed-by confines trust to this key; normal APT signature/hash checks
    # authenticate repository metadata and packages. No invented fingerprint pin.
    apt-get -o APT::Update::Error-Mode=any update || { die "XanMod 仓库更新或签名验证失败"; return 1; }
    level=$(detect_x86_level) || return 1
    package=$(select_xanmod_package "$level" "$track") || return 1
    apt_network_guard "$package" || return $?
    log INFO "系统=$codename CPU=x86-64-v$level 选择包=$package"
    DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y "$package" || { die "XanMod 内核包安装失败"; return 1; }
    if command_exists update-grub; then update-grub || { die "内核包已安装，但 GRUB 更新失败；请检查启动配置"; return 1; }; fi
    log OK "XanMod 内核包已安装；当前运行内核未切换、未删除。请在维护窗口自行重启，再执行 kernel status 验证"
)

kernel_status() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    printf '%-18s %s\n' "Running kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "x86-64 level" "$(detect_x86_level 2>/dev/null || echo n/a)"
    printf '%-18s %s\n' "Secure Boot" "$(secure_boot_enabled && echo enabled || echo disabled/unknown)"
    printf '%-18s %s\n' "BBR support" "$(bbr_kernel_support_status)"
    printf '%-18s %s\n' "BBR compatibility" "$(bbr_compatibility_status "$cc")"
    printf '%-18s %s\n' "BBR generation" "$(bbr_generation_status "$cc")"
    dpkg-query -W -f='${Package}\t${Version}\n' 'linux-*xanmod*' 2>/dev/null || true
}

kernel_install() {
    require_root || return 1; acquire_lock || return 1
    local track="${1:-lts}" codename
    [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
    [[ "$(os_id)" == debian || "$(os_id)" == ubuntu ]] || { die "XanMod 自动安装只支持 Debian/Ubuntu"; return 1; }
    [[ "$(uname -m)" == x86_64 ]] || { die "XanMod 官方 APT 仅支持 amd64；ARM64 请使用发行版内核或审计后的社区构建"; return 1; }
    is_container && { die "容器中不能更换宿主机内核"; return 1; }
    secure_boot_enabled && { die "检测到 Secure Boot 已启用；请先准备签名/MOK 或关闭后再安装"; return 1; }
    require_commands apt-get apt-cache dpkg-query || return 1
    codename=$(os_codename)
    [[ "$codename" =~ ^[a-z][a-z0-9]*$ ]] || { die "无法读取合法 VERSION_CODENAME"; return 1; }
    kernel_bootstrap_dependencies || return $?
    kernel_install_repository "$track" "$codename"
}

kernel_remove() {
    require_root || return 1; acquire_lock || return 1
    local -a packages=() safe=() package
    mapfile -t packages < <(dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | sort -u)
    ((${#packages[@]})) || { log INFO "没有已安装的 XanMod 包"; return 0; }
    for package in "${packages[@]}"; do
        if [[ "$(uname -r)" == *xanmod* ]] && dpkg-query -L "$package" 2>/dev/null | grep -F "/boot/vmlinuz-$(uname -r)" >/dev/null; then
            log WARN "跳过当前正在运行的内核包: $package"
        else safe+=("$package"); fi
    done
    ((${#safe[@]})) || { die "没有可安全卸载的非运行中 XanMod 包"; return 1; }
    confirm "将卸载: ${safe[*]}，继续？" || { log INFO "已取消"; return 0; }
    apt-get remove -y "${safe[@]}"
    command_exists update-grub && update-grub
}
