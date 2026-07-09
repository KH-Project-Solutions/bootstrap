#!/usr/bin/env bash
# kh-svm-bootstrap.sh — provision a fresh Debian 13 host and install kh-svm.
#
#   curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/public-tools/main/kh-svm-bootstrap.sh | sudo bash
#
# Public entry point for the private kh-svm. Prompts for a KH-ServiceBot PAT
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

echo
echo "✓ Host provisioned. kh-svm installed at ${INSTALL_PATH}."
if [[ "$TARGET_USER" != "root" ]]; then
    echo "  Log out and back in (or: newgrp docker) so '${TARGET_USER}' can use docker."
fi
echo "  Next: kh-svm doctor && kh-svm deploy <org/repo>"
