# Windows MSI 品牌 / 版本 / 升级码

`apply-branding.ps1` 在 CI 里每次构建前自动执行（见 `build-clients.yml`），负责：

| 项 | 值 |
|---|---|
| 核心版本戳 | `src/openvpn/version.m4`：`PRODUCT_VERSION_PATCH` `.7 → .7-xy1-20260917` |
| MSI 显示/文件名版本 | `PACKAGE_VERSION`：`2.7.7-I001 → 2.7.7-I001-xy1-20260917` |
| MSI 数字版本 | `PRODUCT_VERSION`：`2.7.701`（=补丁号×100+xyN，不含日期，随 xyN 递增） |
| PRODUCT_CODE | **每次构建**自动换新 GUID（MSI 升级语义要求） |
| UPGRADE_CODE_x86 / amd64 / arm64 | 固定 3 个 自定义发行版专属 GUID，**发布后不得再改** |

custom 专属 upgrade code（已固定，勿改）：

```
x86   {CD910A49-22C1-486E-8316-F1FDEB24C105}
amd64 {1FE42D8E-F68A-4F80-91C4-8D2519E0C3C7}
arm64 {BEF6BCC3-47DA-405B-96E5-9BFD4C404421}
```

为什么必须自备 upgrade code：官方 `version.m4` 里注释明确写了
"Please use own upgrade codes when deploying a non-official OpenVPN release"。
沿用官方的 code 会让定制 MSI 与官方 MSI 被 Windows Installer 视为同一产品线，
互相触发升级/卸载（用户装了官方版再装定制版，会直接把对方顶掉）。

## 发布节奏

- 上游换版本（如 2.7.8）→ `XY_VERSION` 回 `xy1`，数字版本自动变 `2.7.801`（= 补丁号 8×100 + 1）；
- 同一上游版本第二次自定义打包 → `xy2`（数字版本 `2.7.702`、新 PRODUCT_CODE）；
- 发版日期由 CI 按构建日（UTC）自动追加为 `-YYYYMMDD`，如 `2.7.7-xy1-20260917`；
- 客户端界面/日志里区分用 `-xyN-YYYYMMDD` 字符串；MSI 升级用数字版本 + PRODUCT_CODE。

## 待接

- `PRODUCT_NAME` / `PRODUCT_PUBLISHER` 仍是 `OpenVPN` / `OpenVPN, Inc.`：
  等拿到旧 custom-legacy fork 的品牌信息（名称、发布者、图标资源）后在
  `apply-branding.ps1` 里一并替换。图标/资源改动同时涉及
  `openvpn-build/windows-msi/artwork/` 与 openvpn-gui 仓库（需 fork）。