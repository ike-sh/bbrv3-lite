# BBRv3 Lite

BBRv3 Lite 是面向 Debian/Ubuntu VPS 的可测量 TCP 调优工具。它把原项目中可靠的 XanMod 安装、BBR/FQ、DNS/IPv6 管理、严格配置、持久化与回滚重新实现，并吸收 tcpfit 的机器画像、iperf3 测量、policer 拐点扫描、并发锁和最早基线保护。

当前版本：v7.0.0

项目不追求“sysctl 越多越好”。默认配置保持克制，出口整形必须经过测试，测量结果不会自动写入生产配置。

## 核心能力

- BBR + FQ 基础调优，以及可选的 BDP/RAM 自适应缓冲区。
- `HTB root -> FQ leaf` 接口聚合出口整形，不用 FQ `maxrate` 冒充总限速。
- `iperf3 -J` JSON 探测、粗扫、细扫、边界复测和测速流量统计。
- IPv4 优先、IPv6 兜底的默认出口检测；不会遍历修改 Docker/veth/bridge 接口。
- 全局 `flock`，防止两个进程同时修改 sysctl、qdisc 或配置。
- 严格 `KEY=VALUE` 白名单解析，配置文件从不被 shell `source`。
- 首次可信基线不可覆盖；测试中断或应用失败时恢复操作前 qdisc。
- 一个配置、一个 systemd 服务、一个发布脚本，不产生竞争 root qdisc 的服务。
- 官方 XanMod APT 安装、Secure Boot/容器检查、CPU level 保守选择和 APT 网络组件保护。
- DNS 和 IPv6 各自独立备份、独立恢复，不把无关系统改动塞进一次“大回滚”。

## 架构

```mermaid
flowchart LR
    CLI["CLI / 交互菜单"] --> CFG["严格配置解析"]
    CLI --> DETECT["机器与默认出口检测"]
    CLI --> MEASURE["probe / sweep"]
    MEASURE --> TEMP["临时 HTB + FQ"]
    TEMP --> RESULT["历史样本与推荐值"]
    CFG --> APPLY["事务化 apply"]
    APPLY --> SYSCTL["BBR + sysctl profile"]
    APPLY --> TC["HTB aggregate -> FQ leaf"]
    APPLY --> SERVICE["bbrv3-lite.service"]
    APPLY --> BASELINE["不可覆盖的可信基线"]
```

仓库源码位于 `src/`，发布时由 `scripts/build.sh` 按固定顺序生成根目录的 `net-tcp-tune.sh`。用户仍然可以只下载一个文件，维护和测试则按模块进行。

## 安装

推荐安装最新 GitHub Release，并校验 `SHA256SUMS`：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh -o /tmp/install-bbrv3-lite.sh
bash /tmp/install-bbrv3-lite.sh
bbr version
```

测试尚未发布的 `main` 分支时必须显式选择 channel；它同样校验仓库中的 `SHA256SUMS`：

```bash
bash /tmp/install-bbrv3-lite.sh --channel main
```

root 用户默认安装到 `/usr/local/bin/bbr`；普通用户安装到 `~/.local/bin/bbr`。普通用户仍需使用 `sudo bbr ...` 执行会修改系统的命令。

也可以直接下载单文件：

```bash
curl -fsSLO https://github.com/ike-sh/bbrv3-lite/releases/latest/download/net-tcp-tune.sh
curl -fsSLO https://github.com/ike-sh/bbrv3-lite/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
chmod +x net-tcp-tune.sh
sudo ./net-tcp-tune.sh status
```

## 推荐流程

### 1. 只读检测

```bash
sudo bbr detect
sudo bbr detect --target 你的业务目标或近端iperf服务器
sudo bbr kernel status
```

`detect` 输出内核、虚拟化、内存、默认出口、驱动、MTU、链路速率、RX 队列、BBR 可用性和可选目标 RTT，不修改系统。

### 2. 按需安装 XanMod

如果当前内核没有 BBR，或希望使用包含 BBRv3 的 XanMod：

```bash
sudo bbr kernel install --track lts
sudo reboot
```

重启后再次执行 `sudo bbr kernel status`。XanMod 官方 APT 当前只面向 amd64 Debian 系发行版；ARM64 社区内核不再由本项目自动下载和安装，避免把未经项目控制的第三方内核带入默认信任链。

### 3. 安装基础调优

推荐默认档：

```bash
sudo bbr install --profile balanced
```

高 BDP 线路可以先查看自适应计算结果，再应用：

```bash
sudo bbr explain --profile adaptive --role proxy --bandwidth 1000 --rtt 180
sudo bbr install --profile adaptive --role proxy --bandwidth 1000 --rtt 180
```

`balanced` 使用 16 MiB TCP 自动调优上限。`adaptive` 使用 `2 × BDP`，同时受 4 MiB 下限、RAM/32 和 256 MiB 绝对上限约束。两种 profile 都不会修改 `tcp_mem`、`tcp_adv_win_scale`、TIME_WAIT、端口范围、VM、文件句柄或 RPS/RFS。

### 4. 准备可信 iperf3 对端

优先使用同机房或低 RTT 的自有服务器：

```bash
# 对端
iperf3 -s

# 本机安装测量依赖
sudo bbr measure deps
```

公共 iperf3 节点可能繁忙、限速或路径不稳定。工具不会内置不受控制的公共节点列表，也不会把“到中国大陆的线路表现”和“VPS 端口能力”混为一谈。

### 5. 探测与扫描

先探测可用吞吐：

```bash
sudo bbr measure probe --peer 192.0.2.10 --port 5201 --duration 10 --parallel 4
```

自动扫描 policer 拐点：

```bash
sudo bbr measure sweep --peer 192.0.2.10 --nominal 500
```

也可以控制扫描区间：

```bash
sudo bbr measure sweep \
  --peer 192.0.2.10 \
  --low 350 --high 600 --step 25 \
  --duration 8 --parallel 1 \
  --margin 3 --loss-threshold 0.1 --cap 5000
```

扫描流程：

1. 保存操作前 qdisc 和接口流量计数器。
2. 使用 root FQ 做两次不超过 5 秒的单流不限速 JSON 测试并取中位数；超过 `--cap` 时停止扫描。
3. 建立低速率重传本底。
4. 使用与最终部署完全相同的 HTB/FQ 层级向上粗扫。
5. 发现重传比例跳变后细扫边界。
6. 对最后干净档位退让 `--margin`，再进行两次确认测试。
7. 保存样本并恢复操作前 qdisc。

结果保存在 `/var/lib/bbrv3-lite/history/`。这里显示的 `RETRANS_RATIO_EST_PERCENT` 是“iperf3 retransmits / 按 1448 字节估算的 TCP 段数”，用于寻找相对跳变，不是抓包意义上的真实丢包率。

如果不限速测试没有明显跳变，工具会建议保持纯 FQ。只有用户显式指定区间或 `--force-scan` 才会继续扫描。

### 6. 试跑和持久化

```bash
# 临时试跑，不写配置、不安装服务
sudo bbr tc trial 420

# 确认业务延迟、吞吐和重传后再持久化
sudo bbr tc enable 420 --knee 440 --margin 3

sudo bbr tc status
sudo bbr tc stats
```

关闭整形但保留 BBR + FQ：

```bash
sudo bbr tc disable
```

## HTB/FQ 参数原则

- HTB 只负责接口聚合出口上限。
- FQ 只负责流隔离和 pacing，不设置每流 `maxrate`。
- HTB `burst` 根据 `rate / HZ`、MTU 和 32 KiB 下限动态计算，避免固定小 bucket 在高速率下限制吞吐。
- `cburst` 使用 `2 × MTU`；单 class 场景的 quantum 使用 `10 × MTU`，最大 60000 字节。
- 固定 handle 为 `1:`、`1:10`、`10:`，重复执行使用 `replace`，不会不断叠加层级。
- FQ/FQ-CoDel 会保存并重放 `tc qdisc show` 可恢复的参数；发现未知 root qdisc（例如自建 CAKE）时拒绝覆盖。

本工具只处理 egress，不自动创建 IFB，也不做 ingress shaping。

## 配置和持久化

配置文件：`/etc/bbrv3-lite.conf`

```ini
SCHEMA_VERSION=1
BBR_ENABLED=1
SYSCTL_PROFILE=adaptive
ROLE=proxy
BANDWIDTH_MBIT=1000
RTT_MS=180
TC_ENABLED=1
TC_INTERFACE=auto
TC_RATE_MBIT=420
TC_KNEE_MBIT=440
TC_MARGIN_PERCENT=3
INITCWND=0
INITRWND=0
```

配置只允许已知键和受限字符；生产环境要求 root 所有，权限为 `600` 或 `644`。`INITCWND/INITRWND` 默认保持 0，不覆盖路由默认值。

唯一持久化服务为 `bbrv3-lite.service`。unit 只执行：

```text
/usr/local/lib/bbrv3-lite/net-tcp-tune.sh apply
```

网卡、速率和 profile 始终从配置文件读取，不会硬编码进 systemd unit。

## 基线、迁移和恢复

第一次修改前会在 `/var/lib/bbrv3-lite/baseline/` 保存：

- 配置、sysctl 文件和新旧 systemd unit 的存在状态及内容。
- 本工具会修改的运行时 sysctl 值。
- 默认出口以及 qdisc/class 文本快照。
- schema、脚本版本、时间和 provenance。

基线一旦存在就不会覆盖。如果检测到旧调优痕迹但没有可信备份，安装会中止。只有明确接受当前状态为恢复起点时才执行：

```bash
sudo bbr baseline adopt
```

v6 的 `balanced-minimal`、`TC_BASELINE_MBIT`、`TC_PERCENT` 和旧 service 会在已有 `/var/lib/bbrv3-lite/original` 且能保存旧版持久化脚本的前提下迁移；新基线引用旧原始备份，旧备份不会删除。如果缺少其中任一项，工具会拒绝伪造“出厂基线”。

恢复首次可信基线：

```bash
sudo bbr restore
```

普通卸载保留基线和测量历史：

```bash
sudo bbr uninstall
```

不可恢复地删除状态目录必须显式指定：

```bash
sudo bbr uninstall --purge-state
```

## DNS 与 IPv6

DNS 使用独立的 systemd-resolved drop-in：

```bash
sudo bbr dns apply auto   # 853 可达用 DoT，否则明确降级普通 DNS
sudo bbr dns apply dot
sudo bbr dns status
sudo bbr dns restore
```

v7 不再自动安装和改写 dnscrypt-proxy。DoH 代理涉及本地 53 端口、发行版配置和额外软件生命周期，应该作为独立组件管理，而不是 BBR 安装的隐式副作用。

IPv6 管理：

```bash
sudo bbr ipv6 disable temporary
sudo bbr ipv6 disable permanent
sudo bbr ipv6 status
sudo bbr ipv6 restore
```

IPv6 恢复使用首次记录的 `all/default/lo.disable_ipv6` 原值，不假设原始值一定为 0。

## 完整命令

```bash
bbr help
```

无参数并连接终端时显示精简交互菜单；自动化和排障建议使用显式子命令。

## 支持范围

| 环境 | 支持情况 |
| --- | --- |
| Debian 12/13 amd64 KVM | 主要支持 |
| Ubuntu 22.04/24.04 amd64 KVM | 主要支持 |
| 其他 systemd Debian/Ubuntu | 尽力支持 |
| ARM64 | BBR/TC 可用时可运行；不自动安装社区内核 |
| OpenVZ/LXC/Docker | 只读检测；通常不能修改宿主内核/qdisc |
| 非 systemd 系统 | 不支持持久化和 DNS 模块 |

XanMod 包和支持 codename 会变化，安装逻辑从官方仓库实际候选中选择，不写死内核版本。参见 [XanMod 官方安装说明](https://xanmod.org/)。

## 开发与验证

```bash
bash scripts/build.sh
bash scripts/validate.sh
```

真实 TC 集成测试必须放在一次性容器或网络命名空间中：

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" debian:12 \
  bash -lc 'apt-get update -qq && apt-get install -y -qq iproute2 procps util-linux >/dev/null && bash /src/tests/integration_tc.sh'
```

生成 release 校验文件：

```bash
bash scripts/release.sh
```

发布资产至少应包含 `net-tcp-tune.sh` 与 `SHA256SUMS`。模块边界见 [docs/MODULES.md](docs/MODULES.md)。

## v7 与旧版的差异

- 删除八千行单文件中交织的 legacy/v6 双实现，改为模块源码、单文件发布。
- 删除激进 sysctl、固定 `initcwnd=32`、多网卡 root qdisc 覆盖和第二套 TC service。
- 删除自动执行第三方测速/回程脚本和社区 ARM64 内核安装。
- 删除“一键修改内核、DNS、IPv6、TCP”的大范围自动化；各模块独立确认、独立恢复。
- 新增测量历史、JSON 拐点扫描、动态 HTB bucket、可信基线和 release-only 更新。

## 项目来源与许可证

本项目延续 [ike-sh/bbrv3-lite](https://github.com/ike-sh/bbrv3-lite) 和其上游 `vps-tcp-tune` 的实用功能，并参考 [Kylin010/tcpfit](https://github.com/Kylin010/tcpfit) 的测量工作流。实现已按本项目架构重写，不将 tcpfit 的完整 sysctl 表或固定 TC 参数复制进来。

许可证见 [LICENSE](LICENSE)。使用前请为 VPS 创建快照；内核、sysctl、qdisc 和 DNS 修改都可能导致远程连接中断。
