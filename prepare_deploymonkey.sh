#!/usr/bin/env bash
# prepare_deploymonkey.sh — provision (or lock down) a fresh deploy host.
#
#   sudo ./prepare_deploymonkey.sh              # open root SSH with a fresh password
#   sudo ./prepare_deploymonkey.sh --finalize   # blank root password, close root SSH
#
set -euo pipefail

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-deploymonkey.conf

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

restart_sshd() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

if [[ "${1:-}" == "--finalize" ]]; then
    passwd -d root                          # blank root password
    printf 'PermitRootLogin no\n' > "$SSHD_DROPIN"
    restart_sshd
    echo "Finalized: root password blanked, root SSH login disabled."
    exit 0
fi

apt-get update && apt-get upgrade -y

# 32-char password from the kernel CSPRNG (base64, trimmed to 32 chars).
PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
echo "root:${PASSWORD}" | chpasswd

printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$SSHD_DROPIN"
restart_sshd

echo "Root SSH enabled. Root password:"
echo "    ${PASSWORD}"
echo "Run '$0 --finalize' when you are done to lock the host back down."
