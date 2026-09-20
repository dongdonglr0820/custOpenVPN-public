#!/usr/bin/env bash
# 在 macOS runner 上构建「peerinfo 指纹补丁 + xy 版本戳」的 Tunnelblick（未签名/adhoc 测试包）。
#
# 前置：CWD = Tunnelblick 源码根；已装 Xcode CLT / brew autotools / Rosetta（见 workflow 步骤）。
# 环境变量：
#   CUST_DIR     custOpenVPN 仓库根（必填）
#   XY_VERSION   默认 xy1
#   XY_DATE      默认当天 UTC
#   OUT_DIR      产物目录，默认 $PWD/out
set -euo pipefail

: "${CUST_DIR:?所需变量 CUST_DIR 未设置}"
XY_VERSION="${XY_VERSION:-xy1}"
XY_DATE="${XY_DATE:-$(date -u +%Y%m%d)}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
mkdir -p "$OUT_DIR"

OVPN_DIR="third_party/sources/openvpn/openvpn-2.7.7"
PATCH_DIR="$OVPN_DIR/patches"
mkdir -p "$PATCH_DIR"

# 1) 注入 peerinfo 指纹补丁（文件名 99-* 保证排在 Tunnelblick 自带补丁之后）；
#    sed 去 CR 兜底：防止补丁在 Windows 检出被转成 CRLF（patch -p1 会打不上）
sed 's/\r$//' "$CUST_DIR/patches/openvpn-peerinfo-spoof-2.7.7.patch" > "$PATCH_DIR/99-custom-peerinfo.diff"

# 2) 现场生成版本戳补丁：PRODUCT_VERSION_PATCH [.7] -> [.7-xy1-YYYYMMDD]
#    （Tunnelblick 的 built-openvpn-prepare 会对每个 patches/*.diff 做 patch -p1 -N）
cat > "$PATCH_DIR/99-custom-version-stamp.diff" <<EOF
--- openvpn-2.7.7/version.m4	2026-09-17 00:00:00.000000000 +0000
+++ openvpn-2.7.7-patched/version.m4	2026-09-17 00:00:00.000000000 +0000
@@ -1,11 +1,11 @@
 dnl define the OpenVPN version
 define([PRODUCT_NAME], [OpenVPN])
 define([PRODUCT_TARNAME], [openvpn])
 define([PRODUCT_VERSION_MAJOR], [2])
 define([PRODUCT_VERSION_MINOR], [7])
-define([PRODUCT_VERSION_PATCH], [.7])
+define([PRODUCT_VERSION_PATCH], [.7-${XY_VERSION}-${XY_DATE}])
 m4_append([PRODUCT_VERSION], [PRODUCT_VERSION_MAJOR])
 m4_append([PRODUCT_VERSION], [PRODUCT_VERSION_MINOR], [[.]])
 m4_append([PRODUCT_VERSION], [PRODUCT_VERSION_PATCH], [[]])
 define([PRODUCT_BUGREPORT], [openvpn-users@lists.sourceforge.net])
 define([PRODUCT_VERSION_RESOURCE], [2,7,7,0])
EOF

# 3) 构建第三方组件（openssl/lzo/lz4/pkcs11 + 打补丁后的 openvpn 2.7.7）
# 注意 1：third_party/Makefile 里 TOPDIR=$(PWD)，而 make -C 不会更新 PWD（CI 上曾因此
#         找错 sources 目录、rsync 报 No such file），必须显式传 TOPDIR。
# 注意 2：补丁循环里会用 [ "$name" != 01-... -o $XCODE_VERSION_MAJOR = 0300 ] 判断；
#         XCODE_VERSION_MAJOR 为空时该 test 解析报错，导致【所有补丁被静默跳过】
#         （构建照常通过但补丁没打上）。CI 里不是 Xcode 调用，必须显式导出。
export XCODE_VERSION_MAJOR="${XCODE_VERSION_MAJOR:-1600}"
# 注意 3：SDK_DIR / MACOSX_DEPLOYMENT_TARGET 是 Xcode 构建阶段注入的环境变量，
#         CI 直接跑 make 时为空 → openssl Configure 的 -isysroot/-mmacosx-version-min
#         变成空值、编译秒失败（表现为 lipo 找不到 openssl 产物）。必须自己提供。
export SDK_DIR="${SDK_DIR:-$(xcrun --sdk macosx --show-sdk-path)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# 注意 4：以下变量由 BuildThirdPartyItems.sh 在 Xcode 环境里准备，CI 直接跑必须自备：
#   - TB_CAN_BUILD_X86_64 / TB_CAN_BUILD_ARM：架构能力；为空 → 架构列表为空 →
#     openssl/lzo/lz4/pkcs11 的内层构建循环整体被跳过（现象：lipo 找不到 openssl 产物）
#   - TB_CONFIGURE_HOST：lzo/openvpn/pkcs11 configure --host 用
#   - COMMAND_MODE=unix2003：官方注释"make openssl build without error"所需
export TB_CAN_BUILD_X86_64=1
export TB_CAN_BUILD_ARM=1
export TB_CONFIGURE_HOST="$(uname -m)-apple-darwin"
export COMMAND_MODE=unix2003
make -C third_party TOPDIR="$PWD/third_party"

echo "=== openvpn 产物:"
ls third_party/products/openvpn/ || true

# 4) 构建 App：Release + 产物落 tunnelblick/build（Legacy 布局）；
#    BuildAppsAndDmgs.sh 是 Xcode 工程内的构建阶段，会自动做打包/adhoc 签名/dmg。
#    注意 5：工程里两处配置硬编码 SDKROOT = macosx26.0（作者用 Xcode 26.0 构建），
#            runner 上 SDK 只有 26.2 → "unable to find sdk 'macosx26.0'"；
#            命令行传 SDKROOT=macosx 覆盖为"当前可用 SDK"。
xcodebuild -project tunnelblick/Tunnelblick.xcodeproj \
    -alltargets -configuration Release \
    SYMROOT="$PWD/tunnelblick/build" \
    SDKROOT=macosx \
    build

# 5) 验证内嵌 OpenVPN，再收产物
APP="tunnelblick/build/Release/Tunnelblick.app"
[ -d "$APP" ] || { echo "error: Tunnelblick.app 未生成（检查 xcodebuild 日志）"; exit 1; }

EXPECTED_OVPN="2.7.7-$XY_VERSION-$XY_DATE"
OVPN_BINS=()
while IFS= read -r bin; do
    OVPN_BINS+=("$bin")
done < <(find "$APP/Contents/Resources/openvpn" -type f -name openvpn | sort)
[ "${#OVPN_BINS[@]}" -ge 2 ] || { echo "error: expected >=2 embedded openvpn binaries"; exit 1; }

for bin in "${OVPN_BINS[@]}"; do
    echo "=== validate embedded OpenVPN: $bin"
    ver="$("$bin" --version | head -1)"
    echo "$ver"
    [[ "$ver" == *"$EXPECTED_OVPN"* ]] || { echo "error: custom version missing from $bin"; exit 1; }

    archs="$(lipo -archs "$bin")"
    echo "archs: $archs"
    [[ "$archs" == *"x86_64"* && "$archs" == *"arm64"* ]] || {
        echo "error: $bin is not universal2 (x86_64 + arm64)"; exit 1;
    }

    grep -a -q 'IV_DISK=' "$bin" || {
        echo "error: peerinfo fingerprint patch marker IV_DISK= missing from $bin"; exit 1;
    }
done

# Tunnelblick 的 CFBundleShortVersionString 可能包含 "(build N) Unsigned" 等展示文字，
# 产物文件名固定使用基线版本，避免空格和 runner 构建描述污染文件名。
NAME="Tunnelblick-9.0.1-openvpn-$EXPECTED_OVPN-unsigned"
ditto -c -k --keepParent "$APP" "$OUT_DIR/$NAME.zip"

# 实际 DMG 位于 build/Release/，原脚本匹配 build/*.dmg 会漏掉。
shopt -s nullglob
for f in tunnelblick/build/Release/*.dmg tunnelblick/build/Release/Signed/*.dmg; do
    base="$(basename "$f")"
    cp "$f" "$OUT_DIR/${base%.dmg}-openvpn-$EXPECTED_OVPN.dmg"
done
shopt -u nullglob

test -s "$OUT_DIR/$NAME.zip"
echo "=== 产物:"; ls -lh "$OUT_DIR"