#!/usr/bin/env bash
# kh-svm.sh — provision a fresh Debian 13 host and install kh-svm.
#
#   curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/kh-svm.sh | sudo bash
#
# Public entry point for the private kh-svm. Synced automatically to the public
# KH-Project-Solutions/bootstrap repo — edit here, not there. Prompts for a KH-ServiceBot PAT
# (repo scope) to pull the private release binary. The PAT is used only for that
# download and never written to disk; `kh-svm deploy` prompts for it again later.
# For unattended runs, pre-set KH_SVM_PAT in the environment to skip the prompt.
set -euo pipefail

KH_SVM_REPO="${KH_SVM_REPO:-KH-Project-Solutions/kh-svm}"
INSTALL_PATH=/usr/local/bin/kh-svm

if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root — pipe it to sudo: … | sudo bash" >&2
    exit 1
fi

# PAT: from the environment (unattended) or prompted from the terminal. We read
# /dev/tty rather than stdin so the prompt works under `curl … | sudo bash`,
# where stdin is the script itself.
if [[ -z "${KH_SVM_PAT:-}" ]]; then
    if [[ -r /dev/tty ]]; then
        read -rsp "KH-ServiceBot PAT (repo scope): " KH_SVM_PAT < /dev/tty
        echo >&2
    fi
fi
if [[ -z "${KH_SVM_PAT:-}" ]]; then
    echo "No PAT provided (no terminal to prompt on; set KH_SVM_PAT instead)." >&2
    exit 1
fi

# The user to add to the docker group — the human behind sudo, not root.
TARGET_USER="${SUDO_USER:-root}"

# Debian 13 (Trixie) only.
. /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
    echo "Unsupported OS: ${PRETTY_NAME:-unknown}. kh-svm supports Debian 13 (Trixie) only." >&2
    exit 1
fi

apt-get update
apt-get install -y ca-certificates curl git jq

# Docker engine via the official convenience script (idempotent — skips if present).
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# Let the operator run docker without sudo (takes effect on next login).
if [[ "$TARGET_USER" != "root" ]]; then
    usermod -aG docker "$TARGET_USER"
fi

# Fetch the private kh-svm binary from the latest GitHub Release. The PAT's
# `repo` scope authorizes both the release lookup and the asset download.
API="https://api.github.com/repos/${KH_SVM_REPO}/releases/latest"
ASSET_ID=$(curl -fsSL -H "Authorization: Bearer ${KH_SVM_PAT}" \
    -H "Accept: application/vnd.github+json" "$API" \
    | jq -r '.assets[] | select(.name=="kh-svm") | .id')
if [[ -z "$ASSET_ID" || "$ASSET_ID" == "null" ]]; then
    echo "No 'kh-svm' asset in the latest release of ${KH_SVM_REPO} (check the token and that a release exists)." >&2
    exit 1
fi
curl -fsSL -H "Authorization: Bearer ${KH_SVM_PAT}" -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/${KH_SVM_REPO}/releases/assets/${ASSET_ID}" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# ── Daemon service (kh-svm daemon) under a dedicated user ────────────────────
# The daemon owns the state and all docker orchestration. Running it as a system
# user in the docker group sidesteps the docker-group re-login problem for the
# service itself: systemd can start it immediately.
if ! id khsvm >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/khsvm --shell /usr/sbin/nologin khsvm
fi
usermod -aG docker khsvm
# State dir (owned by khsvm; the binary defaults here — see kh-svm state.rs).
install -d -o khsvm -g khsvm -m 0750 /var/lib/khsvm

# ── Caddy: reverse proxy for kh-svm instances (kh-svm bind-domain) ───────────
# Instances listen on 127.0.0.1 only; Caddy is the public front (TLS + vhosts).
# kh-svm writes one site file per instance into /etc/caddy/khsvm/ and reloads
# Caddy via its admin API — so the khsvm daemon needs no root, only ownership of
# that drop-in dir. The main Caddyfile just imports it.
if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi
# Per-instance drop-in dir, owned by the daemon user so bind-domain can write it.
install -d -o khsvm -g khsvm -m 0755 /etc/caddy/khsvm
# Ensure the main Caddyfile imports the drop-in dir (idempotent).
touch /etc/caddy/Caddyfile
if ! grep -q '^import /etc/caddy/khsvm/' /etc/caddy/Caddyfile; then
    echo 'import /etc/caddy/khsvm/*.caddy' >> /etc/caddy/Caddyfile
fi
systemctl enable --now caddy
systemctl reload caddy 2>/dev/null || true

# systemd unit. RuntimeDirectory gives the daemon a writable /run/khsvm for its
# socket; 0755 so the operator can traverse it, while the socket itself is
# group-docker 0660 (set by the daemon) — same trust boundary as docker.
cat > /etc/systemd/system/khsvmd.service <<UNIT
[Unit]
Description=kh-svm daemon (Odoo production manager)
Requires=docker.service
After=docker.service

[Service]
User=khsvm
Group=khsvm
RuntimeDirectory=khsvm
RuntimeDirectoryMode=0755
ExecStart=${INSTALL_PATH} daemon
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now khsvmd

echo
echo "✓ Host provisioned. kh-svm installed at ${INSTALL_PATH}; khsvmd running."
if [[ "$TARGET_USER" != "root" ]]; then
    echo "  Log out and back in (or: newgrp docker) so '${TARGET_USER}' can use docker + kh-svm."
fi
echo "  Next: kh-svm doctor && kh-svm deploy <name>"
