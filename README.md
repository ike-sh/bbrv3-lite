# BBR v3 / XanMod / TCP 网络调优脚本

当前版本：v5.2.0

本精简版只保留网络调优相关功能，聚焦 XanMod 内核、BBR v3、TCP 参数调优、DNS 净化、IPv6 管理，以及必要的测速、预检和回滚能力。

原项目 License 保持不变，详见 [LICENSE](LICENSE)。

## 安装快捷命令

新机器如果未安装 `curl`，请先执行：

```bash
apt update -y && apt install curl -y
```

推荐安装 `/usr/local/bin/bbr` 系统命令：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh?$(date +%s)")
bbr
```

安装脚本会优先写入 `/usr/local/bin/bbr`。如果当前用户无法写入 `/usr/local/bin`，会自动回退到 shell alias 方式，并提示执行 `source ~/.bashrc` 或 `source ~/.zshrc`。

卸载快捷命令：

```bash
bash install-alias.sh uninstall
```

卸载时会同时尝试删除 `/usr/local/bin/bbr` 和 shell alias block。

## 在线运行

不安装快捷命令，临时在线运行：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)")
```

也可以下载到本地后执行：

```bash
wget -O net-tcp-tune.sh "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)"
chmod +x net-tcp-tune.sh
./net-tcp-tune.sh
```

## 保留功能

| 编号 | 功能 |
| :--: | --- |
| 1 | 安装/更新 XanMod 内核 + BBR v3 |
| 2 | 卸载 XanMod 内核 |
| 3 | BBR 直连/落地优化（智能带宽检测） |
| 4 | DNS 净化（抗污染/驯服 DHCP） |
| 5 | IPv6 管理（临时/永久禁用/取消） |
| 6 | 查看系统详细状态 |
| 7 | 服务器带宽测试 |
| 8 | iperf3 单线程测试 |
| 9 | 三网回程路由测试 |
| 10 | 一键全自动优化（BBR v3 + 网络调优） |
| 11 | 环境预检 / 兼容性检查 |
| 12 | 回滚 / 卸载管理 |

## 系统兼容性

完整支持 Debian/Ubuntu KVM；其他发行版仅保证部分功能可尝试，不作为主要支持目标。

| 环境 | 支持状态 | 说明 |
| --- | --- | --- |
| Debian 12 bookworm / Debian 13 trixie + KVM + x86_64 | 完整支持 | 推荐环境，支持 XanMod + BBR v3 + TCP 调优 |
| Ubuntu 22.04 / 24.04 或常见 LTS + KVM + x86_64 | 完整支持 | 使用系统自身 codename 添加 XanMod 源 |
| Debian/Ubuntu ARM64 | 实验/部分支持 | 如脚本已有 ARM64 逻辑，可尝试；建议先做快照 |
| Rocky / Alma / CentOS / Fedora / RHEL | 部分支持 | sysctl、测速等功能可尝试，不保证 XanMod 安装 |
| OpenVZ / LXC / Docker 容器 | 不建议/通常不支持 | 通常不能自行更换内核 |
| Alpine | 非主要目标 | 仅少量逻辑可能兼容 |
| 非 systemd 系统 | 部分功能不可用 | DNS 净化、服务持久化等可能不可用 |

建议先执行功能 11：环境预检 / 兼容性检查，截图结果便于排障。

## XanMod 源与包名选择

脚本不使用固定的 `releases` APT 源，也不固定安装单一包名。

- 通过 `/etc/os-release` 读取 `VERSION_CODENAME`。
- Debian 12 使用 `bookworm`，Debian 13 使用 `trixie`。
- Ubuntu 使用系统自身 codename。
- 添加的 XanMod APT 源格式为：

```text
deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
```

`apt update` 后，脚本会通过 `apt-cache search '^linux-xanmod'` 查找仓库中实际可用的包名，并严格按 CPU 支持等级选择：

- CPU 支持 x64v4：优先 `linux-xanmod-lts-x64v4`，再逐级回退到 x64v3、x64v2、x64v1。
- CPU 支持 x64v3：优先 `linux-xanmod-lts-x64v3`，再回退到 x64v2、x64v1。
- CPU 支持 x64v2：只会选择 x64v2 或 x64v1。
- CPU 只支持 x64v1 或无法可靠识别：只会选择 x64v1。

安装前会打印系统 codename、检测到的 CPU level、最终选择的 XanMod 包名和当前 XanMod APT 源。找不到合适包时，会打印当前 `apt-cache search '^linux-xanmod'` 的候选列表用于排障。

## DoT 853 被封时的 DoH Fallback

功能 4：DNS 净化会保留原有 DoT 853 连通性检测。

- 如果 DoT 853 可达，继续使用原有 `systemd-resolved` + `DNSOverTLS` 配置。
- 如果 DoT 853 不可达，脚本会提示可能是 NAT 商家或机房防火墙封锁出站 853，并询问是否自动切换到 DoH 443 模式。
- DoH 443 模式优先使用系统源安装 `dnscrypt-proxy`，不会强行编译安装。
- 配置 `dnscrypt-proxy` 前会检测本机 53 端口占用。
- 如果 53 未占用，`dnscrypt-proxy` 监听 `127.0.0.1:53`。
- 如果 53 已占用，自动改用 `127.0.0.1:5353`，并让 `systemd-resolved` 指向对应地址。
- 如果 DoH 模式也失败，脚本会继续询问是否降级为普通 DNS 53。
- 如果用户拒绝 DoH 和普通 DNS 53 降级，DNS 净化会被跳过，不影响后续 BBR/TCP 调优流程。

DNS 净化执行前会备份 `systemd-resolved`、`resolv.conf`、`dnscrypt-proxy` 等相关配置；成功完成后会输出回滚脚本路径。

## 功能 10：一键全自动优化

一键全自动优化仍然保留原项目自动化逻辑。

执行链路保持为：

```text
1 -> 3 -> 4 -> 5
```

一键全自动优化分两阶段执行：

- 首次执行：安装 XanMod/BBR v3 内核并提示重启。
- 重启后再次进入脚本选择“一键全自动优化”：自动执行 BBR 直连优化、DNS 净化和 IPv6 管理。

v5.1.0 起，一键优化最后会输出结果汇总，标记每一步成功、失败或跳过，并给出 DNS 回滚、IPv6 恢复、XanMod 卸载等提示。DNS、IPv6 这类辅助步骤失败时不会阻断 BBR/TCP 主流程。

v5.1.1 起，IPv6 汇总状态以真实 sysctl 检测为准：只有 `net.ipv6.conf.all.disable_ipv6`、`net.ipv6.conf.default.disable_ipv6`、`net.ipv6.conf.lo.disable_ipv6` 三项均为 `1` 时，才显示 IPv6 已永久禁用。

## 回滚 / 卸载

功能 12：回滚 / 卸载管理提供统一入口：

- 卸载 XanMod 内核。
- 删除本脚本生成的 TCP/sysctl 调优配置。
- 删除 `tc` / MSS clamp / `bbr-optimize-persist.service` 持久化。
- 自动查找并执行最近一次 DNS 净化回滚脚本。
- 恢复 IPv6。
- 删除 `/usr/local/bin/bbr` 快捷命令。
- 查看 DNS、sysctl 相关备份目录。

所有删除或恢复操作都会打印将处理的路径，并要求二次确认。

## 使用建议

- 首次使用建议先执行功能 11 做环境预检。
- 确认适合换内核后，再执行功能 1，重启进入 XanMod 内核后执行功能 3 或功能 10。
- 不确定带宽档位时，功能 3 可使用自动检测，让脚本沿用原项目的 Speedtest、BDP 计算和 sysctl 模板逻辑。
- 调优后可用功能 6 查看系统状态，用功能 7、8、9 辅助验证线路表现。

## 风险提醒

- 换内核前建议先给 VPS 做快照。
- OpenVZ/LXC 等容器虚拟化环境通常不支持自行更换内核。
- 生产机请谨慎执行内核安装、DNS 修改、IPv6 禁用等操作，建议确保有控制台或救援模式可用。

## v5.2.0 更新记录

- 移除小众中转专项功能，进一步聚焦 BBRv3 / XanMod / TCP 调优。
- 精简主菜单和一键优化流程。
- 一键优化阶段 2 改为 TCP 调优、DNS 净化、IPv6 管理三步。
- 回滚 / 卸载管理移除中转专项备份展示。
- README 同步更新 lite 版定位。

## v5.1.1 更新记录

- 修复一键优化中 IPv6 禁用失败但汇总误报成功的问题。
- 修复确认重启后脚本未立即退出导致菜单短暂重绘的问题。

## v5.1.0 更新记录

- 修复 XanMod 包选择逻辑，严格按 CPU 支持等级选择 x64v4/x64v3/x64v2/x64v1。
- 新增系统兼容性矩阵与环境预检菜单。
- 新增一键优化结果汇总。
- 优化 DoH fallback，`dnscrypt-proxy` 自动避让 53 端口冲突。
- 新增 `/usr/local/bin/bbr` 快捷命令安装方式。
- 新增回滚/卸载管理入口。

## 已删除内容

删除了代理部署、AI 工具箱、Cloudflare Tunnel、Caddy、Sub-Store 等非调优功能。

v5.2.0 起移除 Realm 相关小众中转功能，进一步聚焦 BBRv3 / XanMod / TCP 调优。

本精简版不再包含 Snell、Xray、SOCKS5 代理部署、Sub-Store 多实例管理、Cloudflare Tunnel、Caddy 多域名反代、AI 代理工具箱、Open WebUI、CRS、Fuclaude、Sub2API、OpenClaw、OpenAI Responses API 转换代理、Codex Console、CLIProxyAPI、OAI2、第三方工具跳转脚本、F 佬 sing-box 脚本、科技 lion 脚本、IP 质量检测、媒体/AI 解锁检测、NQ 一键检测等非 BBRv3/TCP 调优模块。
