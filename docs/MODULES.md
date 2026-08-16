# BBRv3 Lite 模块结构

`src/` 是可维护源码，`net-tcp-tune.sh` 是生成的单文件发布物。不要直接修改生成文件；修改模块后运行 `bash scripts/build.sh`。

| 顺序 | 模块 | 职责 |
| ---: | --- | --- |
| 00 | `00-header.sh` | shebang、版本、项目与 schema 常量 |
| 10 | `core.sh` | 路径、日志、确认、全局锁、原子安装 |
| 20 | `config.sh` | 默认配置、白名单验证、严格加载与保存 |
| 30 | `platform.sh` | OS/虚拟化/网卡/MTU/机器画像与依赖 |
| 40 | `state.sh` | 状态 schema、不可覆盖基线、路径/sysctl/持久化生命周期快照 |
| 50 | `sysctl.sh` | balanced/adaptive profile、业务 RTT 模型、完整运行时验证、init windows |
| 60 | `tc.sh` | qdisc guard、HTB/FQ、按内核 HZ 计算 bucket、事务和状态 |
| 70 | `measure.sh` | iperf3 JSON、probe、sweep、历史和流量统计 |
| 80 | `systemd.sh` | v6 迁移、统一服务、持久化一致性、apply/restore/uninstall |
| 90 | `kernel.sh` | 官方 XanMod APT、CPU level、安全预检 |
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
- `/var/lib/bbrv3-lite/history`：probe/sweep 每次运行的样本与摘要。
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
16. 生成脚本必须通过 `bash -n`、核心测试和 ShellCheck。

## 测试

- `tests/test_core.sh`：配置注入、v6 迁移、profile 计算、CLI 边界、TCP/TC/DNS/IPv6 事务、测量判断、基线/持久化/自更新生命周期。
- `tests/integration_tc.sh`：一次性网络命名空间中的真实 HTB/FQ 创建、验证和移除。
- `scripts/validate.sh`：重建发布物、语法、架构标记、单元测试和 ShellCheck。
