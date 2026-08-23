# BBRv3 Lite 模块结构

`src/` 是可维护源码，`net-tcp-tune.sh` 是生成的单文件发布物。不要直接修改生成文件；修改模块后运行 `bash scripts/build.sh`。

| 顺序 | 模块 | 职责 |
| ---: | --- | --- |
| 00 | `00-header.sh` | shebang、版本、项目与 schema 常量 |
| 10 | `core.sh` | 路径、日志、确认、全局锁、原子安装 |
| 20 | `config.sh` | 默认配置、白名单验证、严格加载与保存 |
| 30 | `platform.sh` | OS/虚拟化/CPU/内存/网卡/MTU/队列/offload 画像，硬件档位、扫描上限、采样时长/流数与依赖 |
| 40 | `state.sh` | 状态 schema、不可覆盖基线、路径/sysctl/持久化生命周期快照 |
| 50 | `sysctl.sh` | balanced/adaptive profile、硬件感知 BDP/缓冲/队列预算、标准/第三方 BBR 兼容性保护、业务 RTT 模型、完整运行时验证、init windows |
| 60 | `tc.sh` | 能力预检、qdisc guard、HTB/FQ、按内核 HZ/MTU 计算 bucket、事务和状态 |
| 70 | `measure.sh` | iperf3 JSON、公共候选池、负载 RTT/污染检测、自适应采样、probe/sweep/verify/compare、置信度与历史 |
| 80 | `systemd.sh` | v6 迁移、统一服务、持久化一致性、apply/restore/uninstall |
| 90 | `kernel.sh` | 官方 XanMod APT、完整 x86-64 psABI level、安全预检与 Main/LTS 轨道隔离 |
| 100 | `dns.sh` | systemd-resolved 策略、原子基线和本次操作回滚 |
| 110 | `ipv6.sh` | 临时/永久禁用、原子基线和本次操作回滚 |
| 120 | `update.sh` | GitHub Release + SHA256、双副本原子自更新与回滚 |
| 130 | `cli.sh` | 子命令、帮助、交互菜单和 main |

## 依赖方向

```text
core
  ├─ config
  ├─ platform
  └─ state
       ├─ sysctl
       └─ tc
            └─ measure

systemd -> config + state + sysctl + tc
kernel  -> core + platform
dns     -> core + measure(peer TCP check)
ipv6    -> core
cli     -> all modules
```

构建顺序由 `scripts/build.sh` 中的显式数组控制。模块不互相 `source`，避免发布单文件中出现运行时路径依赖。

## 状态边界

- `/etc/bbrv3-lite.conf`：唯一运行配置，严格解析。
- `/etc/sysctl.d/99-bbrv3-lite.conf`：本项目 TCP sysctl。
- `/var/lib/bbrv3-lite/baseline`：第一次可信基线，永不覆盖。
- `/var/lib/bbrv3-lite/history`：probe/sweep/verify/compare 每次运行的原始样本、环境指标与摘要。
- `/usr/local/lib/bbrv3-lite/net-tcp-tune.sh`：systemd 使用的固定副本。
- `/etc/systemd/system/bbrv3-lite.service`：唯一持久化服务。

DNS 和 IPv6 使用各自的状态子目录，不由 TCP `restore` 擅自处理。

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

## 测试

- `tests/test_core.sh`：配置注入、v6 迁移、micro/standard/high/extreme 硬件模型与 profile 计算、BBR 变体冲突、XanMod CPU/轨道选择、CLI 边界、TCP/TC/DNS/IPv6 事务、测速硬上限/失败恢复、测量污染/稳定性/A-B/置信度、基线/持久化/自更新生命周期。
- `tests/integration_tc.sh`：一次性网络命名空间中的真实 HTB/FQ 创建、验证和移除。
- `tests/integration_measure.sh`：一次性特权 Linux 容器中的真实 iperf3 JSON、负载 RTT、CPU/接口指标、硬件自适应多流复验和历史列集成测试。
- `scripts/validate.sh`：重建发布物、语法、架构标记、单元测试和 ShellCheck。
