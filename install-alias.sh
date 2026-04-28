#!/bin/bash
#=============================================================================
# 脚本名称: install-alias.sh
# 功能描述: 为 BBR v3 / XanMod / TCP 网络调优脚本创建或卸载快捷别名
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
if [ "$MODE" != "install" ] && [ "$MODE" != "uninstall" ]; then
    echo -e "${RED}错误: 未知参数 '$MODE'${NC}"
    echo "使用方法:"
    echo "  安装: bash install-alias.sh [install]"
    echo "  卸载: bash install-alias.sh uninstall"
    exit 1
fi

CURRENT_SHELL=$(basename "$SHELL")

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
        touch "$RC_FILE"
    fi
}

detect_rc_file

uninstall_alias() {
    echo -e "${CYAN}=== 卸载 net-tcp-tune 快捷别名 ===${NC}"
    echo ""
    echo -e "检测到 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo -e "配置文件: ${GREEN}${RC_FILE}${NC}"
    echo ""

    if ! grep -q "net-tcp-tune 快捷别名" "$RC_FILE" 2>/dev/null; then
        echo -e "${YELLOW}未找到已安装的别名，无需卸载${NC}"
        echo ""
        return 0
    fi

    TEMP_FILE=$(mktemp)

    if grep -q "^# ================" "$RC_FILE" 2>/dev/null; then
        sed '/^# ================/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE" 2>/dev/null

        if grep -q "net-tcp-tune 快捷别名" "$TEMP_FILE" 2>/dev/null; then
            sed '/net-tcp-tune 快捷别名/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE"
        fi
    else
        sed '/net-tcp-tune 快捷别名/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE"
    fi

    if ! diff -q "$RC_FILE" "$TEMP_FILE" >/dev/null 2>&1; then
        cp "$RC_FILE" "${RC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$TEMP_FILE" "$RC_FILE"

        echo -e "${GREEN}✅ 别名已从 ${RC_FILE} 中移除${NC}"
        echo ""
        echo -e "${YELLOW}提示: 原配置文件已备份为 ${RC_FILE}.bak.*${NC}"
        echo ""
        echo -e "${CYAN}=== 现在生效，执行以下命令 ===${NC}"
        echo ""
        echo -e "${YELLOW}source ${RC_FILE}${NC}"
        echo ""
        echo "或者关闭终端重新打开，卸载即可生效。"
        echo ""
    else
        rm -f "$TEMP_FILE"
        echo -e "${YELLOW}未找到需要删除的内容${NC}"
        echo ""
    fi
}

install_alias() {
    echo -e "${CYAN}=== 安装 net-tcp-tune 快捷别名 ===${NC}"
    echo ""
    echo -e "检测到 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo -e "配置文件: ${GREEN}${RC_FILE}${NC}"
    echo ""

    ALIAS_CONTENT='
# ========================================
# net-tcp-tune 快捷别名（自动添加）
# 使用时间戳参数确保每次都获取最新版本，避免缓存
# ========================================
alias bbr="bash <(curl -fsSL \"https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?\$(date +%s)\")"
'

    if grep -q "net-tcp-tune 快捷别名" "$RC_FILE" 2>/dev/null; then
        echo -e "${YELLOW}配置已存在，正在更新...${NC}"

        cp "$RC_FILE" "${RC_FILE}.bak"

        if grep -q "^# ================" "$RC_FILE" 2>/dev/null; then
            sed -i '/^# ================/,/^alias bbr=/d' "$RC_FILE" 2>/dev/null || sed -i '/net-tcp-tune 快捷别名/,/^alias bbr=/d' "$RC_FILE"
        else
            sed -i '/net-tcp-tune 快捷别名/,/^alias bbr=/d' "$RC_FILE"
        fi

        if grep -q "alias dog=" "$RC_FILE"; then
            grep -v "alias dog=" "$RC_FILE" > "${RC_FILE}.tmp" && mv "${RC_FILE}.tmp" "$RC_FILE"
        fi

        echo "$ALIAS_CONTENT" >> "$RC_FILE"
        echo -e "${GREEN}✅ 别名已更新到 ${RC_FILE}${NC}"
        echo ""
    else
        echo "$ALIAS_CONTENT" >> "$RC_FILE"
        echo -e "${GREEN}✅ 别名已添加到 ${RC_FILE}${NC}"
        echo ""
    fi

    echo -e "${CYAN}=== 快捷命令 ===${NC}"
    echo ""
    echo -e "  ${GREEN}bbr${NC}   - 一键运行网络调优脚本"
    echo ""
    echo -e "${CYAN}=== 使用方法 ===${NC}"
    echo ""
    echo "1. 重新加载配置："
    echo -e "   ${YELLOW}source ${RC_FILE}${NC}"
    echo ""
    echo "2. 或者关闭终端重新打开"
    echo ""
    echo "3. 然后直接输入快捷命令："
    echo -e "   ${GREEN}bbr${NC}"
    echo ""
    echo -e "${CYAN}=== 卸载方法 ===${NC}"
    echo ""
    echo "如需卸载别名，请运行："
    echo -e "   ${YELLOW}bash install-alias.sh uninstall${NC}"
    echo ""
    echo -e "${CYAN}=== 现在生效，执行以下命令 ===${NC}"
    echo ""
    echo -e "${YELLOW}source ${RC_FILE}${NC}"
    echo ""
}

case "$MODE" in
    install)
        install_alias
        ;;
    uninstall)
        uninstall_alias
        ;;
esac
