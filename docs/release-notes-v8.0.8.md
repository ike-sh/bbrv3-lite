# bbrv3-lite v8.0.8 — High-Bandwidth Measurement Reliability

正式版本：v8.0.8。发布日期：2026-11-13。[GitHub Release](https://github.com/ike-sh/bbrv3-lite/releases/tag/v8.0.8)。

v8.0.8 改善高带宽场景的预算规划、参考样本质量与失败解释，避免把未完成测量呈现为可信调优结果。

- **Budget feasibility**：取得实际容量与路径遥测后，在第一个扫描点前评估剩余工作量。expected cost、包含有界确认/重试的 conservative upper bound 与 hard limit 分开显示；规划有不确定性，不承诺当前预算必然完成。
- **Clean reference**：低重传与吞吐代表性分别判断。低效样本先冷却、同档有界复验；没有可靠参考时保持 inconclusive，不能凭慢对端建立 policer knee。
- **Decision confidence**：完整样本仍可获得 High Sample Confidence；预算中断、候选未确认、验证失败等不完整操作保持 low/inconclusive。未确认 knee 不作为正式确认值，未完成扫描不生成 recommendation。
- **Peer Health**：分别显示 sample success、completed sweeps/operations 和 busy/reset/timeout attempts，缺少 RTT 时显示 n/a。统计辅助候选排序，不能替代本轮路径和样本验证。
- **History integrity**：samples TSV 保持 20 列与数值精度，写入前拒绝单元格 Tab/换行注入；旧历史只读兼容，不迁移或重写原文件。
- **Budget diagnostics**：CLI、history、summary.tsv 和 failure.tsv 使用一致的失败快照，区分实际耗尽、下一阶段预留不足和当前计划预计不可完成。

预算失败继续返回 **RC70**，兼容 reason **budget-exceeded**。`BUDGET_FAILURE_SUBTYPE` 提供更细的分类：

| Subtype | 含义 |
| --- | --- |
| exhausted | 实际 TX 或时间达到硬上限 |
| insufficient-reservation | 仍有余额，但不足以安全覆盖下一阶段必要预留 |
| feasibility-rejected | 实测容量发现后，所选 profile 的剩余计划预计不能在当前预算内完成 |
| unknown | 旧记录没有足够证据明确分类 |

预留不足和可完成性拒绝不会被解释成实际耗尽。拒绝时的 used/remaining/required 快照与最终接口 TX 计数各自保留；required 表示下一阶段预留或 expected remaining plan，不表示已经消耗，也不等于整个分支上界。

默认 hard TX budget 仍为 **6 GiB**。程序不会静默增加预算或切换 profile，也不会通过跳过 spike confirmation、candidate confirmation 或 final single/multi verify 完成测量。预算或验证失败不持久化未验证参数，并沿原事务路径恢复系统状态；rollback 失败仍单独报告。

原 SATURATION、PATH_CONTROL、receiver-driven sweep、2/3 spike、knee/margin、hard guard、operation-wide TX/time ledger、v8.0.7 PMTU、final path provenance、IPv6 resolved leaf 和 baseline immutability 规则保留。

验证证据分为三层：原 P3 构建的真实容量 **1142.86 Mbit/s**、6 GiB 预算提前拦截与真实 runtime rollback；RC1 对未变路径的独立差异审计；RC1 在真实 VPS 上的只读原始证据解释和隔离三类预算重放。最后一层没有重新运行真实 iperf，也没有再次执行真实网络 mutation/rollback。`P3_QUALIFIED` 继承原构建未变预算与回滚路径的实测证据，不代表完整生产 auto 或持久化推荐已实机通过。真实低效参考和未完成 spike 仍为 **NOT EXERCISED / FIXTURE PASS**。完整本地、四发行版 privileged 与 systemd/PID1 的最终重验及历史 ShellCheck 阻塞关闭见 [Final Audit Blocker Resolution Report](v8.0.8-final-audit-blocker-resolution-report.md)；[Final Release Audit](v8.0.8-final-release-audit-report.md) 保留修复前的历史状态。

Public iperf availability varies. 公共测速节点可能繁忙、限速或不可用，结果只代表所选 peer/path 与测试时段。High-bandwidth measurement consumes traffic. 高带宽验证会消耗真实流量，6 GiB 不保证完成所有 profile。Some failure scenarios are fixture-tested only. 不宣称所有生产样本条件均已实测覆盖。**Automatic Repair is not implemented.**

正式资产为 `net-tcp-tune.sh`、`install-alias.sh` 和 `SHA256SUMS`。安装器默认解析最新正式 GitHub Release、校验 SHA256，并在所选正式 tag 缺少 Release assets 时验证同一不可变 tag 的副本。默认安装入口：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/bbrv3-lite/main/install-alias.sh | bash
```
