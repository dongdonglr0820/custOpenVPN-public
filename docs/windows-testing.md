# Windows xy3 系统盘标识测试

本轮基于 OpenVPN 2.7.8-I002，定制版 xy3，DCO 2.8.14；系统盘采集逻辑沿用 xy2。普通 Intel/AMD 64 位电脑安装 `amd64.msi`；仅 Windows ARM 电脑安装 `arm64.msi`。MSI 未做发布者签名。

1. 备份原 `.ovpn` 配置，记录旧客户端版本和服务端当前设备绑定。退出 OpenVPN GUI，并断开连接。
2. 安装完整 MSI，确保 core 和 **OpenVPN Interactive Service** 都更新。不要只替换 `openvpn.exe`。若原版使用另一套安装产品标识，先备份配置并卸载旧版，再安装测试包；不要并存使用同一路径的两个安装产品。
3. 在管理员 PowerShell 运行以下命令，保留每次输出。诊断不联网，不修改服务端绑定：

   ```powershell
   & "$env:ProgramFiles\OpenVPN\bin\openvpn.exe" --version
   & "$env:ProgramFiles\OpenVPN\bin\openvpn.exe" --show-device-info |
       Tee-Object -FilePath "$env:USERPROFILE\Desktop\openvpn-device-before.txt"
   ```

4. 检查配置。新版自动生成 `IV_PLAT/IV_USER/IV_INFO/IV_DISK/UV_DEVICE_ID_SCHEMA`；如果旧配置含这些 `setenv` 行，应在备份后移除。不要移除证书、远端、OTP 等其他配置。
5. 先对照诊断值与旧绑定。新算法固定选择 **Windows 安装所在卷对应的磁盘**；旧版若曾绑定数据盘，新值可能不同，需要管理员核实后仅迁移该配置的磁盘字段。客户端不会自动清空绑定或修改 OTP。
6. 以普通用户运行 GUI，使用当前有效验证码连接。日志应出现 `schema=win-system-disk-v1 source=windows-volume via=interactive-service`。记录连接是否成功。
7. 连续重启至少 **5 次**，每次重新运行诊断并用新验证码连接；同时测试冷启动、睡眠恢复、插拔 USB/外接盘。`IV_DISK`、`IV_INFO`、同一用户的 `IV_USER` 应稳定。`disk_number` 允许改变，它只用于本次查找，不属于绑定值。

若失败，收集客户端版本、诊断输出、连接时间和相关日志。诊断包含设备和用户标识，只交给内部排障人员。`AUTH_FAILED` 仍需看对应服务端日志区分 OTP、权限和设备绑定；不能仅凭客户端日志判定。

`DEVICE_IDENTITY_ERROR` 会标明采集阶段和 Win32 错误码；跨盘系统卷、无有效序列号、SYSTEM 无人值守上下文以及旧 interactive service 均会明确失败，不换另一块盘继续认证。

回滚前保留新旧诊断和绑定记录；若管理员已迁移绑定，回滚客户端时须同时复核那一项绑定。此次测试包不修改生产服务端。

CI 验证边界：GitHub Windows 2022 的 Microsoft 虚拟系统盘没有序列号。CI 验证安装后的程序及服务能明确拒绝空值；TLS 字段传输使用独立的测试管道程序提供合成硬件值，该程序不会放入 MSI。真实硬盘采集成功、业务 VPN 登录和连续重启稳定性，仍需按上述步骤在测试电脑上确认。
