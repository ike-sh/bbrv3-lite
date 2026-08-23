# -----------------------------------------------------------------------------
# CLI and compact interactive menu.
# -----------------------------------------------------------------------------

show_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - measured BBR/HTB/FQ tuning

Usage:
  ${0##*/} auto
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
  ${0##*/} measure verify --peer HOST [--port 5201] [--duration 10]
  ${0##*/} measure compare --peer HOST --rate MBIT [--port 5201] [--duration 6] [--rounds 2]
  ${0##*/} measure sweep --peer HOST [--nominal MBIT] [--low MBIT --high MBIT]
                         [--step MBIT] [--duration 8] [--parallel 1]
                         [--margin 3] [--loss-threshold 0.1] [--cap MBIT] [--force-scan]
  ${0##*/} kernel status|install [--track lts|main]|remove
  ${0##*/} dns status|apply [auto|dot|plain]|restore
  ${0##*/} ipv6 status|disable [temporary|permanent]|restore
  ${0##*/} baseline info|adopt [--interface DEV]
  ${0##*/} verify
  ${0##*/} restore
  ${0##*/} uninstall [--purge-state]
  ${0##*/} update | version | help

Internal systemd command: apply
EOF
}

require_option_value() {
    local option="${1:-}"
    (($# >= 2)) && [[ -n "${2:-}" && "${2:-}" != --* ]] || {
        die "${option:-选项} 需要参数"
        return 1
    }
}

require_no_arguments() {
    local context="$1"; shift
    (($# == 0)) || {
        die "$context 不接受额外参数: $*"
        return 1
    }
}

parse_common_profile_options() {
    CLI_PROFILE=balanced; CLI_ROLE=mixed; CLI_BANDWIDTH=0; CLI_RTT=0; CLI_INTERFACE=auto
    while (($#)); do
        case "$1" in
            --profile) require_option_value "$@" || return 1; CLI_PROFILE="$2"; shift 2 ;;
            --role) require_option_value "$@" || return 1; CLI_ROLE="$2"; shift 2 ;;
            --bandwidth) require_option_value "$@" || return 1; CLI_BANDWIDTH="$2"; shift 2 ;;
            --rtt) require_option_value "$@" || return 1; CLI_RTT="$2"; shift 2 ;;
            --interface) require_option_value "$@" || return 1; CLI_INTERFACE="$2"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    if ! validate_config_value SYSCTL_PROFILE "$CLI_PROFILE" ||
       ! validate_config_value ROLE "$CLI_ROLE" ||
       ! validate_config_value BANDWIDTH_MBIT "$CLI_BANDWIDTH" ||
       ! validate_config_value RTT_MS "$CLI_RTT" ||
       ! validate_interface_name "$CLI_INTERFACE"; then
        die "profile/role/bandwidth/rtt/interface 参数无效"
        return 1
    fi
    if [[ "$CLI_PROFILE" == adaptive ]] && (( CLI_BANDWIDTH == 0 || CLI_RTT == 0 )); then
        die "adaptive profile 必须同时提供非零 --bandwidth 和 --rtt"
        return 1
    fi
}

cmd_detect() {
    local iface=auto target=""
    while (($#)); do
        case "$1" in
            --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
            --target) require_option_value "$@" || return 1; target="$2"; shift 2 ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    detect_profile "$iface" "$target"
}

cmd_install() { parse_common_profile_options "$@" || return 1; install_base_tuning "$CLI_INTERFACE" "$CLI_PROFILE" "$CLI_ROLE" "$CLI_BANDWIDTH" "$CLI_RTT"; }
cmd_explain() {
    parse_common_profile_options "$@" || return 1
    reset_config; SYSCTL_PROFILE="$CLI_PROFILE"; ROLE="$CLI_ROLE"; BANDWIDTH_MBIT="$CLI_BANDWIDTH"; RTT_MS="$CLI_RTT"; TC_INTERFACE="$CLI_INTERFACE"
    explain_sysctl_profile
}

cmd_tc() {
    local action="${1:-}"; shift || true
    local rate="" iface=auto knee=0 margin=3
    case "$action" in
        trial)
            rate="${1:-}"; shift || true
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "需要 1–1000000 的合法 RATE"; return 1; }
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    *) die "tc trial 不支持参数: $1"; return 1 ;;
                esac
            done
            tc_trial "$rate" "$iface"
            ;;
        enable)
            rate="${1:-}"; shift || true
            is_uint "$rate" && (( rate > 0 && rate <= 1000000 )) || { die "需要 1–1000000 的合法 RATE"; return 1; }
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    --knee) require_option_value "$@" || return 1; knee="$2"; shift 2 ;;
                    --margin) require_option_value "$@" || return 1; margin="$2"; shift 2 ;;
                    *) die "未知参数: $1"; return 1 ;;
                esac
            done
            is_uint "$knee" && (( knee <= 1000000 )) || { die "--knee 必须是 0–1000000 的整数"; return 1; }
            is_uint "$margin" && (( margin <= 25 )) || { die "--margin 必须是 0–25 的整数"; return 1; }
            (( knee == 0 || knee >= rate )) || { die "--knee 不能低于最终整形 RATE"; return 1; }
            tc_enable "$rate" "$iface" "$knee" "$margin"
            ;;
        disable|status|stats)
            while (($#)); do
                case "$1" in
                    --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
                    *) die "未知参数: $1"; return 1 ;;
                esac
            done
            case "$action" in disable) tc_disable "$iface" ;; status|stats) tc_status "$iface" ;; esac
            ;;
        *) die "tc 子命令应为 trial/enable/disable/status/stats" ;;
    esac
}

cmd_measure() {
    local action="${1:-}"; shift || true
    local peer="" port=5201 iface=auto duration=10 parallel=4 nominal=0 low=0 high=0 step=0 margin=3 threshold=0.1 force=0 cap=0
    local rate=0 rounds=2
    if [[ "$action" == deps ]]; then
        require_no_arguments "measure deps" "$@" || return 1
        install_measure_dependencies
        return
    fi
    [[ "$action" == probe || "$action" == sweep || "$action" == verify || "$action" == compare ]] || { die "measure 子命令应为 deps/probe/sweep/verify/compare"; return 1; }
    [[ "$action" == sweep ]] && { duration=8; parallel=1; }
    [[ "$action" == compare ]] && { duration=6; parallel=1; }
    while (($#)); do
        case "$1" in
            --peer) require_option_value "$@" || return 1; peer="$2"; shift 2 ;;
            --port) require_option_value "$@" || return 1; port="$2"; shift 2 ;;
            --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;;
            --duration) require_option_value "$@" || return 1; duration="$2"; shift 2 ;;
            --parallel)
                [[ "$action" != verify && "$action" != compare ]] || { die "measure $action 使用固定流数，不接受 --parallel"; return 1; }
                require_option_value "$@" || return 1; parallel="$2"; shift 2
                ;;
            --rate|--rounds)
                [[ "$action" == compare ]] || { die "measure $action 不支持参数: $1"; return 1; }
                require_option_value "$@" || return 1
                case "$1" in --rate) rate="$2" ;; --rounds) rounds="$2" ;; esac
                shift 2
                ;;
            --nominal|--low|--high|--step|--margin|--loss-threshold|--cap)
                [[ "$action" == sweep ]] || { die "measure $action 不支持参数: $1"; return 1; }
                require_option_value "$@" || return 1
                case "$1" in
                    --nominal) nominal="$2" ;; --low) low="$2" ;; --high) high="$2" ;; --step) step="$2" ;;
                    --margin) margin="$2" ;; --loss-threshold) threshold="$2" ;; --cap) cap="$2" ;;
                esac
                shift 2
                ;;
            --force-scan)
                [[ "$action" == sweep ]] || { die "measure $action 不支持参数: $1"; return 1; }
                force=1; shift
                ;;
            *) die "未知参数: $1"; return 1 ;;
        esac
    done
    [[ -n "$peer" ]] || { die "需要 --peer HOST"; return 1; }
    if [[ "$action" == compare ]]; then
        is_uint "$rate" && (( rate >= 1 && rate <= 1000000 )) || { die "measure compare 需要 --rate 1–1000000"; return 1; }
        is_uint "$rounds" && (( rounds >= 2 && rounds <= 5 )) || { die "measure compare --rounds 必须是 2–5"; return 1; }
        is_uint "$duration" && (( duration >= 3 && duration <= 30 )) || { die "measure compare --duration 必须是 3–30 秒"; return 1; }
    fi
    if [[ "$action" == probe ]]; then measure_probe "$peer" "$port" "$iface" "$duration" "$parallel"
    elif [[ "$action" == verify ]]; then measure_verify "$peer" "$port" "$iface" "$duration"
    elif [[ "$action" == compare ]]; then measure_compare "$peer" "$port" "$iface" "$rate" "$duration" "$rounds"
    else measure_sweep "$peer" "$port" "$iface" "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$threshold" "$force" "$cap"; fi
}

cmd_kernel() {
    local action="${1:-status}" track=lts; shift || true
    case "$action" in
        status) require_no_arguments "kernel status" "$@" || return 1; kernel_status ;;
        install)
            while (($#)); do
                case "$1" in --track) require_option_value "$@" || return 1; track="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac
            done
            [[ "$track" == lts || "$track" == main ]] || { die "--track 只支持 lts/main"; return 1; }
            kernel_install "$track"
            ;;
        remove) require_no_arguments "kernel remove" "$@" || return 1; kernel_remove ;;
        *) die "kernel 子命令应为 status/install/remove" ;;
    esac
}

cmd_dns() {
    local action="${1:-status}" mode; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "dns status" "$@" || return 1; dns_status ;;
        apply)
            (($# <= 1)) || { die "dns apply 最多接受一个 mode"; return 1; }
            mode="${1:-auto}"; [[ "$mode" == auto || "$mode" == dot || "$mode" == plain ]] || { die "DNS mode 只支持 auto/dot/plain"; return 1; }
            dns_apply "$mode"
            ;;
        restore) require_no_arguments "dns restore" "$@" || return 1; dns_restore ;;
        *) die "dns 子命令应为 status/apply/restore" ;;
    esac
}

cmd_ipv6() {
    local action="${1:-status}" mode; (($#)) && shift || true
    case "$action" in
        status) require_no_arguments "ipv6 status" "$@" || return 1; ipv6_status ;;
        disable)
            (($# <= 1)) || { die "ipv6 disable 最多接受一个 mode"; return 1; }
            mode="${1:-temporary}"; [[ "$mode" == temporary || "$mode" == permanent ]] || { die "IPv6 mode 只支持 temporary/permanent"; return 1; }
            ipv6_disable "$mode"
            ;;
        restore) require_no_arguments "ipv6 restore" "$@" || return 1; ipv6_restore ;;
        *) die "ipv6 子命令应为 status/disable/restore" ;;
    esac
}

cmd_baseline() {
    local action="${1:-info}" iface=auto; shift || true
    case "$action" in
        info) require_no_arguments "baseline info" "$@" || return 1; baseline_info ;;
        adopt)
            while (($#)); do case "$1" in --interface) require_option_value "$@" || return 1; iface="$2"; shift 2 ;; *) die "未知参数: $1"; return 1 ;; esac; done
            baseline_adopt "$iface"
            ;;
        *) die "baseline 子命令应为 info/adopt" ;;
    esac
}

ensure_interactive_measure_dependencies() {
    local -a missing=() command
    for command in iperf3 jq ping; do command_exists "$command" || missing+=("$command"); done
    ((${#missing[@]} == 0)) && return 0
    log WARN "自动调优需要: ${missing[*]}"
    confirm "现在安装测量依赖？" y || { die "缺少测量依赖，已取消"; return 1; }
    install_measure_dependencies || return 1
    require_commands iperf3 jq ping timeout || return 1
}

activate_public_peer_candidate() {
    local index="$1" candidate host port rtt region provider
    is_uint "$index" && (( index < ${#PUBLIC_PEER_CANDIDATES[@]} )) || return 1
    candidate="${PUBLIC_PEER_CANDIDATES[$index]}"
    IFS='|' read -r host port rtt region provider <<< "$candidate"
    validate_peer "$host" "$port" || return 1
    WIZARD_PEER="$host"; WIZARD_PORT="$port"; WIZARD_PEER_RTT="$rtt"
    WIZARD_PEER_REGION="$region"; WIZARD_PEER_PROVIDER="$provider"; WIZARD_PUBLIC_INDEX="$index"
}

interactive_select_peer() {
    local choice spec
    printf '%s\n' '测速对端：' '  1) 自动选择公共节点（Leaseweb / OVH / Clouvider）' '  2) 自有 iperf3 服务器（推荐）'
    read -r -p '选择 [1]: ' choice || return 1
    case "${choice:-1}" in
        1)
            auto_pick_peer || return 1
            WIZARD_PUBLIC_PEER=1; WIZARD_FAILOVERS=0
            activate_public_peer_candidate 0 || return 1
            return 0
            ;;
        2)
            read -r -p '对端 HOST[:PORT]（IPv6 用 [ADDR]:PORT）: ' spec || return 1
            ;;
        *) die "无效对端选择"; return 1 ;;
    esac
    parse_peer_spec "$spec" || return 1
    peer_port_open "$PEER_HOST" "$PEER_PORT" || { die "无法连接 $PEER_HOST:$PEER_PORT"; return 1; }
    WIZARD_PUBLIC_PEER=0; WIZARD_PEER="$PEER_HOST"; WIZARD_PORT="$PEER_PORT"
    WIZARD_PEER_RTT=0; WIZARD_PUBLIC_INDEX=0; WIZARD_FAILOVERS=0
}

auto_measure_with_peer_failover() {
    local iface="$1" nominal="$2" index=0 count=1 rc path_rate
    local duration="${WIZARD_SAMPLE_DURATION:-5}" cap="${WIZARD_SCAN_CAP:-5000}"
    if (( ${WIZARD_PUBLIC_PEER:-0} )); then count=${#PUBLIC_PEER_CANDIDATES[@]}; fi
    for ((index=0; index<count; index++)); do
        if (( ${WIZARD_PUBLIC_PEER:-0} )); then
            activate_public_peer_candidate "$index" || return 1
            if (( index > 0 )); then
                ((WIZARD_FAILOVERS+=1))
                log WARN "切换到备用公共对端 $((index + 1))/${count}: $WIZARD_PEER:$WIZARD_PORT（$WIZARD_PEER_REGION/$WIZARD_PEER_PROVIDER，RTT ${WIZARD_PEER_RTT}ms）"
            fi
        fi
        if (( nominal > 0 )); then
            path_rate=$((nominal * 40 / 100)); ((path_rate < 1)) && path_rate=1
            if measure_path_check "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$path_rate"; then
                :
            else
                rc=$?
                if (( ${WIZARD_PUBLIC_PEER:-0} && (rc == IPERF_UNAVAILABLE_RC || rc == 2) )); then
                    (( index + 1 < count )) && continue
                    break
                fi
                return "$rc"
            fi
        fi
        if measure_sweep "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$nominal" 0 0 0 "$duration" 1 3 0.1 0 "$cap" auto; then
            WIZARD_SWEEP_PEER="$WIZARD_PEER"
            WIZARD_SWEEP_PORT="$WIZARD_PORT"
            return 0
        else
            rc=$?
        fi
        if (( ${WIZARD_PUBLIC_PEER:-0} && (rc == IPERF_UNAVAILABLE_RC || rc == 2) )); then
            (( index + 1 < count )) && continue
            break
        fi
        return "$rc"
    done
    die "所有已预检的公共 iperf3 对端都不可用或不适合当前路径；请稍后重试或使用自有服务器"
    return 1
}

auto_verify_with_peer_failover() {
    local iface="$1" duration="$2" expected_rate="$3" min_efficiency="$4" baseline_loss="$5"
    local sweep_peer="${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" current_index="${WIZARD_PUBLIC_INDEX:-0}"
    local candidate host index rc
    if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1; then
        return 0
    else
        rc=$?
    fi
    (( ${WIZARD_PUBLIC_PEER:-0} && rc == IPERF_UNAVAILABLE_RC )) || return "$rc"

    # The acceptance thresholds come from the sweep path. A different host may
    # have a different bottleneck, so final verification may only change ports
    # on the same host. Cross-host failover must restart the complete sweep.
    for ((index=0; index<${#PUBLIC_PEER_CANDIDATES[@]}; index++)); do
        (( index != current_index )) || continue
        candidate="${PUBLIC_PEER_CANDIDATES[$index]}"
        host="${candidate%%|*}"
        [[ "$host" == "$sweep_peer" ]] || continue
        activate_public_peer_candidate "$index" || return 1
        ((WIZARD_FAILOVERS+=1))
        log WARN "最终复验切换到同主机备用端口: $WIZARD_PEER:$WIZARD_PORT"
        if measure_verify "$WIZARD_PEER" "$WIZARD_PORT" "$iface" "$duration" "$expected_rate" "$min_efficiency" "$baseline_loss" 0.1; then
            return 0
        else
            rc=$?
        fi
        (( rc == IPERF_UNAVAILABLE_RC )) || return "$rc"
    done
    die "扫描主机 $sweep_peer 的可用端口在最终复验阶段全部不可用；为保持同路径基线，不会切换到其他主机"
    return "$IPERF_UNAVAILABLE_RC"
}

auto_tune_execute() {
    local iface="$1" profile="$2" role="$3" nominal="$4" tuning_rtt="$5" peer_rtt="${6:-0}"
    local summary recommend knee measured no_knee confirmed reject_reason min_efficiency baseline_loss expected_rate=0
    local role_floor rtt_source verify_summary verify_confidence_score verify_confidence_grade verify_confidence_reasons
    prepare_auto_tuning_runtime "$iface" auto "$profile" "$role" "$nominal" "$tuning_rtt" || return 1
    if [[ -z "${WIZARD_PEER:-}" ]]; then
        verify_runtime_tuning "$iface" || return 1
        persist_current_tuning || return 1
        printf '\n'
        log OK "BBR + FQ 基础调优和持久化提交完成（未运行测速）"
        show_status
        return 0
    fi
    auto_measure_with_peer_failover "$iface" "$nominal" || return 1
    if (( ${WIZARD_PUBLIC_PEER:-0} )); then
        peer_rtt="${WIZARD_PEER_RTT:-0}"
        tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    fi
    summary="$MEASURE_RUN_DIR/summary.tsv"
    recommend=$(summary_value "$summary" RECOMMEND)
    knee=$(summary_value "$summary" BROKE_AT); knee="${knee:-0}"
    measured=$(summary_value "$summary" UNSHAPED_MBIT)
    no_knee=$(summary_value "$summary" NO_KNEE)
    confirmed=$(summary_value "$summary" CONFIRMED)
    reject_reason=$(summary_value "$summary" REJECT_REASON)
    min_efficiency=$(summary_value "$summary" MIN_EFFICIENCY_RATIO); min_efficiency="${min_efficiency:-0.90}"
    baseline_loss=$(summary_value "$summary" CLEAN_BASE_RETRANS_RATIO_EST_PERCENT); baseline_loss="${baseline_loss:-0}"
    role_floor=$(role_tuning_rtt_floor "$role") || return 1
    if (( peer_rtt > role_floor )); then rtt_source="observed-peer"; else rtt_source="role-floor"; fi
    printf 'SWEEP_PEER\t%s\nSWEEP_PORT\t%s\nPEER_RTT_MS\t%s\nTUNING_RTT_MS\t%s\nTUNING_RTT_SOURCE\t%s\nROLE\t%s\nPUBLIC_PEER_FAILOVERS\t%s\n' \
        "${WIZARD_SWEEP_PEER:-$WIZARD_PEER}" "${WIZARD_SWEEP_PORT:-$WIZARD_PORT}" "$peer_rtt" "$tuning_rtt" "$rtt_source" "$role" "${WIZARD_FAILOVERS:-0}" >> "$summary" || return 1

    if [[ -n "$reject_reason" || ( -n "$knee" && "$knee" != 0 && "$confirmed" != 1 ) ]]; then
        die "扫描候选值未通过确认测试（${reject_reason:-unconfirmed}），不会应用或持久化"
        return 2
    fi
    if [[ -n "$measured" && "$tuning_rtt" -gt 0 ]]; then
        SYSCTL_PROFILE=adaptive; BANDWIDTH_MBIT=$(awk -v g="$measured" 'BEGIN {printf "%d", g+0.5}'); RTT_MS="$tuning_rtt"; ROLE="$role"
        apply_sysctl_profile runtime || return 1
    fi
    if [[ -n "$recommend" ]]; then
        TC_ENABLED=1; TC_INTERFACE=auto; TC_RATE_MBIT="$recommend"; TC_KNEE_MBIT="$knee"; TC_MARGIN_PERCENT=3
        apply_shaping "$iface" "$recommend" || return 1
        expected_rate="$recommend"
    else
        TC_ENABLED=0; TC_INTERFACE=auto; TC_RATE_MBIT=0; TC_KNEE_MBIT=0; TC_MARGIN_PERCENT=3
        apply_fq "$iface" || return 1
        log INFO "扫描未发现可信拐点（NO_KNEE=${no_knee:-1}），保持 BBR + FQ，不启用 HTB"
    fi
    verify_runtime_tuning "$iface" || return 1
    auto_verify_with_peer_failover "$iface" 6 "$expected_rate" "$min_efficiency" "$baseline_loss" || return 1
    verify_summary="$MEASURE_RUN_DIR/summary.tsv"
    verify_confidence_score=$(summary_value "$verify_summary" CONFIDENCE_SCORE); verify_confidence_score="${verify_confidence_score:-0}"
    verify_confidence_grade=$(summary_value "$verify_summary" CONFIDENCE_GRADE); verify_confidence_grade="${verify_confidence_grade:-unknown}"
    verify_confidence_reasons=$(summary_value "$verify_summary" CONFIDENCE_REASONS); verify_confidence_reasons="${verify_confidence_reasons:-unavailable}"
    if (( ${WIZARD_FAILOVERS:-0} > 0 )) && is_uint "$verify_confidence_score"; then
        verify_confidence_score=$((verify_confidence_score - 10)); (( verify_confidence_score < 0 )) && verify_confidence_score=0
        if (( verify_confidence_score >= 90 )); then verify_confidence_grade=high
        elif (( verify_confidence_score >= 65 )); then verify_confidence_grade=medium
        else verify_confidence_grade=low
        fi
        if [[ "$verify_confidence_reasons" == clean ]]; then verify_confidence_reasons="peer-failover"
        else verify_confidence_reasons="${verify_confidence_reasons},peer-failover"
        fi
    fi
    printf 'FINAL_VERIFY_PEER\t%s\nFINAL_VERIFY_PORT\t%s\nTOTAL_PUBLIC_PEER_FAILOVERS\t%s\nFINAL_VERIFY_CONFIDENCE_SCORE\t%s\nFINAL_VERIFY_CONFIDENCE_GRADE\t%s\nFINAL_VERIFY_CONFIDENCE_REASONS\t%s\n' \
        "$WIZARD_PEER" "$WIZARD_PORT" "${WIZARD_FAILOVERS:-0}" "$verify_confidence_score" "$verify_confidence_grade" "$verify_confidence_reasons" >> "$summary" || return 1
    persist_current_tuning || return 1
    printf '\n'
    log OK "自动调优、复验和持久化提交完成"
    log INFO "最终复验置信度: ${verify_confidence_grade} (${verify_confidence_score}/100, ${verify_confidence_reasons})"
    show_status
    log INFO "扫描记录: $summary"
}

auto_tune_wizard() {
    require_root || return 1
    require_host_network_control || return 1
    require_systemd_runtime || return 1
    [[ -t 0 ]] || { die "auto 向导需要交互终端"; return 1; }
    local bandwidth_input nominal=0 role_choice role=mixed peer_rtt=0 tuning_rtt=0 profile=balanced estimate="动态估算" iface rc rollback_rc=0
    WIZARD_PEER=""; WIZARD_PORT=5201; WIZARD_PUBLIC_PEER=0; WIZARD_PUBLIC_INDEX=0; WIZARD_PEER_RTT=0; WIZARD_FAILOVERS=0
    WIZARD_SWEEP_PEER=""; WIZARD_SWEEP_PORT=0; WIZARD_SCAN_CAP=5000; WIZARD_SAMPLE_DURATION=5
    printf '\n%s v%s 自动调优\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '首次修改前会保存不可覆盖的基线：%s\n' "$BASELINE_DIR"
    printf '包含本工具涉及的 sysctl、配置/服务、qdisc/class，以及 IPv4/IPv6 路由快照。\n\n'
    ensure_interactive_measure_dependencies || return 1

    read -r -p '标称带宽 Mbit/s（a=自动测量，0=仅安装 BBR+FQ）[a]: ' bandwidth_input || return 1
    bandwidth_input="${bandwidth_input:-a}"
    if [[ "$bandwidth_input" != a && "$bandwidth_input" != auto ]]; then
        is_uint "$bandwidth_input" && (( bandwidth_input <= 1000000 )) || { die "带宽必须是非负整数或 a"; return 1; }
        nominal="$bandwidth_input"
    fi

    if [[ "$nominal" != 0 || "$bandwidth_input" == a || "$bandwidth_input" == auto ]]; then
        interactive_select_peer || return 1
        peer_rtt="${WIZARD_PEER_RTT:-0}"
        if (( peer_rtt == 0 )); then peer_rtt=$(median_ping_ms "$WIZARD_PEER"); [[ -n "$peer_rtt" ]] || peer_rtt=0; fi
    fi

    printf '%s\n' '用途：1) 混合业务  2) 代理/转发  3) 大文件吞吐'
    read -r -p '选择 [1]: ' role_choice || return 1
    case "${role_choice:-1}" in 1) role=mixed ;; 2) role=proxy ;; 3) role=bulk ;; *) die "无效用途"; return 1 ;; esac
    tuning_rtt=$(recommended_tuning_rtt "$role" "$peer_rtt") || return 1
    iface=$(detect_interface auto) || return 1
    WIZARD_SCAN_CAP=$(recommended_scan_cap "$iface" "$nominal") || return 1
    WIZARD_SAMPLE_DURATION=$(recommended_measure_duration "$iface" "$nominal") || return 1
    if (( nominal > 0 && tuning_rtt > 0 )); then
        profile=adaptive
        estimate="约 $(human_bytes "$(estimate_sweep_bytes "$((nominal * 13 / 10))" "$WIZARD_SAMPLE_DURATION" 20)") 上行"
    elif [[ -n "${WIZARD_PEER:-}" ]]; then
        estimate="将按实测带宽动态计算，扫描上限 ${WIZARD_SCAN_CAP} Mbit/s"
    else
        estimate="不运行测速"
    fi

    printf '\n执行摘要\n'
    hardware_profile_values "$iface" "$nominal" || return 1
    printf '  网卡/用途       %s / %s\n' "$iface" "$role"
    printf '  硬件模型        %s / %s CPU / %s MiB / RX:TX %s:%s\n' "$HARDWARE_CLASS" "$HARDWARE_CPU_COUNT" "$HARDWARE_MEMORY_MB" "$HARDWARE_RX_QUEUES" "$HARDWARE_TX_QUEUES"
    printf '  链路/采样       %s Mbit（%s）/ %ss\n' "$HARDWARE_LINK_MBIT" "$HARDWARE_LINK_TRUST" "$WIZARD_SAMPLE_DURATION"
    printf '  扫描策略        初始上限 %s Mbit；自动测量后可按基准扩展\n' "$WIZARD_SCAN_CAP"
    printf '  标称带宽        %s\n' "$([[ "$bandwidth_input" == a || "$bandwidth_input" == auto ]] && echo 自动测量 || echo "${nominal} Mbit/s")"
    if [[ -n "${WIZARD_PEER:-}" ]]; then
        printf '  iperf3 对端     %s:%s（测速 RTT %sms）\n' "$WIZARD_PEER" "$WIZARD_PORT" "${peer_rtt:-unknown}"
        if (( WIZARD_PUBLIC_PEER )); then printf '  公共备用对端    %s 个（正式采样不可用时自动切换）\n' "$(( ${#PUBLIC_PEER_CANDIDATES[@]} - 1 ))"; fi
        printf '  缓冲区调优 RTT  %sms（按用途下限与测速 RTT 取较大值）\n' "$tuning_rtt"
    fi
    printf '  预计时间/流量   约 3–8 分钟 / %s\n' "$estimate"
    printf '  持久化位置      %s + %s\n' "$CONFIG_FILE" "$SERVICE_FILE"
    confirm "确认开始？" || { log INFO "已取消，未修改系统"; return 0; }

    qdisc_guard "$iface" || return 1
    BANDWIDTH_MBIT="$nominal"; network_tuning_preflight "$iface" 1 || return 1
    action_transaction_begin "$iface" || return 1
    if auto_tune_execute "$iface" "$profile" "$role" "$nominal" "$tuning_rtt" "$peer_rtt"; then
        action_transaction_commit
        return
    else
        rc=$?
    fi
    log WARN "自动调优未完成，正在恢复开始前状态"
    action_transaction_rollback || rollback_rc=$?
    (( rollback_rc == 0 )) || return "$rollback_rc"
    return "$rc"
}

menu_run() {
    local rc
    set +e
    ( set -Eeuo pipefail; "$@" )
    rc=$?
    set -e
    (( rc != 90 )) || return 90
    (( rc == 0 )) || log WARN "操作失败（exit $rc）；系统不会把本次操作报告为成功"
    return 0
}

ui_clear() {
    [[ -t 1 && "${TERM:-dumb}" != dumb ]] || return 0
    printf '\033[2J\033[H'
}

ui_pause() {
    [[ -t 0 ]] || return 0
    read -r -p '按 Enter 继续...' || true
}

submenu_run() {
    ui_clear
    if ! menu_run "$@"; then return 90; fi
    ui_pause
}

invalid_menu_choice() {
    log WARN "无效选择"
    ui_pause
}

measurement_action() {
    local choice="$1" rate
    ensure_interactive_measure_dependencies || return 1
    interactive_select_peer || return 1
    case "$choice" in
        1) measure_sweep "$WIZARD_PEER" "$WIZARD_PORT" auto 0 0 0 0 5 1 3 0.1 0 0 ;;
        2) measure_probe "$WIZARD_PEER" "$WIZARD_PORT" auto 8 4 ;;
        3) measure_verify "$WIZARD_PEER" "$WIZARD_PORT" auto 8 ;;
        4)
            read -r -p 'A/B 整形速率 Mbit/s: ' rate || return 1
            measure_compare "$WIZARD_PEER" "$WIZARD_PORT" auto "$rate" 6 2
            ;;
    esac
}

measurement_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' '测量与复验' '1) 自动拐点扫描' '2) 单次带宽探测' '3) 单流/硬件自适应多流复验' '4) FQ 与整形 A/B 对照' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1|2|3|4) submenu_run measurement_action "$choice" || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

tc_menu() {
    local choice rate
    while true; do
        ui_clear
        printf '%s\n' 'TC 整形管理' '1) 状态/统计' '2) 临时试跑速率' '3) 持久启用速率' '4) 关闭整形并保留 FQ' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run tc_status auto || return 90 ;;
            2) read -r -p '速率 Mbit/s: ' rate; submenu_run tc_trial "$rate" auto || return 90 ;;
            3) read -r -p '速率 Mbit/s: ' rate; submenu_run tc_enable "$rate" auto 0 3 || return 90 ;;
            4) submenu_run tc_disable auto || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

kernel_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'XanMod 内核管理' '1) 内核/BBR 状态' '2) 安装 XanMod LTS' '3) 安装 XanMod Main' '4) 卸载非运行中的 XanMod' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run kernel_status || return 90 ;;
            2) if confirm '安装 XanMod LTS？'; then submenu_run kernel_install lts || return 90; else log INFO "已取消"; ui_pause; fi ;;
            3) if confirm '安装 XanMod Main？'; then submenu_run kernel_install main || return 90; else log INFO "已取消"; ui_pause; fi ;;
            4) submenu_run kernel_remove || return 90 ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

dns_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'DNS 管理' '1) 状态' '2) 自动选择 DoT/普通 DNS' '3) 强制 DoT' '4) 普通 DNS' '5) 恢复 DNS 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run dns_status || return 90 ;; 2) submenu_run dns_apply auto || return 90 ;;
            3) submenu_run dns_apply dot || return 90 ;; 4) submenu_run dns_apply plain || return 90 ;;
            5) if confirm '恢复 DNS 基线？'; then submenu_run dns_restore || return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

ipv6_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' 'IPv6 管理' '1) 状态' '2) 临时禁用' '3) 永久禁用' '4) 恢复 IPv6 基线' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run ipv6_status || return 90 ;; 2) submenu_run ipv6_disable temporary || return 90 ;;
            3) submenu_run ipv6_disable permanent || return 90 ;;
            4) if confirm '恢复 IPv6 基线？'; then submenu_run ipv6_restore || return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

maintenance_menu() {
    local choice
    while true; do
        ui_clear
        printf '%s\n' '恢复 / 更新 / 卸载' '1) 查看基线' '2) 只恢复首次可信基线' '3) 检查更新' \
            '4) 完整卸载（恢复配置、删除 bbr，保留备份）' '5) 完整卸载并永久删除全部状态' '0) 返回主菜单'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run baseline_info || return 90 ;;
            2) if confirm '恢复首次可信基线？'; then submenu_run restore_baseline || return 90; else log INFO "已取消"; ui_pause; fi ;;
            3) submenu_run self_update || return 90 ;;
            4) if confirm '恢复可恢复配置并删除 bbr 命令？'; then ui_clear; uninstall_managed 0 && return 90; else log INFO "已取消"; ui_pause; fi ;;
            5) if confirm '先恢复可恢复配置，再永久删除 bbr 命令、基线和历史？'; then ui_clear; uninstall_managed 1 && return 90; else log INFO "已取消"; ui_pause; fi ;;
            0) return 0 ;; *) invalid_menu_choice ;;
        esac
    done
}

status_and_verify_action() { show_status; verify_system_state; }

interactive_menu() {
    local choice
    while true; do
        ui_clear
        printf '\n%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf '%s\n' '1) 自动调优（推荐）' '2) 安装/刷新 BBR + FQ' '3) 测量与复验' '4) TC 整形管理' \
            '5) 完整状态与一致性验证' '6) XanMod 内核管理' '7) DNS 管理' '8) IPv6 管理' '9) 恢复/更新/卸载' '0) 退出'
        read -r -p '选择: ' choice || return 0
        case "$choice" in
            1) submenu_run auto_tune_wizard ;;
            2) submenu_run cmd_install ;;
            3) if ! menu_run measurement_menu; then return 0; fi ;;
            4) if ! menu_run tc_menu; then return 0; fi ;;
            5) submenu_run status_and_verify_action ;;
            6) if ! menu_run kernel_menu; then return 0; fi ;;
            7) if ! menu_run dns_menu; then return 0; fi ;;
            8) if ! menu_run ipv6_menu; then return 0; fi ;;
            9) if ! menu_run maintenance_menu; then return 0; fi ;;
            0) return 0 ;;
            *) invalid_menu_choice ;;
        esac
    done
}

main() {
    trap cleanup_core EXIT
    local command="${1:-}"; [[ -n "$command" ]] && shift || true
    if [[ -z "$command" ]]; then
        if [[ -t 0 ]]; then interactive_menu; else show_help; fi
        return
    fi
    case "$command" in
        auto) require_no_arguments "auto" "$@" || return 1; auto_tune_wizard ;;
        detect) cmd_detect "$@" ;;
        install) cmd_install "$@" ;;
        explain) cmd_explain "$@" ;;
        status) require_no_arguments "status" "$@" || return 1; show_status ;;
        tc) cmd_tc "$@" ;;
        measure) cmd_measure "$@" ;;
        kernel) cmd_kernel "$@" ;;
        dns) cmd_dns "$@" ;;
        ipv6) cmd_ipv6 "$@" ;;
        baseline) cmd_baseline "$@" ;;
        verify) require_no_arguments "verify" "$@" || return 1; verify_system_state ;;
        restore) require_no_arguments "restore" "$@" || return 1; restore_baseline ;;
        uninstall)
            case "$#:${1:-}" in 0:) uninstall_managed 0 ;; 1:--purge-state) uninstall_managed 1 ;; *) die "uninstall 只接受一个可选参数 --purge-state" ;; esac
            ;;
        apply) require_no_arguments "apply" "$@" || return 1; apply_configured_state ;;
        update) require_no_arguments "update" "$@" || return 1; self_update ;;
        version|--version|-V) require_no_arguments "version" "$@" || return 1; printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
        help|--help|-h) require_no_arguments "help" "$@" || return 1; show_help ;;
        *) die "未知命令: $command（运行 help 查看用法）" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
