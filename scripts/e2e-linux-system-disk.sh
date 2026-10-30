#!/usr/bin/env bash
# Run the final artifact against native hardware, where available, and against
# an isolated multi-disk sysfs topology. No fixture interface enters the binary.
set -euo pipefail

if [[ "${1:-}" = --inside ]]; then
    fixture="$2"
    bin="$3"
    repo="$4"
    work="$5"
    expected="$6"
    mount --bind "$fixture" /sys
    mount -o remount,bind,ro /sys
    EXPECTED_VERSION="$expected" E2E_WORK_DIR="$work/fixture" \
        bash "$repo/scripts/e2e-peerinfo.sh" "$bin"
    grep -Fx 'IV_DISK=CI-SYNTHETIC-SYSTEM-DISK-9' "$work/fixture/client-connect-valid.env"

    # Even a usable data disk must not rescue an unavailable system-disk ID.
    printf '\n' > "$fixture/devices/block/nvme9n1/serial"
    if "$bin" --show-system-disk > "$work/serial-missing.log" 2>&1; then
        echo 'ERROR: missing system serial was replaced by another disk'; exit 1
    fi
    grep -q 'SYSTEM_DISK_ERROR.*serial-invalid' "$work/serial-missing.log"
    printf 'CI-SYNTHETIC-SYSTEM-DISK-9\n' > "$fixture/devices/block/nvme9n1/serial"
    "$bin" --show-system-disk > "$work/serial-restored.log"
    grep -Fx 'IV_DISK=CI-SYNTHETIC-SYSTEM-DISK-9' "$work/serial-restored.log"
    # The collected ID stays raw; the upstream server sanitizes internal spaces.
    printf 'CI SYSTEM DISK 9\n' > "$fixture/devices/block/nvme9n1/serial"
    EXPECTED_VERSION="$expected" E2E_WORK_DIR="$work/fixture-spaces" \
        bash "$repo/scripts/e2e-peerinfo.sh" "$bin"
    grep -Fx 'IV_DISK=CI SYSTEM DISK 9' "$work/fixture-spaces/system-disk.log"
    grep -Fx 'IV_DISK=CI_SYSTEM_DISK_9' "$work/fixture-spaces/client-connect-valid.env"
    echo 'PASS: final artifact selects only the system disk, rejects missing ID and recovers after fixture restoration'
    exit
fi

BIN="$(realpath "${1:?usage: $0 <final-openvpn-binary>}")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${EXPECTED_VERSION:?EXPECTED_VERSION is required}"
WORK="${E2E_WORK_DIR:-$PWD/e2e-peerinfo-logs}"
mkdir -p "$WORK"
WORK="$(realpath "$WORK")"

if "$BIN" --show-system-disk > "$WORK/native-system-disk.log" 2>&1; then
    E2E_WORK_DIR="$WORK/native" bash "$REPO/scripts/e2e-peerinfo.sh" "$BIN"
    echo 'PASS: runner native system-disk collector and TLS handshake'
else
    grep -q 'SYSTEM_DISK_ERROR:' "$WORK/native-system-disk.log"
    echo 'Runner exposes no supported native disk ID; rejection recorded. Synthetic topology TLS below is separate evidence.'
fi

FIXTURE="$(mktemp -d)"
cleanup_fixture() {
    local rc=$?
    trap - EXIT
    # The unchanged artifact runs as root inside the private namespace; GitHub's
    # artifact uploader runs as the runner user and must be able to read logs.
    if ! sudo chown -R "$(id -u):$(id -g)" "$WORK"; then rc=1; fi
    rm -rf "$FIXTURE"
    exit "$rc"
}
trap cleanup_fixture EXIT
python3 - "$FIXTURE" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
device = os.stat('/').st_dev
if not os.major(device):
    raise SystemExit('Fixture E2E requires a block-backed runner root')
(root / 'dev/block').mkdir(parents=True)
for name, serial in [('sda', 'CI-DATA-DISK-DO-NOT-SELECT'), ('nvme9n1', 'CI-SYNTHETIC-SYSTEM-DISK-9')]:
    disk = root / 'devices/block' / name
    (disk / 'slaves').mkdir(parents=True)
    (disk / 'serial').write_text(serial + '\n')
partition = root / 'devices/block/nvme9n1/nvme9n1p2'
partition.mkdir()
(partition / 'partition').write_text('2\n')
(root / 'dev/block' / f'{os.major(device)}:{os.minor(device)}').symlink_to(partition)
PY
chmod -R a+rX "$FIXTURE"
sudo unshare --mount --propagation private \
    bash "$0" --inside "$FIXTURE" "$BIN" "$REPO" "$WORK" "$EXPECTED_VERSION"
