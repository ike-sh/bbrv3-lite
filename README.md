# BBR v3 / XanMod / TCP 缃戠粶璋冧紭鑴氭湰

鏈簿绠€鐗堝彧淇濈暀缃戠粶璋冧紭鐩稿叧鍔熻兘锛岃仛鐒?XanMod 鍐呮牳銆丅BR v3銆乀CP 鍙傛暟璋冧紭銆丏NS 鍑€鍖栥€両Pv6 绠＄悊銆丷ealm 杞彂 timeout 淇锛屼互鍙婂繀瑕佺殑娴嬮€熷拰鐘舵€佹煡鐪嬭兘鍔涖€?
鍘熼」鐩?License 淇濇寔涓嶅彉锛岃瑙?[LICENSE](LICENSE)銆?
## 涓€閿畨瑁呭埆鍚?
鏂版満鍣ㄥ鏋滄湭瀹夎 `curl`锛岃鍏堟墽琛岋細

```bash
apt update -y && apt install curl -y
```

瀹夎蹇嵎鍒悕鍚庯紝鍙洿鎺ヨ緭鍏?`bbr` 杩愯鑴氭湰锛?
```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh?$(date +%s)")
source ~/.bashrc
bbr
```

## 鍦ㄧ嚎杩愯

涓嶅畨瑁呭埆鍚嶏紝涓存椂鍦ㄧ嚎杩愯锛?
```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)")
```

涔熷彲浠ヤ笅杞藉埌鏈湴鍚庢墽琛岋細

```bash
wget -O net-tcp-tune.sh "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)"
chmod +x net-tcp-tune.sh
./net-tcp-tune.sh
```

## 淇濈暀鍔熻兘

| 缂栧彿 | 鍔熻兘 |
| :--: | --- |
| 1 | 瀹夎/鏇存柊 XanMod 鍐呮牳 + BBR v3 |
| 2 | 鍗歌浇 XanMod 鍐呮牳 |
| 3 | BBR 鐩磋繛/钀藉湴浼樺寲锛堟櫤鑳藉甫瀹芥娴嬶級 |
| 4 | DNS 鍑€鍖栵紙鎶楁薄鏌?椹湇 DHCP锛?|
| 5 | Realm 杞彂 timeout 淇 |
| 6 | IPv6 绠＄悊锛堜复鏃?姘镐箙绂佺敤/鍙栨秷锛?|
| 7 | 鏌ョ湅绯荤粺璇︾粏鐘舵€?|
| 8 | 鏈嶅姟鍣ㄥ甫瀹芥祴璇?|
| 9 | iperf3 鍗曠嚎绋嬫祴璇?|
| 10 | 涓夌綉鍥炵▼璺敱娴嬭瘯 |
| 11 | 涓€閿叏鑷姩浼樺寲锛圔BR v3 + 缃戠粶璋冧紭锛?|

## 鍔熻兘 11锛氫竴閿叏鑷姩浼樺寲

涓€閿叏鑷姩浼樺寲浠嶇劧淇濈暀鍘熼」鐩嚜鍔ㄥ寲閫昏緫銆?
鎵ц閾捐矾淇濇寔涓猴細

```text
1 -> 3 -> 4 -> 5 -> 6
```

涓€閿叏鑷姩浼樺寲鍒嗕袱闃舵鎵ц锛?
- 棣栨鎵ц锛氬畨瑁?XanMod/BBR v3 鍐呮牳骞舵彁绀洪噸鍚€?- 閲嶅惎鍚庡啀娆¤繘鍏ヨ剼鏈€夋嫨鈥滀竴閿叏鑷姩浼樺寲鈥濓細鑷姩鎵ц BBR 鐩磋繛浼樺寲銆丏NS 鍑€鍖栥€丷ealm 淇鍜?IPv6 绠＄悊銆?
## 浣跨敤寤鸿

- 棣栨浣跨敤寤鸿鍏堟墽琛屽姛鑳?1锛岄噸鍚繘鍏?XanMod 鍐呮牳鍚庡啀鎵ц鍔熻兘 3 鎴栧姛鑳?11锛氫竴閿叏鑷姩浼樺寲銆?- 涓嶇‘瀹氬甫瀹芥。浣嶆椂锛屽姛鑳?3 鍙娇鐢ㄨ嚜鍔ㄦ娴嬶紝璁╄剼鏈部鐢ㄥ師椤圭洰鐨?Speedtest銆丅DP 璁＄畻鍜?sysctl 妯℃澘閫昏緫銆?- 璋冧紭鍚庡彲鐢ㄥ姛鑳?7 鏌ョ湅绯荤粺鐘舵€侊紝鐢ㄥ姛鑳?8銆?銆?0 杈呭姪楠岃瘉绾胯矾琛ㄧ幇銆?
## 椋庨櫓鎻愰啋

- 鎹㈠唴鏍稿墠寤鸿鍏堢粰 VPS 鍋氬揩鐓с€?- OpenVZ/LXC 绛夊鍣ㄨ櫄鎷熷寲鐜閫氬父涓嶆敮鎸佽嚜琛屾洿鎹㈠唴鏍搞€?- 鐢熶骇鏈鸿璋ㄦ厧鎵ц鍐呮牳瀹夎銆丏NS 淇敼銆両Pv6 绂佺敤绛夋搷浣滐紝寤鸿纭繚鏈夋帶鍒跺彴鎴栨晳鎻存ā寮忓彲鐢ㄣ€?
## 宸插垹闄ゅ唴瀹?
鍒犻櫎浜嗕唬鐞嗛儴缃层€丄I 宸ュ叿绠便€丆loudflare Tunnel銆丆addy銆丼ub-Store 绛夐潪璋冧紭鍔熻兘銆?
鏈簿绠€鐗堜笉鍐嶅寘鍚?Snell銆乆ray銆丼OCKS5 浠ｇ悊閮ㄧ讲銆丼ub-Store 澶氬疄渚嬬鐞嗐€丆loudflare Tunnel銆丆addy 澶氬煙鍚嶅弽浠ｃ€丄I 浠ｇ悊宸ュ叿绠便€丱pen WebUI銆丆RS銆丗uclaude銆丼ub2API銆丱penClaw銆丱penAI Responses API 杞崲浠ｇ悊銆丆odex Console銆丆LIProxyAPI銆丱AI2銆佺涓夋柟宸ュ叿璺宠浆鑴氭湰銆丗 浣?sing-box 鑴氭湰銆佺鎶€ lion 鑴氭湰銆両P 璐ㄩ噺妫€娴嬨€佸獟浣?AI 瑙ｉ攣妫€娴嬨€丯Q 涓€閿娴嬬瓑闈?BBRv3/TCP 璋冧紭妯″潡銆?
