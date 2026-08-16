# -----------------------------------------------------------------------------
# CLI and compact interactive menu.
# -----------------------------------------------------------------------------

show_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - measured BBR/HTB/FQ tuning

Usage:
  ${0##*/} detect [--interface DEV] [--target HOST]
  ${0##*/} install [--profile balanced|adaptive] [--role proxy|mixed|bulk]
                     [--bandwidth MBIT --rtt MS] [--interface DEV]
  ${0##*/} explain [same profile options as install]
  ${0##*/} status
  ${0##*/} tc trial RATE [--interface DEV]
  ${0##*/} tc enable RATE [--interface DEV] [--knee RATE] [--margin PERCENT]
  ${0##*/} tc disable|status|stats [--interface DEV]
  ${0##*/} measure deps
  ${0##*/} measure probe --peer HOST [--port 5201] [--duration 10] [--parallel 4]
  ${0##*/} measure sweep --peer HOST [--nominal MBIT] [--low MBIT --high MBIT]
                         [--step MBIT] [--duration 8] [--parallel 1]
                         [--margin 3] [--loss-threshold 0.1] [--cap 5000] [--force-scan]
  ${0##*/} kernel status|install [--track lts|main]|remove
  ${0##*/} dns status|apply [auto|dot|plain]|restore
  ${0##*/} ipv6 status|disable [temporary|permanent]|restore
  ${0##*/} baseline info|adopt [--interface DEV]
  ${0##*/} restore
  ${0##*/} uninstall [--purge-state]
  ${0##*/} update | version | help

Internal systemd command: apply
EOF
}

parse_common_profile_options() {
    CLI_PROFILE=balanced; CLI_ROLE=mixed; CLI_BANDWIDTH=0; CLI_RTT=0; CLI_INTERFACE=auto
    while (($#)); do
        case "$1" in
            --profile) CLI_PROFILE="${2:?missing profile}"; shift 2 ;;
            --role) CLI_ROLE="${2:?missing role}"; shift 2 ;;
            --bandwidth) CLI_BANDWIDTH="${2:?missing bandwidth}"; shift 2 ;;
            --rtt) CLI_RTT="${2:?missing rtt}"; shift 2 ;;
            --interface) CLI_INTERFACE="${2:?missing interface}"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    validate_config_value SYSCTL_PROFILE "$CLI_PROFILE" && validate_config_value ROLE "$CLI_ROLE" &&
        validate_config_value BANDWIDTH_MBIT "$CLI_BANDWIDTH" && validate_config_value RTT_MS "$CLI_RTT" &&
        validate_interface_name "$CLI_INTERFACE"
}

cmd_detect() {
    local iface=auto target=""
    while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; --target) target="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    detect_profile "$iface" "$target"
}

cmd_install() { parse_common_profile_options "$@" || return 1; install_base_tuning "$CLI_INTERFACE" "$CLI_PROFILE" "$CLI_ROLE" "$CLI_BANDWIDTH" "$CLI_RTT"; }
cmd_explain() {
    parse_common_profile_options "$@" || return 1
    reset_config; SYSCTL_PROFILE="$CLI_PROFILE"; ROLE="$CLI_ROLE"; BANDWIDTH_MBIT="$CLI_BANDWIDTH"; RTT_MS="$CLI_RTT"
    explain_sysctl_profile
}

cmd_tc() {
    local action="${1:-}"; shift || true
    local rate="" iface=auto knee=0 margin=3
    case "$action" in
        trial|enable)
            rate="${1:-}"; shift || true
            is_uint "$rate" && ((rate>0)) || { die "需要合法 RATE"; return 1; }
            while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; --knee) knee="$2"; shift 2 ;; --margin) margin="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            if [[ "$action" == trial ]]; then tc_trial "$rate" "$iface"; else tc_enable "$rate" "$iface" "$knee" "$margin"; fi
            ;;
        disable|status|stats)
            while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            case "$action" in disable) tc_disable "$iface" ;; status|stats) tc_status "$iface" ;; esac
            ;;
        *) die "tc 子命令应为 trial/enable/disable/status/stats" ;;
    esac
}

cmd_measure() {
    local action="${1:-}"; shift || true
    local peer="" port=5201 iface=auto duration=10 parallel=4 nominal=0 low=0 high=0 step=0 margin=3 threshold=0.1 force=0 cap=5000
    [[ "$action" == deps ]] && { install_measure_dependencies; return; }
    [[ "$action" == probe || "$action" == sweep ]] || { die "measure 子命令应为 deps/probe/sweep"; return 1; }
    [[ "$action" == sweep ]] && { duration=8; parallel=1; }
    while (($#)); do
        case "$1" in
            --peer) peer="$2"; shift 2 ;; --port) port="$2"; shift 2 ;; --interface) iface="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;; --parallel) parallel="$2"; shift 2 ;; --nominal) nominal="$2"; shift 2 ;;
            --low) low="$2"; force=1; shift 2 ;; --high) high="$2"; force=1; shift 2 ;; --step) step="$2"; shift 2 ;;
            --margin) margin="$2"; shift 2 ;; --loss-threshold) threshold="$2"; shift 2 ;; --cap) cap="$2"; shift 2 ;; --force-scan) force=1; shift ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    [[ -n "$peer" ]] || { die "需要 --peer HOST"; return 1; }
    if [[ "$action" == probe ]]; then measure_probe "$peer" "$port" "$iface" "$duration" "$parallel"
    else measure_sweep "$peer" "$port" "$iface" "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$threshold" "$force" "$cap"; fi
}

cmd_kernel() {
    local action="${1:-status}" track=lts; shift || true
    while (($#)); do case "$1" in --track) track="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    case "$action" in status) kernel_status ;; install) kernel_install "$track" ;; remove) kernel_remove ;; *) die "kernel 子命令应为 status/install/remove" ;; esac
}

cmd_dns() { local action="${1:-status}" mode="${2:-auto}"; case "$action" in status) dns_status ;; apply) dns_apply "$mode" ;; restore) dns_restore ;; *) die "dns 子命令应为 status/apply/restore" ;; esac; }
cmd_ipv6() { local action="${1:-status}" mode="${2:-temporary}"; case "$action" in status) ipv6_status ;; disable) ipv6_disable "$mode" ;; restore) ipv6_restore ;; *) die "ipv6 子命令应为 status/disable/restore" ;; esac; }

cmd_baseline() {
    local action="${1:-info}" iface=auto; shift || true
    while (($#)); do case "$1" in --interface) iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
    case "$action" in info) baseline_info ;; adopt) baseline_adopt "$iface" ;; *) die "baseline 子命令应为 info/adopt" ;; esac
}

interactive_menu() {
    local choice
    while true; do
        printf '\n%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '%s\n' '1) 系统/网卡检测' '2) 安装 BBR + FQ' '3) 自动测量 policer 拐点' '4) TC 状态' \
            '5) 完整状态' '6) XanMod 内核管理' '7) DNS 管理' '8) IPv6 管理' '9) 恢复基线' '0) 退出'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) cmd_detect ;;
            2) cmd_install ;;
            3) read -r -p 'iperf3 peer: ' peer; cmd_measure sweep --peer "$peer" ;;
            4) cmd_tc status ;;
            5) show_status ;;
            6) kernel_status ;;
            7) dns_status ;;
            8) ipv6_status ;;
            9) confirm '恢复首次可信基线？' && restore_baseline ;;
            0) return 0 ;;
            *) log WARN "无效选择" ;;
        esac
    done
}

main() {
    trap cleanup_core EXIT
    local command="${1:-}"; [[ -n "$command" ]] && shift || true
    if [[ -z "$command" ]]; then [[ -t 0 ]] && interactive_menu || show_help; return; fi
    case "$command" in
        detect) cmd_detect "$@" ;;
        install) cmd_install "$@" ;;
        explain) cmd_explain "$@" ;;
        status) show_status ;;
        tc) cmd_tc "$@" ;;
        measure) cmd_measure "$@" ;;
        kernel) cmd_kernel "$@" ;;
        dns) cmd_dns "$@" ;;
        ipv6) cmd_ipv6 "$@" ;;
        baseline) cmd_baseline "$@" ;;
        restore) restore_baseline ;;
        uninstall)
            case "${1:-}" in "") uninstall_managed 0 ;; --purge-state) uninstall_managed 1 ;; *) die "uninstall 只接受 --purge-state" ;; esac
            ;;
        apply) apply_configured_state ;;
        update) self_update ;;
        version|--version|-V) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
        help|--help|-h) show_help ;;
        *) die "未知命令: $command（运行 help 查看用法）" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
