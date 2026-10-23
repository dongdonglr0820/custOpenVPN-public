# Windows 设备信息采集与稳定磁盘绑定设计

状态：实现已完成，Windows 原生 CI 与故障机验证进行中。2026-10-23。

代码基线：`3763440`（2026-09-24），在 `feature/windows-stable-device-id` 开发；Windows OpenVPN 基线已升级到 `v2.7.8`。此设计针对 Windows 客户端补齐自动采集，保留现有服务端 `IV_PLAT / IV_USER / IV_INFO / IV_DISK` 契约。

## 1. 要解决的问题

同一台电脑、同一用户、同一客户端版本，连接时可能上报两个不同的磁盘标识。服务端只有一个磁盘绑定值，因此一个值通过、另一个值被拒。

已确认的是上报值切换；旧版采集源码尚未取得，不能直接认定它使用了 `PhysicalDrive0` 或 WMI 第一行。新实现应消除“选择依赖枚举顺序”的可能，而非把某一次采集结果永久缓存。

## 2. 第一版的身份契约

| 字段 | 来源与格式 | 兼容原则 |
| --- | --- | --- |
| `IV_PLAT` | 固定 `win` | 与现有服务端一致 |
| `IV_USER` | 发起连接的 Windows 用户，`NameSamCompatible` 形式，如 `computer\user` / `domain\user` | 不改成 SID，不从 `USERNAME` 环境变量取，不把服务进程的 SYSTEM 当登录用户 |
| `IV_INFO` | SMBIOS Type 1 的 System UUID，标准带连字符 UUID | 按 SMBIOS 版本正确处理字节序，并与 `Win32_ComputerSystemProduct.UUID` 实机比对；拒绝全零、全 FF、截断记录 |
| `IV_DISK` | **Windows 安装所在卷对应存储设备的序列号** | 保留序列号内部字符；不改成卷序列号、盘符、磁盘编号、所有盘的哈希 |
| `UV_DEVICE_ID_SCHEMA` | `win-system-disk-v1` | 新增诊断字段；旧服务端可以忽略，不用版本字段自动授权迁移 |

首版只支持 Windows 所在卷映射到一个唯一磁盘编号、且存储驱动返回有效序列号的情况。同一磁盘的多个 extent 去重后仍算单盘。跨多个磁盘、无有效序列号等情况返回明确的不支持原因，不任取第一个 extent。

硬件 RAID / 虚拟机返回的可能是控制器或虚拟设备提供的标识；须经过对应环境重启验证，不能把它称为一定来自物理硬盘的不可伪造 ID。现有客户端指纹仍是辅助绑定条件，并非硬件证明。

## 3. 磁盘选择算法

```text
GetSystemWindowsDirectoryW()
  -> GetVolumePathNameW(Windows 安装路径)
  -> GetVolumeNameForVolumeMountPointW(卷挂载点)
  -> 打开该卷句柄（不带末尾反斜杠）
  -> IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS
  -> 去重 DiskNumber，要求恰好一个
  -> 打开对应 PhysicalDriveN
  -> IOCTL_STORAGE_QUERY_PROPERTY / StorageDeviceProperty
  -> 验证 STORAGE_DEVICE_DESCRIPTOR 和 SerialNumberOffset
  -> 提取、校验序列号 -> IV_DISK
```

`DiskNumber` 只用于本次从卷找到设备，不保存为设备身份。即使重启后系统盘从 Disk 0 变成 Disk 1，也会重新从 Windows 所在卷找到同一存储设备。额外数据盘、USB 盘不会进入选择范围。Windows 安装在 D 盘也应正常工作。

实现约束：

- 不硬编码 `C:`、`PhysicalDrive0`，不取枚举结果第一项，也不按序列号排序后取最小值。
- 固定使用 StorageDeviceProperty 的序列号语义；不能在 NVMe EUI、厂商序列号、卷序列号之间按调用成败切换。
- 动态分配有上限的缓冲区；检查返回长度、extent 数量、结构体版本、偏移范围和字符串终止符；禁止截断后继续认证。
- 去掉首尾空白，拒绝换行、控制字符、空值及明确占位值；内部下划线、短横线和点保留。不要为迁就历史尾部 `.;` 而批量删除所有标点。
- 首版保持服务端现有尾部装饰兼容规则。采集器去除首尾空格后的值由本机诊断命令显示，以区分“取错盘”和“同盘不同表示”。
- 查询失败后可以有限重试，但不能改取另一块盘；没有成功采集就不把空值送去尝试绑定。
- 每次新连接初始化重新采集，在该连接的 TLS 重协商期间复用同一快照。进程重启后重新读取，不建立可漂移的跨启动缓存。

## 4. 运行位置与权限

采集属于 OpenVPN core 的 Windows 模块，不放到 GUI 按钮回调，不通过 PowerShell/WMIC 子进程拼接命令。这样 GUI、管理员 CLI 使用同一套算法。

当前 upstream interactive service 已用调用方令牌 `CreateProcessAsUserW` 启动 core；`IV_USER` 应从这个用户上下文取得。普通用户可能没有直接打开卷/磁盘的权限，所以不能只在管理员终端测试成功就交付：

1. 在现有 interactive service 管道中增加一个固定的“查询本机设备信息”请求，服务端自行定位 Windows 卷并执行只读查询；请求不接收调用方任意设备路径或 IOCTL 编号。
2. 普通 GUI 的 core 通过现有已授权连接请求硬件信息；用户身份在 core 的调用用户令牌中采集。不要改用当前控制台用户，否则 RDP / 多会话会串用户。
3. 管理员直接运行 core 时调用同一采集模块；无服务、又无所需读取权限的 CLI 明确报告权限不足。
4. SYSTEM 自动服务模式不能猜测某个桌面用户。首版返回 `stage=unsupported-service-user`，后续若支持无人值守需设计独立绑定契约。
5. 新消息编号显式分配、不改变现有枚举值；独立的定长、带协议版本响应，不改动旧通用 ACK 的布局。验证类型、长度、请求 ID、字段上限；客户端与服务版本不匹配时明确失败。
6. 采集在 TLS peer-info 序列化前完成，复用现有 `msg_channel`。管道等待有超时；存储查询使用有界等待/可取消 I/O，服务交互默认等待 15 秒；存储 I/O 等待 3 秒后请求取消，并等待取消完成后释放缓冲区。损坏驱动不响应取消时仍可能阻塞服务线程，不能承诺硬性的存储查询总时限。

Windows 产品构建由 native collector 唯一填充四个身份字段；`.ovpn` 的 `setenv IV_*` 不能覆盖它们。若发现配置冲突，给出具体配置错误，不输出两个同名字段。Linux/macOS 现有透传与测试路径保持原契约。用于伪造测试值的接口只能存在于测试目标中。

## 5. 旧绑定迁移

固定取系统盘不意味着一定与旧绑定相等：历史客户端可能绑定了数据盘，也可能用另一种序列号表示。

- 升级前用新采集器的只读诊断结果对照服务端旧绑定，分别检查系统用户、设备 UUID、磁盘值。
- 相同则无需迁移。不同则先核实同一用户、同一设备及实际系统盘，再由管理员进行一次性、限定配置和环境的磁盘字段迁移。
- 迁移记录保留旧值、新值、操作者和时间，并以“当前值仍等于预期旧值”为前提更新；不覆盖其他设备字段，不重置 OTP，不清空整条绑定让下一次连接抢占。
- 不因客户端版本号、主板 UUID 相同或客户端声称“属于同一台机器”，自动接受新磁盘值；也不把全部历史磁盘值加入永久白名单。
- 客户端更换/磁盘迁移后，回滚旧客户端可能再次遇到不同取盘结果。回滚要同时核对客户端和单条绑定快照，不能声称卸载升级包即可无条件恢复。

本轮设计和客户端实现不包含生产数据库改写、OTP 重置或服务端策略放宽。

## 6. 补丁与构建组织

遵循本仓库“补丁是事实源”的方式，增加 Windows 专用补丁，CI 顺序应用：

1. 现有 `patches/openvpn-peerinfo-spoof-2.7.8.patch`。
2. 新 `patches/openvpn-windows-device-identity-2.7.8.patch`（仅 Windows job）。

新补丁覆盖：

- 共用 Windows 采集模块：纯解析/规范化逻辑与 Win32 I/O 分离，供 core、interactive service、诊断及测试复用。
- `src/openvpn/init.c`：在 TLS 初始握手前准备快照并处理采集错误。
- `src/openvpn/ssl.c`：产品 Windows 路径只序列化 native 字段，消除 `setenv` 覆盖和重复值。
- `include/openvpn-msg.h`、`src/openvpnserv/interactive.c`、core 管道客户端：添加只读查询协议。
- CMake / 必要的 Windows 构建依赖：确保 core 与 service 都编译同一采集实现。

增加 `--show-device-info` 只读诊断入口，输出 schema、Windows 卷、所选磁盘、模型、序列号、用户、设备 UUID 与具体错误，供本机人工排障；不发起 VPN 连接或写绑定。普通日志仅记录采集阶段、错误码、schema 与调用路径，不记录密码/OTP，不默认完整打印硬件序列号。

实现发布用 `xy2` 区分当前 `xy1`；MSI 必须同时更新 core 和 interactive service。新增代码进入补丁及 CI，不能只改被 `.gitignore` 忽略的本地 `openvpn/` 克隆。

## 7. 验收条件

| 场景 | 必须验证的结果 |
| --- | --- |
| 单盘、双盘、多盘 | 始终选 Windows 所在卷对应磁盘 |
| 模拟磁盘枚举/编号变化 | 同一系统盘的身份不变，另一块盘不能被选中 |
| 插拔 USB、增加数据盘 | 原系统盘身份不变 |
| Windows 位于非 C 盘 | 从系统 API 定位正确卷 |
| 同盘多个 extent、跨盘 extent | 前者去重成功，后者明确拒绝 |
| 空序列号、占位值、损坏描述符、超长值 | 明确失败，无越界、无静默截断、无换盘兜底 |
| SMBIOS 字节序、全零/FF、畸形记录 | 有效 UUID 与 WMI 对照一致，无效记录明确失败 |
| 普通用户 GUI + service / 管理员 CLI | 硬件身份一致，用户身份属于实际发起用户 |
| RDP / 多用户 / SYSTEM 服务 | 不混用控制台用户；不把 SYSTEM 误绑定给人 |
| 新 core + 旧 service、异常长度、超时 | 错误明确、无挂死，原管道消息继续正常 |
| `setenv IV_DISK` 冲突和 peer-info 注入字符 | 无覆盖、无重复字段、无注入 |
| Windows amd64 / arm64 | 编译通过；仅交叉编译不能当 arm64 真机验证 |
| 使用最终 MSI 安装后的真实握手 | 服务端实际收到 native 四字段，OTP、匹配和不匹配分支均验证 |
| 多盘故障机冷启动、重启、睡眠恢复 | 连续重启至少 5 次保持同一磁盘 ID；单次连接成功不算完成 |
| Linux/macOS 回归 | 原补丁及既有 E2E 仍通过 |

自动化覆盖解析、服务协议、MSI 安装、管理员/普通用户服务路径，以及本地 TLS 四字段上报。GitHub Windows 2022 的 Microsoft 虚拟系统盘没有序列号（独立检查 `Get-Disk` 与原始描述符 `SerialNumberOffset=0`）；此环境下必须断言 direct 和两种服务启动均返回明确错误，TLS 序列化另由不入安装包的 `tls-fixture.c` 提供合成硬件响应。测试日志明确标记这一区别，不能将其称为真实硬盘成功采集。若运行机提供序列号，则脚本验证真实 native 身份与 WMI、Storage API 一致并用真实值握手。Windows CI 成功不替代故障机重启验证；业务服务端的 OTP 与绑定迁移须在授权测试环境另行验收。本次仅构建 Windows，Linux/macOS 保留原基线，不声称已回归。

## 8. 依据

- [GetSystemWindowsDirectoryW](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemwindowsdirectoryw)：确定 Windows 安装目录。
- [GetVolumePathNameW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumepathnamew)：确定目录所在卷。
- [IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddvol/ni-ntddvol-ioctl_volume_get_volume_disk_extents)：取得卷与磁盘的关联，返回值可能包含多个磁盘，不能依赖顺序。
- [STORAGE_DEVICE_DESCRIPTOR](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddstor/ns-ntddstor-_storage_device_descriptor)：描述符中的序列号偏移可为零，必须验证后读取。
- [GetSystemFirmwareTable](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemfirmwaretable)：读取原始 SMBIOS。
- [GetUserNameExW](https://learn.microsoft.com/en-us/windows/win32/api/secext/nf-secext-getusernameexw)：读取调用线程用户身份；模拟上下文下返回被模拟用户。
- 本地 OpenVPN `src/openvpnserv/interactive.c` 的 `ImpersonateNamedPipeClient` / `CreateProcessAsUserW`：确认现有 GUI 启动身份链路。
