#!/usr/bin/env bash
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

download() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
    return 0
  fi

  echo "[INFO] curl/wget missing; installing curl"
  dnf -y install curl
  curl -fsSL "$url" -o "$dest"
}

require_cmd dnf

REPO_URL="${REPO_URL:-https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo}"
REPO_DEST="${REPO_DEST:-/etc/yum.repos.d/soldap-release26.repo}"

echo "[INFO] Installing Symas SOLDAP repo: ${REPO_URL} -> ${REPO_DEST}"
download "$REPO_URL" "$REPO_DEST"

echo "[INFO] Refreshing dnf metadata"
dnf clean all
dnf -y makecache

if [[ "${SKIP_DNF_UPDATE:-0}" != "1" ]]; then
  echo "[INFO] Updating OS packages (set SKIP_DNF_UPDATE=1 to skip)"
  dnf -y update
fi

echo "[INFO] Installing Symas OpenLDAP packages"
dnf -y install symas-openldap-clients symas-openldap-servers

echo "[INFO] Verifying Symas OpenLDAP packages are installed"
if ! rpm -q symas-openldap-clients symas-openldap-servers >/dev/null 2>&1; then
  echo "[FATAL] Symas OpenLDAP packages are not installed. Repo file present at: ${REPO_DEST}" >&2
  exit 1
fi
