# BBRv3 Lite 模块结构

`src/` 是可维护源码，`net-tcp-tune.sh` 是生成的单文件发布物。不要直接修改生成文件；修改模块后运行 `bash scripts/build.sh`。

| 顺序 | 模块 | 职责 |
| ---: | --- | --- |
| 00 | `00-header.sh` | shebang、版本、项目与 schema 常量 |
| 10 | `core.sh` | 路径、日志、确认、全局锁、原子安装 |
| 20 | `config.sh` | 默认配置、白名单验证、严格加载与保存 |
| 30 | `platform.sh` | OS/虚拟化/CPU/内存/网卡/MTU/队列/offload 画像，目标路由/FIB 与多网卡安全门，硬件档位、扫描上限、采样时长/流数与依赖 |
| 35 | `path.sh` | endpoint/route 双路径指纹、网关/路由表/MTU 身份、RTT/抖动/丢包/PMTU 画像、路径置信度与调优门槛 |
| 40 | `state.sh` | 状态 schema、不可覆盖基线、路由诊断/sysctl/持久化生命周期快照 |
| 50 | `sysctl.sh` | balanced/adaptive profile、硬件感知 BDP/缓冲/队列预算、标准/第三方 BBR 兼容性保护、业务 RTT 模型、完整运行时验证、init windows |
| 60 | `tc.sh` | 能力预检、qdisc guard、HTB/FQ 原语、按内核 HZ/MTU 计算 bucket、临时试跑与兼容 TC 入口 |
| 65 | `nic.sh` | 严格逐网卡策略、接口/MAC 身份、全局 TCP 模型聚合、独立 qdisc 基线、全接口运行时 apply/verify/rollback 与管理生命周期 |
| 70 | `measure.sh` | peer IP/source 冻结、样本前后路由核验、iperf3 JSON、公共候选池、负载 RTT/污染检测、自适应采样、probe/sweep/verify/compare、置信度与历史 |
| 80 | `systemd.sh` | v6 迁移、统一服务、持久化一致性、apply/restore/uninstall |
| 90 | `kernel.sh` | 官方 XanMod APT、完整 x86-64 psABI level、安全预检与 Main/LTS 轨道隔离 |
| 100 | `dns.sh` | DNS 底层执行器：systemd-resolved 所有权/split-DNS/生命周期检查、严格 DoT、原子基线和本次操作回滚 |
| 105 | `dns-policy.sh` | DNS 策略引擎：`native/strict-dot/plain` 规范化、只读计划、风险门禁、apply 调度、真实查询验证和漂移状态 |
| 110 | `ipv6.sh` | IPv6 底层执行器：仅限无可路由 IPv6 拓扑的逐接口禁用、快照 schema、远程访问保护、disable-flag 恢复与漂移回滚 |
| 115 | `ipv6-policy.sh` | IPv6 策略引擎：`native/disabled-temporary/disabled-persistent` 规划、拓扑分类、旧策略隔离、接口集合检查和独立验证 |
| 120 | `update.sh` | GitHub Release + SHA256、双副本原子自更新与回滚 |
| 130 | `cli.sh` | 子命令、帮助、交互菜单和 main |

## 依赖方向

```text
core
  ├─ config
  ├─ platform
  │    └─ path
  └─ state
       ├─ sysctl
       └─ tc
            ├─ nic
            └─ measure -> path

systemd -> config + state + sysctl + tc + nic
kernel  -> core + platform
dns             -> core
dns-policy      -> dns
ipv6            -> core
ipv6-policy     -> ipv6
cli     -> all modules
```

构建顺序由 `scripts/build.sh` 中的显式数组控制。模块不互相 `source`，避免发布单文件中出现运行时路径依赖。

## 状态边界

- `/etc/bbrv3-lite.conf`：全局 BBR/TCP 聚合模型配置，严格解析。
- `/etc/bbrv3-lite/interfaces.d/DEV.conf`：逐网卡 FQ/HTB-FQ、身份与测量元数据策略；目录和文件均有严格所有权标记。
- `/etc/sysctl.d/99-bbrv3-lite.conf`：本项目 TCP sysctl。
- `/var/lib/bbrv3-lite/baseline`：第一次可信基线，永不覆盖。
- `/var/lib/bbrv3-lite/interfaces/DEV`：每张接管网卡独立、不可覆盖且绑定身份的原始 qdisc 基线。
- `/var/lib/bbrv3-lite/history`：path/probe/sweep/verify/compare 每次运行的原始样本、路径画像、环境指标与摘要。
- `/usr/local/lib/bbrv3-lite/net-tcp-tune.sh`：systemd 使用的固定副本。
- `/etc/systemd/system/bbrv3-lite.service`：唯一持久化服务。

DNS 和 IPv6 使用各自的状态子目录和策略引擎，不由 TCP `auto/install/apply` 擅自处理。完整卸载只在用户明确选择后协调调用各自的基线恢复。

## 关键不变量

1. 配置文件不得由 shell `source` 或 `eval`。
2. 未知 root qdisc 不得覆盖。
3. 测量退出、超时和信号中断后必须恢复操作前 qdisc。
4. 独立 `measure sweep` 不得持久化；`auto` 只有在候选确认和最终复验都通过后才能提交配置。
5. systemd unit 不得硬编码接口、速率或 profile。
6. 缺少 BBR 时不得静默回退到 cubic。
7. 初始基线不得被后续运行覆盖。
8. DNS/IPv6 失败不得留下本轮半应用的文件或运行时值。
9. 子命令不得接受后静默忽略参数；所有写操作必须在修改前完成环境和值域预检。
10. 测速对端 RTT 只描述测量路径，不得不经业务用途下限校正就覆盖持久化调优 RTT。
11. systemd 应用和一致性验证必须逐项核对全部受管 sysctl，不能只以 BBR 已启用代表 profile 完整生效。
12. HTB burst 使用内核 `CONFIG_HZ`；不得把用户态 USER_HZ 当作内核调度频率。
13. 首次基线必须覆盖持久化脚本及 systemd unit 的启用/运行状态，旧基线缺少新字段时仍可恢复。
14. 当前命令与 systemd 持久化副本不得在自更新失败后处于不同版本。
15. 安装器不得覆盖或删除缺少本项目标记的同名 `bbr` 文件。
16. 公共 peer 的临时不可用可以触发候选切换，但本地 TC/sysctl 错误不得被自动换节点掩盖。
17. 跨主机故障转移必须重新执行完整 sweep；最终复验只允许使用 sweep 主机的备用端口，不能拿不同路径验收旧基线。
18. iperf3 的 JSON/本地执行错误不得归类为公共 peer 临时不可用。
19. 后台流量或 CPU steal 持续污染的样本不得参与拐点和最终验收；不稳定基准/确认样本必须补样或失败。
20. `measure compare` 必须交错顺序、不得持久化，并在成功、失败或信号中断后恢复进入前的 qdisc。
21. 负载 RTT 不可用必须记为 `na` 并降低置信度，不得伪造为 0ms；原始重传、估算比例和每 GiB 重传必须明确区分。
22. 生成脚本必须通过 `bash -n`、核心测试和 ShellCheck。
23. 虚拟网卡报告的链路速率不得在缺少显式带宽或实测值时直接作为调优带宽；自动扫描必须能在首轮基准后安全扩展初始上限。
24. 缓冲区、监听队列、netdev backlog 和最终多流数量必须受 CPU/内存/带宽模型约束，低配与高 BDP 档位都必须有边界测试。
25. NIC offload、IRQ affinity 和 RSS/RPS/RFS 只能诊断和提示，不得在未知驱动/NUMA/业务布局时默认改写。
26. 当前拥塞控制若为 `bbr2`、`bbrplus` 等第三方 BBR 变体，不得静默改写为标准 `bbr`；只读检测必须明确报告冲突。
27. BBRv3 在内核运行时仍注册为 `bbr`；不得把 `modinfo` 的供应商模块版本误报为 BBR 代际证明。
28. XanMod Main 请求不得回退到 LTS 包；x86-64-v2/v3 包选择必须覆盖 psABI 要求的 SSE3、F16C 与 LZCNT 等特性。
29. 显式测速 `--cap` 是硬上限，所有整形样本都不得超过；测量开始后的参数计算失败也必须恢复 qdisc。
30. 覆盖多队列 `mq` 前必须确认全部硬件队列叶子可重放，并在事务/基线恢复时逐队列重建；未知自定义叶子必须拒绝覆盖。
31. root qdisc 识别必须兼容 `tc` 把 `root` 输出在行尾的格式，不能把未识别结果当成空/安全 qdisc。
32. `auto` 和正式 measure 在首次修改前必须证明 peer 的全部可路由 A/AAAA 使用同一实际接口；ECMP、跨地址族分流、目标出口与 TC 接口不一致或无法核验 FIB 时必须停止。正式样本只能连接冻结的 IP literal，并在样本前后复核路径。
33. `auto` 是接口发现输入，不是已测整形速率的长期身份。持久策略必须固化实际接口和 MAC；旧 `TC_ENABLED=1 + TC_INTERFACE=auto` 不得按当前默认路由猜测归属。
34. DNS 接管只允许可证明由 systemd-resolved 或本项目管理的解析器；发现 NetworkManager/resolvconf/cloud-init、未知所有权或 split DNS 时不得覆盖。
35. DNS `auto` 只能提交经过运行时查询验证的严格 DoT；失败必须恢复 `resolv.conf`、drop-in 和 systemd unit 生命周期，不得静默降级到明文 DNS。
36. IPv6 禁用不得修改 `lo/::1`；新快照必须逐接口保存 disable flag，`all` 只能记录、绝不能重放，地址/路由只能诊断、不能宣称可恢复；旧三值基线必须明确标为部分恢复。
37. IPv6 写操作必须保护 IPv6 SSH、所有 IPv6 默认路由、global/ULA 地址、业务路由和启动级禁用场景；事务无法完整枚举接口或快照 schema 非法时不得开始修改。事务回滚遇接口漂移要恢复幸存项后返回非零并保留快照。
38. 默认一键调优只负责 TCP/sysctl 与所选接口的 FQ/HTB；DNS、IPv6、内核、路由和 offload 都保持独立入口与独立确认。
39. 正式版本除语法、单元测试和 ShellCheck 外，必须通过 Debian 12/13、Ubuntu 22.04/24.04 的一次性特权 Docker 矩阵；真实 TC、iperf3 和 ECMP 路由测试不得只用 mock 代替。
40. 正式测量必须生成 endpoint/route 双路径指纹；route cache 的动态传输指标不得进入身份，但网关、路由表、source、dev 和 route MTU 必须进入。每个样本前后双指纹必须一致，自动调优的 sweep/verify 也必须同时使用相同远端端点与相同本地出口。
41. ICMP 或 PMTU 不可用只能记录 unknown 并降低路径/测量置信度，不得伪造 0ms 或把接口 MTU当作已证明的端到端 PMTU；明确 unsafe 的路径不得自动持久化。
42. `measure path` 只能读取网络状态和写历史，不得改 qdisc、路由、地址、DNS、IPv6 或持久化配置；`--force-scan` 不得绕过 FIB 唯一性或路径漂移保护。
43. DNS/IPv6 `plan` 必须是只读操作：不得创建基线、事务、配置或服务状态；`apply` 必须在写入前重新执行权威门禁，不能把旧计划当作授权令牌。
44. `native` 只能恢复可信基线；无基线时保持外部状态，有项目受管策略却缺少基线时必须拒绝猜测恢复。
45. DNS/IPv6 策略文件路径被未知内容占用时不得覆盖；旧 IPv6 `all/default/lo` 策略必须先恢复 native，不能自动就地迁移。
46. IPv6 持久策略必须保留 `lo/::1`，并验证策略文件接口集合与当前接口集合；网卡漂移不得误报为一致。
47. 多网卡模式必须把 Linux 全局 TCP sysctl 与逐接口 qdisc 分层：全局模型按所有策略的最大安全需求聚合，FQ/HTB-FQ、速率和原始基线逐网卡独立。
48. 每个策略必须是非符号链接常规数据文件、字段集合完整、文件名与接口一致，并绑定接口名 + MAC；未知目录条目、身份漂移或策略损坏必须在运行时写入前阻断。
49. 所有符合本项目 HTB 形态的接口都必须有明确策略或可验证旧配置归属；不得把孤立 HTB 或失败操作留下的 qdisc 自动采用为原始基线。
50. 多网卡事务必须覆盖全部现有策略接口、本次目标接口和待迁移旧接口。任一接口应用失败时必须恢复全部 qdisc、受管 sysctl 和默认路由窗口；只读快照阶段失败不得调用会写系统状态的回滚流程。
51. `nic plan` 必须只读并计算替换目标策略后的全局模型；`nic unmanage` 必须在写入前验证对应不可覆盖基线，并且只恢复目标接口。
52. v7 单网卡配置只能在完整事务内迁移；systemd 仍只能有一个服务，且该服务必须先验证完整策略集合和全部接口身份，再应用任何 qdisc。
53. 自动调优必须把目标网卡模型与全局候选聚合模型分开保存；临时运行时不得忽略其他策略，持久化时也不得把聚合角色/BDP 误写入目标策略。
54. 逐网卡原始 qdisc 基线必须验证目录所有权/权限、精确文件集合、快照格式和接口 MAC；接口名复用不能成为向新设备重放旧 qdisc 的依据。
55. 兼容 `tc` 命令只能修改逐网卡 qdisc。尚无策略的网卡不得从另一接口主导的全局聚合模型继承虚假的带宽、RTT 或业务角色。

## 测试

- `tests/test_core.sh`：配置注入、v6 迁移、micro/standard/high/extreme 硬件模型与 profile 计算、BBR 变体冲突、XanMod CPU/轨道选择、CLI 边界、TCP/TC/DNS/IPv6 事务、测速硬上限/失败恢复、测量污染/稳定性/A-B/置信度、基线/持久化/自更新生命周期。
- `tests/test_dns_v721.sh`：解析器所有权、split-DNS、systemd-resolved 生命周期、严格 DoT 验证和失败回滚。
- `tests/test_ipv6_v721.sh`：逐接口/VLAN 快照、保留回环、精确恢复、部分失败回滚、IPv6 SSH/IPv6-only/启动级禁用保护和旧基线标记。
- `tests/test_dns_policy_v740.sh`：DNS 策略规范化、只读计划、split-DNS/未知文件阻断、apply/verify/native 调度。
- `tests/test_ipv6_policy_v740.sh`：IPv6 策略推断、拓扑计划、旧策略隔离、持久漂移、apply/verify/native 与回环不变量。
- `tests/test_network_v721.sh`：多默认路由、A/AAAA 出口一致性、legacy auto 配置保护，以及真实 dummy 网卡、ECMP `fibmatch` 与主备 metric 路由。
- `tests/test_measure_v721.sh`：主机名冻结为 IP/source、地址族绑定、样本前后路由漂移拒绝和全部正式测量入口覆盖。
- `tests/test_path_v730.sh`：双指纹规范化、route cache 动态字段、网关/策略表/MTU 漂移、RTT 分类、PMTU、风险门槛、历史与跨阶段路径一致性。
- `tests/test_tc_v721.sh`：v7 单接口配置兼容门禁、旧 `auto` 显式清理、历史跨网卡迁移拒绝和孤立整形反例。
- `tests/test_nic_v800.sh`：策略目录/符号链接/字段与 MAC 身份、严格 qdisc 基线、接口名复用、自动调优目标/全局模型隔离、只读 plan、孤立 HTB、旧配置迁移、全接口事务、快照失败零写入以及 qdisc/sysctl/路由窗口回滚。
- `tests/integration_tc.sh`：一次性网络命名空间中的真实 HTB/FQ 创建、验证和移除。
- `tests/integration_multi_nic.sh`：真实双 veth 上同时应用不同策略，并故意让第二张网卡失败以验证第一张和第二张都回到操作前 qdisc。
- `tests/integration_measure.sh`：一次性特权 Linux 容器中的真实 iperf3 JSON、负载 RTT、CPU/接口指标、硬件自适应多流复验和历史列集成测试。
- `tests/integration_path.sh`：隔离 veth/网络命名空间中的真实 RTT、PMTU/MSS、CLI 参数传播与 route-MTU 指纹漂移拒绝。
- `tests/integration_ipv6_policy.sh`：真实网络命名空间中的临时/持久 IPv6 策略、逐接口运行时验证、`all/lo` 不变量和 native 恢复。
- `scripts/validate.sh`：重建发布物、语法、架构标记、全部 `test_*.sh` 和 ShellCheck。
- `tests/integration_dns_systemd.sh`：以 systemd 为 PID 1 的真实 systemd-resolved plain/DoT、查询、回滚与 unit 生命周期测试。
- `scripts/docker-validate.sh`：Debian 12/13、Ubuntu 22.04/24.04 一次性特权容器中的统一发布门禁，并强制开启真实逐网卡 qdisc/跨接口回滚、多路由/ECMP、IPv6 拓扑反例与全部集成测试；Debian 12 额外运行嵌套 systemd。
