# -----------------------------------------------------------------------------
# Self-update: release-only download, SHA256 verification and atomic replacement.
# -----------------------------------------------------------------------------

self_update() {
    require_root || return 1; acquire_lock || return 1; require_commands curl awk sha256sum sort install grep || return 1
    local latest latest_version current target tmp base expected actual backup newest persist_distinct=0
    current=$(current_script_path 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        current=$(command -v bbr 2>/dev/null || true)
        [[ -f "$current" ]] || { die "当前从临时流运行且没有已安装的 bbr 命令；请先运行 install-alias.sh"; return 1; }
    fi
    latest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${PROJECT_REPO}/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4; exit}' || true)
    if [[ -z "$latest" ]]; then
        latest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${PROJECT_REPO}/tags?per_page=100" |
            awk -F'"' '/"name"[[:space:]]*:/ && $4 ~ /^v[0-9]+[.][0-9]+[.][0-9]+$/ {print $4}' | sort -V | tail -n1)
    fi
    [[ "$latest" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { die "无法取得合法 release 版本"; return 1; }
    [[ "$latest" != "v${SCRIPT_VERSION}" ]] || { log OK "已经是最新版本 $latest"; return 0; }
    latest_version="${latest#v}"
    newest=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$latest_version" | sort -V | tail -n1)
    if [[ "$newest" == "$SCRIPT_VERSION" ]]; then log WARN "当前 v${SCRIPT_VERSION} 比最新 release $latest 更新，不执行降级"; return 0; fi
    tmp=$(mktemp -d) || return 1
    base="https://github.com/${PROJECT_REPO}/releases/download/${latest}"
    if ! curl -fsSL --max-time 120 "$base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" ||
       ! curl -fsSL --max-time 30 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
        base="https://raw.githubusercontent.com/${PROJECT_REPO}/${latest}"
        curl -fsSL --max-time 120 "$base/net-tcp-tune.sh" -o "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; return 1; }
        curl -fsSL --max-time 30 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || { rm -rf "$tmp"; die "tag 缺少 SHA256SUMS"; return 1; }
        log WARN "GitHub Release 资产缺失，已从不可变 tag 更新"
    fi
    expected=$(awk '$2=="net-tcp-tune.sh" || $2=="*net-tcp-tune.sh" {print $1; exit}' "$tmp/SHA256SUMS")
    actual=$(sha256sum "$tmp/net-tcp-tune.sh" | awk '{print $1}')
    [[ -n "$expected" && "$actual" == "$expected" ]] || { rm -rf "$tmp"; die "SHA256 校验失败"; return 1; }
    bash -n "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本语法检查失败"; return 1; }
    grep -Fq 'SCRIPT_NAME="bbrv3-lite"' "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本缺少项目标记"; return 1; }
    grep -q "SCRIPT_VERSION=\"${latest#v}\"" "$tmp/net-tcp-tune.sh" || { rm -rf "$tmp"; die "新脚本版本标记不匹配"; return 1; }
    target="$current"; backup="${current}.previous"
    cp -a -- "$current" "$tmp/current.before" || { rm -rf "$tmp"; die "无法备份当前脚本"; return 1; }
    atomic_install "$tmp/current.before" "$backup" 0755 || { rm -rf "$tmp"; die "无法写入上一版本备份: $backup"; return 1; }
    if [[ -e "$PERSIST_SCRIPT" && "$(readlink -f "$PERSIST_SCRIPT")" != "$(readlink -f "$target")" ]]; then
        persist_distinct=1
    fi
    if ! atomic_install "$tmp/net-tcp-tune.sh" "$target" 0755; then
        rm -rf "$tmp"
        die "更新当前 bbr 命令失败；原文件未替换"
        return 1
    fi
    if (( persist_distinct )) && ! atomic_install "$tmp/net-tcp-tune.sh" "$PERSIST_SCRIPT" 0755; then
        if ! atomic_install "$tmp/current.before" "$target" 0755; then
            rm -rf "$tmp"
            die "持久化副本更新失败，且当前命令自动回滚失败；上一版本仍保存在 $backup"
            return 1
        fi
        rm -rf "$tmp"
        die "持久化副本更新失败；当前 bbr 命令已回滚到更新前版本"
        return 1
    fi
    rm -rf "$tmp"
    log OK "已更新到 $latest；上一版本保存在 $backup"
}
