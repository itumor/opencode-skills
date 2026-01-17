#!/usr/bin/env bash
set -euo pipefail

# Symas OpenLDAP 2.6 on RHEL9 - verification script
# Run as root.

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo -e "[FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "[WARN] $*"; WARN=$((WARN+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    bad "This script must be run as root (sudo -i or sudo ./script)"
    exit 1
  fi
}

detect_unit() {
  # Return best-guess unit name via stdout.
  # Prefers enabled/known units: slapd, symas-openldap-servers
  local unit=""
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
    unit="slapd"
  elif systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
    unit="symas-openldap-servers"
  else
    # try active units
    if systemctl list-units --type=service --all --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
      unit="slapd"
    elif systemctl list-units --type=service --all --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
      unit="symas-openldap-servers"
    fi
  fi
  echo "$unit"
}

check_cmd_version() {
  local bin="$1"
  local label="$2"
  if [[ -x "$bin" ]]; then
    local vv=""
    vv="$("$bin" -VV 2>/dev/null | head -n 1 || true)"
    if [[ -n "$vv" ]]; then
      ok "$label: $vv"
    else
      warn "$label present ($bin) but couldn't read version with -VV"
    fi
  else
    warn "$label not found at $bin"
  fi
}

check_rootdse() {
  # RootDSE query with anonymous bind
  local uri="${1:-ldap://localhost}"
  if ! have ldapsearch; then
    bad "ldapsearch not found in PATH; cannot run RootDSE check"
    return 1
  fi

  local out rc
  set +e
  out="$(ldapsearch -x -H "$uri" -b "" -s base 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    bad "RootDSE query failed ($uri). Output: $out"
    return 1
  fi

  # Expect at least "dn:" line
  if echo "$out" | grep -qE '^dn:\s*$'; then
    ok "RootDSE query succeeded ($uri)"
    return 0
  fi

  # Sometimes ldapsearch prints "dn:" with whitespace or returns RootDSE attrs anyway
  if echo "$out" | grep -qE 'supportedLDAPVersion|namingContexts|vendorName|vendorVersion'; then
    ok "RootDSE query succeeded ($uri) (attributes detected)"
    return 0
  fi

  warn "RootDSE query returned but expected attributes weren't detected. Output (first 30 lines):"
  echo "$out" | head -n 30
  return 0
}

check_firewalld_ports() {
  if ! have firewall-cmd; then
    warn "firewall-cmd not found; skipping firewall checks"
    return 0
  fi

  if ! systemctl is-active --quiet firewalld; then
    warn "firewalld not active; skipping firewall checks"
    return 0
  fi

  local ports
  ports="$(firewall-cmd --list-ports 2>/dev/null || true)"

  if echo "$ports" | grep -qE '(^|[[:space:]])389/tcp([[:space:]]|$)'; then
    ok "firewalld: 389/tcp allowed"
  else
    warn "firewalld: 389/tcp NOT listed in --list-ports (may still be allowed via service/zone rules)"
  fi

  if echo "$ports" | grep -qE '(^|[[:space:]])636/tcp([[:space:]]|$)'; then
    ok "firewalld: 636/tcp allowed"
  else
    warn "firewalld: 636/tcp NOT listed in --list-ports (OK if you don't use LDAPS)"
  fi
}

check_selinux() {
  if ! have getenforce; then
    warn "SELinux tools not found; skipping SELinux checks"
    return 0
  fi

  local mode
  mode="$(getenforce 2>/dev/null || true)"
  [[ -n "$mode" ]] || mode="Unknown"

  ok "SELinux mode: $mode"

  local d="/opt/symas/etc/openldap/slapd.d"
  if [[ -d "$d" ]]; then
    if have ls && have awk; then
      local ctx
      ctx="$(ls -Zd "$d" 2>/dev/null | awk '{print $1}' || true)"
      if [[ -n "$ctx" ]]; then
        ok "SELinux context on $d: $ctx"
      else
        warn "Couldn't read SELinux context on $d"
      fi
    fi
  else
    warn "$d not present (OK if using static slapd.conf only)"
  fi
}

check_listeners() {
  if ! have ss; then
    warn "ss not found; skipping listener checks"
    return 0
  fi

  local out
  out="$(ss -tulnp 2>/dev/null | grep -E 'slapd|:389|:636' || true)"

  if echo "$out" | grep -q 'slapd'; then
    ok "slapd appears in listener table"
  else
    bad "slapd not found in listener table (ss -tulnp)"
    echo "$out" | sed 's/^/  /'
  fi

  if echo "$out" | grep -qE ':[[:digit:]]*389'; then
    ok "LDAP listener detected on 389/tcp (or mapped socket)"
  else
    warn "No obvious 389/tcp listener detected (OK if using ldapi/ldaps only)"
  fi

  if echo "$out" | grep -qE ':[[:digit:]]*636'; then
    ok "LDAPS listener detected on 636/tcp"
  else
    warn "No obvious 636/tcp listener detected (OK if you haven't enabled LDAPS)"
  fi
}

check_packages() {
  if ! have rpm; then
    bad "rpm not available; cannot verify packages"
    return 1
  fi

  local clients servers
  clients="$(rpm -q symas-openldap-clients 2>/dev/null || true)"
  servers="$(rpm -q symas-openldap-servers 2>/dev/null || true)"

  if [[ "$clients" == symas-openldap-clients-* ]]; then
    ok "Package installed: $clients"
  else
    bad "symas-openldap-clients not installed"
  fi

  if [[ "$servers" == symas-openldap-servers-* ]]; then
    ok "Package installed: $servers"
  else
    bad "symas-openldap-servers not installed"
  fi
}

check_paths() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    ok "Found system-wide env: $prof"
    if grep -q "/opt/symas/bin" "$prof" && grep -q "LDAPCONF=/opt/symas/etc/openldap/ldap.conf" "$prof"; then
      ok "symas_env.sh contains PATH + LDAPCONF settings"
    else
      warn "symas_env.sh exists but may be missing PATH/LDAPCONF entries"
    fi
  else
    warn "No /etc/profile.d/symas_env.sh found (OK if you export PATH manually)"
  fi

  if have ldapsearch; then
    ok "ldapsearch in PATH: $(command -v ldapsearch)"
  else
    warn "ldapsearch not in PATH (expected at /opt/symas/bin/ldapsearch)"
  fi

  if [[ -n "${LDAPCONF:-}" ]]; then
    ok "LDAPCONF is set: $LDAPCONF"
  else
    warn "LDAPCONF not set (OK, but Symas recommends /opt/symas/etc/openldap/ldap.conf)"
  fi
}

check_binaries() {
  check_cmd_version "/opt/symas/lib/slapd" "slapd (Symas /opt/symas/lib/slapd)"
  check_cmd_version "/opt/symas/sbin/slapd" "slapd (Symas /opt/symas/sbin/slapd)"
  if have slapd; then
    check_cmd_version "$(command -v slapd)" "slapd (from PATH)"
  else
    warn "slapd not found in PATH"
  fi

  if [[ -x /opt/symas/bin/ldapsearch ]]; then
    local vv=""
    vv="$(/opt/symas/bin/ldapsearch -VV 2>/dev/null | head -n 1 || true)"
    [[ -n "$vv" ]] && ok "ldapsearch (Symas): $vv" || warn "ldapsearch present but couldn't read version"
  else
    warn "ldapsearch not found at /opt/symas/bin/ldapsearch"
  fi
}

check_service() {
  local unit
  unit="$(detect_unit)"

  if [[ -z "$unit" ]]; then
    bad "Could not detect slapd systemd unit (neither slapd nor symas-openldap-servers found)"
    return 1
  fi

  ok "Detected systemd unit: ${unit}.service"

  if systemctl is-enabled --quiet "${unit}.service" 2>/dev/null; then
    ok "${unit}.service is enabled"
  else
    warn "${unit}.service not enabled (OK for lab; enable for boot persistence)"
  fi

  if systemctl is-active --quiet "${unit}.service"; then
    ok "${unit}.service is active"
  else
    bad "${unit}.service is NOT active"
    systemctl status "${unit}.service" --no-pager || true
    return 1
  fi
}

main() {
  require_root

  section "Host basics"
  if [[ -f /etc/redhat-release ]]; then
    ok "OS: $(cat /etc/redhat-release)"
  else
    warn "/etc/redhat-release not found"
  fi
  ok "Hostname: $(hostnamectl --static 2>/dev/null || hostname)"

  section "Packages"
  check_packages

  section "Shell environment / PATH"
  check_paths

  section "Binaries / versions"
  check_binaries

  section "systemd service"
  check_service

  section "Listeners"
  check_listeners

  section "RootDSE (anonymous) query"
  # Prefer ldap://localhost; adjust if you only listen on ldapi/ldaps
  check_rootdse "ldap://localhost" || true

  section "SELinux"
  check_selinux

  section "Firewall"
  check_firewalld_ports

  section "Summary"
  echo "PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
  if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Result: FAIL (see failures above)"
    exit 2
  fi
  echo
  echo "Result: OK (with possible warnings)"
}

main "$@"
