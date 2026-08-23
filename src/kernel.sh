# -----------------------------------------------------------------------------
# XanMod kernel lifecycle: official repository, conservative CPU level choice.
# -----------------------------------------------------------------------------

secure_boot_enabled() {
    command_exists mokutil || return 1
    mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
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
    local package="$1" simulation
    simulation=$(apt-get -s install "$package" 2>/dev/null) || return 1
    if grep -E '^Remv (ifupdown|network-manager|systemd|systemd-resolved|iproute2|openssh-server)( |$)' <<< "$simulation"; then
        die "APT 模拟显示会移除关键网络组件，已中止"
        return 1
    fi
}

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
    local track="${1:-lts}" codename level package key_tmp keyring_tmp source_tmp
    [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
    [[ "$(os_id)" == debian || "$(os_id)" == ubuntu ]] || { die "XanMod 自动安装只支持 Debian/Ubuntu"; return 1; }
    [[ "$(uname -m)" == x86_64 ]] || { die "XanMod 官方 APT 仅支持 amd64；ARM64 请使用发行版内核或审计后的社区构建"; return 1; }
    is_container && { die "容器中不能更换宿主机内核"; return 1; }
    secure_boot_enabled && { die "检测到 Secure Boot 已启用；请先准备签名/MOK 或关闭后再安装"; return 1; }
    require_commands apt-get apt-cache curl gpg || return 1
    codename=$(os_codename); [[ -n "$codename" ]] || { die "无法读取 VERSION_CODENAME"; return 1; }
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    install -d -m 0755 /etc/apt/keyrings
    key_tmp=$(mktemp) || return 1
    curl -fsSL --connect-timeout 15 --max-time 60 https://dl.xanmod.org/archive.key -o "$key_tmp"
    gpg --show-keys "$key_tmp" >/dev/null 2>&1 || { rm -f "$key_tmp"; die "XanMod 公钥格式验证失败"; return 1; }
    keyring_tmp=$(mktemp) || { rm -f "$key_tmp"; return 1; }
    gpg --dearmor --yes -o "$keyring_tmp" "$key_tmp"
    rm -f "$key_tmp"
    atomic_install "$keyring_tmp" /etc/apt/keyrings/xanmod-archive-keyring.gpg 0644 || { rm -f "$keyring_tmp"; return 1; }
    rm -f "$keyring_tmp"
    source_tmp=$(mktemp) || return 1
    printf 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org %s main\n' "$codename" > "$source_tmp"
    atomic_install "$source_tmp" /etc/apt/sources.list.d/xanmod-release.list 0644 || { rm -f "$source_tmp"; return 1; }
    rm -f "$source_tmp"
    apt-get update
    level=$(detect_x86_level); package=$(select_xanmod_package "$level" "$track") || return 1
    apt_network_guard "$package" || return 1
    log INFO "系统=$codename CPU=x86-64-v$level 选择包=$package"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    command_exists update-grub && update-grub
    log OK "XanMod 已安装；当前内核未被删除。请自行安排重启后执行 status 验证"
}

kernel_remove() {
    require_root || return 1; acquire_lock || return 1
    local -a packages=() safe=() package
    mapfile -t packages < <(dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | sort -u)
    ((${#packages[@]})) || { log INFO "没有已安装的 XanMod 包"; return 0; }
    for package in "${packages[@]}"; do
        if [[ "$(uname -r)" == *xanmod* ]] && dpkg-query -L "$package" 2>/dev/null | grep -Fq "/boot/vmlinuz-$(uname -r)"; then
            log WARN "跳过当前正在运行的内核包: $package"
        else safe+=("$package"); fi
    done
    ((${#safe[@]})) || { die "没有可安全卸载的非运行中 XanMod 包"; return 1; }
    confirm "将卸载: ${safe[*]}，继续？" || { log INFO "已取消"; return 0; }
    apt-get remove -y "${safe[@]}"
    command_exists update-grub && update-grub
}
