# Changelog

## v8.0.8 — High-Bandwidth Measurement Reliability（2026-11-13）

- 根据实测接收容量评估剩余扫描、必要确认和最终复验成本，分别显示 expected、conservative upper bound 与 hard budget；预算不足时安全退出，默认仍为 6 GiB。
- 在建立 clean throughput reference 前验证吞吐代表性，低效但低重传的样本经过有界同档复验，不能直接污染参考或产生 knee。
- 分离 Sample Confidence 与 Decision Confidence；未完成测量为 low/inconclusive，不生成 confirmed knee 或 recommendation。
- 分离 Peer Health 的 sample success、completed sweep/operation 和失败 attempt；缺失 RTT 显示为 n/a。
- 保持 20 列 samples TSV，拒绝单元格 Tab/换行注入，并只读兼容旧历史。
- 保留 RC70 和 budget-exceeded，区分实际耗尽、下一阶段预留不足、剩余计划可完成性拒绝，统一 CLI/history/summary/failure 诊断。

原 SATURATION/PATH_CONTROL、receiver-driven sweep、2/3 spike、knee/margin、pre-spawn hard guard、operation-wide ledger、final single/multi verify、PMTU/provenance、resolved-leaf 与 transaction/baseline 保护继续保留。详见 [Release Notes](docs/release-notes-v8.0.8.md)。

既有 v8.0.7 等版本的历史说明和回归 fixture 保留在 README、源码及 tests 中；本文件从 v8.0.8 开始单独记录变更，不补造先前发布记录。
