#!/usr/bin/env bash
# Validate the exact packaged app, including explicit native rejection on VMs.
set -euo pipefail
CUST_DIR="${CUST_DIR:?CUST_DIR is required}"
EXPECTED_OVPN="${EXPECTED_OVPN:?EXPECTED_OVPN is required}"
APP="${1:?usage: $0 <Tunnelblick.app>}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[[ -d "$APP" ]] || { echo 'Missing packaged application'; exit 1; }
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

    if grep -a -q 'CI-SYNTHETIC-MAC-SYSTEM-DISK' "$bin"; then
        echo 'ERROR: test-only provider marker entered the shipped core'; exit 1
    fi
    original_hash="$(shasum -a 256 "$bin")"

    # Validate the unmodified delivered core first. Hosted macOS VMs do not
    # necessarily expose a real disk serial: rejection is required evidence.
    for cpu in arm64 x86_64; do
        case_dir="$PWD/e2e-peerinfo-logs/$(basename "$(dirname "$bin")")-$cpu"
        mkdir -p "$case_dir"
        if /usr/bin/arch "-$cpu" "$bin" --show-system-disk > "$case_dir/native-system-disk.log" 2>&1; then
            EXPECTED_VERSION="$EXPECTED_OVPN" E2E_ARCH="$cpu" \
            E2E_WORK_DIR="$case_dir" \
                bash "$CUST_DIR/scripts/e2e-peerinfo-tls.sh" "$bin"
        else
            cat "$case_dir/native-system-disk.log"
            grep -Eq '^SYSTEM_DISK_ERROR: stage=mac-(system-disk-not-physical|system-disk-serial-unavailable-or-invalid)' \
                "$case_dir/native-system-disk.log" || { echo 'Unexpected native collection failure'; exit 1; }
            echo 'CI virtual storage rejected. TLS serialization uses a separate, non-shipping IOKit provider.'
            fixture_dir="$(mktemp -d)"
            clang -arch "$cpu" -std=c11 -Wall -Wextra -Werror -dynamiclib \
                "$CUST_DIR/tests/unix-system-disk/macos-tls-fixture.c" \
                -framework CoreFoundation -framework IOKit -o "$fixture_dir/provider.dylib"
            cp "$bin" "$fixture_dir/openvpn-test-only"
            # Remove runtime library validation on the test copy alone. The
            # packaged app and its original core are never modified.
            codesign --force --sign - "$fixture_dir/openvpn-test-only"
            codesign --force --sign - "$fixture_dir/provider.dylib"
            EXPECTED_VERSION="$EXPECTED_OVPN" E2E_ARCH="$cpu" \
            E2E_DEVICE_FIXTURE_LIB="$fixture_dir/provider.dylib" E2E_WORK_DIR="$case_dir" \
                bash "$CUST_DIR/scripts/e2e-peerinfo-tls.sh" "$fixture_dir/openvpn-test-only"
            rm -rf "$fixture_dir"
        fi
    done
    [[ "$(shasum -a 256 "$bin")" = "$original_hash" ]] || { echo 'ERROR: validation modified shipped core'; exit 1; }
done
