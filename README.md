# custOpenVPN — Custom OpenVPN Client Builds

基于 OpenVPN 社区版维护多平台定制客户端：
保留 **peer-info 指纹上报**（`IV_USER / IV_INFO / IV_DISK / IV_PLAT`，用于测试服务端
`clientConnecionValidator.py` 的设备绑定），版本号带 **xy** 标识与官方版本区分。

Windows `xy2` 自动从 Windows 所在卷采集磁盘序列号，并通过原生模块采集设备 UUID 和当前用户；禁止配置覆盖这些字段。参见[实现说明](docs/windows-device-identity.md)和[Windows 测试步骤](docs/windows-testing.md)。

> Linux/macOS 旧版背景：测试服务端的兼容性检查 只认带齐 IV_* 指纹的客户端，缺字段即
> `INCOMPATIBLE_CLIENT` 拒绝。指纹由客户端 `setenv IV_*` 写入，上游
> `push_peer_info()` 会丢弃它们，必须打补丁转发。

## 目录

```
custOpenVPN/
├── patches/                    补丁（唯一事实源，CI 直接应用）
│   ├── openvpn-peerinfo-spoof-2.7.8.patch   全平台基线
│   ├── openvpn-windows-device-identity-2.7.8.patch  Windows 原生身份采集
│   ├── tunnelblick-tuntap-format.patch   macOS 旧驱动日志格式兼容修正
│   ├── openvpn-peerinfo-spoof-2.7.7.patch   历史全平台基线
│   └── openvpn-peerinfo-spoof-2.6.14.patch  历史（办公网关 2.6.14 基线）
├── branding/windows/           MSI 品牌 / 版本 / 升级码
├── scripts/                    构建脚本
├── .github/workflows/build-clients.yml     CI
├── openvpn/                    ┐
├── openvpn-gui/                ├ 本地开发克隆（不入库；CI 从上游拉+打补丁）
├── openvpn-build/              │
└── tunnelblick/                ┘ macOS 上游源码克隆
```

## 当前全平台基线（2026-10-23）

- Core：OpenVPN **2.7.8**，自定义版本 **xy2**。
- Windows 构建：固定 `openvpn-build` 提交 `ecbfe78be2b86d53ff9fff6d89d55653d7a4b0ca`（2.7.8-I001），GUI 固定提交 `91c7fc056609d124bf29b348b23f678e35480563`，DCO 2.8.13、TAP 9.27.0。
- Linux：amd64 / arm64 全静态核心，使用 2.7.8 的 peerinfo 补丁。
- macOS：Tunnelblick **10.0.1**，内嵌 OpenVPN **2.7.8-xy2**，Universal 2（Intel + Apple Silicon），最低 macOS 13。使用上游 tarball 和补丁系列，再追加本仓库的 peerinfo 与版本戳补丁。
- 原生系统盘身份补丁仅 Windows 使用；Linux/macOS 保留现有 `setenv IV_*` 上报方式。
- Windows `2.7.8-xy2-20261023` 完整 MSI 已获用户实机测试可用反馈；具体连续重启次数、升级/回滚、ARM64 实机覆盖未另行记录。本轮 `only=unix` 复用此包，构建 Linux/macOS；验收步骤见 [Linux/macOS 测试说明](docs/unix-testing.md)。
- Linux/macOS [CI 39921447098](https://github.com/dongdonglr0820/custOpenVPN-public/actions/runs/39921447098) 已全部通过（构建代码 `c48aa2684a931975e0ec966f3a1895860c1d33d2`）：Linux 双架构真实连接及缺字段拒绝测试；Mac 两种 OpenSSL 变体 × 两种架构的回环 TLS。下载后的校验值、Mac ZIP 完整性、GUI/核心 Universal 2 和最低 macOS 13.0 也已核对。

## 上次全平台基线（2026-09-17）

| 组件 | 版本 | 说明 |
|---|---|---|
| openvpn 核心 | v2.7.7 | 上次全平台验证版本；当前基线已升级到 2.7.8 |
| openvpn-gui | v11.66.0.0 | 即 2.7.7-I001 安装器内置版本 |
| openvpn-build | release/2.7 | MSI 构建；内置 TAP-Windows6 9.27.0、ovpn-dco-win 2.8.7 |
| Tunnelblick | v9.0.1 | mac 定制基线；内置 openvpn-2.7.7 tarball + 补丁系列 |
| 旧定制版基线 | 2.6.12-I001-custom-legacy | 2024-07 构建，落后约 10 个上游版本 |

## 版本号规则（xy 标识）

| 场景 | 形式 | 示例 |
|---|---|---|
| 核心（`openvpn --version`、`IV_VER`、Linux 产物名） | `<上游版本>-xy<N>-<YYYYMMDD>` | `2.7.7-xy1-20260917` |
| Windows MSI（文件名 / DisplayVersion） | `<上游包版本>-xy<N>-<YYYYMMDD>` | `OpenVPN-2.7.7-I001-xy1-20260917-amd64.msi` |
| Windows MSI 数字版本（升级逻辑用） | `<major>.<minor>.<补丁号*100+N>` | `2.7.701`（xy1；数字版本不含日期） |

- `N` 每次**自定义发布** +1：上游版本相同、我们重打一次包也 +1。
- 日期 `YYYYMMDD` 默认取构建当天 UTC，由 CI 自动生成；**文件名与 `--version`/`IV_VER`
  都同步带日期+版本**，便于区分同一上游版本的不同发版（`2.7.7-xy1-20260917`
  vs `2.7.7-xy2-20261020`）。
- 核心实现：`version.m4` 的 `PRODUCT_VERSION_PATCH` `.7 → .7-xy1-YYYYMMDD`（autotools 与
  CMake 两套构建都由此拼 `PACKAGE_VERSION`，Linux/Windows 一致生效）。
- **升级码**：非官方发行版必须用自己的 `UPGRADE_CODE`（官方提示），否则会和官方
  MSI 互相升级/打架。本仓库在 `branding/windows/apply-branding.ps1` 里固定了三个
  自定义发行版专属 GUID，发布后不得再改；`PRODUCT_CODE` 每次构建自动换新。

## CI（.github/workflows/build-clients.yml）

- **windows-msi**：`windows-2022` × [amd64, arm64]。checkout 上述固定 openvpn-build
  提交（含 vcpkg/WiX 工具链）→ 把 `src/openvpn` 换成 v2.7.8 + 指纹及原生身份补丁 →
  打 xy 版本戳 → `build-and-package.ps1` 出 MSI（未签名，签名后续接）。
- **linux**：容器内构建（默认 `ubuntu:22.04`）× [amd64, arm64]。**默认全静态单文件**
  （`STATIC=0` 可切回动态链接）。amd64 / arm64 分别在 `ubuntu-24.04` / `ubuntu-24.04-arm`
  原生构建并测试。产物：`openvpn-2.7.8-xy2-20261023-linux-<arch>.tar.gz` + sha256。
  静态配方（已实测）：configure 加 `LDFLAGS=-static`（暴露 -lz/-lzstd 静态依赖）+
  make 覆盖 `LDFLAGS=-all-static`（libtool 会吃掉 `-static`）+ `OPENSSL_LIBS="-lssl -lcrypto -lz -lzstd"`；
  脚本内置「非静态即拒绝出包」断言。两架构打包完成后都会运行真实 E2E：
  解包最终 tar.gz，启动本地 OpenVPN server，再用交付二进制作为 client 完成 TLS/VPN 握手，
  服务端 `client-connect` 必须实际收到 `IV_USER / IV_INFO / IV_DISK / IV_PLAT / IV_VER`；
  同时断言非白名单 `IV_NOT_ALLOWED` 不得被转发。注意：glibc 静态包对 **DNS 域名** 解析有已知限制，
  测试配置的 `.ovpn` remote 均为 IP，无影响；若未来出现域名远端，请用动态构建。
- **macos-tunnelblick**（未做 Developer ID 签名/公证）：`macos-15`；checkout Tunnelblick `v10.0.1` →
  把 peerinfo 补丁 + 现场生成的版本戳补丁注入其
  `third_party/sources/openvpn/openvpn-2.7.8/patches/` → `make -C third_party` →
  `xcodebuild -alltargets Release`（工程内置的 BuildAppsAndDmgs.sh 自动打包/adhoc 签名）→
  产物 `Tunnelblick-10.0.1-openvpn-2.7.8-xy2-20261023-unsigned.zip`（+ dmg 若生成）及 SHA256。
  强制校验内嵌 OpenVPN 为 Universal 2（`x86_64 + arm64`），两种 OpenSSL 变体的两种架构均通过回环 TLS 验证版本及指纹字段。
  工具链限制为 Xcode 26.0.1–26.3，以保留 Intel 编译支持；x86_64 测试使用 Rosetta。
  先用当前 autotools 重新生成核心构建文件，校验 TUN/TAP 实际产物；OpenSSL 通过 make jobserver 并行编译。第三方构建成功后写入上游 `do-not-clean` 标记，防止 Xcode 清空并重复编译已准备好的依赖。
- 触发：`workflow_dispatch` / push `v*` tag；`ci/final-validation` 分支临时用于全平台验收。
- **最终 gate**：`only=all` 要求 Windows 两架构、Linux 两架构、macOS 全部成功；`only=unix` 要求 Linux/macOS 成功且 Windows 跳过，保留已验收 Windows 包。
  workflow 配置 concurrency，同一 ref 新提交会取消被替代的旧验收 run。
- 私有仓库注意：Actions 分钟数计费，Windows 首次构建（vcpkg 全量）较慢，
  vcpkg 缓存已配置（第二次起明显加快）。

## 升级 runbook（跟随上游）

1. 本地 `openvpn/` 在隔离分支把当前基线补丁移植到新 tag，冲突时对照
   补丁四处改动手工解决（见下）；导出新补丁
   `git format-patch -1 --stdout > patches/openvpn-peerinfo-spoof-2.7.8.patch`。
2. 改 workflow 顶部 env：`OPENVPN_REF`、`PATCH_FILE`；`XY_VERSION` 重置为 `xy1`
   （新上游版本从 1 重新计数；发版日期由 CI 自动生成，无需手改）。
   同步两个构建脚本的默认版本，并移植/更新 `WINDOWS_IDENTITY_PATCH`。
   其余版本相关处（MSI 产物校验、E2E 期望版本、macOS 源码目录/版本戳补丁/产物名）
   都从这几项推导，无需逐处改。另需确认两处上游配套：
   - `OPENVPN_BUILD_REF` 分支的 `windows-msi/version.m4` 已跟到新版本（MSI 包版本前缀须与
     `OPENVPN_REF` 一致，CI 的 MSI 校验会拦截不匹配）；
   - macOS job 的 `TUNNELBLICK_REF` 对应的 Tunnelblick 已内置
     `third_party/sources/openvpn/openvpn-<新版本>/`（否则 CI 直接报错），必要时一起升级。
3. Windows MSI 数字版本 / PRODUCT_CODE 由 `apply-branding.ps1` 自动处理，无需手改。
4. 验证新编译的交付二进制：`openvpn --version` 应显示 `<上游版本>-<XY_VERSION>-<日期>`；
   连通测试环境确认 `IV_USER/IV_INFO/IV_DISK` 上报且服务端
   `LOGGED IN` / `DEVICE_UUID MATCHED`。
5. 推工作分支并手动 dispatch `only=all`（只补 Linux/macOS 时用 `only=unix`）→ 验证产物。合并、打 tag 与发布单独执行。

### 补丁的四处改动（rebase 时对照）

`src/openvpn/ssl.c`：
1. include `env_set.h`；
2. `IV_PLAT` 内置值改为可被 `setenv IV_PLAT` 覆盖；
3. env 转发循环白名单加 `IV_PLAT / IV_USER / IV_INFO / IV_DISK`；
4. （2 的配对）收尾大括号。
注意：2.7 的循环里 `IV_SSO` 条件收尾括号在同一行（2.6 在下一行），补丁上下文已适配。

## TODO

- [x] Windows 原生稳定系统盘/UUID/用户采集、服务查询与诊断；[实现说明](docs/windows-device-identity.md)
- [x] Windows 最终 MSI：用户反馈实机测试完成、可用（2026-10-23；具体测试覆盖未另行记录）
- [ ] MSI 品牌名/发布者（`PRODUCT_NAME` / `PRODUCT_PUBLISHER`，现暂留 OpenVPN）
- [x] macOS：Tunnelblick CI 接入；当前升级至 v10.0.1，产物检查 Universal 2 + 版本戳 + 指纹 TLS 上报
- [ ] macOS 品牌 / 正式签名（notarize 需要 Apple 证书；当前只出 adhoc 未签名测试包）
- [x] Linux 产物：默认全静态单文件（`tar.gz` + sha256；`STATIC=0` 可切动态）
- [ ] 代码签名（Windows Authenticode；macOS notarize）
- [ ] tag → GitHub Release 自动附产物
