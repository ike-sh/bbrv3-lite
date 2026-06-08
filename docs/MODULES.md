# net-tcp-tune.sh 逻辑模块地图

主脚本 `net-tcp-tune.sh` 为单文件部署设计（支持 curl 在线执行），以下为内部逻辑分区，便于后续按需拆分。

| 行号区间（约） | 模块 | 核心函数 |
| --- | --- | --- |
| 1–200 | 初始化 | 颜色、常量、`log()`、`check_root()` |
| 200–560 | 依赖与磁盘 | `ensure_packages()`、`check_disk_space()`、`add_swap()` |
| 560–1040 | IPv6 | `manage_ipv6()`、`disable_ipv6_permanent()` |
| 1040–1720 | 测速与带宽 | `detect_bandwidth()`、`calculate_buffer_size()` |
| 1720–2580 | TCP/BBR 调优 | `bbr_configure_direct()`、`apply_tc_fq_now()` |
| 2580–3120 | 内核与预检 | `check_bbr_status()`、`import_xanmod_gpg_key()`、`show_environment_precheck()` |
| 3120–3550 | 状态展示 | `install_xanmod_kernel()`、`show_detailed_status()` |
| 3550–5740 | DNS 净化 | `dns_purify_and_harden()`（含动态生成 rollback.sh） |
| 5740–6180 | 网络测试 | `run_speedtest()`、`run_backtrace()`、`iperf3_single_thread_test()` |
| 6180–6580 | 一键优化 | `one_click_optimize()` |
| 6580–6994 | 菜单与入口 | `show_main_menu()`、`main()` |

## 拆分建议（未来）

1. `lib/download.sh` — `safe_download_script` / `verify_downloaded_script` / `run_remote_script`
2. `lib/xanmod.sh` — GPG、APT 源、CPU level、包选择
3. `lib/dns.sh` — DNS 净化与回滚生成
4. `lib/tcp-tune.sh` — sysctl、tc fq、RPS/RFS

拆分时须保留单文件 curl 发布通道，或同步更新 `install-alias.sh` 拉取完整包。
