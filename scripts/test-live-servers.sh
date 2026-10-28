#!/usr/bin/env bash
# Runs the remote sources against real servers on this Mac:
#   S3   a RustFS container (docker run rustfs/rustfs:1.0.3), filled with the MinIO client
#   SFTP a private sshd as you, on 127.0.0.1:22222, with a key and host key made for this run
# FTP, FTPS and FTPES need nothing extra: `swift test` runs them against Tests/.../ftps_server.py.
#
# Needs Docker (or OrbStack); docker pulls rustfs/rustfs and pgsty/mc when they are not there yet.
# Nothing outside a temporary folder is changed, and everything is stopped and removed at the end.
set -euo pipefail

cd "$(dirname "$0")/.."
# Under /private/tmp, spelled out: Docker can mount it, unlike the per-user temporary folder,
# and plain /tmp means the VM's own /tmp to OrbStack.
work="$(cd "$(mktemp -d /tmp/moire-live.XXXXXX)" && pwd -P)"
container="moire-live-s3-$$"
sshd_pid=""
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    if [ -n "$sshd_pid" ]; then kill "$sshd_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# Files to compare: the same tree is served and kept locally.
data="$work/data"
mkdir -p "$data/src/deep" "$data/with space"
echo hello > "$data/a.txt"
: > "$data/empty.txt"
head -c 3000000 /dev/urandom > "$data/src/deep/big.bin"
echo "é" > "$data/with space/naïve café.txt"

echo "S3: starting RustFS…"
docker run -d --name "$container" -p 19000:9000 \
    -e RUSTFS_ACCESS_KEY=moiretest -e RUSTFS_SECRET_KEY=moiretestsecret123 rustfs/rustfs:1.0.3 >/dev/null
sleep 6
docker run --rm -v "$data":/src --entrypoint sh pgsty/mc -c \
    "mc alias set t http://host.docker.internal:19000 moiretest moiretestsecret123 >/dev/null && mc mb t/moire >/dev/null && mc cp -r /src/ t/moire/copy/ >/dev/null"
AWS_ACCESS_KEY_ID=moiretest AWS_SECRET_ACCESS_KEY=moiretestsecret123 \
MOIRE_TEST_REMOTE_URL=s3://moire/copy MOIRE_TEST_REMOTE_LOCAL="$data" \
MOIRE_TEST_S3_ENDPOINT=http://localhost:19000 MOIRE_TEST_S3_REGION=us-east-1 \
    swift test --filter LiveServerTests

echo "SFTP: starting a private sshd…"
ssh="$work/sshd"
mkdir -m 700 "$ssh"
ssh-keygen -q -t ed25519 -N "" -f "$ssh/host_key"
ssh-keygen -q -t ed25519 -N "" -f "$ssh/client_key"
cp "$ssh/client_key.pub" "$ssh/authorized_keys"
cat > "$ssh/sshd_config" <<CONFIG
Port 22222
ListenAddress 127.0.0.1
HostKey $ssh/host_key
AuthorizedKeysFile $ssh/authorized_keys
PidFile $ssh/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
CONFIG
/usr/sbin/sshd -f "$ssh/sshd_config" -E "$ssh/sshd.log"
sleep 1
sshd_pid="$(cat "$ssh/sshd.pid")"
MOIRE_TEST_SSHD_PORT=22222 MOIRE_TEST_SSHD_KEY="$ssh/client_key" MOIRE_TEST_SSHD_KNOWN_HOSTS="$ssh/known_hosts" \
    swift test --filter LiveSSHTests

echo "All live server tests passed."
