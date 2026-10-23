#!/usr/bin/env bash
# 在 macOS runner 上构建「peerinfo 指纹补丁 + xy 版本戳」的 Tunnelblick（未签名/adhoc 测试包）。
#
# 前置：CWD = Tunnelblick 源码根；已装 Xcode CLT / brew autotools / Rosetta（见 workflow 步骤）。
# 环境变量：
#   CUST_DIR         custOpenVPN 仓库根（必填）
#   OPENVPN_REF      上游 tag，默认 v2.7.8（Tunnelblick 需内置同版本 tarball）
#   PATCH_FILE       peerinfo 补丁，相对 CUST_DIR，默认 patches/openvpn-peerinfo-spoof-<版本>.patch
#   TUNNELBLICK_REF  Tunnelblick tag，默认 v10.0.1（仅用于产物命名）
#   XY_VERSION       默认 xy2
#   XY_DATE          默认当天 UTC
#   OUT_DIR          产物目录，默认 $PWD/out
#   XY_BUILD_JOBS    每个 OpenSSL 架构的编译并发（默认 CPU 数；各架构仍顺序构建）
set -euo pipefail

: "${CUST_DIR:?所需变量 CUST_DIR 未设置}"
OPENVPN_REF="${OPENVPN_REF:-v2.7.8}"
OPENVPN_VER="${OPENVPN_REF#v}"
PATCH_FILE="${PATCH_FILE:-patches/openvpn-peerinfo-spoof-$OPENVPN_VER.patch}"
TUNNELBLICK_REF="${TUNNELBLICK_REF:-v10.0.1}"
XY_VERSION="${XY_VERSION:-xy2}"
XY_DATE="${XY_DATE:-$(date -u +%Y%m%d)}"
XY_SUFFIX="$XY_VERSION-$XY_DATE"
OUT_DIR="${OUT_DIR:-$PWD/out}"
[[ "$XY_DATE" =~ ^[0-9]{8}$ ]] || { echo 'error: XY_DATE must be YYYYMMDD'; exit 1; }
mkdir -p "$OUT_DIR"

OVPN_DIR="third_party/sources/openvpn/openvpn-$OPENVPN_VER"
OVPN_TARBALL="$OVPN_DIR/openvpn-$OPENVPN_VER.tar.gz"
PATCH_DIR="$OVPN_DIR/patches"
[ -f "$OVPN_TARBALL" ] || {
    echo "error: $OVPN_TARBALL 不存在：$TUNNELBLICK_REF 未内置 openvpn $OPENVPN_VER，需换 Tunnelblick 版本"; exit 1;
}
mkdir -p "$PATCH_DIR"

# 1) 注入 peerinfo 指纹补丁（文件名 99-* 保证排在 Tunnelblick 自带补丁之后）；
#    sed 去 CR 兜底：防止补丁在 Windows 检出被转成 CRLF（patch -p1 会打不上）
sed 's/\r$//' "$CUST_DIR/$PATCH_FILE" > "$PATCH_DIR/99-custom-peerinfo.diff"
cp "$CUST_DIR/patches/tunnelblick-tuntap-format.patch" \
    third_party/sources/tuntap/tuntap-20141104/patches/99-custom-format.diff

# 2) 现场生成版本戳补丁：PRODUCT_VERSION_PATCH [.7] -> [.7-xy1-YYYYMMDD]
#    （Tunnelblick 的 built-openvpn-prepare 会对每个 patches/*.diff 做 patch -p1 -N）
#    以 tarball 里真实的 version.m4 为基准做 diff，上游换版本无需改这里。
STAMP_TMP="$(mktemp -d)"
tar -xzOf "$OVPN_TARBALL" "openvpn-$OPENVPN_VER/version.m4" > "$STAMP_TMP/version.m4.orig"
sed -E "s/^define\(\[PRODUCT_VERSION_PATCH\], \[([^]]+)\]\)/define([PRODUCT_VERSION_PATCH], [\1-$XY_SUFFIX])/" \
    "$STAMP_TMP/version.m4.orig" > "$STAMP_TMP/version.m4"
grep -q "define(\[PRODUCT_VERSION_PATCH\], \[.*-$XY_SUFFIX\])" "$STAMP_TMP/version.m4" \
    || { echo "error: version stamp failed"; exit 1; }
diff -u --label "openvpn-$OPENVPN_VER/version.m4" --label "openvpn-$OPENVPN_VER-patched/version.m4" \
    "$STAMP_TMP/version.m4.orig" "$STAMP_TMP/version.m4" > "$PATCH_DIR/99-custom-version-stamp.diff" || true
[ -s "$PATCH_DIR/99-custom-version-stamp.diff" ] || { echo "error: empty version stamp diff"; exit 1; }
cat "$PATCH_DIR/99-custom-version-stamp.diff"
rm -rf "$STAMP_TMP"

# 3) 构建第三方组件（openssl/lzo/lz4/pkcs11 + 打补丁后的 openvpn）
# 注意 1：third_party/Makefile 里 TOPDIR=$(PWD)，而 make -C 不会更新 PWD（CI 上曾因此
#         找错 sources 目录、rsync 报 No such file），必须显式传 TOPDIR。
# 注意 2：补丁循环里会用 [ "$name" != 01-... -o $XCODE_VERSION_MAJOR = 0300 ] 判断；
#         XCODE_VERSION_MAJOR 为空时该 test 解析报错，导致【所有补丁被静默跳过】
#         （构建照常通过但补丁没打上）。CI 里不是 Xcode 调用，必须显式导出。
export XCODE_VERSION_MAJOR="${XCODE_VERSION_MAJOR:-2600}"
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
TB_CONFIGURE_HOST="$(uname -m)-apple-darwin"
export TB_CONFIGURE_HOST
export COMMAND_MODE=unix2003

# Prepare the patched core and regenerate its autotools files with the installed
# toolchain. The release tarball references aclocal-1.16, while current Homebrew
# supplies a newer Automake; changing version.m4 otherwise triggers that missing
# version only after all SSL variants have finished compiling.
make -C third_party TOPDIR="$PWD/third_party" built-openvpn-prepare
(
    cd "third_party/build/openvpn/openvpn-$OPENVPN_VER/openvpn"
    autoreconf -fiv
)

# Upstream's tuntap recipe can mask an inner compiler failure with a final touch.
# Check its actual outputs before spending time on the crypto dependencies.
make -C third_party TOPDIR="$PWD/third_party" built-tuntap
for driver in tun tap; do
    driver_bin="third_party/products/tuntap/$driver.kext/Contents/MacOS/$driver"
    test -s "$driver_bin" || { echo "error: missing $driver kernel extension"; exit 1; }
    driver_archs="$(lipo -archs "$driver_bin")"
    [[ "$driver_archs" == *x86_64* && "$driver_archs" == *arm64e* ]] || {
        echo "error: incomplete $driver architectures: $driver_archs"; exit 1;
    }
done

# Only parallelize compilation within a single OpenSSL source/architecture.
# Keep upstream's architecture loop and the legacy tuntap build sequential.
XY_BUILD_JOBS="${XY_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
[[ "$XY_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'error: invalid XY_BUILD_JOBS'; exit 1; }
make -j "$XY_BUILD_JOBS" -C third_party TOPDIR="$PWD/third_party" built-allssl
make -C third_party TOPDIR="$PWD/third_party"

# Xcode's BuildThirdPartyItems.sh otherwise runs make clean, discarding this
# completed build AND the regenerated autotools files. Use its documented
# marker only after the complete dependency build succeeds.
touch third_party/do-not-clean

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

EXPECTED_OVPN="$OPENVPN_VER-$XY_SUFFIX"
OVPN_BINS=()
while IFS= read -r bin; do
    OVPN_BINS+=("$bin")
done < <(find "$APP/Contents/Resources/openvpn" -type f -name openvpn | sort)
[ "${#OVPN_BINS[@]}" -ge 2 ] || { echo "error: expected >=2 embedded openvpn binaries"; exit 1; }

for bin in "${OVPN_BINS[@]}"; do
    echo "=== validate embedded OpenVPN: $bin"
    ver="$("$bin" --version | sed -n '1p')"
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

    # Exercise both slices and both bundled OpenSSL variants over a real TLS
    # connection. These tests configure no interfaces and use no business VPN.
    for cpu in arm64 x86_64; do
        EXPECTED_VERSION="$EXPECTED_OVPN" E2E_ARCH="$cpu" \
        E2E_WORK_DIR="$PWD/e2e-peerinfo-logs/$(basename "$(dirname "$bin")")-$cpu" \
            bash "$CUST_DIR/scripts/e2e-peerinfo-tls.sh" "$PWD/$bin"
    done
done

# Tunnelblick 的 CFBundleShortVersionString 可能包含 "(build N) Unsigned" 等展示文字，
# 产物文件名固定使用基线版本，避免空格和 runner 构建描述污染文件名。
NAME="Tunnelblick-${TUNNELBLICK_REF#v}-openvpn-$EXPECTED_OVPN-unsigned"
ditto -c -k --keepParent "$APP" "$OUT_DIR/$NAME.zip"

# 实际 DMG 位于 build/Release/，原脚本匹配 build/*.dmg 会漏掉。
shopt -s nullglob
for f in tunnelblick/build/Release/*.dmg tunnelblick/build/Release/Signed/*.dmg; do
    base="$(basename "$f")"
    cp "$f" "$OUT_DIR/${base%.dmg}-openvpn-$EXPECTED_OVPN.dmg"
done
shopt -u nullglob

test -s "$OUT_DIR/$NAME.zip"
( cd "$OUT_DIR"; shopt -s nullglob; shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS.txt )
echo "=== 产物:"; ls -lh "$OUT_DIR"
