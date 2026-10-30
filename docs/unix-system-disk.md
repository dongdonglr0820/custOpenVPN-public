# Linux/macOS 系统盘 ID（xy3）

`IV_DISK` 表示系统所在存储设备的序列号。它不再来自配置、磁盘枚举第一行、所有盘的拼接或设备名。`IV_USER / IV_INFO / IV_PLAT` 保留既有来源；Windows 的四字段原生采集保持原实现。

## Linux

从 `stat("/").st_dev` 找 `/sys/dev/block/<major>:<minor>`，将分区映射到真实 sysfs 父盘，递归处理 LVM、dm-crypt、md 等设备的 `slaves`。所有路径最终必须落在同一块盘；多个分区落在同一盘允许，多块底层盘明确拒绝。SCSI/SATA 和 NVMe 分别在 `device/serial`、`serial` 导出序列号；已有字段为空或无效时不改取另一种 ID。

不依赖 `/dev/sda`、磁盘编号、枚举顺序或 `/dev/disk/by-id` 首项。根设备无法映射到块设备时明确报错，包括 overlay、网络根、匿名设备号的 Btrfs；不退回 machine-id、文件系统 UUID 或数据盘。

## macOS

固定执行 `/usr/sbin/diskutil info -plist /`，从系统卷或系统快照的 `APFSPhysicalStores` 定位唯一 Physical Store，再查其 `ParentWholeDisk`。非 APFS 按系统卷的父盘定位。要求 whole disk 为 Physical，并只沿该 IOMedia 的 IOService 父链查 `Serial Number` 或 `Device Characteristics/Serial Number`。

不使用 `disk0` 假设，不使用 APFS snapshot UUID（它会随系统更新改变）、卷 UUID或整机序列号兜底。Fusion/多 Physical Store、虚拟盘和缺 serial 明确失败。命令无 shell/PATH 查找，输出有 1 MiB 上限，每次查询有 15 秒超时，并回收子进程。最低 macOS 13。

## 连接与诊断

每次连接初始化生成一份磁盘快照，TLS 重协商复用。只有 TLS client 采集，server 不需要本机磁盘 ID。序列号去首尾空格，拒绝空值、占位值、控制字符、嵌入 NUL 和过长字段。失败在握手前终止，不向服务端发送空 ID。

```sh
./openvpn --show-system-disk
```

只读诊断输出 `schema`、本次定位的 `system_disk` 和 `IV_DISK`，不连接 VPN。普通连接日志只记录 schema 和采集阶段；本机诊断包含设备标识，按内部排障资料处理。

移除旧配置中的 `setenv IV_DISK ...` 和 `setenv UV_SYSTEM_DISK_SCHEMA ...`，保留 `IV_USER / IV_INFO / IV_PLAT` 的既有来源。禁止配置覆盖以免另一块盘被当作系统盘；服务端推送或环境中的同名值也不会进入最终 peer-info。

诊断保留 serial 内部字符；上游服务端 `validate_peer_info_line()` 会把空格及 `$`、`(`、反引号替换为下划线，再写入 peer-info 日志和脚本环境。核对服务端绑定时按这条既有规则比较，不应把这种正规化误判成取了另一块盘。

升级前对比诊断值与现有绑定。历史值不同可能是之前选了数据盘或使用了不同 ID 语义；需核实后按单配置迁移磁盘绑定。客户端不会清空服务端绑定、重置 OTP 或自动放宽验证。

## 自动验证边界

Linux 单元测试以真实临时 sysfs 树验证系统盘不在第一位、编号变化、NVMe、LVM/加密、多 extent 去重、多盘根拒绝、缺 serial、字段注入和循环。

Linux 的最终交付二进制在独立 mount namespace 中读取合成的多盘 sysfs，真实握手必须只上报指定系统盘 serial；缺 serial 必须失败，恢复后重新通过。若 CI runner 提供原生 serial，也运行原生采集与握手；没有时记录明确拒绝，合成拓扑证据单独标记。

macOS 的两种架构分别运行 APFS snapshot、非零盘号、HFS、多盘、异常 plist 和嵌入 NUL serial 测试。最终应用的两种 OpenSSL 核心 × 两种 CPU slice 先做未修改二进制的原生诊断；宿主提供有效 serial 时直接执行本地 TLS。

CI 虚拟存储没有有效 serial 或为 Virtual 时，原生拒绝必须匹配明确的设备错误；随后仅在临时核心副本中加载独立 IOKit 测试 provider，做四组真实 TLS、唯一 `IV_DISK`、字段白名单和配置覆盖拒绝测试。provider 和测试副本不会出包；测试前后检查原交付核心的 SHA256 不变，并拒绝产品内出现测试 serial 标记。此路径只证明 TLS 序列化，不能声称 CI 成功采集了真实硬盘。另在真实 Intel Mac 上独立核对 APFS 系统盘 serial；业务 VPN/OTP 和真实重启仍需单独验收。

本地 TLS 不代表业务 VPN/OTP、GUI 安装、真实多盘插拔或多次冷启动已验收。Windows 的既有 CI 及实机结果也不能外推到新包或 Unix 平台。
