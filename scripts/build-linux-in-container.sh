#!/usr/bin/env bash
# 在容器里构建打过 peerinfo 补丁的 openvpn，打上 -xyN-YYYYMMDD 定制版本号。
# 默认静态链接（单文件、最大兼容）。
#
# 用法:  build-linux-in-container.sh <amd64|arm64>
#
# 约定环境变量:
#   OPENVPN_REF   上游 tag（默认 v2.7.7）
#   XY_VERSION    定制序号（默认 xy1）
#   XY_DATE       发版日期 YYYYMMDD（默认取构建当天 UTC；CI 会显式传入保持跨平台一致）
#   PATCH_FILE    peerinfo 补丁绝对路径（默认 /cust/patches/openvpn-peerinfo-spoof-2.7.7.patch）
#   OUT_DIR       产物目录（默认 /out）
#   STATIC        1=全静态单文件（默认 1）；0=动态链接
set -euo pipefail

ARCH="${1:?usage: $0 <amd64|arm64>}"
OPENVPN_REF="${OPENVPN_REF:-v2.7.7}"
XY_VERSION="${XY_VERSION:-xy1}"
XY_DATE="${XY_DATE:-$(date -u +%Y%m%d)}"
XY_SUFFIX="${XY_VERSION}-${XY_DATE}"
PATCH_FILE="${PATCH_FILE:-/cust/patches/openvpn-peerinfo-spoof-2.7.7.patch}"
OUT_DIR="${OUT_DIR:-/out}"
STATIC="${STATIC:-1}"

[[ "$XY_DATE" =~ ^[0-9]{8}$ ]] || { echo "ERROR: XY_DATE must be YYYYMMDD, got '$XY_DATE'"; exit 1; }

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates git build-essential autoconf automake libtool pkg-config \
    libssl-dev libcap-ng-dev liblz4-dev zlib1g-dev libzstd-dev python3-docutils file

WORK="$(mktemp -d /tmp/custovpn-XXXXXX)"
git clone --depth 1 --branch "$OPENVPN_REF" https://github.com/OpenVPN/openvpn.git "$WORK/openvpn"
cd "$WORK/openvpn"

git apply "$PATCH_FILE"

# 定制版本号：PRODUCT_VERSION_PATCH [.7] -> [.7-xy1-20260917]
# autotools 与 CMake 两套构建都从这一行拼 PACKAGE_VERSION（--version / IV_VER）。
sed -i -E \
    "s/^define\(\[PRODUCT_VERSION_PATCH\], \[([^]]+)\]\)/define([PRODUCT_VERSION_PATCH], [\1-${XY_SUFFIX}])/" \
    version.m4
grep -q "define(\[PRODUCT_VERSION_PATCH\], \[.*-${XY_SUFFIX}\])" version.m4 \
    || { echo "ERROR: version stamp failed"; exit 1; }
grep -n "PRODUCT_VERSION_PATCH" version.m4

autoreconf -i
CONFIGURE_ARGS=(--disable-systemd --disable-pkcs11 --disable-lzo --disable-dco --disable-plugin-auth-pam)
if [ "$STATIC" = "1" ]; then
    # 静态链接要点（本机已实测）：
    # 1) configure 阶段 LDFLAGS="-static"：让 openssl 等探测直接按静态方式链接，
    #    缺失的静态依赖（-lz/-lzstd）会立刻暴露；
    # 2) make 阶段必须覆盖 LDFLAGS="-all-static"：libtool 会把 "-static" 当自己的
    #    旗标吃掉（最终 gcc 命令里没有 -static），只有 "-all-static" 才会翻译成 gcc 的 -static；
    # 3) 静态 libcrypto 需要 -lz（新版 OpenSSL 还带 -lzstd）。
    OPENSSL_LIBS="-lssl -lcrypto -lz -lzstd" \
        ./configure "${CONFIGURE_ARGS[@]}" LDFLAGS="-static"
    make -j"$(nproc)" LDFLAGS="-all-static"
else
    ./configure "${CONFIGURE_ARGS[@]}"
    make -j"$(nproc)"
fi

VERSION="$(
    sed -n -E 's/^define\(\[PRODUCT_VERSION_MAJOR\], \[(.*)\]\)/\1/p' version.m4
).$(
    sed -n -E 's/^define\(\[PRODUCT_VERSION_MINOR\], \[(.*)\]\)/\1/p' version.m4
)$(
    sed -n -E 's/^define\(\[PRODUCT_VERSION_PATCH\], \[(.*)\]\)/\1/p' version.m4
)"
echo "custom version: $VERSION"
./src/openvpn/openvpn --version | head -1

if [ "$STATIC" = "1" ]; then
    echo "=== link check (expect: statically linked / not a dynamic executable):"
    file src/openvpn/openvpn || true
    ldd src/openvpn/openvpn 2>&1 | head -1 || true
    file src/openvpn/openvpn | grep -q "statically linked" \
        || { echo "ERROR: STATIC=1 但产物不是静态链接（拒绝出包）"; exit 1; }
fi

STAGE="$OUT_DIR/openvpn-$VERSION-linux-$ARCH"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/doc/openvpn"
install -m755 src/openvpn/openvpn "$STAGE/bin/openvpn"
install -m644 COPYING "$STAGE/share/doc/openvpn/COPYING"
{
    echo "OpenVPN $VERSION (custom custom build: peer-info fingerprint forwarding)"
    echo "target: linux/$ARCH"
    echo "source: OpenVPN/openvpn $OPENVPN_REF + $(basename "$PATCH_FILE")"
    echo "link: $([ "$STATIC" = "1" ] && echo "static (single file)" || echo "dynamic")"
    echo "build base: $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo
    echo "动态链接构建时目标机需提供 libssl(libcrypto) / liblz4 / libcap-ng；"
    echo "静态构建（默认）无运行时依赖。"
} > "$STAGE/README.txt"

tar -C "$OUT_DIR" -czf "$STAGE.tar.gz" "$(basename "$STAGE")"
( cd "$OUT_DIR" && sha256sum "$(basename "$STAGE").tar.gz" > "$(basename "$STAGE").tar.gz.sha256" )
find "$OUT_DIR" -maxdepth 1 -type f | sort