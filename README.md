# custOpenVPN — Custom OpenVPN Client Builds

基于 OpenVPN 社区版维护多平台定制客户端：
保留 **peer-info 指纹上报**（`IV_USER / IV_INFO / IV_DISK / IV_PLAT`，用于测试服务端
`clientConnecionValidator.py` 的设备绑定），版本号带 **xy** 标识与官方版本区分。

> 背景：测试服务端的兼容性检查 只认带齐 IV_* 指纹的客户端，缺字段即
> `INCOMPATIBLE_CLIENT` 拒绝。指纹由客户端 `setenv IV_*` 写入，上游
> `push_peer_info()` 会丢弃它们，必须打补丁转发。

## 目录

```
custOpenVPN/
├── patches/                    补丁（唯一事实源，CI 直接应用）
│   ├── openvpn-peerinfo-spoof-2.7.7.patch   当前主线（v2.7.7 基线）
│   └── openvpn-peerinfo-spoof-2.6.14.patch  历史（办公网关 2.6.14 基线）
├── branding/windows/           MSI 品牌 / 版本 / 升级码
├── scripts/                    构建脚本
├── .github/workflows/build-clients.yml     CI
├── openvpn/                    ┐
├── openvpn-gui/                ├ 本地开发克隆（不入库；CI 从上游拉+打补丁）
└── openvpn-build/              ┘
```

## 版本基线（2026-09-17）

| 组件 | 版本 | 说明 |
|---|---|---|
| openvpn 核心 | v2.7.7 | 2.7 线最新稳定；2.6 线停在 2.6.22（已转 Old Stable） |
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

- **windows-msi**：`windows-2022` × [amd64, arm64]。checkout openvpn-build
  `release/2.7`（含 vcpkg/WiX 工具链）→ 把 `src/openvpn` 换成 v2.7.7 + 打指纹补丁 →
  打 xy 版本戳 → `build-and-package.ps1` 出 MSI（未签名，签名后续接）。
- **linux**：容器内构建（默认 `ubuntu:22.04`）× [amd64, arm64]。**默认全静态单文件**
  （无运行时依赖，最大化兼容；`STATIC=0` 可切回动态链接）。arm64 走 QEMU 模拟
  （`tonistiigi/binfmt`）；若私有仓库有原生 arm64 runner（`ubuntu-24.04-arm`），
  可改 matrix 提速。产物：`openvpn-2.7.7-xy1-20260917-linux-<arch>.tar.gz` + sha256。
  静态配方（已实测）：configure 加 `LDFLAGS=-static`（暴露 -lz/-lzstd 静态依赖）+
  make 覆盖 `LDFLAGS=-all-static`（libtool 会吃掉 `-static`）+ `OPENSSL_LIBS="-lssl -lcrypto -lz -lzstd"`；
  脚本内置「非静态即拒绝出包」断言。amd64 打包完成后还会运行真实 E2E：
  解包最终 tar.gz，启动本地 OpenVPN server，再用交付二进制作为 client 完成 TLS/VPN 握手，
  服务端 `client-connect` 必须实际收到 `IV_USER / IV_INFO / IV_DISK / IV_PLAT / IV_VER`；
  同时断言非白名单 `IV_NOT_ALLOWED` 不得被转发。注意：glibc 静态包对 **DNS 域名** 解析有已知限制，
  测试配置的 `.ovpn` remote 均为 IP，无影响；若未来出现域名远端，请用动态构建。
- **macos-tunnelblick**（实验性，未签名）：`macos-15`；checkout Tunnelblick `v9.0.1` →
  把 peerinfo 补丁 + 现场生成的版本戳补丁注入其
  `third_party/sources/openvpn/openvpn-2.7.7/patches/` → `make -C third_party` →
  `xcodebuild -alltargets Release`（工程内置的 BuildAppsAndDmgs.sh 自动打包/adhoc 签名）→
  产物 `Tunnelblick-9.0.1-openvpn-2.7.7-xy1-20260917-unsigned.zip`（+ dmg 若生成），并强制校验内嵌 OpenVPN 为 Universal 2（`x86_64 + arm64`），同时兼容 Intel Mac 与 Apple Silicon。
  只在**手动触发或打 tag** 时构建（macOS runner 分钟数贵）；首次运行可能需要调优。
- 触发：`workflow_dispatch` / push `v*` tag；`ci/final-validation` 分支临时用于全平台验收。
- **最终 gate**：Windows 两架构（amd64/arm64）、Linux 两架构（含 amd64 peer-info E2E）、macOS Universal 2 全部成功才通过。
  workflow 配置 concurrency，同一 ref 新提交会取消被替代的旧验收 run。
- 私有仓库注意：Actions 分钟数计费，Windows 首次构建（vcpkg 全量）较慢，
  vcpkg 缓存已配置（第二次起明显加快）。

## 升级 runbook（跟随上游）

1. 本地 `openvpn/` 把 `custom/v2.7.7` rebase 到新 tag（如 `v2.7.8`），冲突时对照
   补丁四处改动手工解决（见下）；导出新补丁
   `git format-patch -1 --stdout > patches/openvpn-peerinfo-spoof-2.7.8.patch`。
2. 改 workflow 顶部 env：`OPENVPN_REF`、`PATCH_FILE`；`XY_VERSION` 重置为 `xy1`
   （新上游版本从 1 重新计数；发版日期由 CI 自动生成，无需手改）。
3. Windows MSI 数字版本 / PRODUCT_CODE 由 `apply-branding.ps1` 自动处理，无需手改。
4. 本地验证：`./openvpn/src/openvpn/openvpn --version` 应显示 `2.7.8-xy1-<日期>`；
   连通测试环境确认 `IV_USER/IV_INFO/IV_DISK` 上报且服务端
   `LOGGED IN` / `DEVICE_UUID MATCHED`。
5. 推 `main`/打 tag → CI 出全平台产物。

### 补丁的四处改动（rebase 时对照）

`src/openvpn/ssl.c`：
1. include `env_set.h`；
2. `IV_PLAT` 内置值改为可被 `setenv IV_PLAT` 覆盖；
3. env 转发循环白名单加 `IV_PLAT / IV_USER / IV_INFO / IV_DISK`；
4. （2 的配对）收尾大括号。
注意：2.7 的循环里 `IV_SSO` 条件收尾括号在同一行（2.6 在下一行），补丁上下文已适配。

## TODO

- [ ] Windows 侧 `IV_*` 值采集/写入逻辑（旧版定制 fork 源码待并入，或重做）
- [ ] MSI 品牌名/发布者（`PRODUCT_NAME` / `PRODUCT_PUBLISHER`，现暂留 OpenVPN）
- [x] macOS：Tunnelblick CI 接入（v9.0.1；补丁注入方式已在本地用真实 tarball 验证；
      第三方向构建 + Xcode 阶段待首次 CI 跑通）
- [ ] macOS 品牌 / 正式签名（notarize 需要 Apple 证书；当前只出 adhoc 未签名测试包）
- [x] Linux 产物：默认全静态单文件（`tar.gz` + sha256；`STATIC=0` 可切动态）
- [ ] 代码签名（Windows Authenticode；macOS notarize）
- [ ] tag → GitHub Release 自动附产物