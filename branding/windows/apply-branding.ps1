# custom 定制：给 openvpn 核心与 windows-msi 版本文件打 xy 版本戳 / 专属升级码。
# 版本号形式：<上游版本>-xy<N>-<YYYYMMDD>（如 2.7.7-xy1-20260917）。
#
# 用法（在 openvpn-build/windows-msi 目录下）:
#   apply-branding.ps1 -XyVersion xy1 -XyDate 20260917 -CoreVersionM4 <path/to/openvpn-build/src/openvpn/version.m4>
#
# 作用:
#   [core version.m4]  PRODUCT_VERSION_PATCH  .7 -> .7-xy1-20260917
#                      （autotools/CMake 都由此拼 PACKAGE_VERSION，openvpn --version / IV_VER 生效）
#   [windows-msi version.m4]
#     PACKAGE_VERSION 2.7.7-I001 -> 2.7.7-I001-xy1-20260917  （MSI 文件名与 DisplayVersion）
#     PRODUCT_VERSION 2.7.701    -> 2.7.<补丁号*100+xyN>      （MSI 数字版本，单调递增；不含日期）
#     PRODUCT_CODE    每次构建换新 GUID                        （MSI 升级逻辑要求）
#     UPGRADE_CODE_*  替换为 custom 专属固定 GUID              （官方提示：非官方发行版必须自备）
#
# 幂等：已带 -xyN-YYYYMMDD 后缀的文件再次运行会自动跳过，不会重复叠加。
#
# 注意：UPGRADE_CODE 是"同一产品线"的稳定标识，发布后不得再改；
#       PRODUCT_CODE 必须每次发布都变化，因此这里每次运行都生成新 GUID。
param(
    [string]$XyVersion = "xy1",
    [string]$XyDate = (Get-Date).ToUniversalTime().ToString("yyyyMMdd"),
    [Parameter(Mandatory = $true)][string]$CoreVersionM4
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path "version.m4")) {
    throw "cwd must be openvpn-build/windows-msi (version.m4 not found)"
}
if ($XyVersion -notmatch '^xy(?<n>\d+)$') {
    throw "-XyVersion must look like xy1, xy2, ..."
}
$xyNum = [int]$Matches['n']   # 注意：必须紧跟本次匹配取值，后面任何 -match/-notmatch 都会覆盖 $Matches
if ($XyDate -notmatch '^\d{8}$') {
    throw "-XyDate must be YYYYMMDD, got '$XyDate'"
}
$xySuffix = "$XyVersion-$XyDate"
$stampPattern = '-xy\d+-\d{8}'

# custom 专属 MSI upgrade code（2026-09-17 生成，固定不变）
$upgradeX86 = "{CD910A49-22C1-486E-8316-F1FDEB24C105}"
$upgradeAmd64 = "{1FE42D8E-F68A-4F80-91C4-8D2519E0C3C7}"
$upgradeArm64 = "{BEF6BCC3-47DA-405B-96E5-9BFD4C404421}"

# ---------- 1. openvpn 核心版本戳 ----------
$core = Get-Content -Raw $CoreVersionM4
if ($core -match $stampPattern) {
    Write-Host "core: already stamped, skip"
} else {
    $core = $core -replace '(?m)^define\(\[PRODUCT_VERSION_PATCH\], \[([^]]+)\]\)', "define([PRODUCT_VERSION_PATCH], [`$1-$xySuffix])"
    Set-Content -NoNewline -Encoding ascii $CoreVersionM4 $core
}
Write-Host "core: $((Select-String 'PRODUCT_VERSION_PATCH' $CoreVersionM4).Line.Trim())"

# ---------- 2. windows-msi 包版本 ----------
$raw = Get-Content -Raw version.m4

# 数字版本：第三段 = 补丁号*100 + xyN（沿用上游约定：2.7.701 = 2.7.7 的第 1 次构建）
if ($raw -notmatch 'define\(\[PRODUCT_VERSION\], \[(\d+)\.(\d+)\.(\d+)\]\)') {
    throw "PRODUCT_VERSION not found in version.m4"
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$upstreamThird = [int]$Matches[3]
$patchLevel = [int][math]::Floor($upstreamThird / 100)
if ($patchLevel -eq 0) { $patchLevel = $upstreamThird }   # 兼容 "2.7.7" 这类写法
$numericVersion = "$major.$minor.$($patchLevel * 100 + $xyNum)"

if ($raw -match $stampPattern) {
    Write-Host "msi : already stamped, skip"
} else {
    $newProductCode = "{$((New-Guid).ToString().ToUpper())}"
    $m4 = $raw
    $m4 = $m4 -replace '(?m)^define\(\[PACKAGE_VERSION\], \[(.*?)\]\)', "define([PACKAGE_VERSION], [`$1-$xySuffix])"
    $m4 = $m4 -replace '(?m)^define\(\[PRODUCT_VERSION\], \[.*\]\)', "define([PRODUCT_VERSION], [$numericVersion])"
    $m4 = $m4 -replace '(?m)^define\(\[PRODUCT_CODE\], \[\{.*?\}\]\)', "define([PRODUCT_CODE], [$newProductCode])"
    $m4 = $m4 -replace '(?m)^define\(\[UPGRADE_CODE_x86\],.*$', "define([UPGRADE_CODE_x86],   [$upgradeX86])"
    $m4 = $m4 -replace '(?m)^define\(\[UPGRADE_CODE_amd64\],.*$', "define([UPGRADE_CODE_amd64], [$upgradeAmd64])"
    $m4 = $m4 -replace '(?m)^define\(\[UPGRADE_CODE_arm64\],.*$', "define([UPGRADE_CODE_arm64], [$upgradeArm64])"
    Set-Content -NoNewline -Encoding ascii version.m4 $m4
}
Write-Host "msi : $(Select-String 'PACKAGE_VERSION' version.m4 | Select-Object -First 1)"
Write-Host "msi : $(Select-String 'PRODUCT_VERSION' version.m4 | Select-Object -First 1)"
Write-Host "branding applied: $xySuffix (numeric $numericVersion)"