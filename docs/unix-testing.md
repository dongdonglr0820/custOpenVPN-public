# Linux / macOS 2.7.8-xy2 验收

本次将 Linux 和 macOS 的 OpenVPN 核心从 2.7.7 升至 2.7.8，保留原有设备字段上报。
macOS 外壳从 Tunnelblick 9.0.1 升至 10.0.1。Windows 已测试的 MSI 不重新替换。

## Linux

- 分别提供 amd64、arm64 的 `tar.gz` 和 SHA256；两者为全静态 CLI 核心。
- 解压后执行 `bin/openvpn --version`，首行应包含 `2.7.8-xy2-<构建日期>`。
- 先备份原二进制和配置，再用现有启动方式测试新核心；不要覆盖仍在使用的二进制。
- 沿用原有 `setenv IV_USER / IV_INFO / IV_DISK / IV_PLAT` 配置或采集脚本；新核心不替代现有采集流程。
- 分别检查 VPN/OTP 登录、服务端设备绑定、业务地址、DNS，以及重启后的再次连接。
- glibc 静态构建的域名解析存在限制；使用域名作为 remote 的环境需额外验证，必要时采用 `STATIC=0` 动态构建。
- 回滚：停止新客户端，恢复备份的二进制和配置，再按原方式启动。

## macOS / Tunnelblick

- 包含完整 Tunnelblick 10.0.1 应用（ZIP/DMG）；内嵌 OpenVPN 2.7.8-xy2，兼容 Intel 与 Apple Silicon，最低 macOS 13。
- 校验 `SHA256SUMS.txt`；保留旧版安装包，备份现有 Tunnelblick 配置后退出旧客户端，再安装完整新应用。
- 当前为 adhoc 构建，没有 Developer ID 签名或 Apple 公证；若系统阻止运行，按公司软件分发政策处理。
- 导入或沿用已有 `.tblk` / `.ovpn`；需保留设备字段来源，不要填入测试用假值。
- 连接日志中的 OpenVPN 版本应包含 `2.7.8-xy2-<构建日期>`；检查设备绑定、OTP、业务网络和 DNS。
- 测试断开重连、系统重启后重连；如原配置固定选择旧 OpenVPN 版本，在 Tunnelblick 设置中选择本包内的 2.7.8。
- 不要通过官方 Tunnelblick 更新覆盖定制版；官方核心不包含本仓库的设备字段转发补丁。
- 回滚：退出新版、恢复旧应用及原配置，再验证连接。

## 自动验证与边界

- Linux：两种架构均原生构建，解包最终产物，实际 TLS/VPN 连接确认完整指纹可达、缺失 IV_DISK 被测试服务端拒绝、非白名单字段不转发。
- macOS：检查两种 OpenSSL 变体的内嵌核心均为 Universal 2；分别运行 arm64 和 x86_64（Rosetta）进行真实回环 TLS 握手，核对版本与指纹字段。
- 自动测试使用临时证书与测试字段，不连接业务 VPN；不代表 GUI 安装、真实设备采集、OTP 或业务路由已完成人工验收。
- Windows 的实机反馈仅适用于此前交付的 Windows MSI，Linux/macOS 仍需各自验收。
