#!/bin/bash
#=============================================================================
# 鑴氭湰鍚嶇О: install-alias.sh
# 鍔熻兘鎻忚堪: 涓?BBR v3 / XanMod / TCP 缃戠粶璋冧紭鑴氭湰鍒涘缓/鍗歌浇蹇嵎鍒悕
# 浣跨敤鏂规硶: 
#   瀹夎: bash install-alias.sh [install]
#   鍗歌浇: bash install-alias.sh uninstall
#=============================================================================

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# 妫€娴嬫搷浣滄ā寮忥紙瀹夎鎴栧嵏杞斤級
MODE="${1:-install}"
if [ "$MODE" != "install" ] && [ "$MODE" != "uninstall" ]; then
    echo -e "${RED}閿欒: 鏈煡鍙傛暟 '$MODE'${NC}"
    echo "浣跨敤鏂规硶:"
    echo "  瀹夎: bash install-alias.sh [install]"
    echo "  鍗歌浇: bash install-alias.sh uninstall"
    exit 1
fi

# 妫€娴嬪綋鍓嶄娇鐢ㄧ殑 shell
CURRENT_SHELL=$(basename "$SHELL")

# 鏍规嵁涓嶅悓鐨?shell 璁剧疆閰嶇疆鏂囦欢锛堟鏌ュ涓彲鑳界殑閰嶇疆鏂囦欢锛?detect_rc_file() {
    if [ "$CURRENT_SHELL" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    elif [ "$CURRENT_SHELL" = "bash" ]; then
        RC_FILE="$HOME/.bashrc"
        # 濡傛灉 .bashrc 涓嶅瓨鍦紝浣跨敤 .bash_profile
        if [ ! -f "$RC_FILE" ]; then
            RC_FILE="$HOME/.bash_profile"
        fi
    else
        RC_FILE="$HOME/.bashrc"
    fi
    
    # 濡傛灉鏂囦欢涓嶅瓨鍦紝鍒涘缓瀹?    if [ ! -f "$RC_FILE" ]; then
        touch "$RC_FILE"
    fi
}

detect_rc_file

# 鍗歌浇鍔熻兘
uninstall_alias() {
    echo -e "${CYAN}=== 鍗歌浇 net-tcp-tune 蹇嵎鍒悕 ===${NC}"
    echo ""
    echo -e "妫€娴嬪埌 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo -e "閰嶇疆鏂囦欢: ${GREEN}${RC_FILE}${NC}"
    echo ""
    
    # 妫€鏌ュ埆鍚嶆槸鍚﹀凡瀛樺湪
    if ! grep -q "net-tcp-tune 蹇嵎鍒悕" "$RC_FILE" 2>/dev/null; then
        echo -e "${YELLOW}鏈壘鍒板凡瀹夎鐨勫埆鍚嶏紝鏃犻渶鍗歌浇${NC}"
        echo ""
        return 0
    fi
    
    # 鍒涘缓涓存椂鏂囦欢鏉ュ瓨鍌ㄦ竻鐞嗗悗鐨勫唴瀹?    TEMP_FILE=$(mktemp)
    
    # 鍒犻櫎鍖呭惈 "net-tcp-tune 蹇嵎鍒悕" 鐨勬暣涓潡锛堝寘鎷敞閲婂拰鍒悕锛?    # 鍏堝皾璇曞垹闄や粠鍒嗛殧绾垮紑濮嬪埌鍒悕缁撴潫鐨勬暣涓潡
    # 濡傛灉澶辫触锛屽垯鍙垹闄ゅ埆鍚嶅潡鏈韩
    if grep -q "^# ================" "$RC_FILE" 2>/dev/null; then
        # 灏濊瘯鍒犻櫎浠庡垎闅旂嚎寮€濮嬪埌鍒悕缁撴潫鐨勬暣涓潡
        sed '/^# ================/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE" 2>/dev/null

        # 妫€鏌ユ槸鍚﹁繕鏈夊埆鍚嶆畫鐣?        if grep -q "net-tcp-tune 蹇嵎鍒悕" "$TEMP_FILE" 2>/dev/null; then
            # 濡傛灉杩樻湁娈嬬暀锛屼娇鐢ㄦ洿绮剧‘鐨勫垹闄?            sed '/net-tcp-tune 蹇嵎鍒悕/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE"
        fi
    else
        # 鐩存帴鍒犻櫎鍒悕鍧?        sed '/net-tcp-tune 蹇嵎鍒悕/,/^alias bbr=/d' "$RC_FILE" > "$TEMP_FILE"
    fi
    
    # 妫€鏌ユ槸鍚︽湁鍙樻洿
    if ! diff -q "$RC_FILE" "$TEMP_FILE" > /dev/null 2>&1; then
        # 澶囦唤鍘熸枃浠?        cp "$RC_FILE" "${RC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        
        # 鏇挎崲鍘熸枃浠?        mv "$TEMP_FILE" "$RC_FILE"
        echo -e "${GREEN}鉁?鍒悕宸蹭粠 ${RC_FILE} 涓Щ闄?{NC}"
        echo ""
        echo -e "${YELLOW}鎻愮ず: 鍘熼厤缃枃浠跺凡澶囦唤涓?${RC_FILE}.bak.*${NC}"
        echo ""
        echo -e "${CYAN}=== 鐜板湪鐢熸晥锛堟墽琛屼互涓嬪懡浠わ級===${NC}"
        echo ""
        echo -e "${YELLOW}source ${RC_FILE}${NC}"
        echo ""
        echo "鎴栬€呭叧闂粓绔噸鏂版墦寮€锛屽嵏杞藉嵆鐢熸晥銆?
        echo ""
    else
        rm -f "$TEMP_FILE"
        echo -e "${YELLOW}鏈壘鍒伴渶瑕佸垹闄ょ殑鍐呭${NC}"
        echo ""
    fi
}

# 瀹夎鍔熻兘
install_alias() {
    echo -e "${CYAN}=== 瀹夎 net-tcp-tune 蹇嵎鍒悕 ===${NC}"
    echo ""
    echo -e "妫€娴嬪埌 Shell: ${GREEN}${CURRENT_SHELL}${NC}"
    echo ""
    echo -e "閰嶇疆鏂囦欢: ${GREEN}${RC_FILE}${NC}"
    echo ""
    
    # 瀹氫箟瑕佹坊鍔犵殑鍒悕锛堝甫鏃堕棿鎴冲弬鏁帮紝纭繚姣忔鑾峰彇鏈€鏂扮増鏈級
    ALIAS_CONTENT='
# ========================================
# net-tcp-tune 蹇嵎鍒悕 (鑷姩娣诲姞)
# 浣跨敤鏃堕棿鎴冲弬鏁扮‘淇濇瘡娆￠兘鑾峰彇鏈€鏂扮増鏈紝閬垮厤缂撳瓨
# ========================================
alias bbr="bash <(curl -fsSL \"https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?\$(date +%s)\")"
'
    
    # 妫€鏌ュ埆鍚嶆槸鍚﹀凡瀛樺湪
    if grep -q "net-tcp-tune 蹇嵎鍒悕" "$RC_FILE" 2>/dev/null; then
        echo -e "${YELLOW}閰嶇疆宸插瓨鍦紝姝ｅ湪鏇存柊...${NC}"
        
        # 澶囦唤鏂囦欢
        cp "$RC_FILE" "${RC_FILE}.bak"
        
        # 鏂规锛氳鍙栨枃浠讹紝杩囨护鎺夊師鏉ョ殑鍒悕鍧楋紝鐒跺悗鍐嶈拷鍔犳柊鐨?        # 1. 濡傛灉鏈夋棫鐨勫潡缁撴瀯锛屽皾璇曟暣浣撴浛鎹紙鍏煎鏃х増锛?        if grep -q "^# ================" "$RC_FILE" 2>/dev/null; then
             sed -i '/^# ================/,/^alias bbr=/d' "$RC_FILE" 2>/dev/null || sed -i '/net-tcp-tune 蹇嵎鍒悕/,/^alias bbr=/d' "$RC_FILE"
        else
             sed -i '/net-tcp-tune 蹇嵎鍒悕/,/^alias bbr=/d' "$RC_FILE"
        fi

        # 2. 鈿★笍鏆村姏娓呯悊锛氱‘淇濇病鏈夋畫鐣欑殑鏃х増 alias dog= 琛?        if grep -q "alias dog=" "$RC_FILE"; then
            grep -v "alias dog=" "$RC_FILE" > "${RC_FILE}.tmp" && mv "${RC_FILE}.tmp" "$RC_FILE"
        fi
        
        # 鍐嶆坊鍔犳柊鐨?        echo "$ALIAS_CONTENT" >> "$RC_FILE"
        echo -e "${GREEN}鉁?鍒悕宸叉洿鏂板埌 ${RC_FILE}${NC}"
        echo ""
    else
        # 娣诲姞鍒悕鍒伴厤缃枃浠?        echo "$ALIAS_CONTENT" >> "$RC_FILE"
        echo -e "${GREEN}鉁?鍒悕宸叉坊鍔犲埌 ${RC_FILE}${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}=== 蹇嵎鍛戒护 ===${NC}"
    echo ""
    echo -e "  ${GREEN}bbr${NC}   - 涓€閿繍琛岀綉缁滆皟浼樿剼鏈?
    echo ""
    echo -e "${CYAN}=== 浣跨敤鏂规硶 ===${NC}"
    echo ""
    echo "1. 閲嶆柊鍔犺浇閰嶇疆锛?
    echo -e "   ${YELLOW}source ${RC_FILE}${NC}"
    echo ""
    echo "2. 鎴栬€呭叧闂粓绔噸鏂版墦寮€"
    echo ""
    echo "3. 鐒跺悗鐩存帴杈撳叆蹇嵎鍛戒护锛?
    echo -e "   ${GREEN}bbr${NC}  (缃戠粶璋冧紭)"
    echo ""
    echo -e "${CYAN}=== 鍗歌浇鏂规硶 ===${NC}"
    echo ""
    echo "濡傞渶鍗歌浇鍒悕锛岃杩愯锛?
    echo -e "   ${YELLOW}bash install-alias.sh uninstall${NC}"
    echo ""
    echo -e "${CYAN}=== 鐜板湪灏辩敓鏁堬紙鎵ц浠ヤ笅鍛戒护锛?==${NC}"
    echo ""
    echo -e "${YELLOW}source ${RC_FILE}${NC}"
    echo ""
}

# 鏍规嵁妯″紡鎵ц鐩稿簲鎿嶄綔
case "$MODE" in
    install)
        install_alias
        ;;
    uninstall)
        uninstall_alias
        ;;
esac

