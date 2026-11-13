# Changelog

## v8.0.9 — XanMod Dependency Bootstrap Hotfix（2026-11-13）

- 在安全预检及基础 APT 检查后安装缺失依赖，再验证 curl/gpg；精简系统不再因缺少 gpg 提前拒绝 bootstrap。
- 依赖与内核安装均执行关键网络组件移除模拟保护和 --no-remove，保留真实 APT/GPG 错误，拒绝部分索引更新失败。
- 官方 HTTPS 公钥格式/转换校验、原子创建专用仓库文件；保留不同的现有配置，失败清理本次新建文件及临时数据，不保存旧安装备份。
- 保留 CPU/LTS/Main、容器与 Secure Boot guard；不自动重启，不删除运行内核，不更改 TCP/qdisc、持久化策略或测量历史。

本次仅修复 XanMod 安装链路。真实 Debian 13 隔离容器已验证依赖补齐和 LTS 包安装；bootloader 准备、新内核启动与新内核中的 BBRv3 运行均未实机验证，不宣称吞吐改善。详见 [Release Notes](docs/release-notes-v8.0.9.md)。

## v8.0.8 — High-Bandwidth Measurement Reliability（2026-11-13）

- 根据实测接收容量评估剩余扫描、必要确认和最终复验成本，分别显示 expected、conservative upper bound 与 hard budget；预算不足时安全退出，默认仍为 6 GiB。
- 在建立 clean throughput reference 前验证吞吐代表性，低效但低重传的样本经过有界同档复验，不能直接污染参考或产生 knee。
- 分离 Sample Confidence 与 Decision Confidence；未完成测量为 low/inconclusive，不生成 confirmed knee 或 recommendation。
- 分离 Peer Health 的 sample success、completed sweep/operation 和失败 attempt；缺失 RTT 显示为 n/a。
- 保持 20 列 samples TSV，拒绝单元格 Tab/换行注入，并只读兼容旧历史。
- 保留 RC70 和 budget-exceeded，区分实际耗尽、下一阶段预留不足、剩余计划可完成性拒绝，统一 CLI/history/summary/failure 诊断。

原 SATURATION/PATH_CONTROL、receiver-driven sweep、2/3 spike、knee/margin、pre-spawn hard guard、operation-wide ledger、final single/multi verify、PMTU/provenance、resolved-leaf 与 transaction/baseline 保护继续保留。详见 [Release Notes](docs/release-notes-v8.0.8.md)。

既有 v8.0.7 等版本的历史说明和回归 fixture 保留在 README、源码及 tests 中；本文件从 v8.0.8 开始单独记录变更，不补造先前发布记录。
