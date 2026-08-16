# -----------------------------------------------------------------------------
# Platform detection: OS, interface, machine facts and dependency installation.
# -----------------------------------------------------------------------------

os_id() { awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null; }
os_codename() {
    awk -F= '$1=="VERSION_CODENAME" {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null
}

virtualization_type() {
    if command_exists systemd-detect-virt; then systemd-detect-virt 2>/dev/null || printf 'none\n';
    elif [[ -f /.dockerenv ]]; then printf 'docker\n';
    else printf 'unknown\n'; fi
}

is_container() {
    if command_exists systemd-detect-virt && systemd-detect-virt --quiet --container 2>/dev/null; then return 0; fi
    case "$(virtualization_type)" in docker|lxc|openvz|podman|container-other|systemd-nspawn|wsl) return 0 ;; *) return 1 ;; esac
}

require_host_network_control() {
    if is_container; then
        die "容器环境不能安全修改宿主机内核、sysctl 或 qdisc；请在 VPS 宿主系统执行"
        return 1
    fi
    return 0
}

require_systemd_runtime() {
    require_commands systemctl || return 1
    [[ -d /run/systemd/system ]] || { die "当前系统没有运行 systemd，不能安装持久化服务"; return 1; }
    systemctl show-environment >/dev/null 2>&1 || { die "无法连接 systemd，不能安全提交持久化配置"; return 1; }
}

default_route_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '$1=="default" {print $5; exit}')
    [[ -n "$iface" ]] || iface=$(ip -6 route show default 2>/dev/null | awk '$1=="default" {print $5; exit}')
    printf '%s\n' "$iface"
}

interface_is_excluded() {
    case "$1" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*) return 0 ;; *) return 1 ;; esac
}

detect_interface() {
    local requested="${1:-auto}" iface
    if [[ "$requested" != auto ]]; then
        validate_interface_name "$requested" || { die "非法网卡名: $requested"; return 1; }
        [[ -e "/sys/class/net/$requested" ]] || { die "网卡不存在: $requested"; return 1; }
        printf '%s\n' "$requested"
        return 0
    fi
    iface=$(default_route_interface)
    [[ -n "$iface" ]] || { die "没有检测到 IPv4/IPv6 默认路由出口"; return 1; }
    interface_is_excluded "$iface" && { die "默认出口是受保护的虚拟接口: $iface，请显式指定 --interface"; return 1; }
    validate_interface_name "$iface" || { die "检测到非法网卡名: $iface"; return 1; }
    printf '%s\n' "$iface"
}

detect_mtu() { cat "/sys/class/net/$1/mtu" 2>/dev/null || printf '1500\n'; }
detect_link_speed() {
    local value
    value=$(cat "/sys/class/net/$1/speed" 2>/dev/null || true)
    if is_uint "${value:-}" && (( value > 0 )); then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
detect_rx_queues() { find "/sys/class/net/$1/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | wc -l | awk '{print $1}'; }
detect_driver() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null || printf 'virtual\n'; }
memory_mb() { awk '/MemTotal:/ {printf "%d\n", $2/1024}' /proc/meminfo; }

median_ping_ms() {
    local target="$1" family="${2:-auto}" output
    [[ -n "$target" && "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || return 1
    case "$family" in
        4) output=$(ping -4 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        6) output=$(ping -6 -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
        *) output=$(ping -n -c 5 -W 2 -- "$target" 2>/dev/null || true) ;;
    esac
    awk -F'/' '/rtt|round-trip/ {printf "%.0f\n", $5}' <<< "$output"
}

detect_profile() {
    local requested="${1:-auto}" target="${2:-}" iface rtt="not measured"
    require_commands ip awk uname || return 1
    iface=$(detect_interface "$requested") || return 1
    if [[ -n "$target" ]]; then
        [[ "$target" != -* && "$target" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法探测目标: $target"; return 1; }
        rtt=$(median_ping_ms "$target"); [[ -n "$rtt" ]] || rtt="unreachable"
    fi
    printf '%-18s %s\n' "Version" "v${SCRIPT_VERSION}"
    printf '%-18s %s\n' "OS" "$(os_id) $(os_codename)"
    printf '%-18s %s\n' "Kernel" "$(uname -r)"
    printf '%-18s %s\n' "Architecture" "$(uname -m)"
    printf '%-18s %s\n' "Virtualization" "$(virtualization_type)"
    printf '%-18s %s\n' "CPU cores" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo '?')"
    printf '%-18s %s MB\n' "Memory" "$(memory_mb)"
    printf '%-18s %s\n' "Interface" "$iface"
    printf '%-18s %s\n' "Driver" "$(detect_driver "$iface")"
    printf '%-18s %s\n' "MTU" "$(detect_mtu "$iface")"
    local link_speed
    link_speed=$(detect_link_speed "$iface")
    [[ "$link_speed" == unknown ]] || link_speed="${link_speed} Mbps"
    printf '%-18s %s\n' "Link speed" "$link_speed"
    printf '%-18s %s\n' "RX queues" "$(detect_rx_queues "$iface")"
    [[ "$rtt" == "not measured" || "$rtt" == unreachable ]] || rtt="${rtt} ms"
    printf '%-18s %s\n' "Target RTT" "$rtt"
    printf '%-18s %s\n' "Congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf '%-18s %s\n' "Available CC" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
}

install_measure_dependencies() {
    require_root || return 1
    local -a packages=()
    command_exists iperf3 || packages+=(iperf3)
    command_exists jq || packages+=(jq)
    command_exists ping || packages+=(iputils-ping)
    if ! command_exists ip || ! command_exists tc; then packages+=(iproute2); fi
    command_exists sysctl || packages+=(procps)
    command_exists flock || packages+=(util-linux)
    command_exists timeout || packages+=(coreutils)
    ((${#packages[@]} > 0)) || { log OK "测量依赖已经齐全"; return 0; }
    case "$(os_id)" in
        debian|ubuntu)
            log INFO "仅安装缺少的依赖包: ${packages[*]}"
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        *) die "自动安装依赖目前只支持 Debian/Ubuntu" ;;
    esac
}
