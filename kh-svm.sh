#!/usr/bin/env bash
# kh-svm.sh — provision a fresh Debian 13 host and install kh-svm.
#
#   curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/kh-svm.sh | sudo bash
#
# Public entry point for the private kh-svm. Synced automatically to the public
# KH-Project-Solutions/bootstrap repo — edit here, not there. Prompts for a KH-ServiceBot PAT
# (repo scope) to pull the private release binary; it's then persisted on the
# host via `kh-svm daemon set-auth-token` (obfuscated, khsvm-only file) so deploy/update
# and the Cockpit plugin work without re-prompting.
# For unattended runs, pre-set KH_SVM_PAT in the environment to skip the prompt.
set -euo pipefail

KH_SVM_REPO="${KH_SVM_REPO:-KH-Project-Solutions/kh-svm}"
INSTALL_PATH=/usr/local/bin/kh-svm

# Colored progress (honors NO_COLOR and non-tty). Messages go to stderr so they
# never mingle with any captured stdout.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_STEP=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'
else
    C_RESET=; C_STEP=; C_OK=; C_WARN=
fi
section() { printf '\n%s» %s%s\n' "$C_STEP" "$*" "$C_RESET" >&2; }
ok()      { printf '%s✓ %s%s\n'   "$C_OK"   "$*" "$C_RESET" >&2; }
warn()    { printf '%s! %s%s\n'   "$C_WARN" "$*" "$C_RESET" >&2; }

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

section "Installing base packages (apt)"
apt-get update
apt-get install -y ca-certificates curl git jq

# Docker engine via the official convenience script (idempotent — skips if present).
section "Installing Docker"
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
section "Installing kh-svm binary"
API="https://api.github.com/repos/${KH_SVM_REPO}/releases/latest"
# Keep the whole release JSON — the Cockpit plugin asset is fetched from it later.
RELEASE_JSON=$(curl -fsSL -H "Authorization: Bearer ${KH_SVM_PAT}" \
    -H "Accept: application/vnd.github+json" "$API")
ASSET_ID=$(jq -r '.assets[] | select(.name=="kh-svm") | .id' <<<"$RELEASE_JSON")
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

# ── Caddy: reverse proxy for kh-svm instances (kh-svm domain bind) ───────────
# Instances listen on 127.0.0.1 only; Caddy is the public front (TLS + vhosts).
# kh-svm writes one site file per instance into /etc/caddy/khsvm/ and reloads
# Caddy via its admin API — so the khsvm daemon needs no root, only ownership of
# that drop-in dir. The main Caddyfile just imports it.
section "Installing Caddy (reverse proxy)"
if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi
# Per-instance drop-in dir, owned by the daemon user so `domain bind` can write it.
install -d -o khsvm -g khsvm -m 0755 /etc/caddy/khsvm
# Ensure the main Caddyfile imports the drop-in dir (idempotent).
touch /etc/caddy/Caddyfile
if ! grep -q '^import /etc/caddy/khsvm/' /etc/caddy/Caddyfile; then
    echo 'import /etc/caddy/khsvm/*.caddy' >> /etc/caddy/Caddyfile
fi
systemctl enable --now caddy
systemctl reload caddy 2>/dev/null || true

# ── Cockpit: host admin UI, localhost-only behind Caddy ──────────────────────
# Bound to 127.0.0.1:9090 with TLS off — Caddy is the sole public front
# (kh-svm domain bind-admin), same posture as instances. --no-install-recommends
# keeps NetworkManager/packagekit off a server that manages its own networking.
section "Installing Cockpit (admin UI)"
apt-get install -y --no-install-recommends cockpit
install -d /etc/systemd/system/cockpit.socket.d
cat > /etc/systemd/system/cockpit.socket.d/khsvm.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
EOF
# Plain HTTP on loopback; Caddy terminates TLS. cockpit-ws's path varies across
# releases, so resolve it.
WS_BIN=/usr/libexec/cockpit-ws
[[ -x $WS_BIN ]] || WS_BIN=/usr/lib/cockpit/cockpit-ws
install -d /etc/systemd/system/cockpit.service.d
cat > /etc/systemd/system/cockpit.service.d/khsvm.conf <<EOF
[Service]
ExecStart=
ExecStart=${WS_BIN} --no-tls
EOF
# Trust Caddy's forwarded proto/IP so origin checks and logs work under the
# https admin domain. Written once — don't clobber operator edits on rerun.
if [[ ! -e /etc/cockpit/cockpit.conf ]]; then
    install -d /etc/cockpit
    cat > /etc/cockpit/cockpit.conf <<'EOF'
[WebService]
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For
EOF
fi
systemctl daemon-reload
systemctl enable --now cockpit.socket
systemctl try-restart cockpit.service 2>/dev/null || true

# kh-svm Cockpit plugin, from the same release as the binary (static files —
# Cockpit picks them up on page load, no restart). Absent on pre-plugin
# releases; `kh-svm daemon upgrade` refreshes it alongside the binary.
PLUGIN_ID=$(jq -r '.assets[] | select(.name=="khsvm-cockpit.tar.gz") | .id' <<<"$RELEASE_JSON")
if [[ -n "$PLUGIN_ID" && "$PLUGIN_ID" != "null" ]]; then
    rm -rf /usr/share/cockpit/khsvm
    install -d /usr/share/cockpit/khsvm
    curl -fsSL -H "Authorization: Bearer ${KH_SVM_PAT}" -H "Accept: application/octet-stream" \
        "https://api.github.com/repos/${KH_SVM_REPO}/releases/assets/${PLUGIN_ID}" \
        | tar -xz -C /usr/share/cockpit/khsvm
else
    warn "latest release has no khsvm-cockpit.tar.gz — Cockpit plugin skipped"
fi

# systemd unit. RuntimeDirectory gives the daemon a writable /run/khsvm for its
# socket; 0755 so the operator can traverse it, while the socket itself is
# group-docker 0660 (set by the daemon) — same trust boundary as docker.
section "Configuring the khsvmd service"
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
ExecStart=${INSTALL_PATH} daemon run
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now khsvmd

# Wait briefly for the daemon socket so the deploy below goes through the daemon
# (as khsvm), not the root in-process fallback (which would create khsvm-owned
# state as root). Best-effort — proceed after ~5s regardless.
for _ in $(seq 1 25); do
    [[ -S /run/khsvm/khsvmd.sock ]] && break
    sleep 0.2
done

# Persist the PAT on the host (kh-svm set-gh-token → /var/lib/khsvm/.ghtoken):
# deploy/update and the Cockpit plugin then work without a tty. Goes through the
# daemon (running as khsvm) so the file lands khsvm-owned; the chown covers the
# in-process fallback (root-owned would be unreadable to the daemon).
section "Storing the GitHub token"
KH_SVM_PAT="$KH_SVM_PAT" "$INSTALL_PATH" daemon set-auth-token \
    || warn "set-auth-token failed — store it later: kh-svm daemon set-auth-token"
chown khsvm:khsvm /var/lib/khsvm/.ghtoken 2>/dev/null || true

ok "Host provisioned. kh-svm installed at ${INSTALL_PATH}; khsvmd running."

# Offer the guided first deploy right here (we agreed the bootstrap should hand
# straight off to it). Runs as root — root reaches the group-docker socket, and
# </dev/tty gives the interactive picker + PAT prompt a real terminal even though
# this script arrived over `curl | bash`. Skippable with KH_SVM_SKIP_DEPLOY=1.
if [[ -r /dev/tty && -z "${KH_SVM_SKIP_DEPLOY:-}" ]]; then
    printf '\n%sDeploy a project now?%s [Y/n] ' "$C_STEP" "$C_RESET" > /dev/tty
    read -r ans < /dev/tty || ans=""
    case "${ans:-Y}" in
        [Nn]*) : ;;
        *) "$INSTALL_PATH" instance deploy --interactive < /dev/tty \
               || warn "deploy didn't complete — rerun later: kh-svm instance deploy --interactive" ;;
    esac
fi

if [[ "$TARGET_USER" != "root" ]]; then
    warn "Log out and back in (or: newgrp docker) so '${TARGET_USER}' can use docker + kh-svm."
fi
echo "  Next: kh-svm doctor && kh-svm instance deploy --interactive" >&2
