#!/usr/bin/env bash
# End-to-end test for custom peer-info forwarding.
# Starts a real OpenVPN server, connects with the packaged custom client,
# and verifies the server actually receives the device fingerprint fields.
set -euo pipefail

BIN="${1:?usage: $0 <path-to-openvpn>}"
EXPECTED_VERSION="${EXPECTED_VERSION:?EXPECTED_VERSION is required, e.g. 2.7.7-xy1-20260918}"
PORT="${E2E_PORT:-31194}"

BIN="$(realpath "$BIN")"
[[ -x "$BIN" ]] || { echo "ERROR: OpenVPN binary not executable: $BIN"; exit 1; }

if [[ -n "${E2E_WORK_DIR:-}" ]]; then
    WORK="$(realpath -m "$E2E_WORK_DIR")"
    rm -rf "$WORK"
    mkdir -p "$WORK"
else
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/custopenvpn-e2e.XXXXXX")"
fi
SERVER_PID=""
CLIENT_PID=""

cleanup() {
    set +e
    if [[ -n "$CLIENT_PID" ]]; then
        kill "$CLIENT_PID" 2>/dev/null || true
        wait "$CLIENT_PID" 2>/dev/null || true
    fi
    if [[ -f "$WORK/server.pid" ]]; then
        sudo kill "$(cat "$WORK/server.pid")" 2>/dev/null || true
    elif [[ -n "$SERVER_PID" ]]; then
        sudo kill "$SERVER_PID" 2>/dev/null || true
    fi
    sleep 1
    if [[ -f "$WORK/server.pid" ]]; then
        sudo kill -9 "$(cat "$WORK/server.pid")" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== E2E binary"
"$BIN" --version | head -1
"$BIN" --version | head -1 | grep -F "$EXPECTED_VERSION" >/dev/null || {
    echo "ERROR: packaged binary version does not contain $EXPECTED_VERSION"
    exit 1
}

if [[ ! -c /dev/net/tun ]]; then
    sudo modprobe tun 2>/dev/null || true
fi
[[ -c /dev/net/tun ]] || {
    echo "ERROR: /dev/net/tun is unavailable; server-mode E2E cannot run"
    exit 1
}

cd "$WORK"

# Server runs as root for TUN access. Pre-create diagnostics as the runner user
# so root only truncates/writes existing files instead of creating unreadable
# root-owned files. This also keeps upload-artifact able to collect failures.
touch server.log client-connect.env
chmod 0666 server.log client-connect.env

# Ephemeral CA + server/client certificates. Nothing leaves the CI runner.
openssl genrsa -out ca.key 2048 >/dev/null 2>&1
openssl req -x509 -new -key ca.key -sha256 -days 1     -subj "/CN=custOpenVPN-E2E-CA" -out ca.crt

openssl genrsa -out server.key 2048 >/dev/null 2>&1
openssl req -new -key server.key -subj "/CN=custOpenVPN-E2E-Server" -out server.csr
cat > server.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:custopenvpn-e2e-server
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial     -days 1 -sha256 -extfile server.ext -out server.crt >/dev/null

openssl genrsa -out client.key 2048 >/dev/null 2>&1
openssl req -new -key client.key -subj "/CN=custOpenVPN-E2E-Client" -out client.csr
cat > client.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl     -days 1 -sha256 -extfile client.ext -out client.crt >/dev/null

CAPTURE="$WORK/client-connect.env"
cat > capture-peerinfo.sh <<EOF
#!/usr/bin/env bash
set -u
: > "$CAPTURE"
rc=0
for key in IV_VER IV_PLAT IV_USER IV_INFO IV_DISK; do
    if value=\$(printenv "\$key" 2>/dev/null); then
        printf '%s=%s\\n' "\$key" "\$value" >> "$CAPTURE"
    else
        printf 'MISSING_%s=1\\n' "\$key" >> "$CAPTURE"
        rc=1
    fi
done
if value=\$(printenv IV_NOT_ALLOWED 2>/dev/null); then
    printf 'IV_NOT_ALLOWED=%s\\n' "\$value" >> "$CAPTURE"
    rc=1
fi
exit "\$rc"
EOF
chmod +x capture-peerinfo.sh

# Real multi-client OpenVPN server. Server mode intentionally uses a TUN
# device because that is the same code path that invokes --client-connect.
sudo "$BIN"     --dev tun     --topology subnet     --server 10.253.0.0 255.255.255.0     --local 127.0.0.1     --port "$PORT"     --proto udp4     --ca "$WORK/ca.crt"     --cert "$WORK/server.crt"     --key "$WORK/server.key"     --dh none     --duplicate-cn     --script-security 2     --client-connect "$WORK/capture-peerinfo.sh"     --verb 4     --log "$WORK/server.log"     --writepid "$WORK/server.pid" &
SERVER_PID=$!

for _ in $(seq 1 30); do
    if grep -q "Initialization Sequence Completed" "$WORK/server.log" 2>/dev/null; then
        break
    fi
    if ! sudo kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: OpenVPN server exited early"
        cat "$WORK/server.log" || true
        exit 1
    fi
    sleep 1
done
grep -q "Initialization Sequence Completed" "$WORK/server.log" || {
    echo "ERROR: OpenVPN server did not become ready"
    cat "$WORK/server.log" || true
    exit 1
}

IV_USER_VALUE="e2e_user_$(date -u +%s)"
IV_INFO_VALUE="e2e_info_linux_amd64"
IV_DISK_VALUE="e2e_disk_0123456789abcdef"
IV_PLAT_VALUE="e2e_custom_platform"
IV_BLOCKED_VALUE="must_not_cross_peerinfo"

# --client implies --pull, which sets push_peer_info_detail=2 in OpenVPN.
# That is important: the custom fields must work without requiring an
# additional --push-peer-info option.
"$BIN"     --client     --dev null     --ifconfig-noexec     --nobind     --remote 127.0.0.1 "$PORT"     --proto udp4     --ca "$WORK/ca.crt"     --cert "$WORK/client.crt"     --key "$WORK/client.key"     --remote-cert-tls server     --connect-retry 1 1     --connect-retry-max 2     --server-poll-timeout 5     --setenv IV_USER "$IV_USER_VALUE"     --setenv IV_INFO "$IV_INFO_VALUE"     --setenv IV_DISK "$IV_DISK_VALUE"     --setenv IV_PLAT "$IV_PLAT_VALUE"     --setenv IV_NOT_ALLOWED "$IV_BLOCKED_VALUE"     --verb 4     --log "$WORK/client.log"     --writepid "$WORK/client.pid" &
CLIENT_PID=$!

for _ in $(seq 1 30); do
    [[ -s "$CAPTURE" ]] && break
    if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
        echo "ERROR: OpenVPN client exited before server captured peer-info"
        cat "$WORK/client.log" || true
        cat "$WORK/server.log" || true
        exit 1
    fi
    sleep 1
done

[[ -s "$CAPTURE" ]] || {
    echo "ERROR: server client-connect hook did not capture an environment"
    cat "$WORK/client.log" || true
    cat "$WORK/server.log" || true
    exit 1
}

echo "=== captured peer-info"
grep -E '^(IV_(VER|PLAT|USER|INFO|DISK|NOT_ALLOWED)=)' "$CAPTURE" || true

assert_exact() {
    local key="$1"
    local value="$2"
    grep -Fx "$key=$value" "$CAPTURE" >/dev/null || {
        echo "ERROR: expected server env $key=$value"
        echo "--- capture ---"
        cat "$CAPTURE"
        echo "--- server log ---"
        cat "$WORK/server.log"
        exit 1
    }
}

assert_exact IV_USER "$IV_USER_VALUE"
assert_exact IV_INFO "$IV_INFO_VALUE"
assert_exact IV_DISK "$IV_DISK_VALUE"
assert_exact IV_PLAT "$IV_PLAT_VALUE"
assert_exact IV_VER "$EXPECTED_VERSION"

if grep -q '^IV_NOT_ALLOWED=' "$CAPTURE"; then
    echo "ERROR: non-whitelisted IV_NOT_ALLOWED crossed peer-info boundary"
    cat "$CAPTURE"
    exit 1
fi

# Protocol-level evidence from server parsing, independent of the hook snapshot.
for expected in     "IV_USER=$IV_USER_VALUE"     "IV_INFO=$IV_INFO_VALUE"     "IV_DISK=$IV_DISK_VALUE"     "IV_PLAT=$IV_PLAT_VALUE"     "IV_VER=$EXPECTED_VERSION"; do
    grep -F "peer info: $expected" "$WORK/server.log" >/dev/null || {
        echo "ERROR: server log does not show peer info: $expected"
        cat "$WORK/server.log"
        exit 1
    }
done

for _ in $(seq 1 15); do
    grep -q "Initialization Sequence Completed" "$WORK/client.log" 2>/dev/null && break
    kill -0 "$CLIENT_PID" 2>/dev/null || break
    sleep 1
done
grep -q "Initialization Sequence Completed" "$WORK/client.log" || {
    echo "ERROR: TLS/VPN client session never completed initialization"
    cat "$WORK/client.log"
    cat "$WORK/server.log" || true
    exit 1
}
cp "$CAPTURE" "$WORK/client-connect-valid.env"

# End the accepted client before the rejection case.
kill "$CLIENT_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true
CLIENT_PID=""
rm -f "$WORK/client.pid" "$CAPTURE"

# Negative case: omit IV_DISK. The same server-side gate must reject it.
"$BIN" \
    --client \
    --dev null \
    --ifconfig-noexec \
    --nobind \
    --remote 127.0.0.1 "$PORT" \
    --proto udp4 \
    --ca "$WORK/ca.crt" \
    --cert "$WORK/client.crt" \
    --key "$WORK/client.key" \
    --remote-cert-tls server \
    --connect-retry 1 1 \
    --connect-retry-max 1 \
    --server-poll-timeout 5 \
    --setenv IV_USER "negative_missing_disk_user" \
    --setenv IV_INFO "negative_missing_disk_info" \
    --setenv IV_PLAT "$IV_PLAT_VALUE" \
    --verb 4 \
    --log "$WORK/client-missing-disk.log" \
    --writepid "$WORK/client-missing-disk.pid" &
CLIENT_PID=$!

for _ in $(seq 1 20); do
    [[ -s "$CAPTURE" ]] && break
    kill -0 "$CLIENT_PID" 2>/dev/null || break
    sleep 1
done

[[ -s "$CAPTURE" ]] || {
    echo "ERROR: missing-IV_DISK case never reached server validator"
    cat "$WORK/client-missing-disk.log" || true
    cat "$WORK/server.log" || true
    exit 1
}
cp "$CAPTURE" "$WORK/client-connect-missing-disk.env"

grep -Fx 'MISSING_IV_DISK=1' "$CAPTURE" >/dev/null || {
    echo "ERROR: negative test did not prove IV_DISK was missing"
    cat "$CAPTURE"
    exit 1
}
if grep -q '^IV_DISK=' "$CAPTURE"; then
    echo "ERROR: negative test unexpectedly delivered IV_DISK"
    cat "$CAPTURE"
    exit 1
fi

# Give OpenVPN a moment to process the client-connect rejection.
sleep 2
if grep -q "Initialization Sequence Completed" "$WORK/client-missing-disk.log"; then
    echo "ERROR: client without IV_DISK was accepted"
    cat "$WORK/client-missing-disk.log"
    exit 1
fi

kill "$CLIENT_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true
CLIENT_PID=""

echo "PASS: complete device fingerprint was accepted end-to-end"
echo "PASS: missing IV_DISK was rejected by the server-side compatibility gate"
echo "PASS: non-whitelisted IV_NOT_ALLOWED was not forwarded"
