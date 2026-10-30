# Linux / macOS 2.7.8-xy3 验收

本轮 OpenVPN 核心仍为上游最新稳定版 2.7.8；Tunnelblick 升到 10.0.2。Linux/macOS 新增原生系统盘 serial 采集，Windows 升到 I002（DCO 2.8.14）并保留现有原生采集。

1. 校验安装包 SHA256，保留旧包，备份配置后退出旧客户端。
2. Linux 解包静态 CLI；macOS 安装完整 Tunnelblick 10.0.2（Universal 2，最低 macOS 13）。确认核心版本为 `2.7.8-xy3-<日期>`。
3. 先运行核心 `--show-system-disk`，独立核对系统所在盘和序列号。具体定位规则及不支持的根文件系统见[系统盘设计](unix-system-disk.md)。
4. 备份后删除旧 `.ovpn` 的 `setenv IV_DISK` 和 `setenv UV_SYSTEM_DISK_SCHEMA`。保留 `IV_USER / IV_INFO / IV_PLAT` 的原采集来源及证书、OTP 等其他配置。
5. 对比服务端现有磁盘绑定；不同先核实原因并按配置迁移。不能清空整条设备绑定或重置 OTP 来掩盖取盘差异。
6. 检查实际 VPN/OTP 登录、设备绑定、业务地址及 DNS。服务端应恰好收到一个 `IV_DISK`，且与诊断一致。
7. 连续至少 5 次重启并复测，覆盖冷启动、睡眠恢复、插拔 USB/数据盘。系统盘盘号可以变化，序列号必须保持一致。多盘系统卷或读不到有效 serial 时应明确失败，不选另一块盘。
8. 回滚时停止新版，恢复旧程序和配置；若迁移了磁盘绑定，也应核对那一项绑定快照。

Linux 全静态构建对域名解析有 glibc 限制，使用域名作为 remote 时需验证，必要时用动态构建。macOS 当前没有 Developer ID 签名/公证，不要让官方自动更新覆盖定制核心。

本轮交付验证、包校验和真实 Intel Mac 核心测试已通过，见 [xy3 验证记录](xy3-build-validation.md)。自动验证不代表业务 VPN、Mac GUI 安装或多次真实重启已经验收。
