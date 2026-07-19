#!/usr/bin/env bash
#
# lofi247 — VPS bootstrap for Ubuntu 24.04
#
# Idempotent: safe to re-run at any time; every step checks before it acts.
# Covers: base packages, Docker (official apt repo, GPG-verified), UFW rules, SSH hardening
# (only when safe), and content directory permissions.
#
# Usage:
#   sudo ./scripts/vps-setup.sh
#
# Environment overrides:
#   LOFI_USER  user that owns/runs the stack   (default: invoking sudo user, else "lofi")
#   REPO_DIR   path to the lofi247 checkout    (default: /home/$LOFI_USER/lofi247)
#
# See docs/VPS-SETUP.md for the manual walkthrough of everything done here.

set -euo pipefail

LOFI_USER="${LOFI_USER:-${SUDO_USER:-lofi}}"
REPO_DIR="${REPO_DIR:-/home/${LOFI_USER}/lofi247}"
WEB_PORT=8080

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must run as root. Try: sudo $0" >&2
    exit 1
  fi
}

check_os() {
  log "Checking OS"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    note "Detected: ${PRETTY_NAME:-unknown}"
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
      note "WARNING: this script targets Ubuntu 24.04 — continuing anyway."
    fi
  else
    note "WARNING: /etc/os-release not found — continuing anyway."
  fi
}

ensure_user() {
  log "Ensuring user '${LOFI_USER}' exists"
  if id "${LOFI_USER}" >/dev/null 2>&1; then
    note "User exists — skipping."
  else
    adduser --disabled-password --gecos "" "${LOFI_USER}"
    usermod -aG sudo "${LOFI_USER}"
    note "Created '${LOFI_USER}' (no password set — SSH key login only)."
    note "Add your public key to /home/${LOFI_USER}/.ssh/authorized_keys before logging out!"
  fi
}

install_base_packages() {
  log "Installing base packages (curl, git, rsync, ufw, unattended-upgrades)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl git rsync ufw ca-certificates unattended-upgrades >/dev/null
  note "Done."
}

enable_auto_security_updates() {
  log "Enabling unattended security updates"
  # Ships enabled by default on Ubuntu 24.04; make sure it stays that way.
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  note "Done."
}

install_docker() {
  log "Installing Docker (official apt repository, GPG-verified)"
  if command -v docker >/dev/null 2>&1; then
    note "Docker already installed ($(docker --version)) — skipping install."
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" \
      "$(. /etc/os-release && echo "${VERSION_CODENAME}")" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null
    note "Docker installed."
  fi
  systemctl enable --now docker
  if id -nG "${LOFI_USER}" | tr ' ' '\n' | grep -qx docker; then
    note "'${LOFI_USER}' already in docker group."
  else
    usermod -aG docker "${LOFI_USER}"
    note "Added '${LOFI_USER}' to docker group (takes effect on next login)."
  fi
}

configure_firewall() {
  log "Configuring UFW"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow "${WEB_PORT}/tcp" comment 'lofi247 web player' >/dev/null
  # Deliberately NOT opened:
  #   8000 (Icecast)  — internal-only; web player proxies /radio on ${WEB_PORT}
  #   5030 (slskd UI) — reach it via: ssh -L 5030:localhost:5030 ${LOFI_USER}@vps
  ufw --force enable >/dev/null
  note "Allowed: OpenSSH, ${WEB_PORT}/tcp. Kept closed: 8000 (icecast), 5030 (slskd)."
  note "REMINDER: Docker-published ports bypass UFW — private ports must be"
  note "unpublished or bound to 127.0.0.1 in docker-compose.yml."
  note "HEADS-UP: while the slskd 'acquire' profile runs, compose publishes"
  note "50300 (Soulseek peer port) to the internet on purpose; stopping slskd"
  note "closes it (docker compose --profile acquire stop slskd)."
}

harden_ssh() {
  log "Hardening SSH"
  local auth_keys="/home/${LOFI_USER}/.ssh/authorized_keys"
  local conf="/etc/ssh/sshd_config.d/60-lofi247.conf"
  if [[ -s "${auth_keys}" ]]; then
    cat >"${conf}" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    systemctl reload ssh || systemctl reload sshd || true
    note "Key-only auth enforced (${conf})."
  else
    note "SKIPPED: no authorized_keys for '${LOFI_USER}' — refusing to disable"
    note "password auth (you would be locked out). Add your key, then re-run."
  fi
}

prepare_directories() {
  log "Preparing content directories"
  if [[ -d "${REPO_DIR}" ]]; then
    local d
    for d in music visuals downloads; do
      mkdir -p "${REPO_DIR}/${d}"
    done
    chown -R "${LOFI_USER}:${LOFI_USER}" \
      "${REPO_DIR}/music" "${REPO_DIR}/visuals" "${REPO_DIR}/downloads"
    chmod 755 "${REPO_DIR}/music" "${REPO_DIR}/visuals" "${REPO_DIR}/downloads"
    note "music/, visuals/, downloads/ ready under ${REPO_DIR}."
  else
    note "Repo not found at ${REPO_DIR} — skipping."
    note "Clone it, then re-run this script (or mkdir music visuals downloads yourself)."
  fi
}

summary() {
  log "Bootstrap complete"
  note "User:       ${LOFI_USER}"
  note "Repo:       ${REPO_DIR} $([[ -d "${REPO_DIR}" ]] && echo '(present)' || echo '(NOT cloned yet)')"
  note "Docker:     $(docker --version 2>/dev/null || echo 'not found?!')"
  note "Firewall:   $(ufw status | head -1)"
  printf '\nNext steps:\n'
  printf '  1. su - %s   (or reconnect over SSH — refreshes the docker group)\n' "${LOFI_USER}"
  if [[ ! -d "${REPO_DIR}" ]]; then
    printf '  2. git clone <repo-url> %s\n' "${REPO_DIR}"
  fi
  printf '  3. cd %s && cp .env.example .env && edit .env\n' "${REPO_DIR}"
  printf '  4. docker compose up -d\n'
  printf '  5. ./scripts/status.sh\n\n'
}

main() {
  require_root
  check_os
  ensure_user
  install_base_packages
  enable_auto_security_updates
  install_docker
  configure_firewall
  harden_ssh
  prepare_directories
  summary
}

main "$@"
