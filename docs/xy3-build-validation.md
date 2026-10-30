# 2.7.8-xy3-20261030 交付验证

本轮交付包基于上游稳定版：OpenVPN 2.7.8；Windows 2.7.8-I002、GUI 11.66.0.0、DCO 2.8.14；Tunnelblick 10.0.2（build 6590），最低 macOS 13。

产品构建源码：`2bfa727ec7c67e35a9f240211c7249d0effa49f0`。

- [产品构建 41000425235](https://github.com/dongdonglr0820/custOpenVPN-public/actions/runs/41000425235)：Windows/Linux 四架构编译与测试均成功，Mac GUI、两种核心及 ZIP/DMG 也已生成；原 Mac 校验因测试替身影响系统工具而失败。
- [最终交付验证 41003113670](https://github.com/dongdonglr0820/custOpenVPN-public/actions/runs/41003113670)：全绿；验证代码 `5cac8a22cacdd79fe7ad548df5a86c13cdb8fd14`。该任务先断言产品补丁、品牌、上游 refs、Windows/Linux 构建逻辑和 Mac 编译/打包输入未变，再校验同一份安装包并重新运行 Mac 四组 TLS。没有用重新编译的不同包替换原交付物。

| 平台 | 本轮证据 | 未覆盖的实机范围 |
| --- | --- | --- |
| Windows amd64 | I002 MSI 安装、身份解析与服务协议、普通用户/管理员路径、缺序列号拒绝、独立 IPC 测试设备值的 TLS、配置覆盖拒绝 | 真实业务 VPN、真实磁盘多次重启、升级/回滚 |
| Windows arm64 | I002 MSI 编译与包校验 | ARM 电脑上的运行、采集和重启 |
| Linux amd64 / arm64 | 原生架构编译；最终静态包真实 TLS；系统盘选择、缺 ID、覆盖拒绝、字段白名单；多盘 sysfs 隔离环境和内部空格的服务端正规化 | 业务 VPN/OTP、真实多盘插拔及重启 |
| macOS x86_64 / arm64 | GUI 与两个核心 Universal 2；最低 macOS 13；两种 OpenSSL × 两种 CPU 共四组 TLS、字段唯一性、白名单及覆盖拒绝 | Apple Silicon 真实系统盘、GUI 安装、业务 VPN 与重启 |
| 真实 Intel Mac | 最终 ZIP 中未修改的两个核心分别采集真实 APFS 系统盘 serial，完成原生 TLS 与配置覆盖拒绝；运行前后核心 SHA256 不变 | GUI 安装、业务 VPN 与连续重启 |

Linux 的 sysfs 拓扑测试通过 10 项：系统盘不是首盘、盘号变化、NVMe、LVM/加密、同盘多 extent 去重、多盘根拒绝、缺 ID、无效/注入值、禁止切换 ID、循环及设备缺失。

Mac CI 虚拟盘为非 Physical，交付核心原生拒绝，这是预期结果。TLS 测试仅在临时核心副本中加载独立 IOKit provider；测试替身不进入产品、不会继承到 `diskutil`，不修改安装包。它证明 TLS 序列化和拒绝分支，不能算作 CI 成功采集了真实硬盘。真实 Intel Mac 上的原生测试另行记录，两种证据不混用。

所有交付文件已核对 SHA256；Windows MSI 与 CI 的 Get-FileHash 输出一致，Linux 与随包 SHA256 一致，Mac ZIP/DMG 与 SHA256SUMS 一致。下载后再次检查了 ELF/Mach-O 架构、核心版本、GUI 版本、最低 macOS 和产品内没有测试 provider。

## 安装前

- Windows 安装完整 MSI，使核心和 Interactive Service 匹配。
- Linux/macOS 删除旧的 `IV_DISK` 配置或注入项及 `UV_SYSTEM_DISK_SCHEMA` 覆盖；保留原 `IV_USER / IV_INFO / IV_PLAT` 来源。
- 对比现有服务端绑定。新系统盘 serial 不同应核实后迁移单项绑定，不能清空全部设备信息或重置 OTP 掩盖差异。
- 多盘系统卷、缺有效序列号或不支持的根文件系统会明确报错。Linux Btrfs 匿名根设备、overlay 与网络根不支持，详见 [系统盘设计](unix-system-disk.md)。
- Windows/macOS 仍为未正式发布者签名/公证的测试包。按 [Windows 测试](windows-testing.md) 和 [Unix 测试](unix-testing.md) 完成各自业务及真实重启验收。
