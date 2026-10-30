#!/usr/bin/env bash
# Test the delivered core over loopback TLS without configuring interfaces.
# macOS callers select each Universal 2 slice with E2E_ARCH (Rosetta for x86_64).
set -euo pipefail

BIN="${1:?usage: $0 <path-to-openvpn>}"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
: "${EXPECTED_VERSION:?EXPECTED_VERSION is required}"
PORT="${E2E_PORT:-31195}"
RUN=("$BIN")
if [[ -n "${E2E_ARCH:-}" ]]; then
    [[ "$(uname -s)" = Darwin ]] || { echo 'E2E_ARCH requires macOS'; exit 1; }
    RUN=(/usr/bin/arch "-$E2E_ARCH" "$BIN")
fi
if [[ -n "${E2E_DEVICE_FIXTURE_LIB:-}" ]]; then
    [[ "$(uname -s)" = Darwin && -f "$E2E_DEVICE_FIXTURE_LIB" ]] || { echo 'Invalid test-only device provider'; exit 1; }
    RUN=(/usr/bin/env "DYLD_INSERT_LIBRARIES=$E2E_DEVICE_FIXTURE_LIB" "$BIN")
    if [[ -n "${E2E_ARCH:-}" ]]; then
        RUN=(/usr/bin/arch "-$E2E_ARCH" "${RUN[@]}")
    fi
    echo 'TEST ONLY: synthetic IOKit storage provider; this core copy and dylib are not packaged'
fi

mkdir -p "${E2E_WORK_DIR:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "${E2E_WORK_DIR:-${TMPDIR:-/tmp}}/tls.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
SERVER_PID=""
CLIENT_PID=""
cleanup() {
    rc=$?
    trap - EXIT
    if [[ "$rc" != 0 ]]; then
        cat "$WORK/server.log" "$WORK/client.log" 2>/dev/null || true
    fi
    for pid in "$CLIENT_PID" "$SERVER_PID"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -f "$WORK/ca.key" "$WORK/server.key" "$WORK/client.key"
    exit "$rc"
}
trap cleanup EXIT

version="$("${RUN[@]}" --version | sed -n '1p')"
[[ "$version" = "OpenVPN $EXPECTED_VERSION "* ]] || {
    echo "ERROR: unexpected version: $version"; exit 1;
}
echo "$version"
if native_info="$("${RUN[@]}" --show-system-disk 2>&1)"; then
    printf '%s\n' "$native_info" > "$WORK/system-disk.log"
else
    printf '%s\n' "$native_info" | tee "$WORK/system-disk.log"
    exit 1
fi
NATIVE_DISK="$(sed -n 's/^IV_DISK=//p' <<<"$native_info")"
[[ -n "$NATIVE_DISK" && "$NATIVE_DISK" != *$'\n'* ]] || { echo 'Invalid native disk diagnostic'; exit 1; }
if [[ -n "${E2E_DEVICE_FIXTURE_LIB:-}" ]]; then
    [[ "$NATIVE_DISK" = CI-SYNTHETIC-MAC-SYSTEM-DISK ]] || { echo 'Test provider was not loaded'; exit 1; }
fi
cd "$WORK"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt \
    -days 1 -subj /CN=XY-TLS-CI-CA >/dev/null 2>&1
for role in server client; do
    openssl req -newkey rsa:2048 -nodes -keyout "$role.key" -out "$role.csr" \
        -subj "/CN=XY-TLS-CI-$role" >/dev/null 2>&1
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=%sAuth\n' \
        "$role" > "$role.ext"
    openssl x509 -req -in "$role.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -days 1 -extfile "$role.ext" -out "$role.crt" >/dev/null 2>&1
done

COMMON=(--dev null --ifconfig-noexec --route-noexec --proto udp4
    --ca ca.crt --data-ciphers AES-256-GCM --verb 4)
"${RUN[@]}" "${COMMON[@]}" --tls-server --local 127.0.0.1 --port "$PORT" \
    --ifconfig 10.253.0.1 10.253.0.2 --cert server.crt --key server.key --dh none \
    --log server.log &
SERVER_PID=$!
"${RUN[@]}" "${COMMON[@]}" --tls-client --push-peer-info --nobind \
    --remote 127.0.0.1 "$PORT" --ifconfig 10.253.0.2 10.253.0.1 \
    --cert client.crt --key client.key --remote-cert-tls server \
    --setenv IV_USER tls_test_user --setenv IV_INFO tls_test_uuid \
    --setenv IV_PLAT tls_test_platform \
    --setenv IV_NOT_ALLOWED must_not_be_forwarded --log client.log &
CLIENT_PID=$!

for _ in {1..40}; do
    if grep -q 'Initialization Sequence Completed' server.log 2>/dev/null \
        && grep -q 'Initialization Sequence Completed' client.log 2>/dev/null; then
        break
    fi
    if ! kill -0 "$SERVER_PID" || ! kill -0 "$CLIENT_PID"; then
        echo 'ERROR: TLS peer exited before handshake completed'; exit 1
    fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' server.log
grep -q 'Initialization Sequence Completed' client.log

# Exact values also reject duplicate fields (sed would yield multiple lines).
for pair in "IV_VER=$EXPECTED_VERSION" IV_USER=tls_test_user IV_INFO=tls_test_uuid \
    "IV_DISK=$NATIVE_DISK" IV_PLAT=tls_test_platform; do
    key="${pair%%=*}"
    actual="$(sed -n "s/.*peer info: $key=//p" server.log)"
    [[ "$actual" = "${pair#*=}" ]] || {
        echo "ERROR: server did not receive exactly $pair (got '$actual')"; exit 1;
    }
done
if grep -q 'peer info: IV_NOT_ALLOWED=' server.log; then
    echo 'ERROR: non-whitelisted field crossed peer-info boundary'; exit 1
fi
# A profile cannot substitute a data disk or inject a second disk field.
"${RUN[@]}" "${COMMON[@]}" --tls-client --nobind --remote 127.0.0.1 "$PORT" \
    --ifconfig 10.253.0.2 10.253.0.1 --cert client.crt --key client.key \
    --remote-cert-tls server --setenv IV_DISK forged_data_disk --log conflict.log &
CONFLICT_PID=$!
for _ in {1..10}; do
    kill -0 "$CONFLICT_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$CONFLICT_PID" 2>/dev/null; then
    kill "$CONFLICT_PID"; wait "$CONFLICT_PID" || true
    echo 'ERROR: identity override did not fail before handshake'; exit 1
fi
if wait "$CONFLICT_PID"; then echo 'ERROR: identity override returned success'; exit 1; fi
grep -q 'SYSTEM_DISK_CONFIG_CONFLICT' conflict.log
echo "PASS: ${E2E_ARCH:-native} native system-disk TLS, exact peer-info, whitelist and override rejection" | tee result.log
