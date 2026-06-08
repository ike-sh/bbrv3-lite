#!/bin/bash
#=============================================================================
# 脚本名称: install-alias.sh
# 功能描述: 为 BBR v3 / XanMod / TCP 网络调优脚本安装/卸载快捷命令
# 使用方法:
#   安装: bash install-alias.sh [install]
#   卸载: bash install-alias.sh uninstall
#=============================================================================

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m'

MODE="${1:-install}"
WRAPPER_PATH="/usr/local/bin/bbr"
SCRIPT_URL='https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh'

if [ "$MODE" != "install" ] && [ "$MODE" != "uninstall" ]; then
    echo -e "${RED}错误: 未知参数 '$MODE'${NC}"
    echo "使用方法:"
    echo "  安装: bash install-alias.sh [install]"
    echo "  卸载: bash install-alias.sh uninstall"
    exit 1
fi

CURRENT_SHELL=$(basename "${SHELL:-bash}")
RC_FILE=""

detect_rc_file() {
    if [ "$CURRENT_SHELL" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    elif [ "$CURRENT_SHELL" = "bash" ]; then
        RC_FILE="$HOME/.bashrc"
        if [ ! -f "$RC_FILE" ]; then
            RC_FILE="$HOME/.bash_profile"
        fi
    else
        RC_FILE="$HOME/.bashrc"
    fi

    if [ ! -f "$RC_FILE" ]; then
        if [ "$MODE" = "uninstall" ]; then
            return 0
        fi

        if ! touch "$RC_FILE"; then
            echo -e "${RED}错误: 无法写入 shell 配置文件 ${RC_FILE}${NC}" >&2
            return 1
        fi
    fi
}

remove_alias_block() {
    local file="$1"
    local temp_file="$2"

    sed '/^# ================ net-tcp-tune 快捷别名 ================/,/^# ================ net-tcp-tune 快捷别名结束 ================/d' "$file" > "$temp_file"
}

can_install_system_command() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    [ -d /usr/local/bin ] && [ -w /usr/local/bin ]
}

install_system_command() {
    if ! mkdir -p /usr/local/bin 2>/dev/null; then
        return 1
    fi

    cat > "$WRAPPER_PATH" <<'WRAPPER'
#!/usr/bin/env bash
set -e

SCRIPT_URL='https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh'
tmp_file=$(mktemp)
cleanup() {
    rm -f "$tmp_file"
}
trap cleanup EXIT

download_script() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$output" "$url"
    else
        echo "错误: 未找到 curl 或 wget，无法下载 net-tcp-tune.sh" >&2
        return 1
    fi
}

download_url="${SCRIPT_URL}?$(date +%s)"
if ! download_script "$download_url" "$tmp_file"; then
    echo "错误: 下载 net-tcp-tune.sh 失败" >&2
    exit 1
fi

if [ ! -s "$tmp_file" ]; then
    echo "错误: 下载文件为空，已取消执行" >&2
    exit 1
fi

if head -n 1 "$tmp_file" | grep -qiE '<!DOCTYPE|<html'; then
    echo "错误: 下载内容像 HTML 错误页，已取消执行" >&2
    exit 1
fi

if ! head -n 5 "$tmp_file" | sed 's/^\xef\xbb\xbf//' | grep -q '^#!'; then
    echo "错误: 下载脚本缺少 shebang，已取消执行" >&2
    exit 1
fi

if ! grep -q 'SCRIPT_VERSION=' "$tmp_file"; then
    echo "错误: 下载脚本缺少 SCRIPT_VERSION 标识，已取消执行" >&2
    exit 1
fi

if ! grep -q 'BBR v3 / XanMod / TCP' "$tmp_file"; then
    echo "错误: 下载脚本缺少项目标识，已取消执行" >&2
    exit 1
fi

bash "$tmp_file" "$@"
WRAPPER

    chmod +x "$WRAPPER_PATH"
}

install_alias_fallback() {
    detect_rc_file || return 1

    local alias_content
    alias_content=$(cat <<'ALIAS'
# ================ net-tcp-tune 快捷别名 ================
# 使用时间戳参数确保每次都获取最新版本，避免缓存
bbr() {
    local tmp_file
    tmp_file="$(mktemp)" || return 1
    trap 'rm -f "$tmp_file"' RETURN
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)" -o "$tmp_file" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$tmp_file" "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)" || return 1
    else
        echo "错误: 未找到 curl 或 wget，无法下载 net-tcp-tune.sh" >&2
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then echo "错误: 下载文件为空" >&2; return 1; fi
    if head -n 1 "$tmp_file" | grep -qiE '<!DOCTYPE|<html'; then echo "错误: 下载到了 HTML 页面" >&2; return 1; fi
    if ! head -n 20 "$tmp_file" | sed 's/^\xef\xbb\xbf//' | grep -q '^#!'; then echo "错误: 下载脚本缺少 shebang" >&2; return 1; fi
    if ! grep -q 'SCRIPT_VERSION=' "$tmp_file"; then echo "错误: 下载脚本缺少 SCRIPT_VERSION 标识" >&2; return 1; fi
    if ! grep -q 'BBR v3 / XanMod / TCP' "$tmp_file"; then echo "错误: 下载脚本缺少项目标识" >&2; return 1; fi
    bash "$tmp_file" "$@"
}
# ================ net-tcp-tune 快捷别名结束 ================
ALIAS
)

    if grep -q "net-tcp-tune 快捷别名" "$RC_FILE" 2>/dev/null; then
        cp "$RC_FILE" "${RC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        local temp_file
        temp_file=$(mktemp)
        remove_alias_block "$RC_FILE" "$temp_file"
        mv "$temp_file" "$RC_FILE"
    fi

    echo "$alias_content" >> "$RC_FILE"
}

uninstall_alias_fallback() {
    detect_rc_file || return 1

    if ! grep -q "net-tcp-tune 快捷别名" "$RC_FILE" 2>/dev/null; then
        return 1
    fi

    local temp_file
    temp_file=$(mktemp)
    remove_alias_block "$RC_FILE" "$temp_file"

    if ! diff -q "$RC_FILE" "$temp_file" >/dev/null 2>&1; then
        cp "$RC_FILE" "${RC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$temp_file" "$RC_FILE"
        return 0
    fi

    rm -f "$temp_file"
    return 1
}

install_bbr_command() {
    echo -e "${CYAN}=== 安装 bbr 快捷命令 ===${NC}"
    echo ""

    if can_install_system_command && install_system_command; then
        echo -e "${GREEN}✅ 已安装系统命令: ${WRAPPER_PATH}${NC}"
        echo "安装方式: /usr/local/bin/bbr wrapper"
        echo ""
        echo "以后直接运行："
        echo -e "  ${GREEN}bbr${NC}"
        echo ""
        echo "该命令每次执行都会拉取最新版 net-tcp-tune.sh，并支持传递参数。"
    else
        echo -e "${YELLOW}无法写入 /usr/local/bin，回退到 shell function 方式${NC}"
        if install_alias_fallback; then
            echo -e "${GREEN}✅ 已写入 bbr function 到: ${RC_FILE}${NC}"
            echo ""
            echo "请执行以下命令使快捷函数生效："
            echo -e "  ${YELLOW}source ${RC_FILE}${NC}"
            echo ""
            echo "之后运行："
            echo -e "  ${GREEN}bbr${NC}"
        else
            echo -e "${RED}❌ 快捷函数安装失败${NC}"
            exit 1
        fi
    fi

    echo ""
    echo -e "${CYAN}卸载方法：${NC}"
    echo "  bash install-alias.sh uninstall"
    echo ""
}

uninstall_bbr_command() {
    echo -e "${CYAN}=== 卸载 bbr 快捷命令 ===${NC}"
    echo ""

    local removed_system=false
    local removed_alias=false

    if [ -e "$WRAPPER_PATH" ]; then
        if rm -f "$WRAPPER_PATH" 2>/dev/null; then
            removed_system=true
            echo -e "${GREEN}✅ 已删除 ${WRAPPER_PATH}${NC}"
        else
            echo -e "${YELLOW}⚠️  无法删除 ${WRAPPER_PATH}，请使用 root 权限重试${NC}"
        fi
    else
        echo -e "${YELLOW}未检测到 ${WRAPPER_PATH}${NC}"
    fi

    if uninstall_alias_fallback; then
        removed_alias=true
        echo -e "${GREEN}✅ 已从 ${RC_FILE} 移除快捷命令 block${NC}"
        echo -e "${YELLOW}提示: 重新加载 shell 配置后清理生效：source ${RC_FILE}${NC}"
    else
        echo -e "${YELLOW}未检测到 shell 快捷命令 block${NC}"
    fi

    echo ""
    if [ "$removed_system" = true ] || [ "$removed_alias" = true ]; then
        echo -e "${GREEN}卸载完成${NC}"
    else
        echo -e "${YELLOW}未发现需要卸载的快捷命令${NC}"
    fi
    echo ""
}

case "$MODE" in
    install)
        install_bbr_command
        ;;
    uninstall)
        uninstall_bbr_command
        ;;
esac
