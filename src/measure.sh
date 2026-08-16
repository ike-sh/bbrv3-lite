# -----------------------------------------------------------------------------
# Measurement: iperf3 JSON probe and policer-knee sweep with automatic restore.
# -----------------------------------------------------------------------------

MEASURE_IFACE=""
MEASURE_SNAPSHOT=""
MEASURE_TX_START=0
MEASURE_RX_START=0
MEASURE_RESULT_FILE=""
MEASURE_RUN_DIR=""

# Public endpoints are opt-in and used only by the interactive auto-tune wizard.
# Providers and test traffic are disclosed before execution; a private iperf3 peer is preferred.
PUBLIC_PEER_POOL=$(cat <<'EOF'
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
lon.speedtest.clouvider.net|伦敦|Clouvider
EOF
)

parse_peer_spec() {
    local spec="$1" default_port="${2:-5201}"
    PEER_HOST=""; PEER_PORT="$default_port"
    if [[ "$spec" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^([^:]+):([0-9]+)$ ]]; then
        PEER_HOST="${BASH_REMATCH[1]}"; PEER_PORT="${BASH_REMATCH[2]}"
    else
        PEER_HOST="$spec"
    fi
    validate_peer "$PEER_HOST" "$PEER_PORT"
}

public_peer_port() {
    local host="$1" port
    for port in 5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200; do
        if peer_port_open "$host" "$port" && iperf_peer_usable "$host" "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

auto_pick_peer() {
    require_commands ping timeout iperf3 jq
    local temp host region provider rtt port line max_rtt="${BBRV3_PEER_MAX_RTT:-120}"
    temp=$(mktemp -d) || return 1
    log INFO "正在按 RTT 筛选公共 iperf3 节点（Leaseweb / OVH / Clouvider）"
    while IFS='|' read -r host region provider; do
        [[ -n "$host" ]] || continue
        (
            rtt=$(median_ping_ms "$host")
            [[ -n "$rtt" ]] && printf '%s\t%s\t%s\t%s\n' "$rtt" "$host" "$region" "$provider" > "$temp/${host//[^a-zA-Z0-9]/_}"
        ) &
    done <<< "$PUBLIC_PEER_POOL"
    wait || true
    while IFS=$'\t' read -r rtt host region provider; do
        (( rtt <= max_rtt )) || { log INFO "$host ($region/$provider) RTT ${rtt}ms，过远跳过"; continue; }
        if port=$(public_peer_port "$host"); then
            log OK "公共对端已通过 iperf3 预检: $host:$port ($region/$provider, RTT ${rtt}ms)"
            rm -rf -- "$temp"
            printf '%s:%s\n' "$host" "$port"
            return 0
        fi
        log INFO "$host ($region/$provider) 当前无可用测试端口"
    done < <(cat "$temp"/* 2>/dev/null | sort -n)
    rm -rf -- "$temp"
    die "120ms 内没有可用公共 iperf3 节点；请使用自有对端"
}

interface_counter() { cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || printf '0\n'; }

measure_begin() {
    local iface="$1"
    MEASURE_IFACE="$iface"
    MEASURE_SNAPSHOT=$(mktemp) || return 1
    action_qdisc_snapshot "$iface" "$MEASURE_SNAPSHOT" || {
        rm -f -- "$MEASURE_SNAPSHOT"
        MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
        return 1
    }
    MEASURE_TX_START=$(interface_counter "$iface" tx_bytes)
    MEASURE_RX_START=$(interface_counter "$iface" rx_bytes)
    trap 'measure_abort 130' INT TERM HUP
}

measure_restore() {
    local rc=0
    if [[ -n "$MEASURE_IFACE" && -n "$MEASURE_SNAPSHOT" && -f "$MEASURE_SNAPSHOT" ]]; then
        restore_action_qdisc "$MEASURE_IFACE" "$MEASURE_SNAPSHOT" || rc=$?
        rm -f -- "$MEASURE_SNAPSHOT"
    fi
    trap - INT TERM HUP
    MEASURE_IFACE=""; MEASURE_SNAPSHOT=""
    return "$rc"
}

measure_abort() {
    local rc="${1:-130}"
    log WARN "测试被中断，正在恢复操作前 qdisc"
    measure_restore || true
    release_lock
    exit "$rc"
}

traffic_report() {
    local tx_now rx_now tx rx
    tx_now=$(interface_counter "$1" tx_bytes); rx_now=$(interface_counter "$1" rx_bytes)
    tx=$((tx_now - MEASURE_TX_START)); rx=$((rx_now - MEASURE_RX_START))
    (( tx < 0 )) && tx=0; (( rx < 0 )) && rx=0
    log INFO "本轮接口流量: TX $(human_bytes "$tx"), RX $(human_bytes "$rx")"
}

validate_peer() {
    [[ "$1" =~ ^[a-zA-Z0-9._:-]{1,253}$ ]] || { die "非法 peer: $1"; return 1; }
    is_uint "$2" && (( $2 >= 1 && $2 <= 65535 )) || { die "非法端口: $2"; return 1; }
}

peer_port_open() {
    local peer="$1" port="$2"
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$peer" "$port" >/dev/null 2>&1
}

iperf_peer_usable() {
    local peer="$1" port="$2" json rc=0 error bps
    json=$(mktemp) || return 1
    if timeout 8 iperf3 -c "$peer" -p "$port" -t 1 -P 1 -b 1M -J > "$json" 2>/dev/null; then
        error=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
        bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json" 2>/dev/null || printf '0\n')
        [[ -z "$error" ]] && is_decimal "$bps" && awk -v b="$bps" 'BEGIN {exit !(b>0)}' || rc=1
    else
        rc=$?
    fi
    rm -f -- "$json"
    return "$rc"
}

iperf_sample() {
    local peer="$1" port="$2" duration="$3" parallel="$4" json error_file rc=0 reason="" bps bytes retrans goodput ratio
    json=$(mktemp) || return 1
    error_file=$(mktemp) || { rm -f -- "$json"; return 1; }
    if timeout "$((duration + 20))" iperf3 -c "$peer" -p "$port" -t "$duration" -P "$parallel" -J > "$json" 2> "$error_file"; then
        reason=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
        [[ -z "$reason" ]] || rc=1
    else
        rc=$?
        reason=$(jq -r '.error // empty' "$json" 2>/dev/null || true)
        [[ -n "$reason" ]] || reason=$(<"$error_file")
        [[ -n "$reason" ]] || { if (( rc == 124 )); then reason="连接或测试超时"; else reason="iperf3 退出码 $rc"; fi; }
    fi
    rm -f -- "$error_file"
    if (( rc != 0 )); then
        reason=${reason//$'\n'/ }
        reason=${reason//$'\r'/}
        reason=${reason:0:240}
        log WARN "iperf3 $peer:$port 测试失败: $reason"
        rm -f -- "$json"
        return 1
    fi
    bps=$(jq -r '.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0' "$json")
    bytes=$(jq -r '.end.sum_sent.bytes // .end.sum.bytes // 0' "$json")
    retrans=$(jq -r '.end.sum_sent.retransmits // ([.end.streams[]?.sender.retransmits // 0] | add) // 0' "$json")
    rm -f -- "$json"
    if ! is_decimal "$bps" || ! is_uint "$bytes" || ! is_uint "$retrans" || (( bytes == 0 )) || ! awk -v b="$bps" 'BEGIN {exit !(b>0)}'; then
        log WARN "iperf3 $peer:$port 返回的 JSON 结果不完整"
        return 1
    fi
    goodput=$(awk -v b="$bps" 'BEGIN {printf "%.2f", b/1000000}')
    # An estimate, not packet loss: iperf retransmits / estimated MSS-sized segments.
    ratio=$(awk -v r="$retrans" -v b="$bytes" 'BEGIN {n=b/1448; if(n<1)n=1; printf "%.5f", r*100/n}')
    printf '%s\t%s\t%s\t%s\n' "$goodput" "$retrans" "$bytes" "$ratio"
}

median_numbers() { sort -n | awk '{a[NR]=$1} END {if(NR) {if(NR%2) print a[(NR+1)/2]; else printf "%.5f\n", (a[NR/2]+a[NR/2+1])/2}}'; }

sample_repeated() {
    local peer="$1" port="$2" duration="$3" parallel="$4" count="$5" label="$6"
    local -a goodputs=() retrans=() bytes=() ratios=()
    local row i attempt attempts="${BBRV3_IPERF_ATTEMPTS:-3}"
    is_uint "$attempts" && (( attempts >= 1 && attempts <= 5 )) || attempts=3
    for ((i=1; i<=count; i++)); do
        log INFO "$label: ${duration}s × ${parallel} flow(s), sample ${i}/${count}"
        row=""
        for ((attempt=1; attempt<=attempts; attempt++)); do
            if row=$(iperf_sample "$peer" "$port" "$duration" "$parallel"); then break; fi
            (( attempt < attempts )) && { log WARN "2 秒后重试（${attempt}/${attempts}）"; sleep 2; }
        done
        [[ -n "$row" ]] || { die "iperf3 连续 ${attempts} 次失败；请稍后重试或更换对端"; return 1; }
        IFS=$'\t' read -r g r b l <<< "$row"
        goodputs+=("$g"); retrans+=("$r"); bytes+=("$b"); ratios+=("$l")
        [[ -n "$MEASURE_RESULT_FILE" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(utc_now)" "$label" "$g" "$r" "$b" "$l" >> "$MEASURE_RESULT_FILE"
        (( i < count )) && sleep 2
    done
    printf '%s\t%s\t%s\t%s\n' \
        "$(printf '%s\n' "${goodputs[@]}" | median_numbers)" \
        "$(printf '%s\n' "${retrans[@]}" | median_numbers)" \
        "$(printf '%s\n' "${bytes[@]}" | median_numbers)" \
        "$(printf '%s\n' "${ratios[@]}" | median_numbers)"
}

loss_spike() {
    local value="$1" threshold="$2" base="$3"
    awk -v v="$value" -v t="$threshold" -v b="$base" 'BEGIN {
        if (v <= t) exit 1;
        if (b > 0 && v < b*5) exit 1;
        exit 0
    }'
}

estimate_sweep_bytes() {
    local high="$1" duration="$2" tests="$3"
    awk -v r="$high" -v d="$duration" -v n="$tests" 'BEGIN {printf "%.0f", r*1000000/8*d*n*1.08}'
}

new_measure_run() {
    local kind="$1" dir
    ensure_state_layout
    dir="$HISTORY_DIR/$(history_stamp)-${kind}"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    MEASURE_RESULT_FILE="$dir/samples.tsv"
    MEASURE_RUN_DIR="$dir"
    printf 'TIME\tLABEL\tGOODPUT_MBIT\tRETRANSMITS\tBYTES\tRETRANS_RATIO_EST_PERCENT\n' > "$MEASURE_RESULT_FILE"
}

measure_probe() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="$4" parallel="$5" iface dir row rc=0 speed estimate
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && is_uint "$parallel" && ((duration>=3 && duration<=120 && parallel>=1 && parallel<=32)) || { die "duration/parallel 超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    speed=$(detect_link_speed "$iface")
    if is_uint "$speed"; then
        estimate=$(estimate_sweep_bytes "$speed" "$duration" 3)
        log INFO "按接口速率估算，probe 最多可能产生约 $(human_bytes "$estimate") 出站流量"
    fi
    new_measure_run probe
    dir="$MEASURE_RUN_DIR"
    measure_begin "$iface" || return 1
    if apply_fq "$iface" && row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 3 unshaped); then
        printf 'TYPE\tprobe\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nGOODPUT_MBIT\t%s\nRETRANS_RATIO_EST_PERCENT\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$row")" "$(cut -f4 <<< "$row")" > "$dir/summary.tsv"
        log OK "可用带宽中位数: $(cut -f1 <<< "$row") Mbit/s，重传比例估算: $(cut -f4 <<< "$row")%"
        log INFO "结果: $dir"
    else rc=$?; fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

measure_sweep() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" nominal="$4" low="$5" high="$6" step="$7"
    local duration="$8" parallel="$9" margin="${10}" threshold="${11}" force_scan="${12}" cap="${13}"
    local iface dir baseline_row baseline_gp baseline_loss base_row base_loss rate row gp loss
    local last_ok="" broke_at="" fine_start fine_step recommend confirm_row estimated tests rc=0 no_knee=0 above_cap=0 baseline_duration
    validate_peer "$peer" "$port" || return 1
    for value in "$nominal" "$low" "$high" "$step" "$duration" "$parallel" "$margin" "$cap"; do is_uint "$value" || { die "扫描参数必须为非负整数"; return 1; }; done
    is_decimal "$threshold" || { die "loss threshold 必须是数字"; return 1; }
    (( duration >= 3 && duration <= 120 && parallel >= 1 && parallel <= 32 && margin <= 25 && cap >= 100 && cap <= 1000000 )) || { die "扫描参数超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    new_measure_run sweep
    dir="$MEASURE_RUN_DIR"
    measure_begin "$iface" || return 1

    baseline_duration="$duration"; ((baseline_duration>5)) && baseline_duration=5
    if ! apply_fq "$iface"; then
        rc=1
    elif ! baseline_row=$(sample_repeated "$peer" "$port" "$baseline_duration" 1 2 unshaped); then
        rc=1
    else
        baseline_gp=$(cut -f1 <<< "$baseline_row"); baseline_loss=$(cut -f4 <<< "$baseline_row")
        if awk -v g="$baseline_gp" -v c="$cap" 'BEGIN {exit !(g>c)}'; then
            above_cap=1; no_knee=1
            log WARN "不限速单流达到 ${baseline_gp} Mbit/s，超过扫描上限 ${cap} Mbit/s；跳过整形扫描"
        fi
        (( nominal > 0 )) || nominal=$(awk -v g="$baseline_gp" 'BEGIN {printf "%d", g+0.5}')
        (( low > 0 )) || low=$(awk -v g="$baseline_gp" 'BEGIN {v=g*0.80; if(v<1)v=1; printf "%d", v}')
        (( high > 0 )) || high=$(awk -v g="$baseline_gp" 'BEGIN {v=g*1.30; if(v<2)v=2; printf "%d", v}')
        (( step > 0 )) || { step=$((nominal / 20)); ((step < 5)) && step=5; }
        (( high > low )) || { die "扫描上界必须大于下界"; rc=1; }
    fi

    if (( rc == 0 && (step <= 0 || high <= low) )); then
        die "无法根据基准样本生成有效扫描区间"
        rc=1
    fi

    if (( rc == 0 )); then
        tests=$((2 + (high-low)/step + 6))
        estimated=$(estimate_sweep_bytes "$high" "$duration" "$tests")
        log INFO "预计最多测试 $tests 次、产生约 $(human_bytes "$estimated") 出站流量"

        if (( above_cap )); then
            :
        elif (( ! force_scan )) && awk -v v="$baseline_loss" -v t="$threshold" 'BEGIN {limit=t*10; if(limit<1)limit=1; exit !(v>limit)}'; then
            no_knee=1
            log WARN "不限速路径重传估算 ${baseline_loss}% 过高，无法可靠定位 policer；更换对端或使用 --force-scan"
        else
            apply_shaping "$iface" "$low" || rc=$?
            if (( rc == 0 )); then
                base_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "rate-${low}") || rc=$?
                base_loss=$(cut -f4 <<< "${base_row:-$'0\t0\t0\t0'}")
            fi
            if (( rc == 0 )) && loss_spike "$base_loss" "$threshold" 0; then
                die "扫描下界 ${low} Mbit 已有明显重传，无法建立干净本底；请降低 --low 或更换 peer"
                rc=2
            fi
            if (( rc == 0 )); then
                local previous_gp previous_rate stall_count=0 stalled_rate=""
                last_ok="$low"
                previous_gp=$(cut -f1 <<< "$base_row"); previous_rate="$low"
                for ((rate=low+step; rate<=high; rate+=step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "rate-${rate}") || { rc=$?; break; }
                    gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
                    printf '  %6s Mbit -> %8s Mbit/s, retrans-est %s%%\n' "$rate" "$gp" "$loss"
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    if awk -v g="$gp" -v p="$previous_gp" -v r="$rate" -v pr="$previous_rate" 'BEGIN {d=r-pr; gain=g-p; exit !(d>=1 && gain<d*0.25 && g<r*0.90)}'; then
                        ((stall_count+=1)); [[ -n "$stalled_rate" ]] || stalled_rate="$rate"
                        if (( stall_count >= 2 )); then broke_at="$stalled_rate"; break; fi
                        continue
                    fi
                    stall_count=0; stalled_rate=""; last_ok="$rate"; previous_gp="$gp"; previous_rate="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$broke_at" ]]; then
                fine_step=$((step / 5)); ((fine_step < 1)) && fine_step=1
                fine_start=$((last_ok + fine_step))
                for ((rate=fine_start; rate<broke_at; rate+=fine_step)); do
                    apply_shaping "$iface" "$rate" || { rc=$?; break; }
                    row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 1 "refine-${rate}") || { rc=$?; break; }
                    loss=$(cut -f4 <<< "$row")
                    if loss_spike "$loss" "$threshold" "$base_loss"; then broke_at="$rate"; break; fi
                    last_ok="$rate"
                done
            fi
            if (( rc == 0 )) && [[ -n "$last_ok" && -n "$broke_at" ]]; then
                recommend=$(( last_ok * (100-margin) / 100 )); ((recommend < 1)) && recommend=1
                apply_shaping "$iface" "$recommend" || rc=$?
                if (( rc == 0 )); then
                    confirm_row=$(sample_repeated "$peer" "$port" "$duration" "$parallel" 2 "confirm-${recommend}") || rc=$?
                    loss=$(cut -f4 <<< "${confirm_row:-$'0\t0\t0\t999'}")
                    if (( rc == 0 )) && loss_spike "$loss" "$threshold" "$base_loss"; then
                        log WARN "推荐档复测仍有跳变，请降低速率或更换对端复测"
                    fi
                fi
            elif (( rc == 0 )); then
                no_knee=1
                log WARN "扫描到上界仍未发现拐点，不建议基于本次结果启用整形"
            fi
        fi
    fi

    if (( rc == 0 )); then
        printf 'TYPE\tsweep\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nUNSHAPED_MBIT\t%s\nBASE_RETRANS_RATIO_EST_PERCENT\t%s\nLOW\t%s\nHIGH\t%s\nSTEP\t%s\nLAST_OK\t%s\nBROKE_AT\t%s\nRECOMMEND\t%s\nMARGIN_PERCENT\t%s\nNO_KNEE\t%s\nABOVE_CAP\t%s\n' \
            "$peer" "$port" "$iface" "${baseline_gp:-}" "${baseline_loss:-}" "$low" "$high" "$step" "${last_ok:-}" "${broke_at:-}" "${recommend:-}" "$margin" "$no_knee" "$above_cap" > "$dir/summary.tsv"
        if [[ -n "${recommend:-}" ]]; then
            log OK "扫描完成: last clean=${last_ok} Mbit, break=${broke_at:-above-range} Mbit, 推荐=${recommend} Mbit"
            log INFO "确认业务表现后执行: ${0##*/} tc enable ${recommend} --knee ${broke_at:-0} --margin ${margin} --interface ${requested}"
        fi
        log INFO "完整结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}

summary_value() {
    local file="$1" key="$2"
    awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$file" 2>/dev/null
}

measure_path_check() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" rate="$4" iface row gp loss rc=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$rate" && (( rate > 0 )) || { die "路径检查速率无效"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    measure_begin "$iface" || return 1
    log INFO "路径预检: 临时整形 ${rate} Mbit/s，检查对端是否足以承载测量"
    if apply_shaping "$iface" "$rate" && row=$(sample_repeated "$peer" "$port" 5 1 1 path-check); then
        gp=$(cut -f1 <<< "$row"); loss=$(cut -f4 <<< "$row")
        if awk -v g="$gp" -v r="$rate" 'BEGIN {exit !(g < r*0.60)}'; then
            log ERR "路径预检仅达到 ${gp} Mbit/s，明显低于 ${rate} Mbit/s；更换更近对端后重试"
            rc=2
        elif loss_spike "$loss" 0.5 0; then
            log ERR "路径预检重传比例过高 (${loss}%)；本次对端不适合寻找 policer 拐点"
            rc=2
        else
            log OK "路径预检通过: ${gp} Mbit/s，重传估算 ${loss}%"
        fi
    else
        rc=1
    fi
    measure_restore || rc=$?
    return "$rc"
}

measure_verify() {
    require_root || return 1; acquire_lock || return 1; tc_dependencies || return 1
    require_commands iperf3 jq timeout || return 1
    local peer="$1" port="$2" requested="$3" duration="${4:-8}" iface dir one multi rc=0
    validate_peer "$peer" "$port" || return 1
    is_uint "$duration" && (( duration >= 3 && duration <= 120 )) || { die "verify duration 超出安全范围"; return 1; }
    peer_port_open "$peer" "$port" || { die "无法连接 $peer:$port"; return 1; }
    iface=$(detect_interface "$requested") || return 1
    qdisc_guard "$iface" || return 1
    new_measure_run verify; dir="$MEASURE_RUN_DIR"
    measure_begin "$iface" || return 1
    one=$(sample_repeated "$peer" "$port" "$duration" 1 1 verify-single) || rc=$?
    if (( rc == 0 )); then multi=$(sample_repeated "$peer" "$port" "$duration" 4 1 verify-four) || rc=$?; fi
    if (( rc == 0 )); then
        printf 'TYPE\tverify\nPEER\t%s\nPORT\t%s\nINTERFACE\t%s\nSINGLE_MBIT\t%s\nSINGLE_RETRANS_EST_PERCENT\t%s\nFOUR_MBIT\t%s\nFOUR_RETRANS_EST_PERCENT\t%s\n' \
            "$peer" "$port" "$iface" "$(cut -f1 <<< "$one")" "$(cut -f4 <<< "$one")" \
            "$(cut -f1 <<< "$multi")" "$(cut -f4 <<< "$multi")" > "$dir/summary.tsv"
        log OK "验证完成: 单流 $(cut -f1 <<< "$one") Mbit/s，多流 $(cut -f1 <<< "$multi") Mbit/s"
        log INFO "验证结果: $dir"
    fi
    traffic_report "$iface"
    measure_restore || rc=$?
    return "$rc"
}
