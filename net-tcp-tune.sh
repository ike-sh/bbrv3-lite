#!/bin/bash
#=============================================================================
# BBR v3 / XanMod / TCP 网络调优脚本
# 功能：结合 XanMod 官方内核的稳定性 + 专业队列算法调优
# 特点：保留 BBR v3、XanMod、TCP、DNS、IPv6、预检与回滚相关能力
#=============================================================================
# 版本管理规则：
# 1. 大版本更新时修改 SCRIPT_VERSION，并更新版本备注（保留最新5条）
# 2. 小修复时更新版本备注，用于快速识别脚本是否已更新
#=============================================================================
# v5.2.4: 增强小盘机器一键优化体验，统一磁盘空间检查，并补充 IPv6 恢复备份提示。
# v5.2.3: 修复 DNS 净化安全检查在部分环境下将磁盘可用空间误判为 0MB 的问题。
# v5.2.2: 修复永久禁用 IPv6 时将脚本自身 .ipv6-state-backup.conf 误报为 sysctl.d 冲突项的问题。
# v5.2.1: 修复 /etc/sysctl.conf 中 disable_ipv6=0 覆盖永久禁用 IPv6 配置；永久禁用前自动备份并注释冲突项。
# v5.2.0: 移除小众中转 timeout 处理功能，精简主菜单、一键优化流程和回滚入口。

SCRIPT_VERSION="5.2.4"
#=============================================================================

#=============================================================================
# 📋 推荐配置方案（基于实测优化）
#=============================================================================
# 
# 💡 测试环境：经过本人十几二十几台不同服务器的测试
#    包括酷雪云北京9929等多个节点的实测验证
# 
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
# ⭐ 首选方案（推荐）：
#    步骤1 → 执行菜单选项 1：BBR v3 内核安装
#    步骤2 → 执行菜单选项 3：BBR 直连/落地优化（智能带宽检测）
#            选择子选项 1 进行自动检测
# 
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
#=============================================================================

# 颜色定义（保留中文变量名以兼容现有代码）
gl_hong='\033[31m'      # 红色
gl_lv='\033[32m'        # 绿色
gl_huang='\033[33m'     # 黄色
gl_bai='\033[0m'        # 重置
gl_kjlan='\033[96m'     # 亮青色
gl_zi='\033[35m'        # 紫色
gl_hui='\033[90m'       # 灰色

# 英文别名（供新代码使用）
readonly COLOR_RED="$gl_hong"
readonly COLOR_GREEN="$gl_lv"
readonly COLOR_YELLOW="$gl_huang"
readonly COLOR_RESET="$gl_bai"
readonly COLOR_CYAN="$gl_kjlan"
readonly COLOR_PURPLE="$gl_zi"
readonly COLOR_GRAY="$gl_hui"

# 显示宽度计算（中文占2列，ASCII占1列）
get_display_width() {
    local str="$1"
    local byte_len=$(printf '%s' "$str" | LC_ALL=C wc -c | tr -d ' ')
    local char_len=${#str}
    local extra=$((byte_len - char_len))
    local wide=$((extra / 2))
    echo $((char_len + wide))
}

# 格式化字符串到固定显示宽度（截断+填充，确保宽度精确）
format_fixed_width() {
    local str="$1"
    local target_width=$2
    local current_width=$(get_display_width "$str")

    # 如果太长，截断
    if [ "$current_width" -gt "$target_width" ]; then
        local result=""
        local i=0
        local len=${#str}
        while [ $i -lt $len ]; do
            local char="${str:$i:1}"
            local test_str="${result}${char}"
            local test_width=$(get_display_width "$test_str")
            if [ "$test_width" -gt $((target_width - 2)) ]; then
                str="${result}.."
                break
            fi
            result="$test_str"
            i=$((i + 1))
        done
        current_width=$(get_display_width "$str")
    fi

    # 填充到目标宽度
    local padding=$((target_width - current_width))
    if [ $padding -gt 0 ]; then
        printf "%s%*s" "$str" "$padding" ""
    else
        printf "%s" "$str"
    fi
}

# GitHub 代理设置
gh_proxy="https://"

# 配置文件路径（使用独立文件，不破坏系统配置）
SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"

#=============================================================================
# 常量定义（版本号、URL 等集中管理）
#=============================================================================

# IP 查询服务 URL（按优先级排序）
readonly IP_CHECK_V4_URLS=(
    "https://api.ipify.org"
    "https://ip.sb"
    "https://checkip.amazonaws.com"
    "https://ipinfo.io/ip"
)
readonly IP_CHECK_V6_URLS=(
    "https://api64.ipify.org"
    "https://v6.ipinfo.io/ip"
    "https://ip.sb"
)

# IP 信息查询
readonly IP_INFO_URL="https://ipinfo.io"

#=============================================================================
# 日志系统
#=============================================================================

readonly LOG_FILE="/var/log/net-tcp-tune.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# 统一日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 写入日志文件（静默失败）
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true

    # 根据级别输出到终端
    case "$level" in
        ERROR)
            echo -e "${gl_hong}[ERROR] $message${gl_bai}" >&2
            ;;
        WARN)
            echo -e "${gl_huang}[WARN] $message${gl_bai}"
            ;;
        INFO)
            [ "$LOG_LEVEL" != "ERROR" ] && echo -e "${gl_lv}[INFO] $message${gl_bai}"
            ;;
        DEBUG)
            [ "$LOG_LEVEL" = "DEBUG" ] && echo -e "${gl_hui}[DEBUG] $message${gl_bai}"
            ;;
    esac
}

# 便捷日志函数
log_error() { log "ERROR" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_info()  { log "INFO" "$@"; }
log_debug() { log "DEBUG" "$@"; }

#=============================================================================
# 错误处理
#=============================================================================

# 清理临时文件
cleanup_temp_files() {
    rm -f /tmp/net-tcp-tune.* 2>/dev/null || true
}

# 全局错误处理器（可选启用）
error_handler() {
    local exit_code=$1
    local line_no=$2
    local command="$3"

    log_error "脚本执行失败"
    log_error "  退出码: $exit_code"
    log_error "  行号: $line_no"
    log_error "  命令: $command"

    cleanup_temp_files
}

# 启用严格模式（用于调试）
enable_strict_mode() {
    set -euo pipefail
    trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR
}

# 退出时清理
trap cleanup_temp_files EXIT

#=============================================================================
# 工具函数
#=============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: ${gl_bai}此脚本需要 root 权限运行！"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

break_end() {
    [ "$AUTO_MODE" = "1" ] && return
    echo -e "${gl_lv}操作完成${gl_bai}"
    echo "按任意键继续..."
    read -n 1 -s -r -p ""
    echo ""
}

clean_sysctl_conf() {
    # 备份主配置文件
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
    fi
    
    # 注释所有冲突参数
    sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.core\.default_qdisc/s/^/# /' /etc/sysctl.conf 2>/dev/null
    sed -i '/^net\.ipv4\.tcp_congestion_control/s/^/# /' /etc/sysctl.conf 2>/dev/null
}

install_package() {
    local packages=("$@")
    local missing_packages=()
    local os_release="/etc/os-release"
    local os_id=""
    local os_like=""
    local pkg_manager=""
    local update_cmd=()
    local install_cmd=()

    for package in "${packages[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        return 0
    fi

    if [ -r "$os_release" ]; then
        # shellcheck disable=SC1091
        . "$os_release"
        os_id="${ID,,}"
        os_like="${ID_LIKE,,}"
    fi

    local detection="${os_id} ${os_like}"

    if [[ "$detection" =~ (debian|ubuntu) ]]; then
        pkg_manager="apt"
        update_cmd=(apt-get update)
        install_cmd=(apt-get install -y)
    elif [[ "$detection" =~ (rhel|centos|fedora|rocky|alma|redhat) ]]; then
        if command -v dnf &>/dev/null; then
            pkg_manager="dnf"
            update_cmd=(dnf makecache)
            install_cmd=(dnf install -y)
        elif command -v yum &>/dev/null; then
            pkg_manager="yum"
            update_cmd=(yum makecache)
            install_cmd=(yum install -y)
        else
            echo "错误: 未找到可用的 RHEL 系包管理器 (dnf 或 yum)" >&2
            return 1
        fi
    else
        echo "错误: 未支持的 Linux 发行版，无法自动安装依赖。请手动安装: ${missing_packages[*]}" >&2
        return 1
    fi

    if [ ${#update_cmd[@]} -gt 0 ]; then
        echo -e "${gl_huang}正在更新软件仓库...${gl_bai}"
        if ! "${update_cmd[@]}"; then
            echo "错误: 使用 ${pkg_manager} 更新软件仓库失败。" >&2
            return 1
        fi
    fi

    for package in "${missing_packages[@]}"; do
        echo -e "${gl_huang}正在安装 $package...${gl_bai}"
        if ! "${install_cmd[@]}" "$package"; then
            echo "错误: ${pkg_manager} 安装 $package 失败，请检查上方输出信息。" >&2
            return 1
        fi
    done
}

safe_download_script() {
    local url=$1
    local output_file=$2

    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$output_file" "$url"
    else
        return 1
    fi

    [ -s "$output_file" ]
}

verify_downloaded_script() {
    local file=$1

    if [ ! -s "$file" ]; then
        return 1
    fi

    if head -n 1 "$file" | grep -qiE '<!DOCTYPE|<html'; then
        return 1
    fi

    # 检查 shebang，同时处理 UTF-8 BOM (ef bb bf) 开头的情况
    head -n 5 "$file" | sed 's/^\xef\xbb\xbf//' | grep -q '^#!'
}

run_remote_script() {
    local url=$1
    local interpreter=${2:-bash}
    shift 2

    local tmp_file
    tmp_file=$(mktemp /tmp/net-tcp-tune.XXXXXX) || {
        echo -e "${gl_hong}❌ 无法创建临时文件${gl_bai}"
        return 1
    }

    if ! safe_download_script "$url" "$tmp_file"; then
        echo -e "${gl_hong}❌ 下载脚本失败: ${url}${gl_bai}"
        rm -f "$tmp_file"
        return 1
    fi

    if ! verify_downloaded_script "$tmp_file"; then
        echo -e "${gl_hong}❌ 脚本校验失败，已取消执行${gl_bai}"
        rm -f "$tmp_file"
        return 1
    fi

    chmod +x "$tmp_file"
    "$interpreter" "$tmp_file" "$@"
    local rc=$?
    rm -f "$tmp_file"
    return $rc
}

get_root_available_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4}'
}

check_disk_space() {
    local required_gb=$1
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb
    local available_space_gb

    DISK_SPACE_CHECK_ABORTED=0
    DISK_SPACE_CHECK_REASON=""

    available_space_mb=$(get_root_available_mb)

    if ! [[ "$available_space_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${gl_huang}警告: ${gl_bai}无法可靠读取根分区可用空间。"
        echo "最低需求: ${required_gb}G"
        read -e -p "是否继续？(Y/N): " continue_choice
        case "$continue_choice" in
            [Yy]) return 0 ;;
            *)
                DISK_SPACE_CHECK_ABORTED=1
                DISK_SPACE_CHECK_REASON="unreadable"
                return 1
                ;;
        esac
    fi

    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        available_space_gb=$(awk -v mb="$available_space_mb" 'BEGIN {printf "%.1f", mb / 1024}')
        echo -e "${gl_huang}警告: ${gl_bai}磁盘空间不足！"
        echo "当前可用: ${available_space_mb}MB（约 ${available_space_gb}G） | 最低需求: ${required_gb}G"
        read -e -p "是否继续？(Y/N): " continue_choice
        case "$continue_choice" in
            [Yy]) return 0 ;;
            *)
                DISK_SPACE_CHECK_ABORTED=1
                DISK_SPACE_CHECK_REASON="insufficient"
                return 1
                ;;
        esac
    fi

    return 0
}

check_swap() {
    local swap_total=$(free -m | awk 'NR==3{print $2}')

    if [ "$swap_total" -eq 0 ]; then
        echo -e "${gl_huang}检测到无虚拟内存，正在创建 1G SWAP...${gl_bai}"
        if fallocate -l $((1025 * 1024 * 1024)) /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1025 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1
            if swapon /swapfile 2>/dev/null; then
                # 防止重复写入 fstab
                if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
                    echo '/swapfile none swap sw 0 0' >> /etc/fstab
                fi
                echo -e "${gl_lv}虚拟内存创建成功${gl_bai}"
            else
                echo -e "${gl_huang}⚠️  SWAP 激活失败，但不影响安装${gl_bai}"
            fi
        else
            echo -e "${gl_huang}⚠️  SWAP 文件创建失败，但不影响安装${gl_bai}"
        fi
    fi
}

add_swap() {
    local new_swap=$1  # 获取传入的参数（单位：MB）

    echo -e "${gl_kjlan}=== 调整虚拟内存（仅管理 /swapfile） ===${gl_bai}"

    # 检测是否存在活跃的 /dev/* swap 分区
    local dev_swap_list
    dev_swap_list=$(awk 'NR>1 && $1 ~ /^\/dev\// {printf "  • %s (大小: %d MB, 已用: %d MB)\n", $1, int(($3+512)/1024), int(($4+512)/1024)}' /proc/swaps)

    if [ -n "$dev_swap_list" ]; then
        echo -e "${gl_huang}检测到以下 /dev/ 虚拟内存处于激活状态：${gl_bai}"
        echo "$dev_swap_list"
        echo ""
        echo -e "${gl_huang}提示:${gl_bai} 本脚本不会修改 /dev/ 分区，请使用 ${gl_zi}swapoff <设备>${gl_bai} 等命令手动处理。"
        echo ""
    fi

    # 确保 /swapfile 不再被使用
    swapoff /swapfile 2>/dev/null
    
    # 删除旧的 /swapfile
    rm -f /swapfile
    
    echo "正在创建 ${new_swap}MB 虚拟内存..."
    
    # 创建新的 swap 分区
    fallocate -l $(( (new_swap + 1) * 1024 * 1024 )) /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((new_swap + 1))
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    
    # 更新 /etc/fstab
    sed -i '/\/swapfile/d' /etc/fstab
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    
    # Alpine Linux 特殊处理
    if [ -f /etc/alpine-release ]; then
        echo "nohup swapon /swapfile" > /etc/local.d/swap.start
        chmod +x /etc/local.d/swap.start
        rc-update add local 2>/dev/null
    fi
    
    echo -e "${gl_lv}虚拟内存大小已调整为 ${new_swap}MB${gl_bai}"
}

disable_ipv6_temporary() {
    clear
    echo -e "${gl_kjlan}=== 临时禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将临时禁用IPv6，重启后自动恢复"
    echo "------------------------------------------------"
    echo ""
    
    read -e -p "$(echo -e "${gl_huang}确认临时禁用IPv6？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在禁用IPv6..."
            
            # 临时禁用IPv6
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
            
            # 验证状态
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "1" ]; then
                echo -e "${gl_lv}✅ IPv6 已临时禁用${gl_bai}"
                echo ""
                echo -e "${gl_zi}注意：${gl_bai}"
                echo "  - 此设置仅在当前会话有效"
                echo "  - 重启后 IPv6 将自动恢复"
                echo "  - 如需永久禁用，请选择'永久禁用IPv6'选项"
            else
                echo -e "${gl_hong}❌ IPv6 禁用失败${gl_bai}"
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
    break_end
}

ipv6_permanent_disabled_state() {
    local ipv6_all
    local ipv6_default
    local ipv6_lo

    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
    ipv6_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "unknown")
    ipv6_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "unknown")

    [ "$ipv6_all" = "1" ] && [ "$ipv6_default" = "1" ] && [ "$ipv6_lo" = "1" ]
}

comment_ipv6_sysctl_conf_conflicts() {
    local sysctl_conf="/etc/sysctl.conf"
    local conflict_pattern='^[[:space:]]*(net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*0([[:space:]]*(#.*)?)?)$'
    local backup_file
    local other_conflicts

    if [ -f "$sysctl_conf" ] && grep -Eq "$conflict_pattern" "$sysctl_conf"; then
        backup_file="/etc/sysctl.conf.bak.disable_ipv6_conflict.$(date +%Y%m%d_%H%M%S)"

        if ! cp "$sysctl_conf" "$backup_file"; then
            echo -e "${gl_hong}❌ 备份 /etc/sysctl.conf 失败，已停止修改${gl_bai}"
            return 1
        fi

        if ! sed -i -E "s|$conflict_pattern|# disabled by bbrv3-lite: \1|" "$sysctl_conf"; then
            echo -e "${gl_hong}❌ 注释 /etc/sysctl.conf IPv6 冲突项失败${gl_bai}"
            return 1
        fi

        echo -e "${gl_lv}✅ 已备份并注释 /etc/sysctl.conf 中的 IPv6 冲突项${gl_bai}"
        echo "  备份文件: ${backup_file}"
    else
        echo -e "${gl_lv}✅ 未发现 /etc/sysctl.conf 中的 IPv6 冲突项${gl_bai}"
    fi

    other_conflicts=$(
        grep -RnsE "$conflict_pattern" /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null \
            | grep -vE '(^|/)\.ipv6-state-backup\.conf:' \
            || true
    )
    if [ -n "$other_conflicts" ]; then
        echo -e "${gl_huang}⚠️  检测到其他 sysctl.d 文件中仍存在 disable_ipv6=0，请留意是否继续覆盖:${gl_bai}"
        echo "$other_conflicts" | sed 's/^/  /'
    fi

    return 0
}

disable_ipv6_permanent() {
    clear
    echo -e "${gl_kjlan}=== 永久禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将永久禁用IPv6，重启后仍然生效"
    echo "------------------------------------------------"
    echo ""
    
    # 检查是否已经永久禁用
    if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        echo -e "${gl_huang}⚠️  检测到已存在永久禁用配置${gl_bai}"
        echo ""
        if [ "$AUTO_MODE" = "1" ]; then
            confirm=Y
        else
            read -e -p "$(echo -e "${gl_huang}是否重新执行永久禁用？(Y/N): ${gl_bai}")" confirm
        fi

        case "$confirm" in
            [Yy])
                ;;
            *)
                echo "已取消"
                break_end
                return 1
                ;;
        esac
    fi
    
    echo ""
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}确认永久禁用IPv6？(Y/N): ${gl_bai}")" confirm
    fi

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_zi}[步骤 1/4] 备份当前IPv6状态...${gl_bai}"
            
            # 读取当前IPv6状态并备份
            local ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
            local ipv6_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "0")
            local ipv6_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "0")
            
            # 创建备份文件
            cat > /etc/sysctl.d/.ipv6-state-backup.conf << BACKUPEOF
# IPv6 State Backup - Created on $(date '+%Y-%m-%d %H:%M:%S')
# This file is used to restore IPv6 state when canceling permanent disable
net.ipv6.conf.all.disable_ipv6=${ipv6_all}
net.ipv6.conf.default.disable_ipv6=${ipv6_default}
net.ipv6.conf.lo.disable_ipv6=${ipv6_lo}
BACKUPEOF
            
            echo -e "${gl_lv}✅ 状态已备份${gl_bai}"
            echo ""

            echo -e "${gl_zi}[步骤 2/4] 清理 /etc/sysctl.conf IPv6 冲突项...${gl_bai}"
            if ! comment_ipv6_sysctl_conf_conflicts; then
                echo ""
                break_end
                return 1
            fi
            echo ""

            echo -e "${gl_zi}[步骤 3/4] 创建永久禁用配置...${gl_bai}"
            
            # 创建永久禁用配置文件
            cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# Permanently Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            
            echo -e "${gl_lv}✅ 配置文件已创建${gl_bai}"
            echo ""

            echo -e "${gl_zi}[步骤 4/4] 应用配置...${gl_bai}"
            
            # 应用配置
            sysctl --system >/dev/null 2>&1
            
            # 验证状态
            local ipv6_all_after
            local ipv6_default_after
            local ipv6_lo_after
            ipv6_all_after=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
            ipv6_default_after=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "unknown")
            ipv6_lo_after=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "unknown")
            
            echo ""
            if [ "$ipv6_all_after" = "1" ] && [ "$ipv6_default_after" = "1" ] && [ "$ipv6_lo_after" = "1" ]; then
                echo -e "${gl_lv}✅ IPv6 已永久禁用${gl_bai}"
                echo ""
                echo -e "${gl_zi}说明：${gl_bai}"
                echo "  - 配置文件: /etc/sysctl.d/99-disable-ipv6.conf"
                echo "  - 备份文件: /etc/sysctl.d/.ipv6-state-backup.conf"
                echo "  - 重启后此配置仍然生效"
                echo "  - 如需恢复，请选择'取消永久禁用'选项"
                echo ""
                break_end
                return 0
            else
                echo -e "${gl_hong}❌ IPv6 禁用失败${gl_bai}"
                echo "  all.disable_ipv6=${ipv6_all_after}"
                echo "  default.disable_ipv6=${ipv6_default_after}"
                echo "  lo.disable_ipv6=${ipv6_lo_after}"
                # 如果失败，删除配置文件
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                rm -f /etc/sysctl.d/.ipv6-state-backup.conf
                echo ""
                break_end
                return 1
            fi
            ;;
        *)
            echo "已取消"
            echo ""
            break_end
            return 1
            ;;
    esac
}

cancel_ipv6_permanent_disable() {
    clear
    echo -e "${gl_kjlan}=== 取消永久禁用IPv6 ===${gl_bai}"
    echo ""
    echo "此操作将完全还原到执行永久禁用前的状态"
    echo "------------------------------------------------"
    echo ""
    
    # 检查是否存在永久禁用配置
    if [ ! -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        echo -e "${gl_huang}⚠️  未检测到永久禁用配置${gl_bai}"
        echo ""
        echo "可能原因："
        echo "  - 从未执行过'永久禁用IPv6'操作"
        echo "  - 配置文件已被手动删除"
        echo ""
        break_end
        return 1
    fi
    
    read -e -p "$(echo -e "${gl_huang}确认取消永久禁用并恢复原始状态？(Y/N): ${gl_bai}")" confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_zi}[步骤 1/4] 删除永久禁用配置...${gl_bai}"
            
            # 删除永久禁用配置文件
            rm -f /etc/sysctl.d/99-disable-ipv6.conf
            echo -e "${gl_lv}✅ 配置文件已删除${gl_bai}"
            echo ""
            
            echo -e "${gl_zi}[步骤 2/4] 检查备份文件...${gl_bai}"
            
            # 检查备份文件
            if [ -f /etc/sysctl.d/.ipv6-state-backup.conf ]; then
                echo -e "${gl_lv}✅ 找到备份文件${gl_bai}"
                echo ""
                
                echo -e "${gl_zi}[步骤 3/4] 从备份还原原始状态...${gl_bai}"
                
                # 读取备份的原始值
                local backup_all=$(grep 'net.ipv6.conf.all.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                local backup_default=$(grep 'net.ipv6.conf.default.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                local backup_lo=$(grep 'net.ipv6.conf.lo.disable_ipv6' /etc/sysctl.d/.ipv6-state-backup.conf | awk -F'=' '{print $2}')
                
                # 恢复原始值
                sysctl -w net.ipv6.conf.all.disable_ipv6=${backup_all} >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=${backup_default} >/dev/null 2>&1
                sysctl -w net.ipv6.conf.lo.disable_ipv6=${backup_lo} >/dev/null 2>&1
                
                # 删除备份文件
                rm -f /etc/sysctl.d/.ipv6-state-backup.conf
                
                echo -e "${gl_lv}✅ 已从备份还原原始状态${gl_bai}"
            else
                echo -e "${gl_huang}⚠️  未找到备份文件${gl_bai}"
                echo ""
                
                echo -e "${gl_zi}[步骤 3/4] 恢复到系统默认（启用IPv6）...${gl_bai}"
                
                # 恢复到系统默认（启用IPv6）
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
                sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
                
                echo -e "${gl_lv}✅ 已恢复到系统默认（IPv6启用）${gl_bai}"
            fi
            
            echo ""
            echo -e "${gl_zi}[步骤 4/4] 应用配置...${gl_bai}"
            
            # 应用配置
            sysctl --system >/dev/null 2>&1
            
            # 验证状态
            local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            
            echo ""
            if [ "$ipv6_status" = "0" ]; then
                echo -e "${gl_lv}✅ IPv6 已恢复启用${gl_bai}"
                echo ""
                echo -e "${gl_zi}说明：${gl_bai}"
                echo "  - 所有相关配置文件已清理"
                echo "  - IPv6 已完全恢复到执行永久禁用前的状态"
                echo "  - 重启后此状态依然保持"
                echo "  - 如果之前脚本注释过 /etc/sysctl.conf 中的 IPv6 冲突项，可查看备份: /etc/sysctl.conf.bak.disable_ipv6_conflict.*"
                echo "  - 如需完全恢复手动配置，请自行对比备份"
            else
                echo -e "${gl_huang}⚠️  IPv6 状态: 禁用（值=${ipv6_status}）${gl_bai}"
                echo ""
                echo "可能原因："
                echo "  - 系统中存在其他IPv6禁用配置"
                echo "  - 手动执行 sysctl -w 命令重新启用IPv6"
                echo "  - 如果之前脚本注释过 /etc/sysctl.conf 中的 IPv6 冲突项，可查看备份: /etc/sysctl.conf.bak.disable_ipv6_conflict.*"
                echo "  - 如需完全恢复手动配置，请自行对比备份"
            fi
            ;;
        *)
            echo "已取消"
            ;;
    esac
    
    echo ""
    break_end
}

manage_ipv6() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== IPv6 管理 ===${gl_bai}"
        echo ""
        
        # 显示当前IPv6状态
        local ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        local status_text=""
        local status_color=""
        
        if [ "$ipv6_status" = "0" ]; then
            status_text="启用"
            status_color="${gl_lv}"
        else
            status_text="禁用"
            status_color="${gl_hong}"
        fi
        
        echo -e "当前状态: ${status_color}${status_text}${gl_bai}"
        echo ""
        
        # 检查是否存在永久禁用配置
        if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
            echo -e "${gl_huang}⚠️  检测到永久禁用配置文件${gl_bai}"
            echo ""
        fi
        
        echo "------------------------------------------------"
        echo "1. 临时禁用IPv6（重启后恢复）"
        echo "2. 永久禁用IPv6（重启后仍生效）"
        echo "3. 取消永久禁用（完全还原）"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -e -p "请输入选择: " choice
        
        case "$choice" in
            1)
                disable_ipv6_temporary
                ;;
            2)
                disable_ipv6_permanent
                ;;
            3)
                cancel_ipv6_permanent_disable
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

#=============================================================================
# 旧版 MTU 优化自动清理（v4.9.2 起移除旧 MTU 菜单，保留清理逻辑）
# 功能3 的 tcp_mtu_probing=1 + clamp-mss-to-pmtu 已覆盖 MTU 智能探测
#=============================================================================

auto_cleanup_legacy_mtu() {
    # 检测旧版 MTU 优化配置文件是否存在
    [ -f /usr/local/etc/mtu-optimize.conf ] || return 0

    # 恢复默认路由 MTU
    local default_route
    default_route=$(ip -4 route show default 2>/dev/null | head -1)
    if [ -n "$default_route" ]; then
        local clean_route
        clean_route=$(echo "$default_route" | sed 's/ mtu lock [0-9]*//;s/ mtu [0-9]*//')
        ip route replace $clean_route 2>/dev/null
    fi

    # 恢复链路 MTU
    local saved_iface saved_original_mtu
    saved_iface=$(grep '^DEFAULT_IFACE=' /usr/local/etc/mtu-optimize.conf 2>/dev/null | cut -d= -f2)
    saved_original_mtu=$(grep '^ORIGINAL_MTU=' /usr/local/etc/mtu-optimize.conf 2>/dev/null | cut -d= -f2)
    if [ -n "$saved_iface" ] && [ -n "$saved_original_mtu" ]; then
        ip link set dev "$saved_iface" mtu "$saved_original_mtu" 2>/dev/null
    fi

    # 清理旧版 iptables set-mss 规则
    if command -v iptables &>/dev/null; then
        local comment_tag="net-tcp-tune-mss"
        local del_mss
        while read -r del_mss; do
            [ -n "$del_mss" ] || continue
            iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
        done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
        while read -r del_mss; do
            [ -n "$del_mss" ] || continue
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$del_mss" -m comment --comment "$comment_tag" 2>/dev/null || true
        done < <(iptables -t mangle -S POSTROUTING 2>/dev/null | grep "$comment_tag" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p')
    fi

    # 清理配置文件和持久化服务
    rm -f /usr/local/etc/mtu-optimize.conf
    if [ -f /usr/local/bin/bbr-optimize-apply.sh ] && grep -q "MTU 优化恢复 (mtu-optimize)" /usr/local/bin/bbr-optimize-apply.sh 2>/dev/null; then
        sed -i '/# MTU 优化恢复 (mtu-optimize)/,/^[[:space:]]*fi[[:space:]]*$/d' /usr/local/bin/bbr-optimize-apply.sh 2>/dev/null || true
    fi
    if [ -f /etc/systemd/system/mtu-optimize-persist.service ]; then
        systemctl disable mtu-optimize-persist.service 2>/dev/null
        rm -f /etc/systemd/system/mtu-optimize-persist.service
        rm -f /usr/local/bin/mtu-optimize-apply.sh
        systemctl daemon-reload 2>/dev/null
    fi

    echo -e "${gl_huang}⚠️ 检测到旧版MTU优化配置（已被功能3的tcp_mtu_probing替代），已自动清理${gl_bai}"
    sleep 2
}


server_reboot() {
    read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}现在重启服务器使配置生效吗？(Y/N): ")" rboot
    case "$rboot" in
        [Yy])
            echo "正在重启..."
            systemctl reboot 2>/dev/null || reboot
            sleep 2
            exit 0
            ;;
        *)
            echo "已取消，请稍后手动执行: reboot"
            ;;
    esac
}

#=============================================================================
# 带宽检测和缓冲区计算函数
#=============================================================================

# 带宽检测函数
detect_bandwidth() {
    # 所有交互式输出重定向到stderr，避免被命令替换捕获
    echo "" >&2
    echo -e "${gl_kjlan}=== 服务器带宽检测 ===${gl_bai}" >&2
    echo "" >&2
    echo "请选择带宽配置方式：" >&2
    echo "1. 自动检测（推荐，自动选择最近服务器）" >&2
    echo "2. 手动指定测速服务器（指定服务器ID）" >&2
    echo "3. 手动选择预设档位（9个常用带宽档位）" >&2
    echo "" >&2
    
    read -e -p "请输入选择 [1]: " bw_choice
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        1)
            # 自动检测带宽 - 选择最近服务器
            echo "" >&2
            echo -e "${gl_huang}正在运行 speedtest 测速...${gl_bai}" >&2
            echo -e "${gl_zi}提示: 自动选择距离最近的服务器${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                # 调用脚本中已有的安装逻辑（简化版）
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用带宽值 500 Mbps" >&2
                        echo "500"
                        return 1
                        ;;
                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用通用值${gl_bai}" >&2
                    echo "500"
                    return 1
                fi
            fi
            
            # 智能测速：获取附近服务器列表，按距离依次尝试
            echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}" >&2
            
            # 获取附近服务器列表（按延迟排序）
            local servers_list=$(speedtest --accept-license --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
            
            if [ -z "$servers_list" ]; then
                echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}" >&2
                servers_list="auto"
            else
                local server_count=$(echo "$servers_list" | wc -l)
                echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}" >&2
            fi
            echo "" >&2
            
            local speedtest_output=""
            local upload_speed=""
            local attempt=0
            local max_attempts=5  # 最多尝试5个服务器
            
            # 逐个尝试服务器
            for server_id in $servers_list; do
                attempt=$((attempt + 1))
                
                if [ $attempt -gt $max_attempts ]; then
                    echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}" >&2
                    break
                fi
                
                if [ "$server_id" = "auto" ]; then
                    echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license 2>&1)
                else
                    echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}" >&2
                    speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                fi
                
                echo "$speedtest_output" >&2
                echo "" >&2
                
                # 提取上传速度
                upload_speed=""
                if echo "$speedtest_output" | grep -q "Upload:"; then
                    upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
                fi
                if [ -z "$upload_speed" ]; then
                    upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
                fi
                
                # 检查是否成功
                if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                    local success_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //')
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                    echo -e "${gl_zi}使用服务器: ${success_server}${gl_bai}" >&2
                    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                    echo "" >&2
                    break
                else
                    local failed_server=$(echo "$speedtest_output" | grep "Server:" | head -n1 | sed 's/.*Server: //' | sed 's/[[:space:]]*$//')
                    if [ -n "$failed_server" ]; then
                        echo -e "${gl_huang}⚠️  失败: ${failed_server}${gl_bai}" >&2
                    else
                        echo -e "${gl_huang}⚠️  此服务器失败${gl_bai}" >&2
                    fi
                    echo -e "${gl_zi}继续尝试下一个服务器...${gl_bai}" >&2
                    echo "" >&2
                fi
            done
            
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 所有尝试都失败了
            if [ -z "$upload_speed" ] || echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo -e "${gl_huang}⚠️  无法自动检测带宽${gl_bai}" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_zi}原因: 测速服务器可能暂时不可用${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_kjlan}默认配置方案：${gl_bai}" >&2
                echo -e "  带宽:       ${gl_huang}1000 Mbps (1 Gbps)${gl_bai}" >&2
                echo -e "  缓冲区:     ${gl_huang}根据地区自动计算${gl_bai}" >&2
                echo -e "  适用场景:   ${gl_zi}标准 1Gbps 服务器（覆盖大多数场景）${gl_bai}" >&2
                echo "" >&2
                echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}" >&2
                echo "" >&2
                
                # 询问用户确认
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                case "$use_default" in
                    [Yy])
                        echo "" >&2
                        echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                    [Nn])
                        echo "" >&2
                        echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                        local manual_bandwidth=""
                        while true; do
                            read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                            if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                                echo "" >&2
                                echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                                echo "$manual_bandwidth"
                                return 0
                            else
                                echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                            fi
                        done
                        ;;
                    *)
                        echo "" >&2
                        echo -e "${gl_huang}输入无效，使用默认值 1000 Mbps${gl_bai}" >&2
                        echo "1000"
                        return 0
                        ;;
                esac
            fi
            
            # 转为整数并验证
            local upload_mbps=${upload_speed%.*}
            if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                upload_mbps=1000
            fi

            echo -e "${gl_lv}✅ 检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
            echo "" >&2

            # 返回带宽值
            echo "$upload_mbps"
            return 0
            ;;
        2)
            # 手动指定测速服务器ID
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动指定测速服务器 ===${gl_bai}" >&2
            echo "" >&2
            
            # 检查speedtest是否安装
            if ! command -v speedtest &>/dev/null; then
                echo -e "${gl_huang}speedtest 未安装，正在安装...${gl_bai}" >&2
                local cpu_arch=$(uname -m)
                local download_url
                case "$cpu_arch" in
                    x86_64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                        ;;
                    aarch64)
                        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                        ;;
                    *)
                        echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}" >&2
                        echo "将使用通用值 1000 Mbps" >&2
                        echo "1000"
                        return 1
                        ;;
                esac
                
                cd /tmp
                wget -q "$download_url" -O speedtest.tgz && \
                tar -xzf speedtest.tgz && \
                mv speedtest /usr/local/bin/ && \
                rm -f speedtest.tgz
                
                if [ $? -ne 0 ]; then
                    echo -e "${gl_hong}安装失败，将使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                fi
                echo -e "${gl_lv}✅ speedtest 安装成功${gl_bai}" >&2
                echo "" >&2
            fi
            
            # 显示如何查看服务器列表
            echo -e "${gl_zi}📋 如何查看可用的测速服务器：${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法1：查看所有服务器列表" >&2
            echo -e "  ${gl_huang}speedtest --servers${gl_bai}" >&2
            echo "" >&2
            echo -e "  方法2：只显示附近服务器（推荐）" >&2
            echo -e "  ${gl_huang}speedtest --servers | head -n 20${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}💡 服务器列表格式说明：${gl_bai}" >&2
            echo -e "  每行开头的数字就是服务器ID" >&2
            echo -e "  例如: ${gl_huang}12345${gl_bai}) 服务商名称 (位置, 距离)" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 询问是否现在查看服务器列表
            read -e -p "是否现在查看附近的测速服务器列表？(Y/N) [Y]: " show_list
            show_list=${show_list:-Y}
            
            if [[ "$show_list" =~ ^[Yy]$ ]]; then
                echo "" >&2
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                speedtest --accept-license --servers 2>/dev/null | head -n 20 >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
            fi
            
            # 输入服务器ID
            local server_id=""
            while true; do
                read -e -p "$(echo -e "${gl_huang}请输入测速服务器ID（纯数字）: ${gl_bai}")" server_id
                
                if [[ "$server_id" =~ ^[0-9]+$ ]]; then
                    break
                else
                    echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}" >&2
                fi
            done
            
            # 使用指定服务器测速
            echo "" >&2
            echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            local speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
            echo "$speedtest_output" >&2
            echo "" >&2
            
            # 提取上传速度
            local upload_speed=""
            if echo "$speedtest_output" | grep -q "Upload:"; then
                upload_speed=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
            fi
            if [ -z "$upload_speed" ]; then
                upload_speed=$(echo "$speedtest_output" | grep -i "Upload:" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
            fi
            
            # 检查测速是否成功
            if [ -n "$upload_speed" ] && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                local upload_mbps=${upload_speed%.*}
                if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || [ "$upload_mbps" -le 0 ] 2>/dev/null; then
                    echo -e "${gl_huang}⚠️ 检测到的带宽值异常 (${upload_speed})，使用默认值 1000 Mbps${gl_bai}" >&2
                    upload_mbps=1000
                fi
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_lv}✅ 测速成功！${gl_bai}" >&2
                echo -e "${gl_lv}检测到上传带宽: ${upload_mbps} Mbps${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo "$upload_mbps"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo -e "${gl_hong}❌ 测速失败${gl_bai}" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "" >&2
                echo -e "${gl_zi}可能原因：${gl_bai}" >&2
                echo "  - 服务器ID不存在或已下线" >&2
                echo "  - 网络连接问题" >&2
                echo "  - 该服务器暂时不可用" >&2
                echo "" >&2
                
                read -e -p "是否使用默认值 1000 Mbps？(Y/N) [Y]: " use_default
                use_default=${use_default:-Y}
                
                if [[ "$use_default" =~ ^[Yy]$ ]]; then
                    echo "" >&2
                    echo -e "${gl_lv}✅ 使用默认配置: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                else
                    echo "" >&2
                    echo -e "${gl_zi}请手动输入带宽值${gl_bai}" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入上传带宽（单位：Mbps，如 500、1000、2000）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的数字${gl_bai}" >&2
                        fi
                    done
                fi
            fi
            ;;
        3)
            # 手动选择预设档位
            echo "" >&2
            echo -e "${gl_kjlan}=== 手动选择带宽档位 ===${gl_bai}" >&2
            echo "" >&2
            echo "请选择带宽档位：" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            echo -e "${gl_huang}【小带宽 VPS】${gl_bai}" >&2
            echo "1. 100 Mbps   (NAT/极小带宽)" >&2
            echo "2. 200 Mbps   (小型VPS)" >&2
            echo "3. 300 Mbps   (入门服务器)" >&2
            echo "" >&2
            echo -e "${gl_huang}【中等带宽】${gl_bai}" >&2
            echo "4. 500 Mbps   (标准小带宽)" >&2
            echo "5. 700 Mbps   (准千兆)" >&2
            echo "6. 1 Gbps ⭐  (标准VPS/最常见)" >&2
            echo "" >&2
            echo -e "${gl_huang}【高带宽服务器】${gl_bai}" >&2
            echo "7. 1.5 Gbps   (中高端VPS)" >&2
            echo "8. 2 Gbps     (高性能VPS)" >&2
            echo "9. 2.5 Gbps   (准万兆)" >&2
            echo "" >&2
            echo -e "${gl_zi}提示: 缓冲区大小将根据后续选择的地区自动计算${gl_bai}" >&2
            echo "" >&2
            echo -e "${gl_zi}【其他选项】${gl_bai}" >&2
            echo "10. 自定义输入（手动指定任意带宽值）" >&2
            echo "0. 返回上级菜单" >&2
            echo "" >&2
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
            echo "" >&2
            
            # 读取用户选择
            local preset_choice=""
            read -e -p "请输入选择 [6]: " preset_choice
            preset_choice=${preset_choice:-6}  # 默认选择6 (1 Gbps)
            
            case "$preset_choice" in
                1)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 100 Mbps${gl_bai}" >&2
                    echo "100"
                    return 0
                    ;;
                2)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 200 Mbps${gl_bai}" >&2
                    echo "200"
                    return 0
                    ;;
                3)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 300 Mbps${gl_bai}" >&2
                    echo "300"
                    return 0
                    ;;
                4)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 500 Mbps${gl_bai}" >&2
                    echo "500"
                    return 0
                    ;;
                5)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 700 Mbps${gl_bai}" >&2
                    echo "700"
                    return 0
                    ;;
                6)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 0
                    ;;
                7)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 1500 Mbps${gl_bai}" >&2
                    echo "1500"
                    return 0
                    ;;
                8)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2000 Mbps${gl_bai}" >&2
                    echo "2000"
                    return 0
                    ;;
                9)
                    echo "" >&2
                    echo -e "${gl_lv}✅ 已选择: 2500 Mbps${gl_bai}" >&2
                    echo "2500"
                    return 0
                    ;;
                10)
                    # 自定义输入
                    echo "" >&2
                    echo -e "${gl_zi}=== 自定义输入 ===${gl_bai}" >&2
                    echo "" >&2
                    local manual_bandwidth=""
                    while true; do
                        read -e -p "请输入带宽值（单位：Mbps，如 750、1200）: " manual_bandwidth
                        if [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && [ "$manual_bandwidth" -gt 0 ]; then
                            echo "" >&2
                            echo -e "${gl_lv}✅ 使用自定义值: ${manual_bandwidth} Mbps${gl_bai}" >&2
                            echo "$manual_bandwidth"
                            return 0
                        else
                            echo -e "${gl_hong}❌ 请输入有效的正整数${gl_bai}" >&2
                        fi
                    done
                    ;;
                0)
                    # 返回上级菜单
                    echo "" >&2
                    echo -e "${gl_huang}已取消选择，返回上级菜单${gl_bai}" >&2
                    echo "1000"  # 返回默认值，避免空值
                    return 1
                    ;;
                *)
                    echo "" >&2
                    echo -e "${gl_hong}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
                    echo "1000"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo -e "${gl_huang}无效选择，使用默认值 1000 Mbps${gl_bai}" >&2
            echo "1000"
            return 1
            ;;
    esac
}

# 缓冲区大小计算函数
calculate_buffer_size() {
    local bandwidth=$1
    local region=${2:-asia}  # asia（亚太）或 overseas（美欧）
    local buffer_mb
    local bandwidth_level

    # 输入验证：确保 bandwidth 是正整数
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ] 2>/dev/null; then
        local fallback_mb=16
        [ "$region" = "overseas" ] && fallback_mb=64
        echo -e "${gl_huang}⚠️ 带宽值无效 (${bandwidth})，使用默认值 ${fallback_mb}MB${gl_bai}" >&2
        echo "$fallback_mb"
        return 0
    fi

    if [ "$region" = "overseas" ]; then
        # ===== 美国/欧洲档位（RTT ~200ms，buffer ≈ BDP × 2.5，上限 64MB）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（100 Mbps·远距离）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（200 Mbps·远距离）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（300 Mbps·远距离）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=32
            bandwidth_level="预设档位（500 Mbps·远距离）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=48
            bandwidth_level="预设档位（700 Mbps·远距离）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1 Gbps·远距离）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1.5 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2.5 Gbps·远距离）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=16
            bandwidth_level="小带宽（< 500 Mbps·远距离）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=48
            bandwidth_level="中等带宽（500-1000 Mbps·远距离）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=64
            bandwidth_level="标准带宽（1-2 Gbps·远距离）"
        else
            buffer_mb=64
            bandwidth_level="高带宽（> 2 Gbps·远距离）"
        fi
    else
        # ===== 亚太地区档位（RTT ~50ms，原有逻辑不变）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=6
            bandwidth_level="预设档位（100 Mbps）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（200 Mbps）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=10
            bandwidth_level="预设档位（300 Mbps）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=12
            bandwidth_level="预设档位（500 Mbps）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=14
            bandwidth_level="预设档位（700 Mbps）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（1 Gbps）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（1.5 Gbps）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=24
            bandwidth_level="预设档位（2 Gbps）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=28
            bandwidth_level="预设档位（2.5 Gbps）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=8
            bandwidth_level="小带宽（< 500 Mbps）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=12
            bandwidth_level="中等带宽（500-1000 Mbps）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=16
            bandwidth_level="标准带宽（1-2 Gbps）"
        elif [ "$bandwidth" -lt 5000 ]; then
            buffer_mb=24
            bandwidth_level="高带宽（2-5 Gbps）"
        elif [ "$bandwidth" -lt 10000 ]; then
            buffer_mb=28
            bandwidth_level="超高带宽（5-10 Gbps）"
        else
            buffer_mb=32
            bandwidth_level="极高带宽（> 10 Gbps）"
        fi
    fi

    # 显示计算结果（输出到stderr）
    local region_label="亚太地区"
    [ "$region" = "overseas" ] && region_label="美国/欧洲"
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽和地区计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  服务地区: ${gl_huang}${region_label}${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    # 询问确认
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
        confirm=${confirm:-Y}
    fi

    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            local default_mb=16
            [ "$region" = "overseas" ] && default_mb=32
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 ${default_mb}MB${gl_bai}" >&2
            echo "$default_mb"
            return 1
            ;;
    esac
}

#=============================================================================
# SWAP智能检测和建议函数（集成到选项2/3）
#=============================================================================
check_and_suggest_swap() {
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local swap_total=$(free -m | awk 'NR==3{print $2}')
    local recommended_swap
    local need_swap=0
    
    # 判断是否需要SWAP
    if [ "$mem_total" -lt 2048 ]; then
        # 小于2GB内存，强烈建议配置SWAP
        need_swap=1
    elif [ "$mem_total" -lt 4096 ] && [ "$swap_total" -eq 0 ]; then
        # 2-4GB内存且没有SWAP，建议配置
        need_swap=1
    fi
    
    # 如果不需要SWAP，直接返回
    if [ "$need_swap" -eq 0 ]; then
        return 0
    fi
    
    # 计算推荐的SWAP大小
    if [ "$mem_total" -lt 512 ]; then
        recommended_swap=1024
    elif [ "$mem_total" -lt 1024 ]; then
        recommended_swap=$((mem_total * 2))
    elif [ "$mem_total" -lt 2048 ]; then
        recommended_swap=$((mem_total * 3 / 2))
    elif [ "$mem_total" -lt 4096 ]; then
        recommended_swap=$mem_total
    else
        recommended_swap=4096
    fi
    
    # 显示建议信息
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_huang}检测到虚拟内存（SWAP）需要优化${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "  物理内存:       ${gl_huang}${mem_total}MB${gl_bai}"
    echo -e "  当前 SWAP:      ${gl_huang}${swap_total}MB${gl_bai}"
    echo -e "  推荐 SWAP:      ${gl_lv}${recommended_swap}MB${gl_bai}"
    echo ""
    
    if [ "$mem_total" -lt 1024 ]; then
        echo -e "${gl_zi}原因: 小内存机器（<1GB）强烈建议配置SWAP，避免内存不足导致程序崩溃${gl_bai}"
    elif [ "$mem_total" -lt 2048 ]; then
        echo -e "${gl_zi}原因: 1-2GB内存建议配置SWAP，提供缓冲空间${gl_bai}"
    elif [ "$mem_total" -lt 4096 ]; then
        echo -e "${gl_zi}原因: 2-4GB内存建议配置少量SWAP作为保险${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 询问用户
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否现在配置虚拟内存？(Y/N): ${gl_bai}")" confirm
    fi

    case "$confirm" in
        [Yy])
            echo ""
            echo -e "${gl_lv}开始配置虚拟内存...${gl_bai}"
            echo ""
            add_swap "$recommended_swap"
            echo ""
            echo -e "${gl_lv}✅ 虚拟内存配置完成！${gl_bai}"
            echo ""
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            sleep 2
            return 0
            ;;
        [Nn])
            echo ""
            echo -e "${gl_huang}已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
        *)
            echo ""
            echo -e "${gl_huang}输入无效，已跳过虚拟内存配置${gl_bai}"
            echo -e "${gl_zi}继续执行 BBR 优化配置...${gl_bai}"
            echo ""
            sleep 2
            return 1
            ;;
    esac
}

#=============================================================================
# 配置冲突检测与清理（避免被其他 sysctl 覆盖）
#=============================================================================
check_and_clean_conflicts() {
    echo -e "${gl_kjlan}=== 检查 sysctl 配置冲突 ===${gl_bai}"
    local conflicts=()
    # 搜索 /etc/sysctl.d/ 下可能覆盖 tcp_rmem/tcp_wmem 的高序号文件
    for conf in /etc/sysctl.d/[0-9]*-*.conf; do
        [ -f "$conf" ] || continue
        [ "$conf" = "$SYSCTL_CONF" ] && continue
        if grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" "$conf" 2>/dev/null; then
            base=$(basename "$conf")
            num=$(echo "$base" | sed -n 's/^\([0-9]\+\).*/\1/p')
            # 99 及以上优先生效，可能覆盖本脚本
            if [ -n "$num" ] && [ "$num" -ge 99 ]; then
                conflicts+=("$conf")
            fi
        fi
    done

    # 主配置文件直接设置也会覆盖
    local has_sysctl_conflict=0
    if [ -f /etc/sysctl.conf ] && grep -qE "(^|\s)net\.ipv4\.tcp_(rmem|wmem)" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [ ${#conflicts[@]} -eq 0 ] && [ $has_sysctl_conflict -eq 0 ]; then
        echo -e "${gl_lv}✓ 未发现可能的覆盖配置${gl_bai}"
        return 0
    fi

    echo -e "${gl_huang}发现可能的覆盖配置：${gl_bai}"
    for f in "${conflicts[@]}"; do
        echo "  - $f"; grep -E "net\.ipv4\.tcp_(rmem|wmem)" "$f" | sed 's/^/      /'
    done
    [ $has_sysctl_conflict -eq 1 ] && echo "  - /etc/sysctl.conf (含 tcp_rmem/tcp_wmem)"

    if [ "$AUTO_MODE" = "1" ]; then
        ans=Y
    else
        read -e -p "是否自动禁用/注释这些覆盖配置？(Y/N): " ans
    fi
    case "$ans" in
        [Yy])
            # 注释 /etc/sysctl.conf 中相关行
            if [ $has_sysctl_conflict -eq 1 ]; then
                # 先创建一次备份，再用 sed -i 逐行注释（避免多次 .bak 覆盖）
                cp /etc/sysctl.conf /etc/sysctl.conf.bak.conflict 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_wmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.ipv4\.tcp_rmem/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.rmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                sed -i '/^net\.core\.wmem_max/s/^/# /' /etc/sysctl.conf 2>/dev/null
                echo -e "${gl_lv}✓ 已注释 /etc/sysctl.conf 中的相关配置（备份: .bak.conflict）${gl_bai}"
            fi
            # 将高优先级冲突文件重命名禁用
            for f in "${conflicts[@]}"; do
                if [ ! -f "$f" ]; then
                    echo -e "${gl_lv}✓ 已跳过: $(basename "$f")（已处理）${gl_bai}"
                    continue
                fi
                if mv "$f" "${f}.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
                    echo -e "${gl_lv}✓ 已禁用: $(basename "$f")${gl_bai}"
                else
                    echo -e "${gl_hong}✗ 无法禁用: $(basename "$f")，请手动处理${gl_bai}"
                fi
            done
            ;;
        *)
            echo -e "${gl_huang}已跳过自动清理，可能导致新配置未完全生效${gl_bai}"
            ;;
    esac
}

#=============================================================================
# 立即生效与防分片函数（无需重启）
#=============================================================================

# 获取需应用 qdisc 的网卡（排除常见虚拟接口）
eligible_ifaces() {
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        echo "$dev"
    done
}

# tc fq 立即生效（无需重启）
apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 tc（iproute2），跳过 fq 应用${gl_bai}"
        return 0
    fi
    local applied=0
    for dev in $(eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied+1))
    done
    [ $applied -gt 0 ] && echo -e "${gl_lv}已对 $applied 个网卡应用 fq（即时生效）${gl_bai}" || echo -e "${gl_huang}未发现可应用 fq 的网卡${gl_bai}"
}

# MSS clamp（防分片）自动启用
apply_mss_clamp() {
    local action=$1  # enable|disable
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${gl_huang}警告: 未检测到 iptables，跳过 MSS clamp${gl_bai}"
        return 0
    fi
    if [ "$action" = "enable" ]; then
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
          || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    else
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    fi
}

#=============================================================================
# BBR 配置函数（智能检测版）
#=============================================================================

# 直连/落地优化配置
bbr_configure_direct() {
    echo -e "${gl_kjlan}=== 配置 BBR v3 + FQ 直连/落地优化（智能检测版） ===${gl_bai}"
    echo ""
    
    # 步骤 0：SWAP智能检测和建议
    echo -e "${gl_zi}[步骤 1/6] 检测虚拟内存（SWAP）配置...${gl_bai}"
    check_and_suggest_swap
    
    # 步骤 0.5：带宽检测和缓冲区计算
    echo ""
    echo -e "${gl_zi}[步骤 2/6] 检测服务器带宽并计算最优缓冲区...${gl_bai}"

    local detected_bandwidth=$(detect_bandwidth)

    # 地区选择（影响缓冲区大小：高延迟地区需要更大缓冲区）
    local region="asia"
    local region_choice=""
    echo ""
    echo -e "${gl_kjlan}请选择服务器主要服务的地区：${gl_bai}"
    echo ""
    echo "1. 亚太地区（港/日/新/韩等）⭐ 推荐"
    echo "   延迟较低（RTT < 100ms），使用标准缓冲区"
    echo ""
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    echo "   延迟较高（RTT 150-300ms），使用大缓冲区"
    echo ""
    read -e -p "请输入选择 [1]: " region_choice
    region_choice=${region_choice:-1}
    case "$region_choice" in
        2) region="overseas" ;;
        *) region="asia" ;;
    esac

    local buffer_mb=$(calculate_buffer_size "$detected_bandwidth" "$region")
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    
    echo -e "${gl_lv}✅ 将使用 ${buffer_mb}MB 缓冲区配置${gl_bai}"
    sleep 2
    
    echo ""
    echo -e "${gl_zi}[步骤 3/6] 清理配置冲突...${gl_bai}"
    echo "正在检查配置冲突..."
    
    # 备份主配置文件（如果还没备份）
    if [ -f /etc/sysctl.conf ] && ! [ -f /etc/sysctl.conf.bak.original ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.original
        echo "已备份: /etc/sysctl.conf -> /etc/sysctl.conf.bak.original"
    fi
    
    # 注释掉 /etc/sysctl.conf 中的 TCP 缓冲区配置（避免覆盖）
    if [ -f /etc/sysctl.conf ]; then
        clean_sysctl_conf
        echo "已清理 /etc/sysctl.conf 中的冲突配置"
    fi
    
    # 删除可能存在的软链接
    if [ -L /etc/sysctl.d/99-sysctl.conf ]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
        echo "已删除配置软链接"
    fi
    
    # 检查并清理可能覆盖的新旧配置冲突
    check_and_clean_conflicts

    # 步骤 3：创建独立配置文件（使用动态缓冲区）
    echo ""
    echo -e "${gl_zi}[步骤 4/6] 创建配置文件...${gl_bai}"
    echo "正在创建新配置..."
    
    # 获取物理内存用于虚拟内存参数调整
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local vm_swappiness=5
    local vm_dirty_ratio=15
    local vm_min_free_kbytes=65536
    
    # 根据内存大小微调虚拟内存参数
    if [ "$mem_total" -lt 2048 ]; then
        vm_swappiness=20
        vm_dirty_ratio=20
        vm_min_free_kbytes=32768
    fi
    
    cat > "$SYSCTL_CONF" << EOF
# BBR v3 Direct/Endpoint Configuration (Intelligent Detection Edition)
# Generated on $(date)
# Bandwidth: ${detected_bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB

# 队列调度算法
net.core.default_qdisc=fq

# 拥塞控制算法
net.ipv4.tcp_congestion_control=bbr

# TCP 缓冲区优化（智能检测：${buffer_mb}MB）
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}

# ===== 直连/落地优化参数 =====

# TIME_WAIT 重用（启用，提高并发）
net.ipv4.tcp_tw_reuse=1

# 端口范围（最大化）
net.ipv4.ip_local_port_range=1024 65535

# 连接队列（高性能）
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192

# 网络队列（高带宽优化）
net.core.netdev_max_backlog=5000

# 高级TCP优化
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# ===== Reality终极优化参数 =====

# 发送低水位（上传速度优化关键）
net.ipv4.tcp_notsent_lowat=16384

# 连接回收优化
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=5000

# TCP Fast Open（节省1个RTT，加速连接建立）
net.ipv4.tcp_fastopen=3

# TCP保活优化（更快检测死连接）
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# UDP缓冲区（QUIC/Hysteria 支持）
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP安全增强
net.ipv4.tcp_syncookies=1

# 虚拟内存优化（根据物理内存调整）
vm.swappiness=${vm_swappiness}
vm.dirty_ratio=${vm_dirty_ratio}
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=${vm_min_free_kbytes}
vm.vfs_cache_pressure=50

# CPU调度优化
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF

    # 检查配置文件是否创建成功
    if [ ! -f "$SYSCTL_CONF" ] || [ ! -s "$SYSCTL_CONF" ]; then
        echo -e "${gl_hong}❌ 配置文件创建失败！请检查磁盘空间和权限${gl_bai}"
        return 1
    fi

    # 步骤 4：应用配置
    echo ""
    echo -e "${gl_zi}[步骤 5/6] 应用所有优化参数...${gl_bai}"
    echo "正在应用配置..."
    local sysctl_output
    sysctl_output=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local sysctl_rc=$?
    if [ $sysctl_rc -ne 0 ]; then
        echo -e "${gl_huang}⚠️ sysctl 部分参数应用失败（可能有不支持的参数）:${gl_bai}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -5
        echo -e "${gl_zi}已支持的参数仍然生效，不影响整体优化${gl_bai}"
    else
        echo -e "${gl_lv}✓ 所有 sysctl 参数已成功应用${gl_bai}"
    fi

    # 立即应用 fq，并启用 MSS clamp（无需重启）
    echo "正在应用队列与防分片（无需重启）..."
    apply_tc_fq_now >/dev/null 2>&1
    apply_mss_clamp enable >/dev/null 2>&1

    # 持久化 tc fq 和 iptables MSS clamp（重启后自动恢复）
    echo "正在配置重启持久化..."
    # 创建 systemd 服务实现 tc fq + MSS clamp 开机恢复
    cat > /etc/systemd/system/bbr-optimize-persist.service << 'PERSISTEOF'
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
PERSISTEOF

    cat > /usr/local/bin/bbr-optimize-apply.sh << 'APPLYEOF'
#!/bin/bash
# BBR Optimize 重启恢复脚本 - 自动生成，勿手动编辑
# 应用 tc fq 到所有物理网卡
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null
done
# 应用 iptables MSS clamp
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
# 禁用透明大页
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
fi
# 优化 TCP 初始拥塞窗口（加速连接起步）
DEF_ROUTE=$(ip route show default 2>/dev/null | head -1)
if [ -n "$DEF_ROUTE" ]; then
    CLEAN_ROUTE=$(echo "$DEF_ROUTE" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $CLEAN_ROUTE initcwnd 32 initrwnd 32 2>/dev/null
fi
# RPS/RFS 多核网络优化（遍历所有物理网卡）
CPU_COUNT=$(nproc 2>/dev/null || echo 1)
if [ "$CPU_COUNT" -gt 1 ]; then
    RPS_MASK=$(printf '%x' $((2**CPU_COUNT - 1)))
    FLOW_ENTRIES=$((4096 * CPU_COUNT))
    echo "$FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for D in /sys/class/net/*; do
        [ -e "$D" ] || continue
        DEV=$(basename "$D")
        case "$DEV" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
        esac
        [ -d "/sys/class/net/$DEV/queues" ] || continue
        for RXQ in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do
            [ -f "$RXQ" ] && echo "$RPS_MASK" > "$RXQ" 2>/dev/null
        done
        for RXQ_DIR in /sys/class/net/$DEV/queues/rx-*/; do
            [ -f "${RXQ_DIR}rps_flow_cnt" ] && echo "$((FLOW_ENTRIES / CPU_COUNT))" > "${RXQ_DIR}rps_flow_cnt" 2>/dev/null
        done
    done
fi
APPLYEOF
    chmod +x /usr/local/bin/bbr-optimize-apply.sh
    systemctl daemon-reload 2>/dev/null
    systemctl enable bbr-optimize-persist.service 2>/dev/null
    echo -e "${gl_lv}✓ tc fq / MSS clamp / 透明大页 重启持久化已配置${gl_bai}"

    # 配置文件描述符限制
    echo "正在优化文件描述符限制..."
    if ! grep -q "^\* soft nofile 524288" /etc/security/limits.conf 2>/dev/null && \
       ! grep -q "BBR - 文件描述符优化" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITSEOF'
# BBR - 文件描述符优化
* soft nofile 524288
* hard nofile 524288
LIMITSEOF
    fi
    ulimit -n 524288 2>/dev/null

    # 禁用透明大页面（当前运行时）
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    # 优化 TCP 初始拥塞窗口（加速连接起步，节省1-2个RTT）
    echo "正在优化 TCP 初始拥塞窗口..."
    local def_route
    def_route=$(ip route show default 2>/dev/null | head -1)
    if [ -n "$def_route" ]; then
        # 清除已有的 initcwnd/initrwnd 再重新设置，避免重复
        local clean_route
        clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
        if ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null; then
            echo -e "${gl_lv}✓ initcwnd=32 initrwnd=32 已应用（加速 TCP 连接起步）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ initcwnd 设置失败（不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_huang}⚠️ 未检测到默认路由，跳过 initcwnd 优化${gl_bai}"
    fi

    # RPS/RFS 多核网络优化（将网卡收包分散到所有 CPU 核心）
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    if [ "$cpu_count" -gt 1 ]; then
        echo "正在配置 RPS/RFS 多核网络优化..."
        # 计算 CPU 掩码（所有核心参与）：2核=3, 4核=f, 8核=ff
        local rps_mask
        rps_mask=$(printf '%x' $((2**cpu_count - 1)))
        local flow_entries=$((4096 * cpu_count))
        echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        # 遍历所有物理网卡（排除虚拟/隧道接口）
        local rps_ok=0
        local rps_devs=""
        local dev
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            dev=$(basename "$d")
            case "$dev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -d "/sys/class/net/$dev/queues" ] || continue
            # 设置 RPS：将收包分散到所有核心
            for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
                if [ -f "$rxq" ]; then
                    echo "$rps_mask" > "$rxq" 2>/dev/null
                    # 写入后读回验证（有些环境 echo 返回0但内核没接受）
                    local verify_val
                    verify_val=$(cat "$rxq" 2>/dev/null | tr -d ',' | sed 's/^0*//')
                    [ -z "$verify_val" ] && verify_val="0"
                    [ "$verify_val" = "$rps_mask" ] && rps_ok=1
                fi
            done
            # 设置 RFS：同一连接的包尽量在同一核处理（减少 cache miss）
            for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
                if [ -f "${rxq_dir}rps_flow_cnt" ]; then
                    echo "$((flow_entries / cpu_count))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null
                fi
            done
            rps_devs="${rps_devs} ${dev}"
        done
        if [ $rps_ok -eq 1 ]; then
            echo -e "${gl_lv}✓ RPS/RFS 已启用（${cpu_count} 核，掩码: 0x${rps_mask}，网卡:${rps_devs}）${gl_bai}"
        else
            echo -e "${gl_huang}⚠️ RPS 设置未生效（当前虚拟化环境可能不支持，不影响其他优化）${gl_bai}"
        fi
    else
        echo -e "${gl_zi}ℹ 单核 CPU，跳过 RPS/RFS（单核无需分担）${gl_bai}"
    fi

    # 步骤 5：验证配置是否真正生效
    echo ""
    echo -e "${gl_zi}[步骤 6/6] 验证配置...${gl_bai}"
    
    local actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local actual_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    local actual_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    
    echo ""
    echo -e "${gl_kjlan}=== 配置验证 ===${gl_bai}"
    
    # 验证队列算法
    if [ "$actual_qdisc" = "fq" ]; then
        echo -e "队列算法: ${gl_lv}$actual_qdisc ✓${gl_bai}"
    else
        echo -e "队列算法: ${gl_huang}$actual_qdisc (期望: fq) ⚠${gl_bai}"
    fi
    
    # 验证拥塞控制
    if [ "$actual_cc" = "bbr" ]; then
        echo -e "拥塞控制: ${gl_lv}$actual_cc ✓${gl_bai}"
    else
        echo -e "拥塞控制: ${gl_huang}$actual_cc (期望: bbr) ⚠${gl_bai}"
    fi
    
    # 验证缓冲区（动态）
    local actual_wmem_mb=$((actual_wmem / 1048576))
    local actual_rmem_mb=$((actual_rmem / 1048576))
    
    if [ "$actual_wmem" = "$buffer_bytes" ]; then
        echo -e "发送缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "发送缓冲区: ${gl_huang}${actual_wmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi
    
    if [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "接收缓冲区: ${gl_lv}${buffer_mb}MB ✓${gl_bai}"
    else
        echo -e "接收缓冲区: ${gl_huang}${actual_rmem_mb}MB (期望: ${buffer_mb}MB) ⚠${gl_bai}"
    fi

    # 验证 initcwnd
    local actual_initcwnd
    actual_initcwnd=$(ip route show default 2>/dev/null | head -1 | grep -oP 'initcwnd \K[0-9]+')
    if [ "$actual_initcwnd" = "32" ]; then
        echo -e "初始窗口:   ${gl_lv}initcwnd=$actual_initcwnd ✓${gl_bai}"
    elif [ -n "$actual_initcwnd" ]; then
        echo -e "初始窗口:   ${gl_huang}initcwnd=$actual_initcwnd (期望: 32) ⚠${gl_bai}"
    else
        echo -e "初始窗口:   ${gl_huang}未设置 (期望: initcwnd=32) ⚠${gl_bai}"
    fi

    # 验证 RPS
    if [ "$cpu_count" -gt 1 ]; then
        local expected_mask
        expected_mask=$(printf '%x' $((2**cpu_count - 1)))
        local rps_verify_devs=""
        local rps_all_ok=1
        for d in /sys/class/net/*; do
            [ -e "$d" ] || continue
            local vdev=$(basename "$d")
            case "$vdev" in
                lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
            esac
            [ -f "/sys/class/net/$vdev/queues/rx-0/rps_cpus" ] || continue
            local rps_val
            # rps_cpus 可能返回 "3" 或 "00000003" 或 "00000000,00000003"
            rps_val=$(cat /sys/class/net/$vdev/queues/rx-0/rps_cpus 2>/dev/null | tr -d ',' | sed 's/^0*//')
            [ -z "$rps_val" ] && rps_val="0"
            if [ "$rps_val" = "$expected_mask" ]; then
                rps_verify_devs="${rps_verify_devs} ${vdev}✓"
            else
                rps_verify_devs="${rps_verify_devs} ${vdev}✗"
                rps_all_ok=0
            fi
        done
        if [ -n "$rps_verify_devs" ]; then
            if [ $rps_all_ok -eq 1 ]; then
                echo -e "RPS/RFS:    ${gl_lv}${cpu_count}核分担 (0x${expected_mask})${rps_verify_devs} ✓${gl_bai}"
            else
                echo -e "RPS/RFS:    ${gl_huang}部分网卡未生效:${rps_verify_devs} ⚠${gl_bai}"
            fi
        else
            echo -e "RPS/RFS:    ${gl_huang}未检测到物理网卡 ⚠${gl_bai}"
        fi
    else
        echo -e "RPS/RFS:    ${gl_zi}单核跳过${gl_bai}"
    fi

    echo ""

    # 最终判断
    if [ "$actual_qdisc" = "fq" ] && [ "$actual_cc" = "bbr" ] && \
       [ "$actual_wmem" = "$buffer_bytes" ] && [ "$actual_rmem" = "$buffer_bytes" ]; then
        echo -e "${gl_lv}✅ BBR v3 直连/落地优化配置完成并已生效！${gl_bai}"
        echo -e "${gl_zi}配置说明: ${buffer_mb}MB 缓冲区（${detected_bandwidth} Mbps 带宽），适合直连/落地场景${gl_bai}"
    else
        echo -e "${gl_huang}⚠️ 配置已保存但部分参数未生效${gl_bai}"
        echo -e "${gl_huang}建议执行以下操作：${gl_bai}"
        echo "1. 检查是否有其他配置文件冲突"
        echo "2. 重启服务器使配置完全生效: reboot"
    fi
}

#=============================================================================
# 状态检查函数
#=============================================================================

check_bbr_status() {
    echo -e "${gl_kjlan}=== 当前系统状态 ===${gl_bai}"
    local kernel_release
    kernel_release=$(uname -r)
    echo "内核版本: $kernel_release"
    
    local congestion="未知"
    local qdisc="未知"
    local bbr_version=""
    local bbr_active=0
    
    if command -v sysctl &>/dev/null; then
        congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        echo "拥塞控制算法: $congestion"
        echo "队列调度算法: $qdisc"
        
        if command -v modinfo &>/dev/null; then
            bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
            if [ -n "$bbr_version" ]; then
                if [ "$bbr_version" = "3" ]; then
                    echo -e "BBR 版本: ${gl_lv}v${bbr_version} ✓${gl_bai}"
                else
                    echo -e "BBR 版本: ${gl_huang}v${bbr_version} (不是 v3)${gl_bai}"
                fi
            fi
        fi
    fi
    
    if [ "$congestion" = "bbr" ] && [ "$bbr_version" = "3" ]; then
        bbr_active=1
    fi
    
    local xanmod_pkg_installed=0
    local dpkg_available=0
    if command -v dpkg &>/dev/null; then
        dpkg_available=1
        if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
            xanmod_pkg_installed=1
        fi
    fi
    
    local xanmod_running=0
    if echo "$kernel_release" | grep -qi 'xanmod'; then
        xanmod_running=1
    fi
    
    local status=1
    
    if [ $xanmod_pkg_installed -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_lv}已安装 ✓${gl_bai}"
        status=0
    elif [ $xanmod_running -eq 1 ]; then
        echo -e "XanMod 内核: ${gl_huang}内核包已卸载，但当前运行版本仍为 ${kernel_release}，请重启系统使卸载完全生效${gl_bai}"
    else
        echo -e "XanMod 内核: ${gl_huang}未安装${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $bbr_active -eq 1 ]; then
        echo -e "${gl_kjlan}提示: 当前仍在运行 BBR v3 模块，重启后将恢复系统默认配置${gl_bai}"
    fi
    
    if [ $status -ne 0 ] && [ $dpkg_available -eq 0 ]; then
        # 非 Debian 系统：仅当内核名确实含 xanmod 时才认为已安装
        # BBR v3 活跃不等于 XanMod（用户可能自编译内核），避免误触发 update 流程
        if [ $xanmod_running -eq 1 ]; then
            status=0
        fi
    fi
    
    return $status
}

#=============================================================================
# XanMod 内核安装（官方源）
#=============================================================================

get_xanmod_codename() {
    local os_id="" version_id="" version_codename=""

    if [ ! -r /etc/os-release ]; then
        echo -e "${gl_hong}错误: 无法读取 /etc/os-release，无法确定 XanMod APT 源版本${gl_bai}" >&2
        return 1
    fi

    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    version_codename="${VERSION_CODENAME:-}"

    case "$os_id" in
        debian)
            case "$version_id" in
                12*) version_codename="bookworm" ;;
                13*) version_codename="trixie" ;;
            esac
            ;;
        ubuntu)
            # Ubuntu 使用系统自身 VERSION_CODENAME
            ;;
        *)
            echo -e "${gl_hong}错误: 仅支持 Debian 和 Ubuntu 系统${gl_bai}" >&2
            return 1
            ;;
    esac

    if [ -z "$version_codename" ]; then
        echo -e "${gl_hong}错误: 未能从 /etc/os-release 读取 VERSION_CODENAME${gl_bai}" >&2
        echo "请检查当前 Debian/Ubuntu 版本是否受 XanMod APT 源支持" >&2
        return 1
    fi

    echo "$version_codename"
}

write_xanmod_apt_source() {
    local gpg_key_file="$1"
    local xanmod_repo_file="$2"
    local version_codename

    version_codename=$(get_xanmod_codename) || return 1
    echo "检测到 XanMod APT 源代号: ${version_codename}"
    echo "deb [signed-by=${gpg_key_file}] http://deb.xanmod.org ${version_codename} main" | \
        tee "$xanmod_repo_file" > /dev/null
}

detect_x64_level() {
    local cpu_arch
    cpu_arch=$(uname -m)

    if [ "$cpu_arch" != "x86_64" ]; then
        echo "unknown"
        return 1
    fi

    local cpu_flags
    cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)

    if [ -z "$cpu_flags" ]; then
        echo "1"
        return 0
    fi

    has_cpu_flags() {
        local required_flag
        for required_flag in "$@"; do
            if ! echo "$cpu_flags" | grep -qw "$required_flag"; then
                return 1
            fi
        done
        return 0
    }

    if has_cpu_flags avx512f avx512bw avx512cd avx512dq avx512vl; then
        echo "4"
    elif has_cpu_flags avx avx2 bmi1 bmi2 fma movbe xsave; then
        echo "3"
    elif has_cpu_flags cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; then
        echo "2"
    else
        echo "1"
    fi

    unset -f has_cpu_flags >/dev/null 2>&1 || true
}

xanmod_candidate_list_for_cpu() {
    local cpu_level="$1"

    case "$cpu_level" in
        4)
            printf '%s\n' \
                linux-xanmod-lts-x64v4 linux-xanmod-x64v4 \
                linux-xanmod-lts-x64v3 linux-xanmod-x64v3 \
                linux-xanmod-lts-x64v2 linux-xanmod-x64v2 \
                linux-xanmod-lts-x64v1 linux-xanmod-x64v1
            ;;
        3)
            printf '%s\n' \
                linux-xanmod-lts-x64v3 linux-xanmod-x64v3 \
                linux-xanmod-lts-x64v2 linux-xanmod-x64v2 \
                linux-xanmod-lts-x64v1 linux-xanmod-x64v1
            ;;
        2)
            printf '%s\n' \
                linux-xanmod-lts-x64v2 linux-xanmod-x64v2 \
                linux-xanmod-lts-x64v1 linux-xanmod-x64v1
            ;;
        *)
            printf '%s\n' \
                linux-xanmod-lts-x64v1 linux-xanmod-x64v1
            ;;
    esac
}

select_xanmod_package() {
    local cpu_level="$1"
    local available_packages=""
    local candidate=""
    local candidate_packages=""

    if ! [[ "$cpu_level" =~ ^[1-4]$ ]]; then
        cpu_level="1"
    fi

    available_packages=$(apt-cache search '^linux-xanmod' 2>/dev/null | awk '{print $1}' | sort -u)

    if [ -z "$available_packages" ]; then
        echo -e "${gl_hong}错误: 未从 XanMod APT 源找到任何 linux-xanmod 包${gl_bai}" >&2
        echo "请检查 Debian/Ubuntu 版本、/etc/os-release 中的 VERSION_CODENAME，以及 XanMod APT 源是否可用。" >&2
        echo "当前 apt-cache search '^linux-xanmod' 无结果。" >&2
        return 1
    fi

    candidate_packages=$(xanmod_candidate_list_for_cpu "$cpu_level")

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if echo "$available_packages" | grep -qx "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done <<< "$candidate_packages"

    echo -e "${gl_hong}错误: 未找到适合当前 CPU 等级 x86-64-v${cpu_level} 的 linux-xanmod 包${gl_bai}" >&2
    echo "请检查 Debian/Ubuntu 版本、XanMod APT 源，以及仓库中可用的 linux-xanmod 包名。" >&2
    echo "" >&2
    echo "按当前 CPU level 允许选择的包:" >&2
    echo "$candidate_packages" | sed 's/^/  - /' >&2
    echo "" >&2
    echo "当前 apt-cache search '^linux-xanmod' 可见包:" >&2
    echo "$available_packages" | sed 's/^/  - /' >&2
    return 1
}

tcp_port_reachable() {
    local host="$1"
    local port="$2"

    if command -v timeout >/dev/null 2>&1; then
        timeout 4 bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1
    else
        bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1
    fi
}

detect_virtualization_type() {
    local virt_type="unknown"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [ -f /proc/user_beancounters ] || [ -d /proc/vz ]; then
        virt_type="openvz"
    elif grep -qaE 'docker|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        virt_type="docker"
    fi

    case "$virt_type" in
        kvm) echo "KVM" ;;
        vmware) echo "VMware" ;;
        microsoft) echo "Hyper-V" ;;
        lxc) echo "LXC" ;;
        openvz) echo "OpenVZ" ;;
        docker|podman|container) echo "Docker" ;;
        none|"") echo "unknown" ;;
        *) echo "$virt_type" ;;
    esac
}

is_bbr_v3_active() {
    local current_cc=""
    local bbr_version=""

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    bbr_version=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}' | head -1)

    [ "$current_cc" = "bbr" ] && [ "$bbr_version" = "3" ]
}

show_environment_precheck() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}   环境预检 / 兼容性检查（只读，不修改系统）${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local os_id="unknown" version_id="unknown" version_codename="unknown" pretty_name="unknown"
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID:-unknown}"
        version_id="${VERSION_ID:-unknown}"
        version_codename="${VERSION_CODENAME:-unknown}"
        pretty_name="${PRETTY_NAME:-unknown}"
    fi

    local cpu_arch
    cpu_arch=$(uname -m)
    local cpu_level
    cpu_level=$(detect_x64_level 2>/dev/null || echo "unknown")
    if [[ "$cpu_level" =~ ^[1-4]$ ]]; then
        cpu_level="x64v${cpu_level}"
    else
        cpu_level="unknown"
    fi

    local virt_type
    virt_type=$(detect_virtualization_type)
    local is_root="否"
    [ "${EUID:-$(id -u)}" -eq 0 ] && is_root="是"
    local has_systemd="否"
    [ -d /run/systemd/system ] && has_systemd="是"
    local has_systemctl="否"
    command -v systemctl >/dev/null 2>&1 && has_systemctl="是"

    local kernel_version
    kernel_version=$(uname -r)
    local current_cc current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")

    local xanmod_installed="否"
    if uname -r | grep -qi xanmod || dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q xanmod; then
        xanmod_installed="是"
    fi

    local bbr_v3="否"
    is_bbr_v3_active && bbr_v3="是"

    local grub_exists="否"
    if [ -d /boot/grub ] || command -v update-grub >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1; then
        grub_exists="是"
    fi

    local old_kernel_status="未知"
    if command -v dpkg-query >/dev/null 2>&1; then
        local kernel_count
        kernel_count=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null | grep -E '^linux-image-[0-9]|^linux-image-(amd64|cloud-amd64|generic)' | wc -l | tr -d ' ')
        if [ "${kernel_count:-0}" -gt 1 ]; then
            old_kernel_status="存在多个内核包（${kernel_count} 个）"
        elif [ "${kernel_count:-0}" -eq 1 ]; then
            old_kernel_status="仅检测到 1 个内核包"
        else
            old_kernel_status="未检测到 dpkg 内核包"
        fi
    fi

    local xanmod_codename="不可用"
    local xanmod_source_status="未检查"
    if xanmod_codename=$(get_xanmod_codename 2>/dev/null); then
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --max-time 6 "http://deb.xanmod.org/dists/${xanmod_codename}/Release" -o /dev/null 2>/dev/null; then
                xanmod_source_status="可访问"
            else
                xanmod_source_status="不可访问或被网络拦截"
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q --timeout=6 --spider "http://deb.xanmod.org/dists/${xanmod_codename}/Release" 2>/dev/null; then
                xanmod_source_status="可访问"
            else
                xanmod_source_status="不可访问或被网络拦截"
            fi
        else
            xanmod_source_status="未安装 curl/wget，无法检查"
        fi
    else
        xanmod_codename="不可用"
    fi

    local xanmod_candidates
    xanmod_candidates=$(apt-cache search '^linux-xanmod' 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    [ -z "$xanmod_candidates" ] && xanmod_candidates="当前 apt-cache 无候选（未添加源或未 apt update）"

    local dot_status="不可达"
    if tcp_port_reachable "1.1.1.1" 853 || tcp_port_reachable "8.8.8.8" 853; then
        dot_status="可达"
    fi

    local doh_status="不可达"
    if tcp_port_reachable "cloudflare-dns.com" 443 || tcp_port_reachable "dns.google" 443; then
        doh_status="可达"
    fi

    local resolv_nameservers
    resolv_nameservers=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    [ -z "$resolv_nameservers" ] && resolv_nameservers="未读取到 nameserver"

    local ipv6_state="未知"
    local ipv6_disabled
    ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
    case "$ipv6_disabled" in
        0) ipv6_state="已启用" ;;
        1) ipv6_state="已禁用" ;;
        *) ipv6_state="未知" ;;
    esac

    local swap_state="未启用"
    if swapon --show 2>/dev/null | awk 'NR>1 {found=1} END {exit !found}'; then
        swap_state="已启用"
    fi

    local disk_free
    disk_free=$(df -h / 2>/dev/null | awk 'NR==2 {print $4 " 可用 / 总计 " $2}' || echo "未知")

    echo -e "${gl_kjlan}[基础环境]${gl_bai}"
    echo "  发行版: ${pretty_name}"
    echo "  ID / VERSION_ID / CODENAME: ${os_id} / ${version_id} / ${version_codename}"
    echo "  CPU 架构: ${cpu_arch}"
    echo "  CPU level: ${cpu_level}"
    echo "  虚拟化类型: ${virt_type}"
    echo "  是否 root: ${is_root}"
    echo "  systemd: ${has_systemd}"
    echo "  systemctl: ${has_systemctl}"
    echo ""

    echo -e "${gl_kjlan}[当前网络内核状态]${gl_bai}"
    echo "  当前内核: ${kernel_version}"
    echo "  拥塞控制: ${current_cc}"
    echo "  队列算法: ${current_qdisc}"
    echo "  是否已安装/运行 XanMod: ${xanmod_installed}"
    echo "  是否 BBR v3: ${bbr_v3}"
    echo "  GRUB: ${grub_exists}"
    echo "  旧内核包: ${old_kernel_status}"
    echo ""

    echo -e "${gl_kjlan}[XanMod 源检查]${gl_bai}"
    echo "  XanMod codename: ${xanmod_codename}"
    echo "  XanMod APT 源: ${xanmod_source_status}"
    echo "  可用 linux-xanmod 候选: ${xanmod_candidates}"
    echo ""

    echo -e "${gl_kjlan}[DNS / IPv6 / 资源]${gl_bai}"
    echo "  DoT 853 连通性: ${dot_status}"
    echo "  DoH 443 连通性: ${doh_status}"
    echo "  resolv.conf nameserver: ${resolv_nameservers}"
    echo "  IPv6 当前状态: ${ipv6_state}"
    echo "  SWAP 当前状态: ${swap_state}"
    echo "  磁盘剩余空间: ${disk_free}"
    echo ""

    local conclusion="谨慎：只建议 TCP/sysctl 调优，不建议换内核"
    if echo "$virt_type" | grep -Eq 'LXC|OpenVZ|Docker'; then
        conclusion="不支持：容器/OpenVZ/LXC 环境通常不能自行更换内核"
    elif [ "$has_systemd" != "是" ] || [ "$has_systemctl" != "是" ]; then
        conclusion="谨慎：非完整 systemd 环境，DNS 净化和服务持久化可能不可用"
    elif [ "$cpu_arch" = "x86_64" ] && [[ "$os_id" =~ ^(debian|ubuntu)$ ]]; then
        conclusion="推荐：适合完整安装 XanMod + BBR v3，并执行 TCP 调优"
    elif [ "$cpu_arch" = "aarch64" ] && [[ "$os_id" =~ ^(debian|ubuntu)$ ]]; then
        conclusion="谨慎：ARM64 仅实验/部分支持，建议先确认内核安装脚本兼容性"
    fi

    echo -e "${gl_kjlan}[兼容性结论]${gl_bai}"
    echo -e "  ${gl_huang}${conclusion}${gl_bai}"
    echo ""
    echo "提示：此页只读，不会安装软件、写入配置或修改系统。"
    echo ""
    break_end
}

install_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 安装 XanMod 内核与 BBR v3 ===${gl_bai}"
    echo "视频教程: https://www.bilibili.com/video/BV14K421x7BS"
    echo "------------------------------------------------"
    echo "支持系统: Debian/Ubuntu (x86_64 & ARM64)"
    echo -e "${gl_huang}警告: 将升级 Linux 内核，请提前备份重要数据！${gl_bai}"
    echo "------------------------------------------------"
    read -e -p "确定继续安装吗？(Y/N): " choice

    case "$choice" in
        [Yy])
            ;;
        *)
            echo "已取消安装"
            return 1
            ;;
    esac
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构特殊处理
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_kjlan}检测到 ARM64 架构，使用专用安装脚本${gl_bai}"

        install_package curl coreutils || return 1

        local tmp_dir
        tmp_dir=$(mktemp -d 2>/dev/null)
        if [ -z "$tmp_dir" ]; then
            echo -e "${gl_hong}错误: 无法创建临时目录用于下载 ARM64 脚本${gl_bai}"
            return 1
        fi

        local script_url="https://jhb.ovh/jb/bbrv3arm.sh"
        local sha256_url="${script_url}.sha256"
        local sha512_url="${script_url}.sha512"
        local script_path="${tmp_dir}/bbrv3arm.sh"
        local sha256_path="${tmp_dir}/bbrv3arm.sh.sha256"
        local sha512_path="${tmp_dir}/bbrv3arm.sh.sha512"

        echo "日志: 正在下载 ARM64 安装脚本到临时目录 ${tmp_dir}"

        if ! curl -fsSL "$script_url" -o "$script_path"; then
            echo -e "${gl_hong}错误: ARM64 安装脚本下载失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha256_url" -o "$sha256_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA256 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if ! curl -fsSL "$sha512_url" -o "$sha512_path"; then
            echo -e "${gl_hong}错误: 未能获取发布方提供的 SHA512 校验文件${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        local expected_sha256 expected_sha512 actual_sha256 actual_sha512
        expected_sha256=$(awk 'NR==1 {print $1}' "$sha256_path")
        expected_sha512=$(awk 'NR==1 {print $1}' "$sha512_path")

        if [ -z "$expected_sha256" ] || [ -z "$expected_sha512" ]; then
            echo -e "${gl_hong}错误: 校验文件内容无效${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        actual_sha256=$(sha256sum "$script_path" | awk '{print $1}')
        actual_sha512=$(sha512sum "$script_path" | awk '{print $1}')

        if [ "$expected_sha256" != "$actual_sha256" ]; then
            echo -e "${gl_hong}错误: SHA256 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        if [ "$expected_sha512" != "$actual_sha512" ]; then
            echo -e "${gl_hong}错误: SHA512 校验失败，已中止${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi

        echo -e "${gl_lv}SHA256 与 SHA512 校验通过${gl_bai}"
        echo -e "${gl_huang}安全提示:${gl_bai} ARM64 脚本已下载至 ${script_path}"
        echo "如需，您可在继续前使用 cat/less 等命令手动审查脚本内容。"
        read -s -r -p "审查完成后按 Enter 继续执行（Ctrl+C 取消）..." _
        echo ""

        if bash "$script_path"; then
            rm -rf "$tmp_dir"
            echo -e "${gl_lv}ARM BBR v3 安装完成${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}安装失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    # 显式检查 x86_64 架构
    if [ "$cpu_arch" != "x86_64" ]; then
        echo -e "${gl_hong}错误: 不支持的 CPU 架构: ${cpu_arch}${gl_bai}"
        echo "本脚本仅支持 x86_64 和 aarch64 架构"
        return 1
    fi

    # x86_64 架构安装流程
    # 检查系统支持并解析 XanMod APT 源代号
    local xanmod_codename
    xanmod_codename=$(get_xanmod_codename) || return 1

    # 环境准备
    check_disk_space 3 || return 1
    check_swap
    install_package wget gnupg || { echo -e "${gl_hong}错误: 无法安装必要依赖 wget/gnupg${gl_bai}"; return 1; }

    # 添加 XanMod GPG 密钥（分步执行，避免管道 $? 只检查最后一条命令）
    echo "正在添加 XanMod 仓库密钥..."
    local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local key_tmp=$(mktemp)
    local gpg_ok=false

    # 尝试1: 从镜像源下载
    if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
       [ -s "$key_tmp" ]; then
        if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
            gpg_ok=true
        fi
    fi

    # 尝试2: 从 XanMod 官方源下载
    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_huang}镜像源失败，尝试 XanMod 官方源...${gl_bai}"
        if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi
    fi

    rm -f "$key_tmp"

    if [ "$gpg_ok" = false ]; then
        echo -e "${gl_hong}错误: GPG 密钥导入失败，无法继续安装${gl_bai}"
        echo "请检查网络连接后重试"
        return 1
    fi
    echo -e "${gl_lv}✅ GPG 密钥导入成功${gl_bai}"

    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"

    # 添加 XanMod 仓库（按系统 VERSION_CODENAME 动态选择）
    if ! write_xanmod_apt_source "$gpg_key_file" "$xanmod_repo_file"; then
        rm -f "$xanmod_repo_file"
        return 1
    fi

    # 检测 CPU 架构版本
    echo "正在检测 CPU 支持的最优内核版本..."
    local version=""
    version=$(detect_x64_level)
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        echo -e "${gl_huang}无法可靠识别 CPU level，按 x86-64-v1 安全处理${gl_bai}"
        version="1"
    fi
    echo -e "${gl_lv}检测到 CPU level: x86-64-v${version}${gl_bai}"

    echo "正在更新软件包列表..."
    if ! apt-get update; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续安装...${gl_bai}"
    fi

    local selected_xanmod_pkg
    if ! selected_xanmod_pkg=$(select_xanmod_package "$version"); then
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_kjlan}━━━━━━━━━━ XanMod 安装信息 ━━━━━━━━━━${gl_bai}"
    echo -e "  当前系统 codename: ${gl_lv}${xanmod_codename}${gl_bai}"
    echo -e "  检测到 CPU level: ${gl_lv}x86-64-v${version}${gl_bai}"
    echo -e "  最终选择的 XanMod 包名: ${gl_lv}${selected_xanmod_pkg}${gl_bai}"
    echo -e "  当前 XanMod APT 源: ${gl_lv}http://deb.xanmod.org ${xanmod_codename} main${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

    # 安装 XanMod 内核
    apt-get install -y "$selected_xanmod_pkg"

    if [ $? -ne 0 ]; then
        echo -e "${gl_hong}内核安装失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    # 验证内核是否真正安装成功
    if ! dpkg-query -W -f='${Status}' "$selected_xanmod_pkg" 2>/dev/null | grep -q "install ok installed"; then
        echo -e "${gl_hong}内核包安装验证失败！${gl_bai}"
        rm -f "$xanmod_repo_file"
        return 1
    fi

    echo -e "${gl_lv}XanMod 内核安装成功！${gl_bai}"
    echo -e "${gl_huang}提示: 请先重启系统加载新内核，然后再配置 BBR${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
    echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${version}${gl_bai}"
    echo -e "  安装内核包名: ${gl_lv}${selected_xanmod_pkg}${gl_bai}"
    echo -e "  APT 源代号: ${gl_lv}${xanmod_codename}${gl_bai}"
    echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${version}，已安装该等级的最新内核${gl_bai}"
    echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}后续更新：再次运行选项1即可检查并安装最新内核${gl_bai}"

    rm -f "$xanmod_repo_file"
    echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"

    return 0
}


#=============================================================================
# IP地址获取函数
#=============================================================================

ip_address() {
    local public_ip=""
    local candidate=""
    local external_api_success=false
    local last_curl_status=0
    local external_api_notice=""

    if candidate=$(curl -4 -fsS --max-time 2 https://ipinfo.io/ip 2>/dev/null); then
        candidate=$(echo "$candidate" | tr -d '\r\n')
        if [ -n "$candidate" ]; then
            public_ip="$candidate"
            external_api_success=true
        fi
    else
        last_curl_status=$?
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://api.ip.sb/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        if candidate=$(curl -4 -fsS --max-time 2 https://ifconfig.me/ip 2>/dev/null); then
            candidate=$(echo "$candidate" | tr -d '\r\n')
            if [ -n "$candidate" ]; then
                public_ip="$candidate"
                external_api_success=true
            fi
        else
            last_curl_status=$?
        fi
    fi

    if [ "$external_api_success" = false ]; then
        public_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$public_ip" ]; then
        public_ip="外部接口不可达"
    fi

    if [ "$external_api_success" = false ]; then
        external_api_notice="外部接口不可达"
        if [ "$last_curl_status" -ne 0 ]; then
            external_api_notice+=" (curl 返回码 $last_curl_status)"
        fi
    fi

    local local_ipv4=""
    local_ipv4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    if [ -z "$local_ipv4" ]; then
        local_ipv4=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$local_ipv4" ]; then
        local_ipv4="外部接口不可达"
    fi

    if ! isp_info=$(curl -fsS --max-time 2 http://ipinfo.io/org 2>/dev/null); then
        isp_info=""
    else
        isp_info=$(echo "$isp_info" | tr -d '\r\n')
    fi

    if [ -z "$isp_info" ] && [ -n "$external_api_notice" ]; then
        isp_info="$external_api_notice"
    fi

    if echo "$isp_info" | grep -Eiq 'mobile|unicom|telecom'; then
        ipv4_address="$local_ipv4"
    else
        ipv4_address="$public_ip"
    fi

    if [ -z "$ipv4_address" ]; then
        ipv4_address="$local_ipv4"
    fi

    if ! ipv6_address=$(curl -fsS --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null); then
        ipv6_address=""
    else
        ipv6_address=$(echo "$ipv6_address" | tr -d '\r\n')
    fi

    if [ -n "$external_api_notice" ] && [ -z "$isp_info" ]; then
        isp_info="$external_api_notice"
    fi

    if [ -z "$isp_info" ]; then
        isp_info="未获取到运营商信息"
    fi
}
#=============================================================================
# 网络流量统计函数
#=============================================================================

output_status() {
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
            rx_total += $2
            tx_total += $10
        }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }

            if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }

            printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
        }' /proc/net/dev)

    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}

#=============================================================================
# 时区获取函数
#=============================================================================

current_timezone() {
    if grep -q 'Alpine' /etc/issue 2>/dev/null; then
        date +"%Z %z"
    else
        timedatectl | grep "Time zone" | awk '{print $3}'
    fi
}

#=============================================================================
# 详细系统信息显示
#=============================================================================

show_detailed_status() {
    clear

    ip_address

    local cpu_info=$(lscpu | awk -F': +' '/Model name:/ {print $2; exit}')

    local cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

    local cpu_cores=$(nproc)

    local cpu_freq=$(cat /proc/cpuinfo | grep "MHz" | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')

    local mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')

    local disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')

    local ipinfo=$(curl -s ipinfo.io)
    local country=$(echo "$ipinfo" | grep 'country' | awk -F': ' '{print $2}' | tr -d '",')
    local city=$(echo "$ipinfo" | grep 'city' | awk -F': ' '{print $2}' | tr -d '",')
    local isp_info=$(echo "$ipinfo" | grep 'org' | awk -F': ' '{print $2}' | tr -d '",')

    local load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
    local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

    local cpu_arch=$(uname -m)
    local hostname=$(uname -n)
    local kernel_version=$(uname -r)

    local congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    local queue_algorithm=$(sysctl -n net.core.default_qdisc)

    local os_info=$(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')

    output_status

    local current_time=$(date "+%Y-%m-%d %I:%M %p")

    local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')

    local runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')

    local timezone=$(current_timezone)

    echo ""
    echo -e "系统信息查询"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}主机名:       ${gl_bai}$hostname"
    echo -e "${gl_kjlan}系统版本:     ${gl_bai}$os_info"
    echo -e "${gl_kjlan}Linux版本:    ${gl_bai}$kernel_version"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU架构:      ${gl_bai}$cpu_arch"
    echo -e "${gl_kjlan}CPU型号:      ${gl_bai}$cpu_info"
    echo -e "${gl_kjlan}CPU核心数:    ${gl_bai}$cpu_cores"
    echo -e "${gl_kjlan}CPU频率:      ${gl_bai}$cpu_freq"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU占用:      ${gl_bai}$cpu_usage_percent%"
    echo -e "${gl_kjlan}系统负载:     ${gl_bai}$load"
    echo -e "${gl_kjlan}物理内存:     ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:     ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}硬盘占用:     ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}总接收:       ${gl_bai}$rx"
    echo -e "${gl_kjlan}总发送:       ${gl_bai}$tx"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}网络算法:     ${gl_bai}$congestion_algorithm $queue_algorithm"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运营商:       ${gl_bai}$isp_info"
    if [ -n "$ipv4_address" ]; then
        echo -e "${gl_kjlan}IPv4地址:     ${gl_bai}$ipv4_address"
    fi

    if [ -n "$ipv6_address" ]; then
        echo -e "${gl_kjlan}IPv6地址:     ${gl_bai}$ipv6_address"
    fi
    echo -e "${gl_kjlan}DNS地址:      ${gl_bai}$dns_addresses"
    echo -e "${gl_kjlan}地理位置:     ${gl_bai}$country $city"
    echo -e "${gl_kjlan}系统时间:     ${gl_bai}$timezone $current_time"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运行时长:     ${gl_bai}$runtime"
    echo

    break_end
}

#=============================================================================
# 内核参数优化 - 星辰大海ヾ优化模式（VLESS Reality 专用）
#=============================================================================

dns_purify_fix_systemd_resolved() {
    echo -e "${gl_kjlan}正在检测 systemd-resolved 服务状态...${gl_bai}"

    # 检查服务是否已启用且正在运行
    if systemctl is-enabled systemd-resolved &> /dev/null; then
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务已启用且运行中${gl_bai}"
            return 0
        else
            # 已启用但未运行（可能 crash 或被手动停止）
            echo -e "${gl_huang}systemd-resolved 已启用但未运行，正在启动...${gl_bai}"
            systemctl start systemd-resolved 2>/dev/null || true
            sleep 2
            if systemctl is-active --quiet systemd-resolved; then
                echo -e "${gl_lv}✅ systemd-resolved 服务已成功启动${gl_bai}"
                return 0
            else
                echo -e "${gl_hong}启动失败，尝试重新启用...${gl_bai}"
                systemctl restart systemd-resolved 2>/dev/null || true
                sleep 2
                if systemctl is-active --quiet systemd-resolved; then
                    echo -e "${gl_lv}✅ systemd-resolved 服务已重启成功${gl_bai}"
                    return 0
                else
                    echo -e "${gl_hong}服务无法启动${gl_bai}"
                    systemctl status systemd-resolved --no-pager || true
                    return 1
                fi
            fi
        fi
    fi

    # 检查是否被 masked
    if systemctl status systemd-resolved 2>&1 | grep -q "masked"; then
        echo -e "${gl_huang}检测到 systemd-resolved 被屏蔽 (masked)，正在修复...${gl_bai}"

        # 解除屏蔽
        if systemctl unmask systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已成功解除 systemd-resolved 的屏蔽状态${gl_bai}"
        else
            echo -e "${gl_hong}解除屏蔽失败，尝试手动修复...${gl_bai}"
            # 手动删除屏蔽链接
            rm -f /etc/systemd/system/systemd-resolved.service 2>/dev/null || true
            systemctl daemon-reload
            echo -e "${gl_lv}✅ 已手动移除屏蔽链接${gl_bai}"
        fi

        # 启用服务
        if systemctl enable systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启用 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启用服务失败${gl_bai}"
            return 1
        fi

        # 启动服务
        if systemctl start systemd-resolved 2>/dev/null; then
            echo -e "${gl_lv}✅ 已启动 systemd-resolved 服务${gl_bai}"
        else
            echo -e "${gl_hong}启动服务失败${gl_bai}"
            return 1
        fi

        # 等待服务完全启动
        sleep 2

        # 验证服务状态
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务运行正常${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}服务启动后状态异常${gl_bai}"
            systemctl status systemd-resolved --no-pager || true
            return 1
        fi
    else
        echo -e "${gl_huang}systemd-resolved 未启用，正在启用...${gl_bai}"
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true

        # 等待服务启动并验证
        sleep 2
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_lv}✅ systemd-resolved 服务已启用并运行${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}systemd-resolved 启动失败${gl_bai}"
            systemctl status systemd-resolved --no-pager || true
            return 1
        fi
    fi
}

# DNS净化 - 主执行函数（SSH安全版）
dns_purify_and_harden() {
    clear
    DNS_PURIFY_RESULT="未执行"
    DNS_PURIFY_ROLLBACK=""
    echo -e "${gl_kjlan}╔════════════════════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_kjlan}║    DNS净化与安全加固脚本 - SSH安全增强版 v2.0             ║${gl_bai}"
    echo -e "${gl_kjlan}╚════════════════════════════════════════════════════════════╝${gl_bai}"
    echo ""

    # ==================== SSH安全检测 ====================
    local IS_SSH=false
    if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
        IS_SSH=true
        echo -e "${gl_hong}⚠️  检测到您正在通过SSH连接${gl_bai}"
        echo -e "${gl_lv}✅ SSH安全模式已启用：本脚本不会中断您的网络连接${gl_bai}"
        echo ""
    fi

    echo -e "${gl_kjlan}功能说明：${gl_bai}"
    echo "  ✓ 配置安全的DNS服务器（支持国外/国内模式）"
    echo "  ✓ 防止DHCP覆盖DNS配置"
    echo "  ✓ 清除厂商残留的DNS配置"
    echo "  ✓ 启用DNS安全功能（DNSSEC + DNS over TLS）"
    echo ""

    if [ "$IS_SSH" = true ]; then
        echo -e "${gl_lv}SSH安全保证：${gl_bai}"
        echo "  ✓ 不会停止或重启网络服务"
        echo "  ✓ 不会中断SSH连接"
        echo "  ✓ 所有配置立即生效，无需重启"
        echo "  ✓ 提供完整的回滚机制"
        echo ""
    fi

    # ==================== 已有配置检测 ====================
    local dns_has_config=false
    local dns_is_legacy=false
    local dns_all_healthy=true
    local current_mode_name=""
    local svc_file="/etc/systemd/system/dns-purify-persist.service"

    # 第一步：检测是否存在 DNS 净化配置（不管健不健康）
    if systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null \
       || [ -f "$svc_file" ] \
       || [ -x /usr/local/bin/dns-purify-apply.sh ]; then
        dns_has_config=true
    fi

    # 第二步：如果存在配置，立即检查是新版还是老版（独立于DNS健康状态）
    if [ "$dns_has_config" = true ]; then
        # 老版特征1: 服务文件用 Requires 而非 Wants
        if [ -f "$svc_file" ] && grep -q "Requires=systemd-resolved" "$svc_file" 2>/dev/null; then
            dns_is_legacy=true
        fi
        # 老版特征2: 持久化脚本缺少 resolvectl 可用性检查
        if [ -x /usr/local/bin/dns-purify-apply.sh ] && ! grep -q "command -v resolvectl" /usr/local/bin/dns-purify-apply.sh 2>/dev/null; then
            dns_is_legacy=true
        fi
    fi

    # 第三步：健康检查（仅在有配置时执行）
    if [ "$dns_has_config" = true ]; then
        # 持久化服务已启用？
        if ! systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null; then
            dns_all_healthy=false
        fi
        # 持久化脚本存在？
        if [ ! -x /usr/local/bin/dns-purify-apply.sh ]; then
            dns_all_healthy=false
        fi
        # resolved 运行中？
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            dns_all_healthy=false
        fi
        # resolv.conf 指向 stub？
        if [ ! -L /etc/resolv.conf ] || [[ "$(readlink /etc/resolv.conf 2>/dev/null)" != *"stub-resolv.conf"* ]]; then
            dns_all_healthy=false
        fi
        # DNS 解析正常？
        if [ "$dns_all_healthy" = true ]; then
            local dns_resolve_ok=false
            if command -v getent >/dev/null 2>&1; then
                if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
                    dns_resolve_ok=true
                fi
            fi
            if [ "$dns_resolve_ok" = false ]; then
                dns_all_healthy=false
            fi
        fi
    fi

    # 检测当前模式
    if [ "$dns_has_config" = true ] && [ -f /etc/systemd/resolved.conf ]; then
        local cur_dot
        cur_dot=$(sed -nE 's/^DNSOverTLS=(.+)/\1/p' /etc/systemd/resolved.conf 2>/dev/null)
        case "$cur_dot" in
            yes)           current_mode_name="纯国外模式（强制DoT）" ;;
            no)            current_mode_name="纯国内模式" ;;
            opportunistic) current_mode_name="混合模式（机会性DoT）" ;;
        esac
    fi

    # ==================== 显示检测结果 ====================
    if [ "$dns_has_config" = true ] && [ "$dns_is_legacy" = true ]; then
        # 老版配置（不管DNS当前是否健康，都必须警告）
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}  ⚠️  检测到老版 DNS 净化配置，重启后可能导致 DNS 失效！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        [ -n "$current_mode_name" ] && echo -e "  当前模式:    ${gl_huang}${current_mode_name}${gl_bai}"
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            echo -e "  resolved:    ${gl_lv}✅ 运行中${gl_bai}"
        else
            echo -e "  resolved:    ${gl_hong}❌ 未运行${gl_bai}"
        fi
        if [ "$dns_all_healthy" = true ]; then
            echo -e "  DNS 解析:    ${gl_lv}✅ 当前正常${gl_bai}"
        else
            echo -e "  DNS 解析:    ${gl_hong}❌ 当前异常${gl_bai}"
        fi
        echo -e "  开机持久化:  ${gl_hong}⚠️  老版（重启有风险）${gl_bai}"
        echo ""
        echo -e "${gl_huang}原因：老版持久化服务存在已知bug，重启后可能导致DNS断连${gl_bai}"
        echo -e "${gl_lv}建议：继续执行功能4，新版会自动替换为安全的持久化机制${gl_bai}"
        echo ""

    elif [ "$dns_has_config" = true ] && [ "$dns_all_healthy" = true ]; then
        # 新版配置 + 全部健康：完美状态
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}  ✅ DNS净化已完美配置，无需重复执行！${gl_bai}"
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  当前模式:    ${gl_lv}${current_mode_name}${gl_bai}"
        echo -e "  resolved:    ${gl_lv}✅ 运行中${gl_bai}"
        echo -e "  resolv.conf: ${gl_lv}✅ 指向 stub（resolved 托管）${gl_bai}"
        echo -e "  开机持久化:  ${gl_lv}✅ dns-purify-persist 已启用（新版）${gl_bai}"
        echo -e "  DNS 解析:    ${gl_lv}✅ 正常${gl_bai}"
        echo ""
        echo -e "${gl_huang}提示：重启后 DNS 会自动恢复，无需担心${gl_bai}"
        echo ""
        if [ "$AUTO_MODE" = "1" ]; then
            return
        fi
        read -e -p "$(echo -e "${gl_huang}如需重新配置请输入 y，返回主菜单按回车: ${gl_bai}")" dns_reconfig
        if [[ ! "$dns_reconfig" =~ ^[Yy]$ ]]; then
            return
        fi
        echo ""
    fi

    # ==================== DNS模式选择 ====================
    echo -e "${gl_kjlan}请选择 DNS 配置模式：${gl_bai}"
    echo ""
    echo "  1. 🌍 纯国外模式（抗污染推荐）"
    echo "     首选：Google DNS + Cloudflare DNS"
    echo "     备用：无"
    echo "     加密：强制 DNS over TLS"
    echo ""
    echo "  2. 🇨🇳 纯国内模式（低延迟推荐）"
    echo "     首选：阿里云 DNS + 腾讯 DNSPod"
    echo "     备用：无"
    echo "     加密：无（国内DNS不支持DoT/DNSSEC）"
    echo ""
    if [ "$AUTO_MODE" = "1" ]; then
        dns_mode_choice=1
    else
        read -e -p "$(echo -e "${gl_huang}请选择 (1/2，默认1): ${gl_bai}")" dns_mode_choice
        dns_mode_choice=${dns_mode_choice:-1}
    fi

    # 验证输入
    if [[ ! "$dns_mode_choice" =~ ^[1-2]$ ]]; then
        dns_mode_choice=1
    fi

    echo ""

    if [ "$AUTO_MODE" = "1" ]; then
        confirm=y
    else
        read -e -p "$(echo -e "${gl_huang}是否继续执行？(y/n): ${gl_bai}")" confirm
    fi

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消操作${gl_bai}"
        return
    fi

    # ==================== 终极安全检查 ====================
    echo ""
    echo -e "${gl_kjlan}[安全检查] 正在验证系统环境...${gl_bai}"
    echo ""
    
    local pre_check_failed=false
    
    # 检查1: 磁盘空间（至少需要100MB）
    echo -n "  → 检查磁盘空间... "
    local available_space
    available_space=$(get_root_available_mb)
    if ! [[ "$available_space" =~ ^[0-9]+$ ]]; then
        echo -e "${gl_huang}警告 (无法读取磁盘空间，跳过硬性拦截)${gl_bai}"
    elif [ "$available_space" -lt 100 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_space}MB, 需要: 100MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_space}MB)${gl_bai}"
    fi
    
    # 检查2: 内存（至少需要50MB可用）
    echo -n "  → 检查可用内存... "
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_mem" -lt 50 ]; then
        echo -e "${gl_hong}失败 (可用: ${available_mem}MB, 需要: 50MB)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过 (可用: ${available_mem}MB)${gl_bai}"
    fi
    
    # 检查3: systemd 是否正常工作
    echo -n "  → 检查 systemd 状态... "
    if ! systemctl --version > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (systemctl 命令无法执行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查4: 是否有其他包管理器在运行
    echo -n "  → 检查包管理器锁... "
    if lsof /var/lib/dpkg/lock-frontend > /dev/null 2>&1 || \
       lsof /var/lib/apt/lists/lock > /dev/null 2>&1 || \
       lsof /var/cache/apt/archives/lock > /dev/null 2>&1; then
        echo -e "${gl_hong}失败 (其他包管理器正在运行)${gl_bai}"
        pre_check_failed=true
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查5: /run 目录是否可写
    echo -n "  → 检查 /run 目录权限... "
    if ! touch /run/.dns_test 2>/dev/null; then
        echo -e "${gl_hong}失败 (/run 目录不可写)${gl_bai}"
        pre_check_failed=true
    else
        rm -f /run/.dns_test
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    # 检查6: 网络连通性（能否访问DNS服务器）
    echo -n "  → 检查网络连通性... "
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1 && \
       ! ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
        echo -e "${gl_huang}警告 (无法ping通DNS服务器，但继续执行)${gl_bai}"
    else
        echo -e "${gl_lv}通过${gl_bai}"
    fi
    
    echo ""
    
    # 如果有检查失败，拒绝执行
    if [ "$pre_check_failed" = true ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}❌ 安全检查未通过！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_huang}系统环境不满足安全执行条件，拒绝执行以避免风险。${gl_bai}"
        echo ""
        echo "请先解决上述问题，然后重试。"
        echo ""
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}✅ 所有安全检查通过，可以安全执行${gl_bai}"
    echo ""

    # ==================== 创建备份 ====================
    local BACKUP_DIR="/root/.dns_purify_backup/$(date +%Y%m%d_%H%M%S)"
    local PRE_STATE_DIR="$BACKUP_DIR/pre_state"
    mkdir -p "$BACKUP_DIR" "$PRE_STATE_DIR"
    DNS_PURIFY_ROLLBACK="$BACKUP_DIR/rollback.sh"
    echo ""
    echo -e "${gl_lv}✅ 创建备份目录：$BACKUP_DIR${gl_bai}"
    echo ""

    # 记录/恢复单个路径状态（文件、符号链接或不存在）
    backup_path_state() {
        local src="$1"
        local key="$2"
        if [[ -e "$src" || -L "$src" ]]; then
            cp -a "$src" "$PRE_STATE_DIR/$key" 2>/dev/null || true
        else
            : > "$PRE_STATE_DIR/$key.absent"
        fi
    }

    restore_path_state() {
        local dst="$1"
        local key="$2"
        rm -f "$dst" 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/$key" || -L "$PRE_STATE_DIR/$key" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$PRE_STATE_DIR/$key" "$dst" 2>/dev/null || true
        elif [[ -f "$PRE_STATE_DIR/$key.absent" ]]; then
            rm -f "$dst" 2>/dev/null || true
        fi
    }

    # 解析 DNS 地址中的 SNI 后缀（例如 1.1.1.1#cloudflare-dns.com -> 1.1.1.1）
    plain_dns_ip() {
        local dns_addr="$1"
        local stripped="${dns_addr%%#*}"
        if [[ "$stripped" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
            echo "${stripped%:*}"
        else
            echo "$stripped"
        fi
    }

    # 预先快照本次功能可能修改的关键文件
    backup_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
    backup_path_state "/etc/network/interfaces" "interfaces"
    backup_path_state "/etc/systemd/resolved.conf" "resolved.conf"
    backup_path_state "/etc/resolv.conf" "resolv.conf"
    backup_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
    backup_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
    backup_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
    backup_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"
    backup_path_state "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" "dnscrypt-proxy.toml"

    # 快照 if-up.d/resolved 执行权限状态
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -e "$ifup_script" ]]; then
        if [[ -x "$ifup_script" ]]; then
            echo "executable" > "$PRE_STATE_DIR/ifup-resolved.exec"
        else
            echo "not_executable" > "$PRE_STATE_DIR/ifup-resolved.exec"
        fi
    else
        echo "absent" > "$PRE_STATE_DIR/ifup-resolved.exec"
    fi

    # 快照服务启用状态
    if systemctl is-enabled --quiet dns-purify-persist.service 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/dns-persist.was-enabled"
    else
        echo "false" > "$PRE_STATE_DIR/dns-persist.was-enabled"
    fi

    # 用文本输出精确记录 enabled/static/disabled/masked 状态（is-enabled --quiet 对 static 也返回 0）
    local resolved_enable_state
    resolved_enable_state=$(systemctl is-enabled systemd-resolved 2>/dev/null || echo "unknown")
    echo "$resolved_enable_state" > "$PRE_STATE_DIR/resolved.enable-state"

    if [[ "$resolved_enable_state" == "masked" || "$resolved_enable_state" == "masked-runtime" ]]; then
        echo "true" > "$PRE_STATE_DIR/resolved.was-masked"
    else
        echo "false" > "$PRE_STATE_DIR/resolved.was-masked"
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/resolved.was-active"
    else
        echo "false" > "$PRE_STATE_DIR/resolved.was-active"
    fi

    # 快照 dnscrypt-proxy 状态（DoH fallback 回滚使用）
    if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
        echo "true" > "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg"
    else
        echo "false" > "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg"
    fi
    if systemctl is-enabled --quiet dnscrypt-proxy 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled"
    else
        echo "false" > "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled"
    fi
    if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
        echo "true" > "$PRE_STATE_DIR/dnscrypt-proxy.was-active"
    else
        echo "false" > "$PRE_STATE_DIR/dnscrypt-proxy.was-active"
    fi

    # 快照 resolvconf 包状态（用于 Debian 11 回滚）
    if dpkg -s resolvconf >/dev/null 2>&1; then
        echo "true" > "$PRE_STATE_DIR/had-resolvconf.pkg"
    else
        echo "false" > "$PRE_STATE_DIR/had-resolvconf.pkg"
    fi

    local pre_dns_health="false"
    if command -v getent >/dev/null 2>&1; then
        if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
            pre_dns_health="true"
        fi
    fi
    echo "$pre_dns_health" > "$PRE_STATE_DIR/pre-dns.health"

    # 快照现有 systemd-networkd DNS drop-in
    : > "$PRE_STATE_DIR/networkd-dropins.map"
    local existing_dropin
    for existing_dropin in /etc/systemd/network/*.network.d/dns-purify-override.conf; do
        [[ -f "$existing_dropin" ]] || continue
        local dropin_key="networkd-$(echo "$existing_dropin" | sed 's|/|__|g')"
        cp -a "$existing_dropin" "$PRE_STATE_DIR/$dropin_key" 2>/dev/null || true
        echo "$existing_dropin|$dropin_key" >> "$PRE_STATE_DIR/networkd-dropins.map"
    done

    # 预生成基础回滚脚本，确保 DoH/降级/跳过分支也有可用回滚入口
    cat > "$BACKUP_DIR/rollback.sh" << 'ROLLBACK_SCRIPT'
#!/bin/bash
# DNS配置基础回滚脚本

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DNS配置基础回滚脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BACKUP_DIR="$(dirname "$0")"
PRE_STATE_DIR="$BACKUP_DIR/pre_state"

restore_path_state() {
    local dst="$1"
    local key="$2"
    rm -f "$dst" 2>/dev/null || true
    if [[ -e "$PRE_STATE_DIR/$key" || -L "$PRE_STATE_DIR/$key" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$PRE_STATE_DIR/$key" "$dst" 2>/dev/null || true
    elif [[ -f "$PRE_STATE_DIR/$key.absent" ]]; then
        rm -f "$dst" 2>/dev/null || true
    fi
}

restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
restore_path_state "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" "dnscrypt-proxy.toml"

if command -v systemctl >/dev/null 2>&1; then
    resolved_enable_state="unknown"
    resolved_was_masked="false"
    resolved_was_active="false"
    [[ -f "$PRE_STATE_DIR/resolved.enable-state" ]] && resolved_enable_state=$(cat "$PRE_STATE_DIR/resolved.enable-state" 2>/dev/null || echo "unknown")
    [[ -f "$PRE_STATE_DIR/resolved.was-masked" ]] && resolved_was_masked=$(cat "$PRE_STATE_DIR/resolved.was-masked" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/resolved.was-active" ]] && resolved_was_active=$(cat "$PRE_STATE_DIR/resolved.was-active" 2>/dev/null || echo "false")

    if [[ "$resolved_was_masked" == "true" ]]; then
        systemctl mask systemd-resolved 2>/dev/null || true
        systemctl stop systemd-resolved 2>/dev/null || true
    else
        systemctl unmask systemd-resolved 2>/dev/null || true
        case "$resolved_enable_state" in
            enabled|enabled-runtime)
                systemctl enable systemd-resolved 2>/dev/null || true
                ;;
            static|indirect|generated)
                ;;
            *)
                systemctl disable systemd-resolved 2>/dev/null || true
                ;;
        esac
        if [[ "$resolved_was_active" == "true" ]]; then
            systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
        else
            systemctl stop systemd-resolved 2>/dev/null || true
        fi
    fi

    had_dnscrypt_proxy_pkg="false"
    dnscrypt_proxy_was_enabled="false"
    dnscrypt_proxy_was_active="false"
    [[ -f "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" ]] && had_dnscrypt_proxy_pkg=$(cat "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" ]] && dnscrypt_proxy_was_enabled=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-active" ]] && dnscrypt_proxy_was_active=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-active" 2>/dev/null || echo "false")
    if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
        if [[ "$had_dnscrypt_proxy_pkg" == "true" ]]; then
            if [[ "$dnscrypt_proxy_was_enabled" == "true" ]]; then
                systemctl enable dnscrypt-proxy 2>/dev/null || true
            else
                systemctl disable dnscrypt-proxy 2>/dev/null || true
            fi
            if [[ "$dnscrypt_proxy_was_active" == "true" ]]; then
                systemctl restart dnscrypt-proxy 2>/dev/null || systemctl start dnscrypt-proxy 2>/dev/null || true
            else
                systemctl stop dnscrypt-proxy 2>/dev/null || true
            fi
        else
            systemctl disable --now dnscrypt-proxy 2>/dev/null || true
        fi
    fi
fi

if [[ -L "$PRE_STATE_DIR/resolv.conf" ]]; then
    backup_link_target=$(readlink "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || echo "")
    if [[ "$backup_link_target" == *"stub-resolv.conf"* ]] && [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
        rm -f /etc/resolv.conf 2>/dev/null || true
        echo "nameserver 127.0.0.53" > /etc/resolv.conf 2>/dev/null || true
    else
        restore_path_state "/etc/resolv.conf" "resolv.conf"
    fi
else
    restore_path_state "/etc/resolv.conf" "resolv.conf"
fi

echo "基础回滚完成。"
ROLLBACK_SCRIPT
    chmod +x "$BACKUP_DIR/rollback.sh"

    # 退出函数时自动清理本函数内动态定义的 helper，避免影响其他功能
    trap 'unset -f backup_path_state restore_path_state plain_dns_ip auto_rollback_dns_purify dns_runtime_health_check can_connect_tcp local_port_busy select_dnscrypt_listen_address configure_dnscrypt_proxy apply_plain_dns_fallback >/dev/null 2>&1 || true' RETURN

    # 自动回滚函数（失败即恢复，避免遗留DNS隐患）
    auto_rollback_dns_purify() {
        # 恢复关键文件到执行前状态（注意：resolv.conf 延后恢复，避免悬空链接）
        restore_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
        restore_path_state "/etc/network/interfaces" "interfaces"
        restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
        # resolv.conf 在服务状态恢复后再处理（见下方）
        restore_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
        restore_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
        restore_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
        restore_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"
        restore_path_state "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" "dnscrypt-proxy.toml"

        # 恢复 dnscrypt-proxy 服务状态（DoH fallback）
        local had_dnscrypt_proxy_pkg="false"
        local dnscrypt_proxy_was_enabled="false"
        local dnscrypt_proxy_was_active="false"
        [[ -f "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" ]] && had_dnscrypt_proxy_pkg=$(cat "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" 2>/dev/null || echo "false")
        [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" ]] && dnscrypt_proxy_was_enabled=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" 2>/dev/null || echo "false")
        [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-active" ]] && dnscrypt_proxy_was_active=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-active" 2>/dev/null || echo "false")
        if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
            if [[ "$had_dnscrypt_proxy_pkg" == "true" ]]; then
                if [[ "$dnscrypt_proxy_was_enabled" == "true" ]]; then
                    systemctl enable dnscrypt-proxy 2>/dev/null || true
                else
                    systemctl disable dnscrypt-proxy 2>/dev/null || true
                fi
                if [[ "$dnscrypt_proxy_was_active" == "true" ]]; then
                    systemctl restart dnscrypt-proxy 2>/dev/null || systemctl start dnscrypt-proxy 2>/dev/null || true
                else
                    systemctl stop dnscrypt-proxy 2>/dev/null || true
                fi
            else
                systemctl disable --now dnscrypt-proxy 2>/dev/null || true
            fi
        fi

        # 恢复 if-up.d/resolved 执行权限
        if [[ -f "$PRE_STATE_DIR/ifup-resolved.exec" ]]; then
            case "$(cat "$PRE_STATE_DIR/ifup-resolved.exec" 2>/dev/null)" in
                executable)
                    [[ -e /etc/network/if-up.d/resolved ]] && chmod +x /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
                not_executable)
                    [[ -e /etc/network/if-up.d/resolved ]] && chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
                absent)
                    rm -f /etc/network/if-up.d/resolved 2>/dev/null || true
                    ;;
            esac
        fi

        # 移除本次可能新增的 networkd drop-in（扩展搜索所有可能路径）
        local dropin_file search_dir
        for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
            for dropin_file in "$search_dir"/*.network.d/dns-purify-override.conf; do
                [[ -f "$dropin_file" ]] || continue
                rm -f "$dropin_file"
                rmdir "$(dirname "$dropin_file")" 2>/dev/null || true
            done
        done

        # 恢复执行前已有的 networkd drop-in
        if [[ -f "$PRE_STATE_DIR/networkd-dropins.map" ]]; then
            local restore_path restore_key
            while IFS='|' read -r restore_path restore_key; do
                [[ -n "$restore_path" && -n "$restore_key" ]] || continue
                [[ -f "$PRE_STATE_DIR/$restore_key" ]] || continue
                mkdir -p "$(dirname "$restore_path")"
                cp -a "$PRE_STATE_DIR/$restore_key" "$restore_path" 2>/dev/null || true
            done < "$PRE_STATE_DIR/networkd-dropins.map"
        fi

        # 重载 systemd-networkd（使 drop-in 变更生效）
        if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
        fi

        # 重载 NetworkManager（使配置文件变更生效）
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl reload NetworkManager 2>/dev/null || true
        fi

        # 恢复 dns-purify 持久化服务启用状态
        local dns_persist_was_enabled="false"
        [[ -f "$PRE_STATE_DIR/dns-persist.was-enabled" ]] && dns_persist_was_enabled=$(cat "$PRE_STATE_DIR/dns-persist.was-enabled" 2>/dev/null || echo "false")

        systemctl daemon-reload 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/dns-purify-persist.service" || -L "$PRE_STATE_DIR/dns-purify-persist.service" ]]; then
            if [[ "$dns_persist_was_enabled" == "true" ]]; then
                systemctl enable dns-purify-persist.service 2>/dev/null || true
            else
                systemctl disable dns-purify-persist.service 2>/dev/null || true
            fi
        else
            systemctl disable dns-purify-persist.service 2>/dev/null || true
        fi

        # 尝试恢复 resolvconf 包状态（Debian 11 场景）
        local had_resolvconf_pkg="false"
        [[ -f "$PRE_STATE_DIR/had-resolvconf.pkg" ]] && had_resolvconf_pkg=$(cat "$PRE_STATE_DIR/had-resolvconf.pkg" 2>/dev/null || echo "false")
        if [[ "$had_resolvconf_pkg" == "true" ]] && ! dpkg -s resolvconf >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y resolvconf >/dev/null 2>&1 || true
        fi

        # 恢复 systemd-resolved 启用/屏蔽/运行状态（在 resolv.conf 之前）
        local resolved_enable_state="unknown"
        local resolved_was_masked="false"
        local resolved_was_active="false"
        [[ -f "$PRE_STATE_DIR/resolved.enable-state" ]] && resolved_enable_state=$(cat "$PRE_STATE_DIR/resolved.enable-state" 2>/dev/null || echo "unknown")
        # 兼容旧版快照格式
        [[ "$resolved_enable_state" == "unknown" && -f "$PRE_STATE_DIR/resolved.was-enabled" ]] && {
            local old_enabled
            old_enabled=$(cat "$PRE_STATE_DIR/resolved.was-enabled" 2>/dev/null || echo "false")
            [[ "$old_enabled" == "true" ]] && resolved_enable_state="enabled" || resolved_enable_state="disabled"
        }
        [[ -f "$PRE_STATE_DIR/resolved.was-masked" ]] && resolved_was_masked=$(cat "$PRE_STATE_DIR/resolved.was-masked" 2>/dev/null || echo "false")
        [[ -f "$PRE_STATE_DIR/resolved.was-active" ]] && resolved_was_active=$(cat "$PRE_STATE_DIR/resolved.was-active" 2>/dev/null || echo "false")

        if [[ "$resolved_was_masked" == "true" ]]; then
            systemctl mask systemd-resolved 2>/dev/null || true
            systemctl stop systemd-resolved 2>/dev/null || true
        else
            systemctl unmask systemd-resolved 2>/dev/null || true
            case "$resolved_enable_state" in
                enabled|enabled-runtime)
                    systemctl enable systemd-resolved 2>/dev/null || true
                    ;;
                static|indirect|generated)
                    # static/indirect/generated 状态由包管理器控制，不改变
                    ;;
                *)
                    systemctl disable systemd-resolved 2>/dev/null || true
                    ;;
            esac

            if [[ "$resolved_was_active" == "true" ]]; then
                systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
                # 等待 resolved 完全启动，确保 stub 文件可用
                local wait_i
                for wait_i in $(seq 1 5); do
                    [[ -f /run/systemd/resolve/stub-resolv.conf ]] && break
                    sleep 1
                done
            else
                systemctl stop systemd-resolved 2>/dev/null || true
            fi
        fi

        # 最后恢复 resolv.conf（此时 resolved 已恢复运行状态，stub 文件可用）
        # 特殊处理：如果备份是指向 stub 的软链接但 resolved 未运行，则写静态文件
        if [[ -L "$PRE_STATE_DIR/resolv.conf" ]]; then
            local backup_link_target
            backup_link_target=$(readlink "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || echo "")
            if [[ "$backup_link_target" == *"stub-resolv.conf"* ]] && [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
                # resolved 未运行，stub 不存在 — 写入静态 nameserver 避免悬空链接
                rm -f /etc/resolv.conf 2>/dev/null || true
                echo "nameserver 127.0.0.53" > /etc/resolv.conf 2>/dev/null || true
            else
                restore_path_state "/etc/resolv.conf" "resolv.conf"
            fi
        else
            restore_path_state "/etc/resolv.conf" "resolv.conf"
        fi

        # 回滚后验证 — 充分等待 resolved 初始化（最多15秒，每3秒重试）
        local rollback_ok=false
        local pre_dns_health="false"
        [[ -f "$PRE_STATE_DIR/pre-dns.health" ]] && pre_dns_health=$(cat "$PRE_STATE_DIR/pre-dns.health" 2>/dev/null || echo "false")

        local max_wait=5
        for i in $(seq 1 $max_wait); do
            if dns_runtime_health_check "global" || dns_runtime_health_check "cn"; then
                rollback_ok=true
                break
            fi
            sleep 3
        done

        if [ "$rollback_ok" = true ]; then
            echo -e "${gl_lv}  ✅ 回滚后DNS健康校验通过${gl_bai}"
        elif [ "$pre_dns_health" = "true" ]; then
            echo -e "${gl_huang}  ⚠️  回滚后DNS验证超时，但已恢复执行前配置，可能需要等待网络就绪${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  执行前DNS即不可用，已恢复原始配置${gl_bai}"
        fi
    }

    # DNS运行时健康检查（多域名，多方法）
    dns_runtime_health_check() {
        local check_mode="${1:-global}"
        local domains=()
        if [[ "$check_mode" == "cn" ]]; then
            domains=("baidu.com" "qq.com" "aliyun.com")
        else
            domains=("google.com" "cloudflare.com" "github.com" "baidu.com")
        fi

        if command -v getent >/dev/null 2>&1; then
            local domain
            for domain in "${domains[@]}"; do
                if getent hosts "$domain" >/dev/null 2>&1; then
                    return 0
                fi
            done
        fi

        if command -v nslookup >/dev/null 2>&1; then
            local domain
            for domain in "${domains[@]}"; do
                if nslookup "$domain" >/dev/null 2>&1; then
                    return 0
                fi
            done
        fi

        local domain
        for domain in "${domains[@]}"; do
            if ping -c 1 -W 2 "$domain" >/dev/null 2>&1; then
                return 0
            fi
        done

        return 1
    }

    # TCP端口探测（用于DoT 853预检）
    can_connect_tcp() {
        local host="$1"
        local port="$2"
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port} && exec 3>&-" >/dev/null 2>&1
        else
            bash -c "exec 3<>/dev/tcp/${host}/${port} && exec 3>&-" >/dev/null 2>&1
        fi
    }

    local_port_busy() {
        local port="$1"

        if command -v ss >/dev/null 2>&1; then
            ss -lntup 2>/dev/null | grep -Eq "(:|\\])${port}([[:space:]]|$)" && return 0
        fi
        if command -v lsof >/dev/null 2>&1; then
            lsof -nP -iTCP:"$port" -iUDP:"$port" 2>/dev/null | awk 'NR>1 {found=1} END {exit !found}' && return 0
        fi
        if command -v netstat >/dev/null 2>&1; then
            netstat -lntup 2>/dev/null | grep -Eq "(:|\\])${port}([[:space:]]|$)" && return 0
        fi

        return 1
    }

    select_dnscrypt_listen_address() {
        DNSCRYPT_LISTEN_ADDR="127.0.0.1:53"
        DNSCRYPT_RESOLVED_DNS="127.0.0.1"

        if local_port_busy 53; then
            echo -e "${gl_huang}⚠️  检测到本机 53 端口已被占用，dnscrypt-proxy 将改用 127.0.0.1:5353${gl_bai}"
            if local_port_busy 5353; then
                echo -e "${gl_hong}❌ 5353 端口也被占用，无法自动启用 DoH fallback${gl_bai}"
                return 1
            fi
            DNSCRYPT_LISTEN_ADDR="127.0.0.1:5353"
            DNSCRYPT_RESOLVED_DNS="127.0.0.1:5353"
        else
            echo -e "${gl_lv}✅ 本机 53 端口未被占用，dnscrypt-proxy 将监听 127.0.0.1:53${gl_bai}"
        fi

        echo -e "${gl_kjlan}dnscrypt-proxy 最终监听地址: ${DNSCRYPT_LISTEN_ADDR}${gl_bai}"
        echo -e "${gl_kjlan}systemd-resolved 将指向: ${DNSCRYPT_RESOLVED_DNS}${gl_bai}"
        return 0
    }

    configure_dnscrypt_proxy() {
        local dnscrypt_conf="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"

        echo -e "${gl_kjlan}正在配置 DoH 443 fallback（dnscrypt-proxy）...${gl_bai}"

        if ! dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
            echo "  → 正在通过 apt 安装 dnscrypt-proxy..."
            apt-get update -y >/dev/null 2>&1 || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y dnscrypt-proxy >/dev/null 2>&1; then
                echo -e "${gl_hong}❌ dnscrypt-proxy 无法通过系统源自动安装${gl_bai}"
                echo -e "${gl_huang}请确认当前系统源是否提供 dnscrypt-proxy；脚本不会强行编译安装。${gl_bai}"
                return 1
            fi
        fi

        if [[ ! -f "$dnscrypt_conf" ]]; then
            echo -e "${gl_hong}❌ 未找到 dnscrypt-proxy 配置文件: $dnscrypt_conf${gl_bai}"
            return 1
        fi

        select_dnscrypt_listen_address || return 1

        set_dnscrypt_toml_key() {
            local key="$1"
            local value="$2"
            if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$dnscrypt_conf"; then
                sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$dnscrypt_conf"
            else
                printf '\n%s = %s\n' "$key" "$value" >> "$dnscrypt_conf"
            fi
        }

        set_dnscrypt_toml_key "server_names" "['cloudflare', 'google']"
        set_dnscrypt_toml_key "listen_addresses" "['${DNSCRYPT_LISTEN_ADDR}']"
        set_dnscrypt_toml_key "ipv4_servers" "true"
        set_dnscrypt_toml_key "ipv6_servers" "false"
        set_dnscrypt_toml_key "dnscrypt_servers" "false"
        set_dnscrypt_toml_key "doh_servers" "true"
        set_dnscrypt_toml_key "require_dnssec" "false"
        set_dnscrypt_toml_key "require_nolog" "false"
        set_dnscrypt_toml_key "require_nofilter" "false"
        unset -f set_dnscrypt_toml_key >/dev/null 2>&1 || true

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable dnscrypt-proxy >/dev/null 2>&1 || true
        if ! systemctl restart dnscrypt-proxy 2>/dev/null; then
            echo -e "${gl_hong}❌ dnscrypt-proxy 启动失败${gl_bai}"
            systemctl status dnscrypt-proxy --no-pager 2>/dev/null || true
            return 1
        fi

        sleep 2
        if ! systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
            echo -e "${gl_hong}❌ dnscrypt-proxy 未保持运行${gl_bai}"
            return 1
        fi

        if command -v dnscrypt-proxy >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
            if ! timeout 10 dnscrypt-proxy -resolve cloudflare.com -config "$dnscrypt_conf" >/dev/null 2>&1; then
                echo -e "${gl_huang}⚠️  dnscrypt-proxy DoH 解析自检未通过${gl_bai}"
                return 1
            fi
        fi

        echo -e "${gl_lv}✅ DoH 443 fallback 已启用，dnscrypt-proxy 监听 ${DNSCRYPT_LISTEN_ADDR}${gl_bai}"
        return 0
    }

    apply_plain_dns_fallback() {
        TARGET_DNS="8.8.8.8 1.1.1.1"
        FALLBACK_DNS=""
        DNS_OVER_TLS="no"
        DNSSEC_MODE="no"
        MODE_NAME="纯国外模式（普通 DNS 53 fallback）"
        INTERFACE_DNS_PRIMARY="8.8.8.8"
        INTERFACE_DNS_SECONDARY="1.1.1.1"
    }

    # 目标DNS配置（根据用户选择的模式）
    local TARGET_DNS=""
    local FALLBACK_DNS=""
    local DNS_OVER_TLS=""
    local DNSSEC_MODE=""
    local MODE_NAME=""
    # 网卡级 DNS（用于 resolvectl）
    local INTERFACE_DNS_PRIMARY=""
    local INTERFACE_DNS_SECONDARY=""
    local DNSCRYPT_LISTEN_ADDR="127.0.0.1:53"
    local DNSCRYPT_RESOLVED_DNS="127.0.0.1"
    case "$dns_mode_choice" in
        1)
            # 纯国外模式
            TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
            FALLBACK_DNS=""
            DNS_OVER_TLS="yes"
            DNSSEC_MODE="no"
            MODE_NAME="纯国外模式"
            # 网卡级使用纯IP，避免个别systemd/resolvectl版本对SNI参数兼容问题
            INTERFACE_DNS_PRIMARY="8.8.8.8"
            INTERFACE_DNS_SECONDARY="1.1.1.1"
            ;;
        2)
            # 纯国内模式（国内DNS和国内域名大多不支持DNSSEC，必须禁用）
            TARGET_DNS="223.5.5.5 119.29.29.29"
            FALLBACK_DNS=""
            DNS_OVER_TLS="no"
            DNSSEC_MODE="no"
            MODE_NAME="纯国内模式"
            INTERFACE_DNS_PRIMARY="223.5.5.5"
            INTERFACE_DNS_SECONDARY="119.29.29.29"
            ;;
    esac

    # DoT 预检：853 不可达时提供 DoH/普通 DNS 降级，不直接终止
    if [[ "$dns_mode_choice" == "1" ]]; then
        local dot_reachable_count=0
        can_connect_tcp "8.8.8.8" 853 && dot_reachable_count=$((dot_reachable_count + 1))
        can_connect_tcp "1.1.1.1" 853 && dot_reachable_count=$((dot_reachable_count + 1))

        if [[ "$dot_reachable_count" -eq 0 ]]; then
            echo -e "${gl_huang}⚠️  检测到当前网络无法连接 DoT 853${gl_bai}"
            echo "可能是 NAT 商家或机房防火墙封锁出站 853。"
            echo ""

            local doh_choice=""
            read -e -p "$(echo -e "${gl_huang}是否自动切换到 DoH 443 模式？(Y/n): ${gl_bai}")" doh_choice
            doh_choice=${doh_choice:-Y}

            if [[ "$doh_choice" =~ ^[Yy]$ ]]; then
                if configure_dnscrypt_proxy; then
                    TARGET_DNS="$DNSCRYPT_RESOLVED_DNS"
                    FALLBACK_DNS=""
                    DNS_OVER_TLS="no"
                    DNSSEC_MODE="no"
                    MODE_NAME="纯国外模式（DoH 443 fallback）"
                    INTERFACE_DNS_PRIMARY="$DNSCRYPT_RESOLVED_DNS"
                    INTERFACE_DNS_SECONDARY="$DNSCRYPT_RESOLVED_DNS"
                    DNS_PURIFY_RESULT="DoH fallback 已启用"
                    echo -e "${gl_lv}DoH fallback 生效路径: systemd-resolved -> ${DNSCRYPT_RESOLVED_DNS} -> dnscrypt-proxy -> DoH 443${gl_bai}"
                else
                    echo -e "${gl_huang}⚠️  DoH 443 模式启用失败${gl_bai}"
                    local plain_choice=""
                    read -e -p "$(echo -e "${gl_huang}是否降级为普通 DNS 53？(Y/n): ${gl_bai}")" plain_choice
                    plain_choice=${plain_choice:-Y}
                    if [[ "$plain_choice" =~ ^[Yy]$ ]]; then
                        auto_rollback_dns_purify
                        apply_plain_dns_fallback
                        DNS_PURIFY_RESULT="普通 DNS 53 fallback 已启用"
                    else
                        auto_rollback_dns_purify
                        DNS_PURIFY_RESULT="用户跳过"
                        echo -e "${gl_huang}已跳过 DNS 净化，不影响后续 BBR/TCP 调优流程${gl_bai}"
                        return 0
                    fi
                fi
            else
                local plain_choice=""
                read -e -p "$(echo -e "${gl_huang}是否降级为普通 DNS 53？(Y/n): ${gl_bai}")" plain_choice
                plain_choice=${plain_choice:-Y}
                if [[ "$plain_choice" =~ ^[Yy]$ ]]; then
                    apply_plain_dns_fallback
                    DNS_PURIFY_RESULT="普通 DNS 53 fallback 已启用"
                else
                    DNS_PURIFY_RESULT="用户跳过"
                    echo -e "${gl_huang}已跳过 DNS 净化，不影响后续 BBR/TCP 调优流程${gl_bai}"
                    return 0
                fi
            fi
        else
            DNS_PURIFY_RESULT="DoT 成功"
            echo -e "${gl_lv}✅ DoT 853 可达，继续使用 systemd-resolved + DNSOverTLS${gl_bai}"
        fi
    fi
    
    echo -e "${gl_lv}已选择：${MODE_NAME}${gl_bai}"
    echo ""
    
    # 构建配置（动态拼接，避免 FallbackDNS 为空时产生空行）
    local SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}"
    if [[ -n "$FALLBACK_DNS" ]]; then
        SECURE_RESOLVED_CONFIG="${SECURE_RESOLVED_CONFIG}
FallbackDNS=${FALLBACK_DNS}"
    fi
    SECURE_RESOLVED_CONFIG="${SECURE_RESOLVED_CONFIG}
LLMNR=no
MulticastDNS=no
DNSSEC=${DNSSEC_MODE}
DNSOverTLS=${DNS_OVER_TLS}
Cache=yes
DNSStubListener=yes
"

    echo "--- 开始执行DNS净化与安全加固流程 ---"
    echo ""

    local debian_version
    debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "unknown")

    # ==================== 阶段一：清除DNS冲突源 ====================
    echo -e "${gl_kjlan}[阶段 1/5] 清除DNS冲突源（安全操作）...${gl_bai}"
    echo ""

    # 1. 驯服 DHCP 客户端
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        # 备份
        cp "$dhclient_conf" "$BACKUP_DIR/dhclient.conf.bak" 2>/dev/null || true
        
        local dhclient_changed=false
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo "" >> "$dhclient_conf"
            echo "# 由DNS净化脚本添加 - $(date)" >> "$dhclient_conf"
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            dhclient_changed=true
        fi
        if ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            if [ "$dhclient_changed" = false ]; then
                echo "" >> "$dhclient_conf"
                echo "# 由DNS净化脚本添加 - $(date)" >> "$dhclient_conf"
            fi
            echo "ignore domain-search;" >> "$dhclient_conf"
            dhclient_changed=true
        fi
        if [ "$dhclient_changed" = true ]; then
            echo "  → 配置 dhclient 忽略DHCP提供的DNS..."
            echo -e "${gl_lv}  ✅ dhclient 配置完成${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ dhclient 已配置（跳过）${gl_bai}"
        fi
    fi

    # 2. 禁用冲突的 if-up.d 脚本
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -f "$ifup_script" ]] && [[ -x "$ifup_script" ]]; then
        echo "  → 禁用 if-up.d/resolved 脚本..."
        chmod -x "$ifup_script"
        echo -e "${gl_lv}  ✅ 已移除可执行权限${gl_bai}"
    fi

    # 3. 注释 /etc/network/interfaces 中的DNS配置
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]]; then
        # 备份
        cp "$interfaces_file" "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
        
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            echo "  → 清除 /etc/network/interfaces 中的DNS配置..."
            sed -i.bak -E 's/^([[:space:]]*dns-(nameservers|search|domain).*)/# \1 # 已被DNS净化脚本禁用/' "$interfaces_file"
            echo -e "${gl_lv}  ✅ 厂商DNS配置已注释${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ /etc/network/interfaces 无DNS配置${gl_bai}"
        fi
    fi

    echo ""

    # ==================== 阶段二：配置 systemd-resolved ====================
    echo -e "${gl_kjlan}[阶段 2/5] 配置 systemd-resolved...${gl_bai}"
    echo ""

    # 检查是否已安装
    if ! command -v resolvectl &> /dev/null; then
        echo "  → 检测到未安装 systemd-resolved"
        echo "  → 安装 systemd-resolved..."
        apt-get update -y > /dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved > /dev/null 2>&1
        echo -e "${gl_lv}  ✅ systemd-resolved 安装完成${gl_bai}"
    else
        echo -e "${gl_lv}  ✅ systemd-resolved 已安装${gl_bai}"
    fi

    # 处理 Debian 11 的 resolvconf 冲突
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null; then
        echo "  → 检测到 Debian 11 的 resolvconf 冲突"
        
        # 🛡️ 关键修复：在卸载前确保 systemd-resolved 完全就绪
        # 先启动 systemd-resolved
        echo "  → 启动 systemd-resolved（在卸载 resolvconf 之前）..."
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        
        # 等待服务启动
        sleep 2
        
        # 验证 systemd-resolved 正在运行
        if ! systemctl is-active --quiet systemd-resolved; then
            echo -e "${gl_hong}❌ 无法启动 systemd-resolved，中止操作${gl_bai}"
            auto_rollback_dns_purify
            break_end
            return 1
        fi
        
        # 验证 stub-resolv.conf 存在
        if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
            echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在，中止操作${gl_bai}"
            auto_rollback_dns_purify
            break_end
            return 1
        fi
        
        # 现在可以安全地卸载 resolvconf
        # 备份当前 resolv.conf
        [[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.pre_remove" 2>/dev/null || true
        
        # 创建临时DNS配置（避免卸载期间DNS中断）
        echo "nameserver $(plain_dns_ip "$INTERFACE_DNS_PRIMARY")" > /etc/resolv.conf.tmp
        echo "nameserver $(plain_dns_ip "$INTERFACE_DNS_SECONDARY")" >> /etc/resolv.conf.tmp
        
        # 使用临时DNS配置
        mv /etc/resolv.conf /etc/resolv.conf.old 2>/dev/null || true
        cp /etc/resolv.conf.tmp /etc/resolv.conf
        
        # 卸载 resolvconf
        echo "  → 卸载 resolvconf..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y resolvconf > /dev/null 2>&1
        
        # 清理临时文件
        rm -f /etc/resolv.conf.tmp /etc/resolv.conf.old
        
        echo -e "${gl_lv}  ✅ resolvconf 已安全卸载${gl_bai}"
    fi

    # 🔧 调用智能修复函数
    if ! dns_purify_fix_systemd_resolved; then
        echo -e "${gl_hong}❌ 无法修复 systemd-resolved 服务，脚本终止${gl_bai}"
        echo "检测到修复失败，正在自动回滚到执行前状态"
        auto_rollback_dns_purify
        break_end
        return 1
    fi

    # 备份并写入配置
    if [[ -f /etc/systemd/resolved.conf ]]; then
        cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null || true
    fi

    echo "  → 配置 systemd-resolved..."
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    
    echo ""

    # ==================== 阶段三：应用DNS配置（SSH安全方式）====================
    echo -e "${gl_kjlan}[阶段 3/5] 应用DNS配置（SSH安全模式）...${gl_bai}"
    echo ""

    # 先重新加载 systemd-resolved 配置
    echo "  → 重新加载 systemd-resolved 配置..."
    if ! systemctl reload-or-restart systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 重启失败！${gl_bai}"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    # 等待服务完全启动
    echo "  → 等待 systemd-resolved 完全启动..."
    sleep 3
    
    # 验证服务状态
    if ! systemctl is-active --quiet systemd-resolved; then
        echo -e "${gl_hong}❌ systemd-resolved 未能正常运行！${gl_bai}"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    # 验证 stub-resolv.conf 文件存在
    if [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
        echo -e "${gl_hong}❌ systemd-resolved stub 文件不存在！${gl_bai}"
        echo "路径: /run/systemd/resolve/stub-resolv.conf"
        echo "正在自动回滚配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ systemd-resolved 配置已重新加载并验证${gl_bai}"

    # 🔧 确保服务开机自启动（修复 #11：某些 Debian 版本服务状态为 static 时不会自启）
    echo "  → 确保 systemd-resolved 开机自启动..."
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    echo -e "${gl_lv}  ✅ 已设置开机自启动${gl_bai}"

    # 🔒 检测 immutable 属性（云服务商保护机制）
    if [[ -e /etc/resolv.conf ]] && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        echo ""
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}⚠️  检测到 /etc/resolv.conf 被锁定保护${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "原因：您的服务器设置了不可变属性（通常是云服务商的保护机制）"
        echo ""
        echo "风险：强制修改可能导致机器失联或网络异常"
        echo ""
        echo "建议：如非必要，不建议继续修改"
        echo "      能正常执行的系统不会弹出此提示"
        echo ""
        echo -e "${gl_huang}状态：检测到锁定保护，正在恢复已修改的配置${gl_bai}"
        # 只回滚 resolved.conf（阶段二已修改），不做完整回滚
        # resolv.conf 尚未被修改（软链接替换在此检查之后），无需恢复
        restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
        systemctl reload-or-restart systemd-resolved 2>/dev/null || true
        echo ""
        break_end
        return 1
    fi
    
    # 🛡️ 关键修复：安全地创建 resolv.conf 链接
    # 备份并创建 resolv.conf 链接（只有在验证通过后才执行）
    if [[ -e /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
        # 如果是普通文件，备份它
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    fi
    
    # 安全地创建链接
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    
    # 验证链接创建成功
    if [[ ! -L /etc/resolv.conf ]] || [[ ! -e /etc/resolv.conf ]]; then
        echo -e "${gl_hong}❌ resolv.conf 链接创建失败！${gl_bai}"
        echo "正在自动回滚原始配置..."
        auto_rollback_dns_purify
        break_end
        return 1
    fi
    
    echo -e "${gl_lv}  ✅ resolv.conf 链接已安全创建${gl_bai}"
    
    # 🚫 完全移除 networking.service 重启（即使非SSH模式也危险）
    # 注意：不管是SSH还是本地连接，都不重启 networking.service
    # 因为重启网络服务在生产环境中极其危险
    echo -e "${gl_lv}  ✅ 网络服务未受影响（安全模式）${gl_bai}"

    echo ""
    
    # ==================== Debian 13特殊修复：D-Bus接口注册问题 ====================
    echo -e "${gl_kjlan}[特殊修复] 检测并修复 D-Bus 接口注册（Debian 13兼容）...${gl_bai}"
    echo ""
    
    # 检测是否需要修复D-Bus接口
    local need_dbus_fix=false
    # debian_version 已在阶段二前定义，此处直接使用

    echo "  → 检测系统版本：Debian ${debian_version:-未知}"
    
    # 检查resolvectl是否能正常通信
    echo "  → 测试 resolvectl 命令响应..."
    if ! timeout 3 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 命令无响应，需要修复 D-Bus 接口${gl_bai}"
        need_dbus_fix=true
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    # 如果需要修复D-Bus接口
    if [ "$need_dbus_fix" = true ]; then
        echo ""
        echo -e "${gl_huang}检测到 D-Bus 接口注册问题（Debian 13已知问题），正在自动修复...${gl_bai}"
        echo ""
        
        # 🛡️ 安全措施：在重启前创建临时DNS配置，确保DNS始终可用
        echo "  → 创建临时DNS配置（防止修复期间DNS中断）..."
        
        # 备份当前resolv.conf
        if [[ -e /etc/resolv.conf ]]; then
            cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.before_dbus_fix" 2>/dev/null || true
        fi
        
        # 创建临时DNS配置文件
cat > /etc/resolv.conf.dbus_fix_temp << TEMP_DNS
# 临时DNS配置（D-Bus修复期间使用）
nameserver $(plain_dns_ip "$INTERFACE_DNS_PRIMARY")
nameserver $(plain_dns_ip "$INTERFACE_DNS_SECONDARY")
TEMP_DNS
        
        # 使用临时DNS配置
        rm -f /etc/resolv.conf
        cp /etc/resolv.conf.dbus_fix_temp /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        
        echo -e "${gl_lv}  ✅ 临时DNS配置已创建（确保修复期间DNS可用）${gl_bai}"
        
        # 1. 完全重启systemd-resolved，让它重新注册D-Bus接口
        echo "  → 重启 systemd-resolved 以重新注册 D-Bus 接口..."
        systemctl stop systemd-resolved 2>/dev/null || true
        sleep 2
        systemctl start systemd-resolved 2>/dev/null || true
        sleep 3
        
        # 🛡️ 恢复到 stub-resolv.conf 链接
        echo "  → 恢复 resolv.conf 链接到 stub-resolv.conf..."
        
        # 验证 stub-resolv.conf 存在
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            rm -f /etc/resolv.conf
            ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            echo -e "${gl_lv}  ✅ resolv.conf 链接已恢复${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  stub-resolv.conf 不存在，保持临时DNS配置${gl_bai}"
        fi
        
        # 清理临时文件
        rm -f /etc/resolv.conf.dbus_fix_temp
        
        # 2. 验证D-Bus接口是否注册成功
        if command -v busctl &>/dev/null; then
            local dbus_status=$(busctl list 2>/dev/null | grep "org.freedesktop.resolve1" | grep -v "activatable" || echo "")
            if [ -n "$dbus_status" ]; then
                echo -e "${gl_lv}  ✅ D-Bus 接口已成功注册${gl_bai}"
                
                # 3. 创建永久修复配置（确保重启后也能正常工作）
                echo "  → 创建永久修复配置..."
                mkdir -p /etc/systemd/system/systemd-resolved.service.d
                cat > /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf << 'DBUS_FIX'
# Debian 13 D-Bus接口注册修复
# 确保D-Bus完全启动后再启动systemd-resolved
[Unit]
After=dbus.service
Requires=dbus.service

[Service]
# 启动后等待1秒，确保D-Bus接口注册完成
ExecStartPost=/bin/sleep 1
DBUS_FIX
                
                systemctl daemon-reload 2>/dev/null || true
                echo -e "${gl_lv}  ✅ 永久修复配置已创建${gl_bai}"
                
                # 4. 再次测试resolvectl
                if timeout 3 resolvectl status >/dev/null 2>&1; then
                    echo -e "${gl_lv}  ✅ resolvectl 现在能正常工作了${gl_bai}"
                else
                    echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应（但DNS配置已通过resolved.conf生效）${gl_bai}"
                fi
            else
                echo -e "${gl_huang}  ⚠️  D-Bus 接口注册可能失败${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        else
            echo -e "${gl_huang}  ⚠️  busctl 命令不可用，无法验证 D-Bus 状态${gl_bai}"
            echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        fi
        
        echo ""
    fi

    echo ""

    # ==================== 阶段四：配置网卡DNS ====================
    echo -e "${gl_kjlan}[阶段 4/5] 配置网卡DNS（立即生效）...${gl_bai}"
    echo ""
    
    # 🔥 强力保障：阶段4执行前二次验证resolvectl（确保100%成功）
    echo "  → 验证 resolvectl 命令状态..."
    local resolvectl_ready=true
    
    # 快速测试resolvectl是否响应（2秒超时）
    if ! timeout 2 resolvectl status >/dev/null 2>&1; then
        echo -e "${gl_huang}  ⚠️  resolvectl 仍无响应${gl_bai}"
        echo ""
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}检测到 resolvectl 命令无法正常工作${gl_bai}"
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "这可能导致阶段4的网卡级DNS配置失败。"
        echo ""
        echo "你可以选择："
        echo "  1) 尝试强制修复（会重启systemd-resolved，有临时DNS保护）"
        echo "  2) 跳过网卡配置（安全，全局DNS已生效，推荐）"
        echo ""
        if [ "$AUTO_MODE" = "1" ]; then
            force_fix_choice=2
        else
            read -e -p "$(echo -e "${gl_huang}请选择 (1/2，默认2): ${gl_bai}")" force_fix_choice
            force_fix_choice=${force_fix_choice:-2}
        fi
        
        if [[ "$force_fix_choice" == "1" ]]; then
            echo ""
            echo -e "${gl_kjlan}正在执行强制修复...${gl_bai}"
            resolvectl_ready=false
            
            # 强制修复：重启systemd-resolved重新注册D-Bus
            echo "  → 创建临时DNS保护..."
            
            # 创建临时DNS保护
            cat > /etc/resolv.conf.stage4_temp << STAGE4_TEMP
nameserver $(plain_dns_ip "$INTERFACE_DNS_PRIMARY")
nameserver $(plain_dns_ip "$INTERFACE_DNS_SECONDARY")
STAGE4_TEMP
            cp /etc/resolv.conf /etc/resolv.conf.stage4_backup 2>/dev/null || true
            cp /etc/resolv.conf.stage4_temp /etc/resolv.conf
            
            echo "  → 强制重启 systemd-resolved..."
            # 完全重启服务
            systemctl stop systemd-resolved 2>/dev/null || true
            sleep 2
            systemctl start systemd-resolved 2>/dev/null || true
            sleep 3
            
            # 恢复链接
            echo "  → 恢复 resolv.conf 链接..."
            if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
                rm -f /etc/resolv.conf
                ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            fi
            
            # 清理临时文件
            rm -f /etc/resolv.conf.stage4_temp /etc/resolv.conf.stage4_backup
            
            # 再次验证
            echo "  → 验证修复结果..."
            if timeout 2 resolvectl status >/dev/null 2>&1; then
                echo -e "${gl_lv}  ✅ resolvectl 已修复，可以继续${gl_bai}"
                resolvectl_ready=true
            else
                echo -e "${gl_huang}  ⚠️  resolvectl 仍无法正常工作${gl_bai}"
                echo -e "${gl_lv}  ✅ 将跳过网卡级DNS配置（全局DNS已生效）${gl_bai}"
                resolvectl_ready=false
            fi
            echo ""
        else
            echo ""
            echo -e "${gl_lv}已选择跳过强制修复（安全选择）${gl_bai}"
            echo -e "${gl_lv}将跳过网卡级DNS配置，全局DNS配置已生效${gl_bai}"
            resolvectl_ready=false
            echo ""
        fi
    else
        echo -e "${gl_lv}  ✅ resolvectl 响应正常${gl_bai}"
    fi
    
    echo ""

    # 检测主网卡
    local main_interface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

    if [[ -n "$main_interface" ]] && command -v resolvectl &> /dev/null && [ "$resolvectl_ready" = true ]; then
        echo "  → 检测到主网卡: ${main_interface}"
        
        # 🛡️ 关键修复：检查timeout命令是否可用
        if ! command -v timeout &> /dev/null; then
            echo -e "${gl_huang}  ⚠️  timeout命令不可用，跳过网卡级DNS配置${gl_bai}"
            echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
        else
            echo "  → 配置网卡 DNS（立即生效，无需重启）..."
            echo ""
            
            # 🛡️ 修复：添加超时机制防止resolvectl命令hang住
            local resolvectl_timeout=5  # 5秒超时
            local dns_config_success=true
            
            echo "    正在应用DNS服务器配置..."
            if timeout "$resolvectl_timeout" resolvectl dns "$main_interface" "$INTERFACE_DNS_PRIMARY" "$INTERFACE_DNS_SECONDARY" 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS服务器配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS服务器配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用DNS域配置..."
            if timeout "$resolvectl_timeout" resolvectl domain "$main_interface" ~. 2>/dev/null; then
                echo -e "    ${gl_lv}✅ DNS域配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  DNS域配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo "    正在应用默认路由配置..."
            if timeout "$resolvectl_timeout" resolvectl default-route "$main_interface" yes 2>/dev/null; then
                echo -e "    ${gl_lv}✅ 默认路由配置成功${gl_bai}"
            else
                echo -e "    ${gl_huang}⚠️  默认路由配置超时或失败（配置已通过resolved.conf生效）${gl_bai}"
                dns_config_success=false
            fi
            
            echo ""
            if [ "$dns_config_success" = true ]; then
                echo -e "${gl_lv}  ✅ 网卡DNS配置已全部应用${gl_bai}"
            else
                echo -e "${gl_huang}  ⚠️  部分网卡DNS配置未能通过resolvectl应用${gl_bai}"
                echo -e "${gl_lv}  ✅ 但DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
            fi
        fi
        echo -e "${gl_lv}  ✅ DNS配置立即生效，无需重启${gl_bai}"
    else
        if [[ -z "$main_interface" ]]; then
            echo -e "${gl_huang}  ⚠️  未检测到默认网卡${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  resolvectl 命令不可用${gl_bai}"
        fi
        echo -e "${gl_lv}  ✅ DNS配置已通过 /etc/systemd/resolved.conf 生效${gl_bai}"
    fi

    # ==================== 阶段4.5：持久化前健康检查 ====================
    echo ""
    echo -e "${gl_kjlan}[阶段 4.5/5] 持久化前DNS健康检查...${gl_bai}"
    echo ""
    local precheck_dns_ok=false
    if [[ "$dns_mode_choice" == "2" ]]; then
        if dns_runtime_health_check "cn"; then
            precheck_dns_ok=true
        fi
    else
        if dns_runtime_health_check "global"; then
            precheck_dns_ok=true
        fi
    fi

    # strict 模式下绝不自动降级：解析失败立即回滚并退出
    if [ "$precheck_dns_ok" = false ] && [ "$DNS_OVER_TLS" = "yes" ]; then
        echo -e "${gl_hong}❌ strict DoT 健康检查失败，按严格策略中止并回滚（不降级）${gl_bai}"
        auto_rollback_dns_purify
        break_end
        return 1
    fi

    if [ "$precheck_dns_ok" = false ]; then
        echo -e "${gl_hong}❌ 持久化前DNS健康检查失败，正在自动回滚本次配置${gl_bai}"
        auto_rollback_dns_purify
        echo -e "${gl_huang}已自动回滚，请检查机房网络对上游DNS/DoT(853)连通性后重试${gl_bai}"
        break_end
        return 1
    else
        echo -e "${gl_lv}✅ 持久化前DNS健康检查通过${gl_bai}"
    fi

    # ==================== 阶段五：配置重启持久化 ====================
    echo ""
    echo -e "${gl_kjlan}[阶段 5/5] 配置重启持久化（确保重启后DNS不失效）...${gl_bai}"
    echo ""

    # --- 5a: 创建开机自动恢复脚本 ---
    echo "  → 创建DNS持久化恢复脚本..."
    cat > /usr/local/bin/dns-purify-apply.sh << 'PERSIST_SCRIPT_HEAD'
#!/bin/bash
# DNS净化持久化脚本 - 开机自动恢复网卡级DNS配置
# 由 net-tcp-tune.sh DNS净化功能自动生成
# 安全说明：仅重新应用 resolvectl 运行时配置，不修改网络服务

PERSIST_SCRIPT_HEAD

    # 写入用户选择的DNS（动态替换变量）
    cat >> /usr/local/bin/dns-purify-apply.sh << PERSIST_SCRIPT_VARS
DNS_PRIMARY="${INTERFACE_DNS_PRIMARY}"
DNS_SECONDARY="${INTERFACE_DNS_SECONDARY}"
PERSIST_SCRIPT_VARS

    cat >> /usr/local/bin/dns-purify-apply.sh << 'PERSIST_SCRIPT_BODY'

# 前置检查：resolvectl 是否可用
if ! command -v resolvectl >/dev/null 2>&1; then
    echo "dns-purify: resolvectl 不可用，跳过" | systemd-cat -t dns-purify 2>/dev/null || true
    exit 0
fi

# 检测默认网卡（动态获取，适应网卡名变更）
IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

if [ -z "$IFACE" ]; then
    echo "dns-purify: 未检测到默认网卡，跳过" | systemd-cat -t dns-purify 2>/dev/null || true
    exit 0
fi

# 等待 systemd-resolved 完全就绪（最多等30秒）
for i in $(seq 1 15); do
    if resolvectl status >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# 应用网卡级DNS配置
resolvectl dns "$IFACE" "$DNS_PRIMARY" "$DNS_SECONDARY" 2>/dev/null
resolvectl domain "$IFACE" "~." 2>/dev/null
resolvectl default-route "$IFACE" yes 2>/dev/null

# 验证DNS可用性
sleep 2
if getent hosts google.com >/dev/null 2>&1 || getent hosts baidu.com >/dev/null 2>&1; then
    echo "dns-purify: DNS配置恢复成功 (接口: $IFACE, DNS: $DNS_PRIMARY $DNS_SECONDARY)" | systemd-cat -t dns-purify 2>/dev/null || true
else
    echo "dns-purify: DNS验证未通过，但配置已应用 (接口: $IFACE)" | systemd-cat -t dns-purify 2>/dev/null || true
fi
PERSIST_SCRIPT_BODY

    chmod +x /usr/local/bin/dns-purify-apply.sh
    echo -e "${gl_lv}  ✅ 持久化脚本已创建: /usr/local/bin/dns-purify-apply.sh${gl_bai}"

    # --- 5b: 创建 systemd 开机服务 ---
    echo "  → 创建开机自启服务..."
    cat > /etc/systemd/system/dns-purify-persist.service << 'PERSIST_SERVICE'
[Unit]
Description=DNS Purify - Restore DNS Configuration on Boot
Documentation=https://github.com/Eric86777/vps-tcp-tune
After=systemd-resolved.service network-online.target
Wants=network-online.target
Wants=systemd-resolved.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dns-purify-apply.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
PERSIST_SERVICE

    systemctl daemon-reload
    systemctl enable dns-purify-persist.service >/dev/null 2>&1
    echo -e "${gl_lv}  ✅ 开机自启服务已创建并启用: dns-purify-persist.service${gl_bai}"

    # --- 5c: 阻止 systemd-networkd DHCP 覆盖DNS（最常见的重启失效原因）---
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "  → 检测到 systemd-networkd，配置 DHCP DNS 阻断..."

        # 查找当前网卡对应的 .network 配置文件
        local networkd_file=""
        if command -v networkctl &>/dev/null; then
            networkd_file=$(networkctl status "$main_interface" 2>/dev/null | sed -nE 's/.*Network File:[[:space:]]*(.*)/\1/p' | head -1)
        fi

        if [[ -n "$networkd_file" ]] && [[ -f "$networkd_file" ]]; then
            # 安全方式：创建 drop-in 覆盖，不修改原文件
            local dropin_dir="${networkd_file}.d"
            mkdir -p "$dropin_dir"
            cat > "$dropin_dir/dns-purify-override.conf" << 'NETWORKD_DROPIN'
# DNS净化脚本 - 阻止DHCP覆盖DNS配置
# 仅禁用DHCP下发的DNS，不影响IP地址等其他DHCP功能
[DHCP]
UseDNS=false
UseDomains=false
NETWORKD_DROPIN
            echo -e "${gl_lv}  ✅ systemd-networkd DHCP DNS 阻断已配置（drop-in: ${dropin_dir}/）${gl_bai}"
            echo -e "${gl_lv}     仅阻止DNS覆盖，不影响IP/网关等DHCP功能${gl_bai}"
        else
            # 没找到现有配置文件，创建通用的 drop-in 目录
            echo -e "${gl_huang}  ⚠️  未找到 ${main_interface} 的 .network 文件${gl_bai}"
            echo -e "${gl_lv}  ✅ 已通过开机服务保障重启后DNS恢复${gl_bai}"
        fi
    else
        echo -e "${gl_lv}  ✅ 未使用 systemd-networkd（无需额外配置）${gl_bai}"
    fi

    # --- 5d: 处理 NetworkManager（如果存在）---
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "  → 检测到 NetworkManager，配置DNS保护..."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-dns-purify.conf << 'NM_CONF'
# DNS净化脚本 - 让 NetworkManager 使用 systemd-resolved
# 不直接管理 /etc/resolv.conf，交给 systemd-resolved
[main]
dns=systemd-resolved
NM_CONF
        echo -e "${gl_lv}  ✅ NetworkManager 已配置为使用 systemd-resolved${gl_bai}"
    fi

    echo ""
    echo -e "${gl_lv}  ✅ 重启持久化配置完成，重启后DNS不会失效${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✅ DNS净化完成！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    # 显示当前DNS状态
    echo -e "${gl_huang}当前DNS配置：${gl_bai}"
    echo "────────────────────────────────────────────────────────"
    if command -v resolvectl &> /dev/null; then
        resolvectl status 2>/dev/null | head -30 || cat /etc/resolv.conf
    else
        cat /etc/resolv.conf
    fi
    echo "────────────────────────────────────────────────────────"
    
    # ==================== 统一验证输出（兼容所有systemd版本）====================
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[智能验证] 网卡DNS配置状态检测：${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    if command -v resolvectl &> /dev/null && [[ -n "$main_interface" ]]; then
        local verify_output=$(resolvectl status "$main_interface" 2>/dev/null || echo "")
        local verify_success=true
        
        # 检测1: Default Route（兼容不同systemd版本）
        if echo "$verify_output" | grep -q "Default Route: yes" || \
           echo "$verify_output" | grep -q "Protocols:.*+DefaultRoute"; then
            echo -e "  ${gl_lv}✅ Default Route: 已启用${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  Default Route: 未启用或不支持${gl_bai}"
            verify_success=false
        fi
        
        # 检测2: DNS Servers（根据用户选择的模式动态验证）
        local escaped_dns_primary=$(echo "$INTERFACE_DNS_PRIMARY" | sed 's/\./\\./g')
        local escaped_dns_secondary=$(echo "$INTERFACE_DNS_SECONDARY" | sed 's/\./\\./g')
        if echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_primary}" && \
           echo "$verify_output" | grep -q "DNS Servers:.*${escaped_dns_secondary}"; then
            echo -e "  ${gl_lv}✅ DNS Servers: ${INTERFACE_DNS_PRIMARY}, ${INTERFACE_DNS_SECONDARY}${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Servers: 配置可能未完全生效${gl_bai}"
            verify_success=false
        fi
        
        # 检测3: DNS Domain
        if echo "$verify_output" | grep -q "DNS Domain:.*~\."; then
            echo -e "  ${gl_lv}✅ DNS Domain: ~. (所有域名)${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠️  DNS Domain: 未配置${gl_bai}"
            verify_success=false
        fi
        
        echo ""
        
        # 最终判断
        if [ "$verify_success" = true ]; then
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_lv}💯 最终判断: 网卡DNS配置 100% 成功！${gl_bai}"
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        else
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_huang}⚠️  网卡DNS配置部分未生效${gl_bai}"
            echo -e "${gl_lv}✅ 但全局DNS配置已生效，DNS解析正常工作${gl_bai}"
            echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        fi
    else
        echo -e "${gl_huang}  ⚠️  resolvectl 不可用或未检测到网卡${gl_bai}"
        echo -e "${gl_lv}  ✅ 全局DNS配置已生效${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    fi
    
    echo ""

    # 测试DNS解析（等待配置生效）
    echo -e "${gl_huang}测试DNS解析：${gl_bai}"
    echo "  → 等待DNS配置生效（3秒）..."
    sleep 3
    
    local dns_test_passed=false
    if [[ "$dns_mode_choice" == "2" ]]; then
        if dns_runtime_health_check "cn"; then
            echo -e "${gl_lv}  ✅ DNS解析正常（国内链路）${gl_bai}"
            dns_test_passed=true
        fi
    else
        if dns_runtime_health_check "global"; then
            echo -e "${gl_lv}  ✅ DNS解析正常（国际链路）${gl_bai}"
            dns_test_passed=true
        fi
    fi
    
    # 如果所有测试都失败
    if [ "$dns_test_passed" = false ]; then
        echo -e "${gl_hong}  ❌ DNS测试未通过，触发自动回滚以避免遗留隐患${gl_bai}"
        auto_rollback_dns_purify
        # 回滚后再次校验，确保脚本退出时机器仍可解析
        local post_rollback_ok=false
        if dns_runtime_health_check "global" || dns_runtime_health_check "cn"; then
            post_rollback_ok=true
        fi
        if [ "$post_rollback_ok" = true ]; then
            echo -e "${gl_lv}  ✅ 回滚后DNS健康校验通过${gl_bai}"
        else
            echo -e "${gl_huang}  ⚠️  回滚后DNS仍异常，请检查上游网络/防火墙策略${gl_bai}"
        fi
        echo -e "${gl_huang}  已自动恢复执行前配置，请检查网络环境后重试${gl_bai}"
        break_end
        return 1
    fi
    echo ""

    # ==================== 生成回滚脚本 ====================
    cat > "$BACKUP_DIR/rollback.sh" << 'ROLLBACK_SCRIPT'
#!/bin/bash
# DNS配置回滚脚本
# 使用方法: bash rollback.sh

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DNS配置回滚脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BACKUP_DIR="$(dirname "$0")"
PRE_STATE_DIR="$BACKUP_DIR/pre_state"

# 优先使用增强回滚（精确恢复执行前状态）
if [[ -d "$PRE_STATE_DIR" ]]; then
    echo "检测到增强备份元数据，正在精确恢复执行前状态..."

    restore_path_state() {
        local dst="$1"
        local key="$2"
        rm -f "$dst" 2>/dev/null || true
        if [[ -e "$PRE_STATE_DIR/$key" || -L "$PRE_STATE_DIR/$key" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -a "$PRE_STATE_DIR/$key" "$dst" 2>/dev/null || true
        elif [[ -f "$PRE_STATE_DIR/$key.absent" ]]; then
            rm -f "$dst" 2>/dev/null || true
        fi
    }

    # 恢复配置文件（resolv.conf 延后，避免悬空链接）
    restore_path_state "/etc/dhcp/dhclient.conf" "dhclient.conf"
    restore_path_state "/etc/network/interfaces" "interfaces"
    restore_path_state "/etc/systemd/resolved.conf" "resolved.conf"
    restore_path_state "/etc/systemd/system/dns-purify-persist.service" "dns-purify-persist.service"
    restore_path_state "/usr/local/bin/dns-purify-apply.sh" "dns-purify-apply.sh"
    restore_path_state "/etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf" "dbus-fix.conf"
    restore_path_state "/etc/NetworkManager/conf.d/99-dns-purify.conf" "nm-99-dns-purify.conf"
    restore_path_state "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" "dnscrypt-proxy.toml"

    # 恢复 dnscrypt-proxy 配置与服务状态（DoH fallback）
    had_dnscrypt_proxy_pkg="false"
    dnscrypt_proxy_was_enabled="false"
    dnscrypt_proxy_was_active="false"
    [[ -f "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" ]] && had_dnscrypt_proxy_pkg=$(cat "$PRE_STATE_DIR/had-dnscrypt-proxy.pkg" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" ]] && dnscrypt_proxy_was_enabled=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-enabled" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/dnscrypt-proxy.was-active" ]] && dnscrypt_proxy_was_active=$(cat "$PRE_STATE_DIR/dnscrypt-proxy.was-active" 2>/dev/null || echo "false")
    if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
        if [[ "$had_dnscrypt_proxy_pkg" == "true" ]]; then
            if [[ "$dnscrypt_proxy_was_enabled" == "true" ]]; then
                systemctl enable dnscrypt-proxy 2>/dev/null || true
            else
                systemctl disable dnscrypt-proxy 2>/dev/null || true
            fi
            if [[ "$dnscrypt_proxy_was_active" == "true" ]]; then
                systemctl restart dnscrypt-proxy 2>/dev/null || systemctl start dnscrypt-proxy 2>/dev/null || true
            else
                systemctl stop dnscrypt-proxy 2>/dev/null || true
            fi
        else
            systemctl disable --now dnscrypt-proxy 2>/dev/null || true
        fi
    fi

    if [[ -f "$PRE_STATE_DIR/ifup-resolved.exec" ]]; then
        case "$(cat "$PRE_STATE_DIR/ifup-resolved.exec" 2>/dev/null)" in
            executable)
                [[ -e /etc/network/if-up.d/resolved ]] && chmod +x /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
            not_executable)
                [[ -e /etc/network/if-up.d/resolved ]] && chmod -x /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
            absent)
                rm -f /etc/network/if-up.d/resolved 2>/dev/null || true
                ;;
        esac
    fi

    # 移除 networkd drop-in（扩展搜索所有可能路径）
    for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
        for dropin_file in "$search_dir"/*.network.d/dns-purify-override.conf; do
            [[ -f "$dropin_file" ]] || continue
            rm -f "$dropin_file"
            rmdir "$(dirname "$dropin_file")" 2>/dev/null || true
        done
    done

    if [[ -f "$PRE_STATE_DIR/networkd-dropins.map" ]]; then
        while IFS='|' read -r restore_path restore_key; do
            [[ -n "$restore_path" && -n "$restore_key" ]] || continue
            [[ -f "$PRE_STATE_DIR/$restore_key" ]] || continue
            mkdir -p "$(dirname "$restore_path")"
            cp -a "$PRE_STATE_DIR/$restore_key" "$restore_path" 2>/dev/null || true
        done < "$PRE_STATE_DIR/networkd-dropins.map"
    fi

    # 重载 networkd/NM 使配置变更生效
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl reload NetworkManager 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || true

    dns_persist_was_enabled="false"
    [[ -f "$PRE_STATE_DIR/dns-persist.was-enabled" ]] && dns_persist_was_enabled=$(cat "$PRE_STATE_DIR/dns-persist.was-enabled" 2>/dev/null || echo "false")

    if [[ -e "$PRE_STATE_DIR/dns-purify-persist.service" || -L "$PRE_STATE_DIR/dns-purify-persist.service" ]]; then
        if [[ "$dns_persist_was_enabled" == "true" ]]; then
            systemctl enable dns-purify-persist.service 2>/dev/null || true
        else
            systemctl disable dns-purify-persist.service 2>/dev/null || true
        fi
    else
        systemctl disable dns-purify-persist.service 2>/dev/null || true
    fi

    had_resolvconf_pkg="false"
    [[ -f "$PRE_STATE_DIR/had-resolvconf.pkg" ]] && had_resolvconf_pkg=$(cat "$PRE_STATE_DIR/had-resolvconf.pkg" 2>/dev/null || echo "false")
    if [[ "$had_resolvconf_pkg" == "true" ]] && ! dpkg -s resolvconf >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y resolvconf >/dev/null 2>&1 || true
    fi

    # 先恢复 resolved 服务状态（在 resolv.conf 之前，避免悬空链接）
    resolved_enable_state="unknown"
    resolved_was_masked="false"
    resolved_was_active="false"
    [[ -f "$PRE_STATE_DIR/resolved.enable-state" ]] && resolved_enable_state=$(cat "$PRE_STATE_DIR/resolved.enable-state" 2>/dev/null || echo "unknown")
    # 兼容旧版快照
    if [[ "$resolved_enable_state" == "unknown" && -f "$PRE_STATE_DIR/resolved.was-enabled" ]]; then
        old_enabled=$(cat "$PRE_STATE_DIR/resolved.was-enabled" 2>/dev/null || echo "false")
        [[ "$old_enabled" == "true" ]] && resolved_enable_state="enabled" || resolved_enable_state="disabled"
    fi
    [[ -f "$PRE_STATE_DIR/resolved.was-masked" ]] && resolved_was_masked=$(cat "$PRE_STATE_DIR/resolved.was-masked" 2>/dev/null || echo "false")
    [[ -f "$PRE_STATE_DIR/resolved.was-active" ]] && resolved_was_active=$(cat "$PRE_STATE_DIR/resolved.was-active" 2>/dev/null || echo "false")

    if [[ "$resolved_was_masked" == "true" ]]; then
        systemctl mask systemd-resolved 2>/dev/null || true
        systemctl stop systemd-resolved 2>/dev/null || true
    else
        systemctl unmask systemd-resolved 2>/dev/null || true
        case "$resolved_enable_state" in
            enabled|enabled-runtime)
                systemctl enable systemd-resolved 2>/dev/null || true
                ;;
            static|indirect|generated)
                ;;
            *)
                systemctl disable systemd-resolved 2>/dev/null || true
                ;;
        esac

        if [[ "$resolved_was_active" == "true" ]]; then
            systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
            # 等待 stub 文件可用
            for wait_i in $(seq 1 5); do
                [[ -f /run/systemd/resolve/stub-resolv.conf ]] && break
                sleep 1
            done
        else
            systemctl stop systemd-resolved 2>/dev/null || true
        fi
    fi

    # 最后恢复 resolv.conf（此时 resolved 已恢复，stub 文件可用）
    if [[ -L "$PRE_STATE_DIR/resolv.conf" ]]; then
        backup_link=$(readlink "$PRE_STATE_DIR/resolv.conf" 2>/dev/null || echo "")
        if [[ "$backup_link" == *"stub-resolv.conf"* ]] && [[ ! -f /run/systemd/resolve/stub-resolv.conf ]]; then
            rm -f /etc/resolv.conf 2>/dev/null || true
            echo "nameserver 127.0.0.53" > /etc/resolv.conf 2>/dev/null || true
        else
            restore_path_state "/etc/resolv.conf" "resolv.conf"
        fi
    else
        restore_path_state "/etc/resolv.conf" "resolv.conf"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ 回滚完成（增强模式）！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

# ===== 旧版回滚（无 pre_state 目录时的兼容模式）=====

# 恢复 dhclient.conf
if [[ -f "$BACKUP_DIR/dhclient.conf.bak" ]]; then
    echo "恢复 dhclient.conf..."
    cp "$BACKUP_DIR/dhclient.conf.bak" /etc/dhcp/dhclient.conf
    echo "✅ 已恢复 dhclient.conf"
fi

# 恢复 interfaces
if [[ -f "$BACKUP_DIR/interfaces.bak" ]]; then
    echo "恢复 interfaces..."
    cp "$BACKUP_DIR/interfaces.bak" /etc/network/interfaces
    echo "✅ 已恢复 interfaces"
fi

# 恢复 resolved.conf
if [[ -f "$BACKUP_DIR/resolved.conf.bak" ]]; then
    echo "恢复 resolved.conf..."
    cp "$BACKUP_DIR/resolved.conf.bak" /etc/systemd/resolved.conf
    echo "✅ 已恢复 resolved.conf"
fi

# 移除DNS持久化服务
if [[ -f /etc/systemd/system/dns-purify-persist.service ]]; then
    echo "移除 DNS持久化服务..."
    systemctl disable dns-purify-persist.service 2>/dev/null || true
    rm -f /etc/systemd/system/dns-purify-persist.service
    echo "✅ 已移除 dns-purify-persist.service"
fi

# 移除DNS持久化脚本
if [[ -f /usr/local/bin/dns-purify-apply.sh ]]; then
    rm -f /usr/local/bin/dns-purify-apply.sh
    echo "✅ 已移除 dns-purify-apply.sh"
fi

# 移除 D-Bus 修复配置（仅删除本脚本创建的文件，不删整个目录）
if [[ -f /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf ]]; then
    rm -f /etc/systemd/system/systemd-resolved.service.d/dbus-fix.conf
    rmdir /etc/systemd/system/systemd-resolved.service.d 2>/dev/null || true
    echo "✅ 已移除 D-Bus 修复配置"
fi

# 移除 systemd-networkd DNS阻断 drop-in（扩展搜索路径）
for search_dir in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
    for dropin_dir in "$search_dir"/*.network.d; do
        if [[ -f "$dropin_dir/dns-purify-override.conf" ]]; then
            rm -f "$dropin_dir/dns-purify-override.conf"
            rmdir "$dropin_dir" 2>/dev/null || true
            echo "✅ 已移除 systemd-networkd DNS阻断配置"
        fi
    done
done

# 移除 NetworkManager DNS配置
if [[ -f /etc/NetworkManager/conf.d/99-dns-purify.conf ]]; then
    rm -f /etc/NetworkManager/conf.d/99-dns-purify.conf
    echo "✅ 已移除 NetworkManager DNS配置"
fi

# 恢复 if-up.d/resolved 可执行权限
if [[ -f /etc/network/if-up.d/resolved ]] && [[ ! -x /etc/network/if-up.d/resolved ]]; then
    echo "恢复 if-up.d/resolved 可执行权限..."
    chmod +x /etc/network/if-up.d/resolved
    echo "✅ 已恢复 if-up.d/resolved 可执行权限"
fi

# 重新加载 systemd
systemctl daemon-reload 2>/dev/null || true

# 重载 networkd/NM
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    networkctl reload 2>/dev/null || systemctl reload systemd-networkd 2>/dev/null || true
fi
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager 2>/dev/null || true
fi

# 重新加载 systemd-resolved
echo "重新加载 systemd-resolved..."
systemctl reload-or-restart systemd-resolved 2>/dev/null || true
echo "✅ systemd-resolved 已重新加载"

# 恢复 resolv.conf（在 resolved 重启之后，保留软链接特性）
if [[ -f "$BACKUP_DIR/resolv.conf.bak" ]]; then
    echo "恢复 resolv.conf..."
    rm -f /etc/resolv.conf
    cp -a "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
    echo "✅ 已恢复 resolv.conf"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 回滚完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLLBACK_SCRIPT

    chmod +x "$BACKUP_DIR/rollback.sh"

    # 显示备份信息
    echo -e "${gl_kjlan}备份与回滚信息：${gl_bai}"
    echo "  所有原始配置已备份到："
    echo "  $BACKUP_DIR"
    echo ""
    echo -e "${gl_huang}如需回滚，执行：${gl_bai}"
    echo "  bash $BACKUP_DIR/rollback.sh"
    echo ""

    if [ "$DNS_PURIFY_RESULT" = "未执行" ]; then
        case "$MODE_NAME" in
            *DoH*) DNS_PURIFY_RESULT="DoH fallback 已启用" ;;
            *普通*) DNS_PURIFY_RESULT="普通 DNS 53 成功" ;;
            *国内*) DNS_PURIFY_RESULT="普通 DNS 53 成功" ;;
            *) DNS_PURIFY_RESULT="DoT 成功" ;;
        esac
    fi

    echo -e "${gl_lv}DNS净化脚本执行完成${gl_bai}"
    echo "原作者：NSdesk"
    echo "安全增强：SSH防断连优化"
    echo "更多信息：https://www.nodeseek.com/space/23129#/general"
    echo "════════════════════════════════════════════════════════"
    echo ""

    break_end
}

run_speedtest() {
    while true; do
        clear
        echo -e "${gl_kjlan}=== 服务器带宽测试 ===${gl_bai}"
        echo ""
        
        # 检测 CPU 架构
        local cpu_arch=$(uname -m)
        echo "检测到系统架构: ${gl_huang}${cpu_arch}${gl_bai}"
        echo ""
        
        # 检查并安装 speedtest
        if ! command -v speedtest &>/dev/null; then
            echo "Speedtest 未安装，正在下载安装..."
            echo "------------------------------------------------"
            echo ""
            
            local download_url
            local tarball_name
            
            case "$cpu_arch" in
                x86_64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    tarball_name="ookla-speedtest-1.2.0-linux-x86_64.tgz"
                    echo "使用 AMD64 架构版本..."
                    ;;
                aarch64)
                    download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
                    tarball_name="speedtest.tgz"
                    echo "使用 ARM64 架构版本..."
                    ;;
                *)
                    echo -e "${gl_hong}错误: 不支持的架构 ${cpu_arch}${gl_bai}"
                    echo "目前仅支持 x86_64 和 aarch64 架构"
                    echo ""
                    break_end
                    return 1
                    ;;
            esac
            
            cd /tmp || {
                echo -e "${gl_hong}错误: 无法切换到 /tmp 目录${gl_bai}"
                break_end
                return 1
            }
            
            echo "正在下载..."
            if [ "$cpu_arch" = "aarch64" ]; then
                curl -Lo "$tarball_name" "$download_url"
            else
                wget -q "$download_url"
            fi
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}下载失败！${gl_bai}"
                break_end
                return 1
            fi
            
            echo "正在解压..."
            tar -xzf "$tarball_name"
            
            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}解压失败！${gl_bai}"
                rm -f "$tarball_name"
                break_end
                return 1
            fi
            
            mv speedtest /usr/local/bin/
            rm -f "$tarball_name"
            
            echo -e "${gl_lv}✅ Speedtest 安装成功！${gl_bai}"
            echo ""
        else
            echo -e "${gl_lv}✅ Speedtest 已安装${gl_bai}"
        fi
        
        echo ""
        echo -e "${gl_kjlan}请选择测速模式：${gl_bai}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. 自动测速"
        echo "2. 手动选择服务器 ⭐ 推荐"
        echo ""
        echo "0. 返回主菜单"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        read -e -p "请输入选择 [1]: " speed_choice
        speed_choice=${speed_choice:-1}
        
        case "$speed_choice" in
            1)
                # 自动测速（使用智能重试逻辑）
                echo ""
                echo -e "${gl_zi}正在搜索附近测速服务器...${gl_bai}"
                
                # 获取附近服务器列表
                local servers_list=$(speedtest --accept-license --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
                
                if [ -z "$servers_list" ]; then
                    echo -e "${gl_huang}无法获取服务器列表，使用自动选择...${gl_bai}"
                    servers_list="auto"
                else
                    local server_count=$(echo "$servers_list" | wc -l)
                    echo -e "${gl_lv}✅ 找到 ${server_count} 个附近服务器${gl_bai}"
                fi
                echo ""
                
                local speedtest_output=""
                local test_success=false
                local attempt=0
                local max_attempts=5
                
                for server_id in $servers_list; do
                    attempt=$((attempt + 1))
                    
                    if [ $attempt -gt $max_attempts ]; then
                        echo -e "${gl_huang}已尝试 ${max_attempts} 个服务器，停止尝试${gl_bai}"
                        break
                    fi
                    
                    if [ "$server_id" = "auto" ]; then
                        echo -e "${gl_zi}[尝试 ${attempt}] 自动选择最近服务器...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest --accept-license
                        test_success=true
                        break
                    else
                        echo -e "${gl_zi}[尝试 ${attempt}] 测试服务器 #${server_id}...${gl_bai}"
                        echo "------------------------------------------------"
                        speedtest_output=$(speedtest --accept-license --server-id="$server_id" 2>&1)
                        echo "$speedtest_output"
                        echo ""
                        
                        # 检查是否成功
                        if echo "$speedtest_output" | grep -q "Download:" && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            echo -e "${gl_lv}✅ 测速成功！${gl_bai}"
                            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                            test_success=true
                            break
                        else
                            echo -e "${gl_huang}⚠️ 此服务器测速失败，尝试下一个...${gl_bai}"
                            echo ""
                        fi
                    fi
                done
                
                if [ "$test_success" = false ]; then
                    echo ""
                    echo -e "${gl_hong}❌ 所有服务器测速均失败${gl_bai}"
                    echo -e "${gl_zi}建议使用「手动选择服务器」模式${gl_bai}"
                fi
                
                echo ""
                break_end
                ;;
            2)
                # 手动选择服务器
                echo ""
                echo -e "${gl_zi}正在获取附近服务器列表...${gl_bai}"
                echo ""
                
                local server_list_output=$(speedtest --accept-license --servers 2>/dev/null | head -n 15)
                
                if [ -z "$server_list_output" ]; then
                    echo -e "${gl_hong}❌ 无法获取服务器列表${gl_bai}"
                    echo ""
                    break_end
                    continue
                fi
                
                echo -e "${gl_kjlan}附近的测速服务器列表：${gl_bai}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "$server_list_output"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo -e "${gl_zi}💡 提示：ID 列的数字就是服务器ID${gl_bai}"
                echo ""
                
                local server_id=""
                while true; do
                    read -e -p "$(echo -e "${gl_huang}请输入服务器ID（纯数字，输入0返回）: ${gl_bai}")" server_id
                    
                    if [ "$server_id" = "0" ]; then
                        break
                    elif [[ "$server_id" =~ ^[0-9]+$ ]]; then
                        echo ""
                        echo -e "${gl_huang}正在使用服务器 #${server_id} 测速...${gl_bai}"
                        echo "------------------------------------------------"
                        echo ""
                        
                        speedtest --accept-license --server-id="$server_id"
                        
                        echo ""
                        echo "------------------------------------------------"
                        break_end
                        break
                    else
                        echo -e "${gl_hong}❌ 无效输入，请输入纯数字的服务器ID${gl_bai}"
                    fi
                done
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${gl_hong}无效选择${gl_bai}"
                sleep 1
                ;;
        esac
    done
}

run_backtrace() {
    clear
    echo -e "${gl_kjlan}=== 三网回程路由测试 ===${gl_bai}"
    echo ""
    echo "正在运行三网回程路由测试脚本..."
    echo "------------------------------------------------"
    echo ""

    # 执行三网回程路由测试脚本
    if ! run_remote_script "https://raw.githubusercontent.com/ludashi2020/backtrace/main/install.sh" sh; then
        echo -e "${gl_hong}❌ 脚本执行失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""
    echo "------------------------------------------------"
    break_end
}

iperf3_single_thread_test() {
    clear
    echo -e "${gl_zi}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_zi}║       iperf3 单线程网络性能测试            ║${gl_bai}"
    echo -e "${gl_zi}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    
    # 检查 iperf3 是否安装
    if ! command -v iperf3 &>/dev/null; then
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_huang}检测到 iperf3 未安装，正在自动安装...${gl_bai}"
        echo -e "${gl_huang}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        
        if command -v apt-get &>/dev/null || command -v apt &>/dev/null; then
            echo "步骤 1/2: 更新软件包列表..."
            apt-get update

            echo ""
            echo "步骤 2/2: 安装 iperf3..."
            apt-get install -y iperf3
            
            if [ $? -ne 0 ]; then
                echo ""
                echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo -e "${gl_hong}iperf3 安装失败！${gl_bai}"
                echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                break_end
                return 1
            fi
        else
            echo -e "${gl_hong}错误: 不支持的包管理器（仅支持 apt）${gl_bai}"
            break_end
            return 1
        fi
        
        echo ""
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}✓ iperf3 安装成功！${gl_bai}"
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
    fi
    
    # 输入目标服务器
    echo -e "${gl_kjlan}[步骤 1/3] 输入目标服务器${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -e -p "请输入目标服务器 IP 或域名: " target_host
    
    if [ -z "$target_host" ]; then
        echo -e "${gl_hong}错误: 目标服务器不能为空！${gl_bai}"
        break_end
        return 1
    fi
    
    echo ""
    
    # 选择测试方向
    echo -e "${gl_kjlan}[步骤 2/3] 选择测试方向${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. 上传测试（本机 → 远程服务器）"
    echo "2. 下载测试（远程服务器 → 本机）"
    echo ""
    read -e -p "请选择测试方向 [1-2]: " direction_choice
    
    case "$direction_choice" in
        1)
            direction_flag=""
            direction_text="上行（本机 → ${target_host}）"
            ;;
        2)
            direction_flag="-R"
            direction_text="下行（${target_host} → 本机）"
            ;;
        *)
            echo -e "${gl_hong}无效的选择，使用默认值: 上传测试${gl_bai}"
            direction_flag=""
            direction_text="上行（本机 → ${target_host}）"
            ;;
    esac
    
    echo ""
    
    # 输入测试时长
    echo -e "${gl_kjlan}[步骤 3/3] 设置测试时长${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "建议: 30-120 秒（默认 60 秒）"
    echo ""
    read -e -p "请输入测试时长（秒）[60]: " test_duration
    test_duration=${test_duration:-60}
    
    # 验证时长是否为数字
    if ! [[ "$test_duration" =~ ^[0-9]+$ ]]; then
        echo -e "${gl_huang}警告: 无效的时长，使用默认值 60 秒${gl_bai}"
        test_duration=60
    fi
    
    # 限制时长范围
    if [ "$test_duration" -lt 1 ]; then
        test_duration=1
    elif [ "$test_duration" -gt 3600 ]; then
        echo -e "${gl_huang}警告: 时长过长，限制为 3600 秒${gl_bai}"
        test_duration=3600
    fi
    
    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}测试配置确认：${gl_bai}"
    echo "  目标服务器: ${target_host}"
    echo "  测试方向: ${direction_text}"
    echo "  测试时长: ${test_duration} 秒"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    
    # 测试连通性
    echo -e "${gl_huang}正在测试连通性...${gl_bai}"
    if ! ping -c 2 -W 3 "$target_host" &>/dev/null; then
        echo -e "${gl_hong}警告: 无法 ping 通目标服务器，但仍尝试 iperf3 测试...${gl_bai}"
    else
        echo -e "${gl_lv}✓ 目标服务器可达${gl_bai}"
    fi
    
    echo ""
    echo -e "${gl_kjlan}正在执行 iperf3 测试，请稍候...${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 执行 iperf3 测试并保存输出
    local test_output=$(mktemp)
    iperf3 -c "$target_host" -P 1 $direction_flag -t "$test_duration" -f m 2>&1 | tee "$test_output"
    local exit_code=$?
    
    echo ""
    
    # 检查是否成功
    if [ $exit_code -ne 0 ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}测试失败！${gl_bai}"
        echo ""
        echo "可能的原因："
        echo "  1. 目标服务器未运行 iperf3 服务（需要执行: iperf3 -s）"
        echo "  2. 防火墙阻止了连接（默认端口 5201）"
        echo "  3. 网络连接问题"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        rm -f "$test_output"
        break_end
        return 1
    fi
    
    # 解析测试结果
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_zi}╔════════════════════════════════════════════╗${gl_bai}"
    echo -e "${gl_zi}║           测 试 结 果 汇 总                ║${gl_bai}"
    echo -e "${gl_zi}╚════════════════════════════════════════════╝${gl_bai}"
    echo ""
    
    # 提取关键指标
    local bandwidth=$(grep "sender\|receiver" "$test_output" | tail -1 | awk '{print $7, $8}')
    local transfer=$(grep "sender\|receiver" "$test_output" | tail -1 | awk '{print $5, $6}')
    local retrans=$(grep "sender" "$test_output" | tail -1 | awk '{print $9}')
    
    echo -e "${gl_kjlan}[测试信息]${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  目标服务器: ${target_host}"
    echo "  测试方向: ${direction_text}"
    echo "  测试时长: ${test_duration} 秒"
    echo "  测试线程: 1"
    echo ""
    
    echo -e "${gl_kjlan}[性能指标]${gl_bai}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -n "$bandwidth" ]; then
        echo "  平均带宽: ${bandwidth}"
    else
        echo "  平均带宽: 无法获取"
    fi
    
    if [ -n "$transfer" ]; then
        echo "  总传输量: ${transfer}"
    else
        echo "  总传输量: 无法获取"
    fi
    
    if [ -n "$retrans" ] && [ "$retrans" != "" ]; then
        echo "  重传次数: ${retrans}"
        # 简单评价
        if [ "$retrans" -eq 0 ]; then
            echo -e "  连接质量: ${gl_lv}优秀（无重传）${gl_bai}"
        elif [ "$retrans" -lt 100 ]; then
            echo -e "  连接质量: ${gl_lv}良好${gl_bai}"
        elif [ "$retrans" -lt 1000 ]; then
            echo -e "  连接质量: ${gl_huang}一般（重传偏多）${gl_bai}"
        else
            echo -e "  连接质量: ${gl_hong}较差（重传过多）${gl_bai}"
        fi
    fi
    
    echo ""
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}✓ 测试完成${gl_bai}"
    echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    
    # 清理临时文件
    rm -f "$test_output"
    
    echo ""
    break_end
}

#=============================================================================
# 一键全自动优化
#=============================================================================

system_supports_regular_bbr() {
    local available_cc

    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if echo "$available_cc" | grep -qw "bbr"; then
        return 0
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
        if echo "$available_cc" | grep -qw "bbr"; then
            return 0
        fi
    fi

    return 1
}

one_click_optimize() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}   ⭐ 一键全自动优化 (BBR v3 + 网络调优)${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local result_kernel="未执行"
    local result_tcp="跳过"
    local result_dns="跳过"
    local result_ipv6="用户跳过"
    local result_light="未启用"
    local dns_rollback="-"
    local run_network_stage=0
    local light_mode=0
    local light_choice=""

    # 检测当前是否已运行 XanMod 内核
    local xanmod_running=0
    if uname -r | grep -qi 'xanmod'; then
        xanmod_running=1
    fi

    if [ $xanmod_running -eq 0 ]; then
        # ===== 阶段1：安装内核 =====
        echo -e "${gl_huang}▶ 阶段 1/2：安装 XanMod + BBR v3 内核${gl_bai}"
        echo ""
        echo "安装完成后需要重启服务器"
        echo "重启后再次进入脚本，选择“一键全自动优化”即可继续阶段2"
        echo ""

        DISK_SPACE_CHECK_ABORTED=0
        DISK_SPACE_CHECK_REASON=""
        install_xanmod_kernel
        if [ $? -eq 0 ]; then
            result_kernel="需要重启"
            echo ""
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo -e "${gl_lv}  ✅ 内核安装完成！${gl_bai}"
            echo -e "${gl_lv}  重启后再次进入脚本，选择“一键全自动优化”即可继续阶段2${gl_bai}"
            echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
            echo ""
            echo -e "${gl_kjlan}一键优化结果汇总：${gl_bai}"
            echo -e "[!] XanMod / BBR v3：${result_kernel}"
            echo -e "[-] TCP 调优：等待重启后执行"
            echo -e "[-] DNS 净化：等待重启后执行"
            echo -e "[-] IPv6：等待重启后执行"
            echo ""
            server_reboot
            return 0
        else
            if [ "${DISK_SPACE_CHECK_ABORTED:-0}" = "1" ]; then
                echo ""
                if system_supports_regular_bbr; then
                    if [ "${DISK_SPACE_CHECK_REASON:-}" = "unreadable" ]; then
                        echo -e "${gl_huang}无法可靠读取根分区可用空间，不建议安装 XanMod / BBR v3 内核；但系统内核支持普通 BBR，可继续执行轻量优化（TCP 调优 / DNS 净化 / IPv6 管理）。${gl_bai}"
                    else
                        echo -e "${gl_huang}当前磁盘空间不足，不建议安装 XanMod / BBR v3 内核；但系统内核支持普通 BBR，可继续执行轻量优化（TCP 调优 / DNS 净化 / IPv6 管理）。${gl_bai}"
                    fi
                    echo -e "${gl_huang}注意：这不会安装 XanMod，也不会把系统普通 BBR 视为 BBR v3。${gl_bai}"
                    read -e -p "$(echo -e "${gl_huang}是否继续轻量优化？(Y/N): ${gl_bai}")" light_choice
                    if [[ "$light_choice" =~ ^[Yy]$ ]]; then
                        if [ "${DISK_SPACE_CHECK_REASON:-}" = "unreadable" ]; then
                            result_kernel="跳过（无法读取磁盘空间，未安装 XanMod / BBR v3）"
                        else
                            result_kernel="跳过（磁盘空间不足，未安装 XanMod / BBR v3）"
                        fi
                        result_light="已继续执行"
                        light_mode=1
                        run_network_stage=1
                    else
                        echo ""
                        echo -e "${gl_hong}一键优化结果汇总：${gl_bai}"
                        echo -e "[x] XanMod / BBR v3：安装失败或已跳过"
                        echo -e "[-] 轻量优化：用户取消"
                        echo -e "[-] TCP 调优：未执行"
                        echo -e "[-] DNS 净化：未执行"
                        echo -e "[-] IPv6：未执行"
                        echo ""
                        break_end
                        return 1
                    fi
                else
                    if [ "${DISK_SPACE_CHECK_REASON:-}" = "unreadable" ]; then
                        echo -e "${gl_hong}无法可靠读取根分区可用空间，且当前内核未检测到普通 BBR 支持。${gl_bai}"
                    else
                        echo -e "${gl_hong}当前磁盘空间不足，且当前内核未检测到普通 BBR 支持。${gl_bai}"
                    fi
                    echo -e "${gl_huang}请扩容磁盘，或更换支持 BBR 的内核后再执行一键优化。${gl_bai}"
                    echo ""
                    echo -e "${gl_hong}一键优化结果汇总：${gl_bai}"
                    echo -e "[x] XanMod / BBR v3：安装失败或已跳过"
                    echo -e "[-] 轻量优化：当前内核不支持普通 BBR"
                    echo -e "[-] TCP 调优：未执行"
                    echo -e "[-] DNS 净化：未执行"
                    echo -e "[-] IPv6：未执行"
                    echo ""
                    break_end
                    return 1
                fi
            else
                echo ""
                echo -e "${gl_hong}一键优化结果汇总：${gl_bai}"
                echo -e "[x] XanMod / BBR v3：安装失败"
                echo -e "[-] TCP 调优：未执行"
                echo -e "[-] DNS 净化：未执行"
                echo -e "[-] IPv6：未执行"
                echo ""
                break_end
                return 1
            fi
        fi
    else
        result_kernel="已运行"
        run_network_stage=1
    fi

    if [ $run_network_stage -eq 1 ]; then
        # ===== 阶段2：全自动优化 =====
        if [ $light_mode -eq 1 ]; then
            echo ""
            echo -e "${gl_lv}✅ 系统内核支持普通 BBR，继续执行轻量优化${gl_bai}"
            echo ""
            echo -e "${gl_huang}▶ 轻量优化：TCP 调优 / DNS 净化 / IPv6 管理${gl_bai}"
        else
            echo ""
            echo -e "${gl_lv}✅ 检测到 XanMod 内核已运行：$(uname -r)${gl_bai}"
            echo ""
            echo -e "${gl_huang}▶ 阶段 2/2：全自动网络优化${gl_bai}"
        fi
        echo "将依次执行："
        echo "  [1/3] 功能3 - BBR 直连优化（自动检测带宽）"
        echo "  [2/3] 功能4 - DNS 净化（纯国外模式）"
        echo "  [3/3] 功能5 - 永久禁用 IPv6"
        echo ""
        sleep 3

        AUTO_MODE=1

        echo -e "${gl_kjlan}━━━━━━ [1/3] BBR 直连优化 ━━━━━━${gl_bai}"
        if bbr_configure_direct; then
            result_tcp="已应用"
        else
            result_tcp="失败"
        fi

        echo ""
        echo -e "${gl_kjlan}━━━━━━ [2/3] DNS 净化 ━━━━━━${gl_bai}"
        DNS_PURIFY_RESULT="未执行"
        DNS_PURIFY_ROLLBACK=""
        if dns_purify_and_harden; then
            result_dns="${DNS_PURIFY_RESULT:-成功}"
        else
            result_dns="失败但未阻断"
        fi
        dns_rollback="${DNS_PURIFY_ROLLBACK:-"-"}"

        AUTO_MODE=""

        echo ""
        echo -e "${gl_kjlan}━━━━━━ [3/3] 禁用 IPv6（可选） ━━━━━━${gl_bai}"
        read -e -p "$(echo -e "${gl_huang}是否永久禁用 IPv6？(Y/N) [Y]: ${gl_bai}")" ipv6_choice
        ipv6_choice=${ipv6_choice:-Y}
        if [[ "$ipv6_choice" =~ ^[Yy]$ ]]; then
            AUTO_MODE=1
            disable_ipv6_permanent
            if ipv6_permanent_disabled_state; then
                result_ipv6="已永久禁用"
            else
                result_ipv6="禁用失败，请检查 /etc/sysctl.d/99-disable-ipv6.conf 或手动执行菜单 IPv6 管理"
            fi
            AUTO_MODE=""
        else
            result_ipv6="用户跳过"
            echo -e "${gl_huang}已跳过 IPv6 禁用${gl_bai}"
        fi

        echo ""
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        if [ $light_mode -eq 1 ]; then
            echo -e "${gl_lv}  ✅ 轻量优化完成！${gl_bai}"
        else
            echo -e "${gl_lv}  ✅ 全部优化完成！${gl_bai}"
        fi
        echo -e "${gl_lv}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}一键优化结果汇总：${gl_bai}"
        if [ $light_mode -eq 1 ]; then
            echo -e "[-] XanMod / BBR v3：${result_kernel}"
            echo -e "[✓] 轻量优化：${result_light}"
        else
            echo -e "[✓] XanMod / BBR v3：${result_kernel}"
        fi
        case "$result_tcp" in
            *失败*) echo -e "[x] TCP 调优：${result_tcp}" ;;
            *) echo -e "[✓] TCP 调优：${result_tcp}" ;;
        esac
        case "$result_dns" in
            *失败*) echo -e "[!] DNS 净化：${result_dns}" ;;
            *跳过*) echo -e "[-] DNS 净化：${result_dns}" ;;
            *) echo -e "[✓] DNS 净化：${result_dns}" ;;
        esac
        case "$result_ipv6" in
            *失败*) echo -e "[!] IPv6：${result_ipv6}" ;;
            *跳过*) echo -e "[-] IPv6：${result_ipv6}" ;;
            *) echo -e "[✓] IPv6：${result_ipv6}" ;;
        esac
        echo ""
        echo -e "${gl_kjlan}日志文件：${gl_bai}"
        echo "$LOG_FILE"
        echo ""
        echo -e "${gl_kjlan}回滚信息：${gl_bai}"
        echo "  DNS 回滚：${dns_rollback}"
        echo "  IPv6 恢复：菜单 5 IPv6 管理 -> 取消永久禁用"
        echo "  XanMod 卸载：菜单 2"
        echo "  统一入口：菜单 12 回滚 / 卸载管理"
        echo ""
        break_end
    fi
}

#=============================================================================
# 回滚 / 卸载管理
#=============================================================================

rollback_confirm() {
    local prompt="$1"
    local confirm=""
    read -e -p "$(echo -e "${gl_huang}${prompt} (Y/N): ${gl_bai}")" confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

remove_tcp_sysctl_config() {
    echo -e "${gl_kjlan}=== 删除 TCP/sysctl 调优配置 ===${gl_bai}"
    echo ""
    echo "将处理以下路径："
    echo "  $SYSCTL_CONF"
    echo ""

    if [ ! -e "$SYSCTL_CONF" ]; then
        echo -e "${gl_huang}未检测到 $SYSCTL_CONF，无需删除${gl_bai}"
        break_end
        return 0
    fi

    rollback_confirm "确认移动该配置并重新加载 sysctl？" || {
        echo "已取消"
        break_end
        return 1
    }

    local rollback_dir="/root/.net-tcp-tune_rollback/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$rollback_dir"
    mv "$SYSCTL_CONF" "$rollback_dir/99-bbr-ultimate.conf" 2>/dev/null || {
        echo -e "${gl_hong}移动配置失败，请检查权限${gl_bai}"
        break_end
        return 1
    }

    sysctl --system >/dev/null 2>&1 || true
    echo -e "${gl_lv}✅ 已移动配置到: $rollback_dir/99-bbr-ultimate.conf${gl_bai}"
    echo -e "${gl_lv}✅ 已执行 sysctl --system${gl_bai}"
    break_end
}

remove_bbr_persist_config() {
    echo -e "${gl_kjlan}=== 删除 tc / MSS clamp / BBR 持久化 ===${gl_bai}"
    echo ""
    echo "将处理以下路径："
    echo "  /etc/systemd/system/bbr-optimize-persist.service"
    echo "  /usr/local/bin/bbr-optimize-apply.sh"
    echo "并尝试删除本脚本添加的 iptables MSS clamp 规则。"
    echo ""

    rollback_confirm "确认删除这些持久化配置？" || {
        echo "已取消"
        break_end
        return 1
    }

    systemctl disable --now bbr-optimize-persist.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bbr-optimize-persist.service
    rm -f /usr/local/bin/bbr-optimize-apply.sh
    apply_mss_clamp disable >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    echo -e "${gl_lv}✅ 已清理 BBR 持久化服务、脚本和 MSS clamp 规则${gl_bai}"
    break_end
}

restore_latest_dns_backup() {
    echo -e "${gl_kjlan}=== 恢复 DNS 净化最近一次备份 ===${gl_bai}"
    echo ""

    local latest_rollback=""
    latest_rollback=$(ls -t /root/.dns_purify_backup/*/rollback.sh 2>/dev/null | head -1)

    if [ -z "$latest_rollback" ]; then
        echo -e "${gl_huang}未找到 /root/.dns_purify_backup 下的 rollback.sh${gl_bai}"
        break_end
        return 1
    fi

    echo "将执行最近备份的回滚脚本："
    echo "  $latest_rollback"
    echo ""
    rollback_confirm "确认执行 DNS 回滚？" || {
        echo "已取消"
        break_end
        return 1
    }

    bash "$latest_rollback"
    break_end
}

remove_bbr_shortcut_command() {
    echo -e "${gl_kjlan}=== 卸载 bbr 快捷命令 ===${gl_bai}"
    echo ""
    echo "将删除："
    echo "  /usr/local/bin/bbr"
    echo ""
    rollback_confirm "确认删除 /usr/local/bin/bbr？" || {
        echo "已取消"
        break_end
        return 1
    }

    if [ -e /usr/local/bin/bbr ]; then
        rm -f /usr/local/bin/bbr
        echo -e "${gl_lv}✅ 已删除 /usr/local/bin/bbr${gl_bai}"
    else
        echo -e "${gl_huang}未检测到 /usr/local/bin/bbr${gl_bai}"
    fi
    echo "如需同时清理 shell alias，可运行：bash install-alias.sh uninstall"
    break_end
}

show_rollback_backups() {
    echo -e "${gl_kjlan}=== 备份目录查看 ===${gl_bai}"
    echo ""
    echo "[DNS 净化备份]"
    ls -ld /root/.dns_purify_backup/* 2>/dev/null | tail -10 || echo "  未找到 /root/.dns_purify_backup"
    echo ""
    echo "[sysctl 备份]"
    ls -l /etc/sysctl.conf.bak* /root/.net-tcp-tune_rollback/*/99-bbr-ultimate.conf 2>/dev/null || echo "  未找到 sysctl 相关备份"
    echo ""
    break_end
}

rollback_uninstall_manager() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}   回滚 / 卸载管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "1. 卸载 XanMod 内核"
        echo "2. 删除 TCP/sysctl 调优配置"
        echo "3. 删除 tc / MSS clamp / BBR 持久化"
        echo "4. 恢复 DNS 净化最近一次备份"
        echo "5. 恢复 IPv6（取消永久禁用）"
        echo "6. 卸载快捷命令 /usr/local/bin/bbr"
        echo "7. 查看备份目录"
        echo "0. 返回主菜单"
        echo ""
        read -e -p "请输入选择: " rollback_choice

        case "$rollback_choice" in
            1) uninstall_xanmod ;;
            2) remove_tcp_sysctl_config ;;
            3) remove_bbr_persist_config ;;
            4) restore_latest_dns_backup ;;
            5) cancel_ipv6_permanent_disable ;;
            6) remove_bbr_shortcut_command ;;
            7) show_rollback_backups ;;
            0) return 0 ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

# 主菜单
#=============================================================================

show_main_menu() {
    clear
    check_bbr_status
    local is_installed=$?

    echo ""
    local box_width=50
    local inner=$((box_width - 2))
    echo -e "${gl_zi}╔$(printf '═%.0s' $(seq 1 $inner))╗${gl_bai}"
    echo -e "${gl_zi}║ $(format_fixed_width "BBR v3 / XanMod / TCP 网络调优脚本" $((inner - 2))) ║${gl_bai}"
    echo -e "${gl_zi}║ $(format_fixed_width "version ${SCRIPT_VERSION}" $((inner - 2))) ║${gl_bai}"
    echo -e "${gl_zi}╚$(printf '═%.0s' $(seq 1 $inner))╝${gl_bai}"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━ 内核管理 ━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}[内核管理]${gl_bai}"
    echo "1. 安装/更新 XanMod 内核 + BBR v3 ⭐ 推荐"
    echo "2. 卸载 XanMod 内核"
    echo ""
    echo -e "${gl_kjlan}[BBR/网络优化]${gl_bai}"
    echo "3. BBR 直连/落地优化（智能带宽检测）⭐ 推荐"
    echo "4. DNS 净化（抗污染/驯服 DHCP）"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━ 系统配置 ━━━━━━━━━━━${gl_bai}"
    echo "5. IPv6 管理（临时/永久禁用/取消）"
    echo "6. 查看系统详细状态"
    echo ""
    echo -e "${gl_kjlan}[网络测试]${gl_bai}"
    echo "7. 服务器带宽测试"
    echo "8. iperf3 单线程测试"
    echo "9. 三网回程路由测试"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━ 一键优化 ━━━━━━━━━${gl_bai}"
    echo "10. ⭐ 一键全自动优化（BBR v3 + 网络调优）"
    echo ""
    echo -e "${gl_kjlan}━━━━━━ 预检 / 回滚 ━━━━━━${gl_bai}"
    echo "11. 环境预检 / 兼容性检查"
    echo "12. 回滚 / 卸载管理"
    echo ""
    echo "0. 退出脚本"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    read -e -p "请输入选择: " choice

    case $choice in
        1)
            if [ $is_installed -eq 0 ]; then
                update_xanmod_kernel
                # update 函数内部已有重启交互，无需再次调用 server_reboot
            else
                install_xanmod_kernel && server_reboot
            fi
            ;;
        2)
            if [ $is_installed -eq 0 ]; then
                uninstall_xanmod
            else
                echo -e "${gl_huang}当前未检测到 XanMod 内核，无需卸载${gl_bai}"
                break_end
            fi
            ;;
        3)
            bbr_configure_direct
            break_end
            ;;
        4)
            dns_purify_and_harden
            ;;
        5)
            manage_ipv6
            ;;
        6)
            show_detailed_status
            ;;
        7)
            run_speedtest
            ;;
        8)
            iperf3_single_thread_test
            ;;
        9)
            run_backtrace
            ;;
        10)
            one_click_optimize
            ;;
        11)
            show_environment_precheck
            ;;
        12)
            rollback_uninstall_manager
            ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选择"
            sleep 2
            ;;
    esac
}

update_xanmod_kernel() {
    clear
    echo -e "${gl_kjlan}=== 更新 XanMod 内核 ===${gl_bai}"
    echo "------------------------------------------------"
    
    # 获取当前内核版本
    local current_kernel=$(uname -r)
    echo -e "当前内核版本: ${gl_huang}${current_kernel}${gl_bai}"
    echo ""
    
    # 检测 CPU 架构
    local cpu_arch=$(uname -m)
    
    # ARM 架构提示
    if [ "$cpu_arch" = "aarch64" ]; then
        echo -e "${gl_huang}ARM64 架构暂不支持自动更新${gl_bai}"
        echo "建议卸载后重新安装以获取最新版本"
        break_end
        return 1
    fi
    
    # x86_64 架构更新流程
    echo "正在检查可用更新..."
    
    local xanmod_repo_file="/etc/apt/sources.list.d/xanmod-release.list"
    local gpg_key_file="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local xanmod_codename
    xanmod_codename=$(get_xanmod_codename) || {
        break_end
        return 1
    }

    # 添加 XanMod 仓库密钥（分步执行，避免管道 $? 问题）
    if [ ! -f "$gpg_key_file" ]; then
        echo "正在添加 XanMod 仓库密钥..."
        local key_tmp=$(mktemp)
        local gpg_ok=false

        if wget -qO "$key_tmp" "${gh_proxy}raw.githubusercontent.com/kejilion/sh/main/archive.key" 2>/dev/null && \
           [ -s "$key_tmp" ]; then
            if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                gpg_ok=true
            fi
        fi

        if [ "$gpg_ok" = false ]; then
            if wget -qO "$key_tmp" "https://dl.xanmod.org/archive.key" 2>/dev/null && \
               [ -s "$key_tmp" ]; then
                if gpg --dearmor -o "$gpg_key_file" --yes < "$key_tmp" 2>/dev/null; then
                    gpg_ok=true
                fi
            fi
        fi

        rm -f "$key_tmp"

        if [ "$gpg_ok" = false ]; then
            echo -e "${gl_hong}错误: GPG 密钥导入失败${gl_bai}"
            break_end
            return 1
        fi
    fi

    # 添加/刷新 XanMod 仓库（按系统 VERSION_CODENAME 动态选择）
    if ! write_xanmod_apt_source "$gpg_key_file" "$xanmod_repo_file"; then
        break_end
        return 1
    fi
    echo -e "${gl_kjlan}使用 XanMod APT 源: http://deb.xanmod.org ${xanmod_codename} main${gl_bai}"

    # 更新软件包列表
    echo "正在更新软件包列表..."
    if ! apt-get update > /dev/null 2>&1; then
        echo -e "${gl_huang}⚠️  apt-get update 部分失败，尝试继续...${gl_bai}"
    fi

    # 检查已安装的 XanMod 内核包（使用 ^ii 过滤，排除已卸载残留）
    local installed_packages=$(dpkg -l | grep -E '^ii\s+linux-.*xanmod' | awk '{print $2}')
    
    if [ -z "$installed_packages" ]; then
        echo -e "${gl_hong}错误: 未检测到已安装的 XanMod 内核${gl_bai}"
        break_end
        return 1
    fi
    
    echo -e "已安装的内核包:"
    echo "$installed_packages" | while read pkg; do
        echo "  - $pkg"
    done
    echo ""
    
    # 检查是否有可用更新
    local upgradable=$(apt list --upgradable 2>/dev/null | grep xanmod)
    
    if [ -z "$upgradable" ]; then
        local cpu_level
        cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
        [ -z "$cpu_level" ] && cpu_level="3"

        # 获取已安装的最新 XanMod 内核版本（从 linux-image 包名提取版本号并取最大值）
        local latest_installed
        latest_installed=$(echo "$installed_packages" \
            | sed -nE 's/^linux-image-([0-9]+\.[0-9]+\.[0-9]+-x64v[1-4]-xanmod[0-9]+)$/\1/p' \
            | sort -V | tail -1)

        local running_latest=0
        if [ -n "$latest_installed" ] && [ "$current_kernel" = "$latest_installed" ]; then
            running_latest=1
        fi

        if [ $running_latest -eq 1 ]; then
            echo -e "${gl_lv}✅ 当前运行内核已是最新版本！${gl_bai}"
        else
            echo -e "${gl_lv}✅ XanMod 内核包已是最新，但当前运行内核尚未切换！${gl_bai}"
            echo -e "  正在运行: ${gl_hong}${current_kernel}${gl_bai}"
            if [ -n "$latest_installed" ]; then
                echo -e "  最新已装: ${gl_lv}${latest_installed}${gl_bai}"
            else
                echo -e "  ${gl_huang}提示: 未能解析最新已装内核版本，请重启后再检查${gl_bai}"
            fi
            echo -e "  ${gl_huang}请重启系统 (reboot) 以切换到最新内核${gl_bai}"
        fi
        echo ""

        echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
        echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
        echo -e "  当前运行内核: ${gl_lv}${current_kernel}${gl_bai}"
        if [ -n "$latest_installed" ] && [ $running_latest -ne 1 ]; then
            echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
        fi
        if [ $running_latest -eq 1 ]; then
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，当前已运行该等级最新内核${gl_bai}"
        else
            echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，最新内核已安装，重启后生效${gl_bai}"
        fi
        echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"

        rm -f "$xanmod_repo_file"
        echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
        break_end
        return 0
    fi
    
    echo -e "${gl_huang}发现可用更新：${gl_bai}"
    echo "$upgradable"
    echo ""
    
    read -e -p "确定更新 XanMod 内核吗？(Y/N): " confirm
    
    case "$confirm" in
        [Yy])
            echo ""
            echo "正在更新内核..."
            apt install --only-upgrade -y $(echo "$installed_packages" | tr '\n' ' ')
            
            if [ $? -eq 0 ]; then
                echo ""
                echo -e "${gl_lv}✅ XanMod 内核更新成功！${gl_bai}"
                echo -e "${gl_huang}⚠️  请重启系统以加载新内核${gl_bai}"
                echo ""
                local cpu_level
                cpu_level=$(echo "$installed_packages" | sed -nE 's/.*x64v([1-4]).*/\1/p' | head -1)
                [ -z "$cpu_level" ] && cpu_level="3"
                local latest_installed
                latest_installed=$(dpkg -l 2>/dev/null | awk '/^ii\s+linux-image-[0-9].*xanmod/ {print $2}' | sed 's/^linux-image-//' | sort -V | tail -1)
                echo -e "${gl_kjlan}━━━━━━━━━━ CPU 架构信息 ━━━━━━━━━━${gl_bai}"
                echo -e "  CPU 架构等级: ${gl_lv}x86-64-v${cpu_level}${gl_bai}"
                if [ -n "$latest_installed" ]; then
                    echo -e "  最新已装内核: ${gl_lv}${latest_installed}${gl_bai}"
                else
                    echo -e "  已更新内核包: ${gl_lv}$(echo "$installed_packages" | head -1)${gl_bai}"
                fi
                echo -e "  ${gl_huang}说明: 本机 CPU 最高支持 v${cpu_level}，已更新至该等级的最新内核${gl_bai}"
                echo -e "  ${gl_huang}不同等级(v1-v4)的内核更新进度可能不同，以 XanMod 官方仓库为准${gl_bai}"
                echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
                echo ""
                echo -e "${gl_kjlan}后续更新：再次运行选项1即可检查并安装最新内核${gl_bai}"

                rm -f "$xanmod_repo_file"
                echo -e "${gl_lv}已自动清理 XanMod 软件源（如需更新可再次运行选项1）${gl_bai}"
                return 0
            else
                echo ""
                echo -e "${gl_hong}❌ 内核更新失败${gl_bai}"
                break_end
                return 1
            fi
            ;;
        *)
            echo "已取消更新"
            break_end
            return 1
            ;;
    esac
}

uninstall_xanmod() {
    echo -e "${gl_huang}警告: 即将卸载 XanMod 内核${gl_bai}"
    echo ""

    # 安全检查：确认系统中有回退内核可用
    local non_xanmod_kernels=$(dpkg -l 2>/dev/null | grep '^ii' | grep 'linux-image-' | grep -v 'xanmod' | grep -v 'dbg' | wc -l)
    if [ "$non_xanmod_kernels" -eq 0 ]; then
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_hong}❌ 安全检查未通过：未检测到非 XanMod 的回退内核！${gl_bai}"
        echo -e "${gl_hong}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "卸载 XanMod 内核后系统将没有可启动的内核，重启会导致 VPS 无法开机。"
        echo ""
        echo -e "${gl_lv}建议：先安装默认内核再卸载 XanMod${gl_bai}"
        echo "  apt install -y linux-image-amd64   # Debian"
        echo "  apt install -y linux-image-generic  # Ubuntu"
        echo ""
        break_end
        return 1
    fi
    echo -e "${gl_lv}✅ 检测到 ${non_xanmod_kernels} 个回退内核，可以安全卸载${gl_bai}"
    echo ""

    read -e -p "确定继续吗？(Y/N): " confirm

    case "$confirm" in
        [Yy])
            # 使用能匹配元包和内核包的模式
            echo "正在卸载 XanMod 相关包..."
            if apt purge -y 'linux-*xanmod*' 2>&1; then
                # 验证卸载结果
                if dpkg -l 2>/dev/null | grep -qE '^ii\s+linux-.*xanmod'; then
                    echo -e "${gl_hong}⚠️  部分 XanMod 包未能卸载，请手动检查：${gl_bai}"
                    dpkg -l | grep -E '^ii\s+linux-.*xanmod' | awk '{print "  - " $2}'
                else
                    echo -e "${gl_lv}✅ XanMod 内核包已全部卸载${gl_bai}"
                fi
                update-grub 2>/dev/null
            else
                echo -e "${gl_hong}❌ 卸载命令执行失败，请手动检查${gl_bai}"
                break_end
                return 1
            fi

            # 清理软件源和 GPG 密钥
            rm -f /etc/apt/sources.list.d/xanmod-release.list
            rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
            echo -e "${gl_lv}✅ XanMod 软件源已清理${gl_bai}"

            rm -f "$SYSCTL_CONF"
            echo -e "${gl_lv}XanMod 内核已卸载${gl_bai}"
            server_reboot
            ;;
        *)
            echo "已取消"
            ;;
    esac
}

# 完全卸载脚本所有内容
show_help() {
    cat << EOF
BBR v3 / XanMod / TCP 网络调优脚本 v${SCRIPT_VERSION}

用法: $0 [选项]

选项:
  -h, --help      显示此帮助信息
  -v, --version   显示版本号
  -i, --install   直接安装 XanMod 内核（非交互）
  --debug         启用调试模式（详细日志）
  -q, --quiet     静默模式（仅显示错误）

示例:
  $0              启动交互式菜单
  $0 -i           直接安装 BBR v3 内核
  $0 --debug      调试模式运行

日志文件: ${LOG_FILE}
配置文件: ~/.net-tcp-tune.conf 或 /etc/net-tcp-tune.conf
EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "net-tcp-tune.sh v${SCRIPT_VERSION}"
                exit 0
                ;;
            -i|--install)
                check_root
                install_xanmod_kernel
                if [ $? -eq 0 ]; then
                    echo ""
                    echo "安装完成后，请重启系统以加载新内核"
                fi
                exit 0
                ;;
            --debug)
                LOG_LEVEL="DEBUG"
                log_debug "调试模式已启用"
                shift
                ;;
            -q|--quiet)
                LOG_LEVEL="ERROR"
                shift
                ;;
            -*)
                echo "未知选项: $1"
                echo "使用 -h 或 --help 查看帮助"
                exit 1
                ;;
            *)
                # 无参数时继续
                break
                ;;
        esac
    done
}

main() {
    # 先解析参数
    parse_args "$@"

    # 检查 root 权限
    check_root

    # 自动清理旧版 MTU 优化残留
    auto_cleanup_legacy_mtu

    # 加载用户配置（如果存在）
    [ -f "/etc/net-tcp-tune.conf" ] && source "/etc/net-tcp-tune.conf"
    [ -f "$HOME/.net-tcp-tune.conf" ] && source "$HOME/.net-tcp-tune.conf"

    # 交互式菜单
    while true; do
        show_main_menu
    done
}

# 执行主函数
main "$@"
