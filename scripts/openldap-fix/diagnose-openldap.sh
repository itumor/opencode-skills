#!/usr/bin/env bash
# scripts/openldap-fix/diagnose-openldap.sh
# Diagnostic collection for Symas OpenLDAP master/replica on RHEL 9.
# Idempotent, masks secrets, structured output.
set -euo pipefail

log() { echo "[INFO]  $*"; }
TS=$(date +%Y%m%d-%H%M%S)
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
REPORT="reports/openldap-diagnosis-${HOSTNAME}-${TS}.txt"
REPORT_DIR="reports"
MASK="${MASK:-***REDACTED***}"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root" >&2; exit 1; }

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

detect_service() {
  for s in symas-openldap-servers slapd; do
    systemctl list-units --type=service 2>/dev/null | grep -qF "$s" && { echo "$s"; return; }
  done
  pgrep -x slapd >/dev/null 2>&1 && echo "slapd" || echo "symas-openldap-servers"
}
SLAPD_SVC=$(detect_service)

mkdir -p "$REPORT_DIR"

{
  echo "# OpenLDAP Diagnostic Report"
  echo "Host: ${HOSTNAME}"
  echo "Timestamp: $(date -Iseconds)"
  echo ""
  echo "## OS Information"
  echo '```'
  cat /etc/os-release 2>/dev/null | grep -E "^(NAME|VERSION)=" || true
  echo "Kernel: $(uname -r)"
  echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
  echo '```'
  echo ""
  echo "## Network"
  echo '```'
  ip -4 addr show 2>/dev/null | grep inet || true
  echo '```'
  echo ""
  echo "## Disk Usage"
  echo '```'
  df -h / /opt/symas /var/symas 2>/dev/null || df -h /
  echo '```'
  echo ""
  echo "## Memory"
  echo '```'
  free -h 2>/dev/null || true
  echo '```'
  echo ""
  echo "## Symas OpenLDAP Packages"
  echo '```'
  rpm -qa 2>/dev/null | grep -i symas || echo "No Symas packages found"
  echo '```'
  echo ""
  echo "## Service (${SLAPD_SVC})"
  echo '```'
  systemctl is-active "$SLAPD_SVC" 2>/dev/null || echo "unknown"
  systemctl is-enabled "$SLAPD_SVC" 2>/dev/null || echo "unknown"
  echo '```'
  echo ""
  echo "## SELinux"
  echo '```'
  getenforce 2>/dev/null || echo "unknown"
  echo '```'
  echo ""
  echo "## LDAP Listeners"
  echo '```'
  ss -tlnp 2>/dev/null | grep -E '389|636' || echo "No LDAP ports found"
  echo '```'
  echo ""
  echo "## Config Tree (slapcat -n 0, truncated)"
  echo '```'
  slapcat -F /opt/symas/etc/openldap/slapd.d -n 0 2>/dev/null | \
    sed "s/olcRootPW:.*/${MASK}/g; s/userPassword:.*/${MASK}/g; s/credentials=.*/${MASK}/g" | \
    head -200 || echo "slapcat failed"
  echo '```'
  echo ""
  echo "## Database Summary (via ldapi)"
  echo '```'
  ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config \
    '(olcDatabase=*)' dn olcDatabase olcSuffix olcDbDirectory olcReadOnly 2>/dev/null | \
    sed "s/olcRootPW:.*/${MASK}/g; s/userPassword:.*/${MASK}/g" || echo "ldapsearch failed"
  echo '```'
  echo ""
  echo "## Replication Config (via ldapi)"
  echo '```'
  ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config \
    '(olcSyncrepl=*)' dn olcSyncrepl olcUpdateRef 2>/dev/null | \
    sed "s/credentials=[^ ]*/${MASK}/g" || echo "No syncrepl config"
  echo '```'
  echo ""
  echo "## ppolicy Overlay"
  echo '```'
  ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config \
    '(olcOverlay=ppolicy)' dn olcPPolicyDefault olcPPolicyHashCleartext 2>/dev/null || echo "No ppolicy overlay"
  echo '```'
  echo ""
  echo "## TLS Config"
  echo '```'
  ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config -s base \
    olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile olcTLSProtocolMin 2>/dev/null || true
  echo '```'
  echo ""
  echo "## TLS Certificate Expiry"
  echo '```'
  for f in /opt/symas/etc/openldap/tls/ldap.crt /opt/symas/etc/openldap/tls/ca.crt; do
    if [[ -f "$f" ]]; then
      echo "--- $f ---"
      openssl x509 -in "$f" -noout -subject -issuer -dates 2>/dev/null || echo "Failed to read cert"
    fi
  done
  echo '```'
  echo ""
  echo "## File Permissions (OpenLDAP paths)"
  echo '```'
  find /opt/symas/etc/openldap -maxdepth 3 -printf '%M %u %g %p\n' 2>/dev/null | head -50 || true
  echo '---'
  ls -la /var/symas/openldap-data/ 2>/dev/null || true
  echo '```'
  echo ""
  echo "## Connectivity Test"
  echo '```'
  LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://localhost 2>&1 || echo "StartTLS test output above"
  echo '```'
  echo ""
  echo "## LDAP Search Test"
  echo '```'
  BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
  ADMIN_DN="cn=admin,${BASE_DN}"
  ADMIN_PW="${ADMIN_PW:-TheN1le1}"
  LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "" -s base contextCSN 2>/dev/null | sed "s/^${ADMIN_PW}/${MASK}/" || echo "Search failed"
  echo '```'
  echo ""
  echo "## Journal (last 100 slapd lines, errors only)"
  echo '```'
  journalctl -u "$SLAPD_SVC" --no-pager -n 100 2>/dev/null | \
    grep -iE 'error|fail|refused|denied|invalid|MDB_MAP|TLS' | head -50 || echo "No errors in recent log"
  echo '```'
  echo ""
  echo "## slaptest Config Check"
  echo '```'
  slaptest -F /opt/symas/etc/openldap/slapd.d -u 2>&1 || true
  echo '```'
  echo ""
  echo "## Entry Count"
  echo '```'
  slapcat -F /opt/symas/etc/openldap/slapd.d -n 1 2>/dev/null | grep -c '^dn:' || echo "0"
  echo '```'

} > "$REPORT"

log "Diagnostic report: $REPORT"
echo "$REPORT"
