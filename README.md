# BBR v3 / XanMod / TCP 网络调优脚本

本精简版只保留网络调优相关功能，聚焦 XanMod 内核、BBR v3、TCP 参数调优、DNS 净化、IPv6 管理、Realm 转发 timeout 修复，以及必要的测速和状态查看能力。

原项目 License 保持不变，详见 [LICENSE](LICENSE)。

## 一键安装别名

新机器如果未安装 `curl`，请先执行：

```bash
apt update -y && apt install curl -y
```

安装快捷别名：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh?$(date +%s)")
```

让别名立即生效：

```bash
source ~/.bashrc
```

运行脚本：

```bash
bbr
```

## 在线运行

不安装别名，临时在线运行：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)")
```

## 下载到本地执行

下载脚本：

```bash
wget -O net-tcp-tune.sh "https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/net-tcp-tune.sh?$(date +%s)"
```

赋予执行权限：

```bash
chmod +x net-tcp-tune.sh
```

运行脚本：

```bash
./net-tcp-tune.sh
```

## 如果 raw.githubusercontent.com 无法解析

如果出现：

```text
curl: (6) Could not resolve host: raw.githubusercontent.com
```

说明当前服务器 DNS 解析异常，先临时写入公共 DNS 后再执行安装命令：

```bash
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
```

如果 `/etc/resolv.conf` 被锁定，可以先解除锁定再写入：

```bash
chattr -i /etc/resolv.conf 2>/dev/null || true
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
```

然后重新执行安装或在线运行命令。

## 保留功能

| 编号 | 功能 |
| :--: | --- |
| 1 | 安装/更新 XanMod 内核 + BBR v3 |
| 2 | 卸载 XanMod 内核 |
| 3 | BBR 直连/落地优化（智能带宽检测） |
| 4 | DNS 净化（抗污染/驯服 DHCP） |
| 5 | Realm 转发 timeout 修复 |
| 6 | IPv6 管理（临时/永久禁用/取消） |
| 7 | 查看系统详细状态 |
| 8 | 服务器带宽测试 |
| 9 | iperf3 单线程测试 |
| 10 | 三网回程路由测试 |
| 11 | 一键全自动优化（BBR v3 + 网络调优） |

## 功能 11：一键全自动优化

一键全自动优化保留原项目自动化逻辑，分两阶段执行。

首次执行：

```text
1. 安装/更新 XanMod 内核 + BBR v3
2. 提示重启服务器
```

重启后再次进入脚本选择功能 11：

```text
3. BBR 直连/落地优化
4. DNS 净化
5. Realm 转发 timeout 修复
6. IPv6 管理
```

## 使用建议

- 首次使用建议先执行功能 1，重启进入 XanMod 内核后再执行功能 3 或功能 11。
- 不确定带宽档位时，功能 3 可使用自动检测，让脚本沿用原项目的 Speedtest、BDP 计算和 sysctl 模板逻辑。
- 调优后可用功能 7 查看系统状态，用功能 8、9、10 辅助验证线路表现。
- `bbr-optimize-persist` 是 oneshot 服务，状态显示 `active (exited)` 表示执行成功，不是异常。
- DNS 净化遇到 `/etc/resolv.conf` 锁定保护时会自动回滚，不影响 BBR v3/TCP 调优。
- 功能 11 最后会询问是否永久禁用 IPv6，默认回车为 Y；需要保留 IPv6 的用户请输入 N。

## 风险提醒

- 换内核前建议先给 VPS 做快照。
- OpenVZ/LXC 等容器虚拟化环境通常不支持自行更换内核。
- 生产机请谨慎执行内核安装、DNS 修改、IPv6 禁用等操作，建议确保有控制台或救援模式可用。

## 已删除内容

删除了代理部署、AI 工具箱、Cloudflare Tunnel、Caddy、Sub-Store 等非调优功能。

本精简版不再包含 Snell、Xray、SOCKS5 代理部署、Sub-Store 多实例管理、Cloudflare Tunnel、Caddy 多域名反代、AI 代理工具箱、Open WebUI、CRS、Fuclaude、Sub2API、OpenClaw、OpenAI Responses API 转换代理、Codex Console、CLIProxyAPI、OAI2、第三方工具跳转脚本、F 佬 sing-box 脚本、科技 lion 脚本、IP 质量检测、媒体/AI 解锁检测、NQ 一键检测等非 BBR v3/TCP 调优模块。
