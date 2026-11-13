# bbrv3-lite v8.0.9 — XanMod Dependency Bootstrap Hotfix

正式版本：v8.0.9。发布日期：2026-11-13。[GitHub Release](https://github.com/ike-sh/bbrv3-lite/releases/tag/v8.0.9)。前一正式版本为 v8.0.8。

本次仅修复 XanMod 内核安装链路。精简 Debian/Ubuntu 缺少 gpg 或 curl 时，v8.0.8 在自动安装 gnupg/curl 之前就因缺少命令退出；v8.0.9 将可补齐依赖放到正确的 bootstrap 阶段。

- 先保留 OS、amd64、容器和既有 Secure Boot 预检，再检查 apt-get、apt-cache、dpkg-query。
- 更新索引，识别缺失的 ca-certificates/curl/gnupg，模拟依赖安装并检查关键 SSH/网络组件移除，再安装依赖、确认 curl/gpg 实际可用。
- 依赖与内核的实际安装使用 `--no-remove`。APT 索引、模拟、下载、GPG 转换、安装或可用的 update-grub 失败均停止，保留错误信息。包管理器仍可能安装或升级所选包所需的依赖；本次没有执行全系统 upgrade/dist-upgrade。
- 公钥来自 [XanMod 官网](https://xanmod.org/) 公布的 HTTPS 地址，格式与转换结果均检查；专用 keyring 由 `signed-by` 限定。格式可解析不代表独立认证了密钥身份；本版本依赖官方 HTTPS 分发和 APT 签名链，没有指纹 pin。
- 仓库文件无覆盖原子创建；不同的已有配置保留并停止。后续失败只清理本次新建且未被替换或更改的文件与临时数据，不创建长期安装备份。
- LTS/Main 轨道与 CPU x86-64 等级选择不变。不自动重启，不删除当前运行内核，不调用 BBR 自动调优，不修改 BBR/FQ/HTB、测量、预算、持久化或可信基线规则。

验证状态严格区分：

| 阶段 | 本次证据 |
| --- | --- |
| Dependency bootstrap | PASS：精简 Debian 13 隔离容器中实际安装并验证依赖 |
| PACKAGE_INSTALLED | PASS：同一构建实际安装 LTS x64v3 meta/image/headers，dpkg 为 install ok installed |
| BOOTLOADER_PREPARED | NOT RUN：未验证真实宿主的 GRUB/UEFI、initramfs 与启动项 |
| NEW_KERNEL_BOOTED | NOT RUN：没有重启，运行内核保持原样 |
| BBRV3_RUNTIME_VERIFIED | NOT RUN：未在新内核中执行 BBRv3 运行验证 |

真实 APT 证据来自一次性容器文件系统，不代表容器运行了 XanMod。测试 helper 在实际验证产品容器拒绝后，仅为该隔离测试重定义容器检测；产品仍禁止在容器中更换宿主内核。本次发布不连接生产 VPS，不安装或重启生产内核。

包安装成功不能证明可启动。实际服务器的 bootloader、initramfs、Secure Boot/MOK、DKMS 和新内核运行兼容性仍需用户在维护窗口另行检查并授权重启。不承诺所有 VPS 均能启动 XanMod，不宣称本次验证了生产 BBRv3 或改善了网络吞吐。

v8.0.8 的 BBR/FQ、HTB、测量、hard budget、PMTU、path provenance、持久化与 transaction/rollback 产品逻辑保持不变。旧 P3 的真实证据仅适用于原先已验证且未变的路径，不能扩展为 XanMod 启动或新内核中的调优资格。

发布资产仍为 `net-tcp-tune.sh`、`install-alias.sh` 和 `SHA256SUMS`。官方安装器逻辑未变：默认下载最新正式 Release，校验 checksum，缺少资产时仅回退到同一个不可变 tag；不会自动获取开发分支。

发布前证据：[Hotfix Report](https://github.com/ike-sh/bbrv3-lite/blob/v8.0.9/docs/v8.0.9-xanmod-bootstrap-hotfix-report.md)、[Final Release Audit](https://github.com/ike-sh/bbrv3-lite/blob/v8.0.9/docs/v8.0.9-final-release-audit-report.md)。两份报告保留各自执行时的历史版本状态与 NOT RUN 边界。
