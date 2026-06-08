#!/bin/bash
#=============================================================================
# BBR v3 Lite ARM64 内核安装助手
# XanMod 官方 APT 仅支持 x86_64；ARM64 使用社区构建（可选）或系统自带 BBR。
#=============================================================================

SCRIPT_VERSION="1.0.0"
COMMUNITY_REPO="zijiren233/xanmod-arm64"
COMMUNITY_API="https://api.github.com/repos/${COMMUNITY_REPO}/releases/latest"

gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'
gl_zi='\033[35m'

check_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        echo -e "${gl_hong}错误: 需要 root 权限${gl_bai}"
        exit 1
    }
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_root_available_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4}'
}

check_disk_space() {
    local need_mb="${1:-3}"
    local avail
    avail=$(get_root_available_mb)
    if [[ "$avail" =~ ^[0-9]+$ ]] && [ "$avail" -lt $((need_mb * 1024)) ]; then
        echo -e "${gl_hong}错误: 根分区可用空间不足 ${need_mb}GB（当前约 ${avail}MB）${gl_bai}"
        return 1
    fi
    return 0
}

bbr_v3_active() {
    local ver
    ver=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
    [ "$ver" = "3" ]
}

regular_bbr_available() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr \
        || modinfo tcp_bbr >/dev/null 2>&1
}

kernel_has_xanmod() {
    uname -r | grep -qi xanmod || dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q xanmod
}

download_file() {
    local url="$1"
    local output="$2"
    if command_exists curl; then
        curl -fsSL --connect-timeout 15 --max-time 600 "$url" -o "$output"
    elif command_exists wget; then
        wget -q -T 600 -O "$output" "$url"
    else
        return 1
    fi
    [ -s "$output" ]
}

fetch_release_assets() {
    local json_file="$1"
    if command_exists curl; then
        curl -fsSL --connect-timeout 15 --max-time 60 "$COMMUNITY_API" -o "$json_file"
    elif command_exists wget; then
        wget -q -T 60 -O "$json_file" "$COMMUNITY_API"
    else
        return 1
    fi
    [ -s "$json_file" ]
}

pick_asset_url() {
    local json_file="$1"
    local pattern="$2"
    python3 - "$json_file" "$pattern" <<'PY' 2>/dev/null || return 1
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
pat = re.compile(sys.argv[2])
for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    digest = asset.get("digest", "")
    if pat.search(name) and url:
        print(url)
        print(digest.replace("sha256:", "") if digest.startswith("sha256:") else "")
        break
PY
}

install_community_debs() {
    local tmp_dir json_file image_url headers_url image_digest headers_digest
    local image_deb headers_deb

    tmp_dir=$(mktemp -d /tmp/bbrv3arm.XXXXXX) || return 1
    json_file="${tmp_dir}/release.json"

    echo -e "${gl_kjlan}正在查询社区 ARM64 XanMod 发布: ${COMMUNITY_REPO}${gl_bai}"
    if ! fetch_release_assets "$json_file"; then
        echo -e "${gl_hong}错误: 无法获取 GitHub Release 信息${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mapfile -t image_meta < <(pick_asset_url "$json_file" '^linux-image-.*arm64-xanmod.*\.deb$')
    mapfile -t headers_meta < <(pick_asset_url "$json_file" '^linux-headers-.*arm64-xanmod.*\.deb$')

    image_url="${image_meta[0]:-}"
    image_digest="${image_meta[1]:-}"
    headers_url="${headers_meta[0]:-}"
    headers_digest="${headers_meta[1]:-}"

    if [ -z "$image_url" ] || [ -z "$headers_url" ]; then
        echo -e "${gl_hong}错误: Release 中未找到 linux-image/linux-headers .deb${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    image_deb="${tmp_dir}/linux-image.deb"
    headers_deb="${tmp_dir}/linux-headers.deb"

    echo "下载 linux-image..."
    download_file "$image_url" "$image_deb" || { rm -rf "$tmp_dir"; return 1; }
    echo "下载 linux-headers..."
    download_file "$headers_url" "$headers_deb" || { rm -rf "$tmp_dir"; return 1; }

    if command_exists sha256sum && [ -n "$image_digest" ]; then
        actual=$(sha256sum "$image_deb" | awk '{print $1}')
        if [ "$actual" != "$image_digest" ]; then
            echo -e "${gl_hong}错误: linux-image SHA256 校验失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    if command_exists sha256sum && [ -n "$headers_digest" ]; then
        actual=$(sha256sum "$headers_deb" | awk '{print $1}')
        if [ "$actual" != "$headers_digest" ]; then
            echo -e "${gl_hong}错误: linux-headers SHA256 校验失败${gl_bai}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    echo -e "${gl_lv}SHA256 校验通过（如 Release 提供 digest）${gl_bai}"
    echo "安装内核包..."
    if ! dpkg -i "$image_deb" "$headers_deb"; then
        echo -e "${gl_hong}错误: dpkg 安装失败${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    update-grub 2>/dev/null || true
    rm -rf "$tmp_dir"
    return 0
}

main() {
    check_root

    echo -e "${gl_kjlan}=== BBR v3 Lite ARM64 内核安装 v${SCRIPT_VERSION} ===${gl_bai}"
    echo -e "${gl_zi}说明: XanMod 官方仓库不支持 ARM64 APT；可选社区构建 ${COMMUNITY_REPO}${gl_bai}"
    echo ""

    if [ "$(uname -m)" != "aarch64" ]; then
        echo -e "${gl_hong}错误: 本脚本仅适用于 aarch64${gl_bai}"
        exit 1
    fi

    if ! [ -r /etc/os-release ]; then
        echo -e "${gl_hong}错误: 无法读取 /etc/os-release${gl_bai}"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *)
            echo -e "${gl_hong}错误: 仅支持 Debian/Ubuntu${gl_bai}"
            exit 1
            ;;
    esac

    check_disk_space 3 || exit 1

    if bbr_v3_active && kernel_has_xanmod; then
        echo -e "${gl_lv}当前已运行 XanMod + BBR v3: $(uname -r)${gl_bai}"
        exit 0
    fi

    if bbr_v3_active; then
        echo -e "${gl_lv}当前内核已支持 BBR v3: $(uname -r)${gl_bai}"
        echo -e "${gl_zi}无需安装社区内核；可直接执行菜单 3 进行 TCP 调优。${gl_bai}"
        exit 0
    fi

    if regular_bbr_available; then
        echo -e "${gl_huang}当前内核支持普通 BBR，但不是 BBR v3 / XanMod。${gl_bai}"
        echo -e "${gl_zi}可跳过内核安装，直接执行菜单 3（轻量 TCP 调优）。${gl_bai}"
        echo ""
        read -e -p "是否仍尝试安装社区 XanMod ARM64 内核？(Y/N): " keep_going
        case "$keep_going" in
            [Yy]) ;;
            *)
                echo "已取消；请使用功能 3 或功能 10 的轻量优化。"
                exit 0
                ;;
        esac
    fi

    install_package_deps() {
        if command_exists apt-get; then
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget ca-certificates python3 dpkg >/dev/null 2>&1 || true
        fi
    }
    install_package_deps

    if ! command_exists python3; then
        echo -e "${gl_huang}警告: 未安装 python3，将跳过 digest 解析校验${gl_bai}"
    fi

    echo ""
    echo -e "${gl_huang}将安装社区维护的 ARM64 XanMod 内核（非 XanMod 官方）${gl_bai}"
    echo -e "${gl_huang}来源: https://github.com/${COMMUNITY_REPO}${gl_bai}"
    read -e -p "确认继续？(Y/N): " confirm
    case "$confirm" in
        [Yy]) ;;
        *)
            echo "已取消"
            exit 1
            ;;
    esac

    if install_community_debs; then
        echo ""
        echo -e "${gl_lv}ARM64 XanMod 内核安装完成，请重启后执行功能 3 或一键优化。${gl_bai}"
        exit 0
    fi

    echo -e "${gl_hong}社区内核安装失败。${gl_bai}"
    if regular_bbr_available; then
        echo -e "${gl_zi}你仍可使用系统普通 BBR + 功能 3 TCP 调优。${gl_bai}"
    fi
    exit 1
}

main "$@"
