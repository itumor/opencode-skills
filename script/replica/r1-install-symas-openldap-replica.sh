#!/usr/bin/env bash
# r1-install-symas-openldap-replica.sh
#
# Installs Symas OpenLDAP packages on the replica node.
# Identical to master install — same packages, same binary.
#
# Repo source (in priority order):
#   1. Red Hat Satellite (production) — repo already enabled, no action needed
#   2. SYMAS_REPO_URL env var — explicit repo URL for test/dev environments
#   3. Auto-detect: if packages not available, install Symas SOLDAP repo directly
#
# Env:
#   SYMAS_REPO_URL  - override repo URL (default: https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo)
#   SKIP_REPO_SETUP - set to 1 to skip repo setup (Satellite-managed environments)
#
# Usage:
#   sudo bash r1-install-symas-openldap-replica.sh                    # Satellite managed
#   sudo SKIP_REPO_SETUP=0 bash r1-install-symas-openldap-replica.sh  # install repo manually
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root" >&2
  exit 1
fi

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] Required command not found: ${bin}" >&2
    exit 1
  fi
}

require_cmd dnf

SKIP_REPO_SETUP="${SKIP_REPO_SETUP:-auto}"
SYMAS_REPO_URL="${SYMAS_REPO_URL:-https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo}"
REPO_DEST="/etc/yum.repos.d/soldap-release26.repo"

# Determine whether to set up repo
if [[ "$SKIP_REPO_SETUP" == "1" ]]; then
  echo "[INFO] Skipping repo setup (SKIP_REPO_SETUP=1 — Satellite managed)"
elif [[ "$SKIP_REPO_SETUP" == "auto" ]]; then
  # Auto: check if packages are already resolvable; if not, add the repo
  if dnf info symas-openldap-servers >/dev/null 2>&1; then
    echo "[INFO] Symas SOLDAP repo already accessible (Satellite or pre-configured)"
  else
    echo "[INFO] Symas packages not found — adding SOLDAP repo from ${SYMAS_REPO_URL}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$SYMAS_REPO_URL" -o "$REPO_DEST"
    elif command -v wget >/dev/null 2>&1; then
      wget -q "$SYMAS_REPO_URL" -O "$REPO_DEST"
    else
      echo "[FATAL] curl/wget not found — cannot download Symas repo file" >&2
      exit 1
    fi
    dnf clean all -q
    dnf makecache -q
    echo "[INFO] Symas SOLDAP repo installed at ${REPO_DEST}"
  fi
else
  # SKIP_REPO_SETUP=0 — force repo install
  echo "[INFO] Installing Symas SOLDAP repo (SKIP_REPO_SETUP=0)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SYMAS_REPO_URL" -o "$REPO_DEST"
  else
    wget -q "$SYMAS_REPO_URL" -O "$REPO_DEST"
  fi
  dnf clean all -q
  dnf makecache -q
fi

echo "[INFO] Installing Symas OpenLDAP packages (replica)"
dnf -y install symas-openldap-clients symas-openldap-servers

echo "[INFO] Verifying Symas OpenLDAP packages are installed"
if ! rpm -q symas-openldap-clients symas-openldap-servers >/dev/null 2>&1; then
  echo "[FATAL] Symas OpenLDAP packages not installed." >&2
  echo "[FATAL] Ensure Symas SOLDAP repo is enabled (Satellite or SKIP_REPO_SETUP=0)." >&2
  exit 1
fi

echo "[OK] Symas OpenLDAP packages installed on replica"
