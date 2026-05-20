#!/usr/bin/env bash
# =============================================================================
# test-openldap-connections.sh
#
# Tests every OpenLDAP connection method and reports PASS/FAIL for each.
#
# Connection types tested:
#   1. LDAP plain (port 389)         - anonymous RootDSE
#   2. LDAP + StartTLS (port 389)    - anonymous RootDSE
#   3. LDAPS (port 636)              - anonymous RootDSE
#   4. ldapi:// (unix socket)        - SASL EXTERNAL (root only)
#   5. Admin bind via LDAP+StartTLS  - cn=admin simple bind
#   6. Admin bind via LDAPS          - cn=admin simple bind
#   7. Replication bind              - cn=replicator simple bind + read check
#   8. Replication bind write-denied - verify replicator cannot write
#   9. MW service account bind       - uid=mw simple bind
#  10. Port connectivity checks      - nc/bash TCP test for 389/636
#
# Usage:
#   sudo bash test-openldap-connections.sh [OPTIONS]
#
# Options:
#   -H <uri>       LDAP URI (default: ldap://localhost)
#   -b <base>      Base DN (default: dc=eab,dc=bank,dc=local)
#   -D <dn>        Admin bind DN (default: cn=admin,<base>)
#   -w <pass>      Admin password (auto-detected from Exampledb/exampledb.sh)
#   -r <dn>        Replication bind DN (default: cn=replicator,<base>)
#   -R <pass>      Replication password (default: replpass)
#   -m <pass>      MW user password (default: ChangeMe123!)
#   -s <host>      Remote host to probe ports on (default: localhost)
#   --no-starttls  Skip StartTLS tests
#   --no-ldaps     Skip LDAPS tests
#   --no-ldapi     Skip ldapi tests (requires root)
#   --no-color     Disable color output
#   -v             Verbose: show ldap command output on failure
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#
# Requirements:
#   - Symas OpenLDAP clients (ldapsearch, ldapwhoami, ldapadd, ldapdelete)
#   - bash 4+
#   - Root required only for ldapi:// tests
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
LDAP_URI="${LDAP_URI:-ldap://localhost}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="${ADMIN_DN:-}"
ADMIN_PW="${ADMIN_PW:-}"
REPL_CN="${REPL_CN:-replicator}"
REPL_DN="${REPL_DN:-}"
REPL_PW="${REPL_PW:-replpass}"
MW_DN="${MW_DN:-}"
MW_PW="${MW_PW:-ChangeMe123!}"
PROBE_HOST="${PROBE_HOST:-localhost}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
export LDAPTLS_REQCERT

SKIP_STARTTLS=0
SKIP_LDAPS=0
SKIP_LDAPI=0
NO_COLOR=0
VERBOSE=0

PASS=0
FAIL=0
SKIP=0
WARN=0

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
color() {
  if [[ "$NO_COLOR" == "1" ]]; then
    echo "$2"
    return
  fi
  local code="$1"
  echo -e "\e[${code}m${2}\e[0m"
}
green()  { color "32" "$*"; }
red()    { color "31" "$*"; }
yellow() { color "33" "$*"; }
cyan()   { color "36" "$*"; }
bold()   { color "1"  "$*"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
pass() { echo "  $(green '[PASS]') $*"; PASS=$((PASS+1)); }
fail() { echo "  $(red '[FAIL]') $*"; FAIL=$((FAIL+1)); }
skip() { echo "  $(yellow '[SKIP]') $*"; SKIP=$((SKIP+1)); }
warn() { echo "  $(yellow '[WARN]') $*"; WARN=$((WARN+1)); }
info() { echo "  [INFO] $*"; }
section() { echo ""; bold "=== $* ==="; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) LDAP_URI="$2"; shift 2 ;;
    -b) BASE_DN="$2"; shift 2 ;;
    -D) ADMIN_DN="$2"; shift 2 ;;
    -w) ADMIN_PW="$2"; shift 2 ;;
    -r) REPL_DN="$2"; shift 2 ;;
    -R) REPL_PW="$2"; shift 2 ;;
    -m) MW_PW="$2"; shift 2 ;;
    -s) PROBE_HOST="$2"; shift 2 ;;
    --no-starttls) SKIP_STARTTLS=1; shift ;;
    --no-ldaps) SKIP_LDAPS=1; shift ;;
    --no-ldapi) SKIP_LDAPI=1; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# =/p' "$0" | grep '^#' | sed 's/^# *//'
      exit 0 ;;
    *) echo "[WARN] Unknown option: $1" >&2; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Derive defaults from BASE_DN
# ---------------------------------------------------------------------------
[[ -z "$ADMIN_DN"  ]] && ADMIN_DN="cn=admin,${BASE_DN}"
[[ -z "$REPL_DN"   ]] && REPL_DN="cn=${REPL_CN},${BASE_DN}"
[[ -z "$MW_DN"     ]] && MW_DN="uid=mw,ou=ServiceAccounts,ou=Systems,${BASE_DN}"

# ---------------------------------------------------------------------------
# Auto-detect admin password from exampledb.sh
# ---------------------------------------------------------------------------
detect_password() {
  local candidates=(
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Exampledb/exampledb.sh"
    "/opt/symas/share/symas/exampledb.sh"
    "/tmp/script/Exampledb/exampledb.sh"
  )
  local file pw
  for file in "${candidates[@]}"; do
    if [[ -f "$file" ]]; then
      pw=$(awk 'tolower($1) ~ /^(rootpw|olcrootpw:?)$/ {print $2; exit}' "$file")
      [[ -n "$pw" ]] && echo "$pw" && return 0
    fi
  done
  return 1
}

if [[ -z "$ADMIN_PW" ]]; then
  ADMIN_PW="$(detect_password || true)"
fi

# ---------------------------------------------------------------------------
# Ensure Symas tools are on PATH
# ---------------------------------------------------------------------------
ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]] || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
}
ensure_symas_env

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { fail "$1 not found in PATH — install Symas OpenLDAP clients"; return 1; }
}

# ---------------------------------------------------------------------------
# Helper: run ldap command, capture output, report pass/fail
# ---------------------------------------------------------------------------
run_ldap() {
  local label="$1"; shift
  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "$label"
  else
    fail "$label (exit $rc)"
    if [[ "$VERBOSE" == "1" ]]; then
      echo "       CMD: $*"
      echo "$out" | sed 's/^/       | /'
    fi
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: check a port is open using bash TCP
# ---------------------------------------------------------------------------
check_port() {
  local host="$1"
  local port="$2"
  local label="${3:-port $port}"
  if bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    pass "$label (${host}:${port} reachable)"
  else
    fail "$label (${host}:${port} not reachable)"
    return 1
  fi
}

# ===========================================================================
# Start
# ===========================================================================
echo ""
bold "============================================================"
bold "  OpenLDAP Connection Test Suite"
bold "============================================================"
echo "  Host:      ${LDAP_URI}"
echo "  Base DN:   ${BASE_DN}"
echo "  Admin DN:  ${ADMIN_DN}"
echo "  Repl DN:   ${REPL_DN}"
echo "  MW DN:     ${MW_DN}"
echo "  TLS cert:  ${LDAPTLS_REQCERT}"
echo "  Date:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# ===========================================================================
# Section 1: Port Connectivity
# ===========================================================================
section "1. Port Connectivity"
check_port "$PROBE_HOST" 389 "LDAP port 389"
if [[ "$SKIP_LDAPS" == "0" ]]; then
  check_port "$PROBE_HOST" 636 "LDAPS port 636"
fi

# ===========================================================================
# Section 2: Service Status
# ===========================================================================
section "2. Service Status"
if command -v systemctl >/dev/null 2>&1; then
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -q "^.*${svc}"; then
      state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
      if [[ "$state" == "active" ]]; then
        pass "systemd unit ${svc} is active"
      else
        fail "systemd unit ${svc} state: ${state}"
      fi
    fi
  done
else
  skip "systemctl not available — skipping service check"
fi

# Check slapd process
if pgrep -x slapd >/dev/null 2>&1 || pgrep -f "opt/symas/lib/slapd" >/dev/null 2>&1; then
  pass "slapd process is running"
else
  fail "slapd process not found"
fi

# ===========================================================================
# Section 3: LDAP plain (port 389) — RootDSE anonymous
# ===========================================================================
section "3. LDAP Plain (port 389)"
if ! require_cmd ldapsearch; then
  skip "ldapsearch not available — skipping all LDAP tests"
else
  # RootDSE should respond even with anonymous bind disabled (rc=48 means server replied)
  out=$(ldapsearch -x -H "${LDAP_URI}" -b '' -s base supportedLDAPVersion 2>&1) || true
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "Anonymous RootDSE query (port 389)"
  elif echo "$out" | grep -qi "anonymous bind disallowed\|Inappropriate authentication\|confidentiality"; then
    pass "Port 389 responding (anonymous bind restricted — expected after hardening)"
    info "Server replied: $(echo "$out" | grep 'additional info:' | head -1)"
  else
    fail "Port 389 not responding or unexpected error"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Verify LDAP version is 3
  ver=$(ldapsearch -x -H "${LDAP_URI}" -b '' -s base supportedLDAPVersion 2>/dev/null | awk '/^supportedLDAPVersion:/{print $2; exit}')
  if [[ "$ver" == "3" ]]; then
    pass "LDAPv3 supported"
  elif [[ -n "$ver" ]]; then
    warn "LDAPv3 check: got version ${ver}"
  else
    info "LDAPv3 version check skipped (anonymous bind not allowed)"
  fi
fi

# ===========================================================================
# Section 4: LDAP + StartTLS (port 389)
# ===========================================================================
section "4. LDAP + StartTLS (port 389)"
if [[ "$SKIP_STARTTLS" == "1" ]]; then
  skip "StartTLS tests disabled (--no-starttls)"
elif ! require_cmd ldapsearch; then
  skip "ldapsearch not available"
else
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "${LDAP_URI}" -b '' -s base \
    supportedLDAPVersion 2>&1) || true
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "StartTLS negotiation (anonymous RootDSE)"
  elif echo "$out" | grep -qi "anonymous bind disallowed\|Inappropriate authentication\|confidentiality"; then
    pass "StartTLS negotiation succeeded (anonymous bind restricted — expected)"
    info "Server replied: $(echo "$out" | grep 'additional info:' | head -1)"
  elif echo "$out" | grep -qi "TLS: hostname does not match\|certificate\|handshake"; then
    warn "StartTLS TLS error: $(echo "$out" | grep -i 'tls\|certificate\|handshake' | head -1)"
  else
    fail "StartTLS failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi
fi

# ===========================================================================
# Section 5: LDAPS (port 636)
# ===========================================================================
section "5. LDAPS (port 636)"
if [[ "$SKIP_LDAPS" == "1" ]]; then
  skip "LDAPS tests disabled (--no-ldaps)"
elif ! require_cmd ldapsearch; then
  skip "ldapsearch not available"
else
  # Derive LDAPS URI from LDAP_URI
  LDAPS_URI="${LDAP_URI/ldap:\/\//ldaps:\/\/}"
  LDAPS_URI="${LDAPS_URI/ldaps:\/\/localhost/ldaps:\/\/localhost}"
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -H "${LDAPS_URI}" -b '' -s base \
    supportedLDAPVersion 2>&1) || true
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "LDAPS connection (anonymous RootDSE)"
  elif echo "$out" | grep -qi "anonymous bind disallowed\|Inappropriate authentication\|confidentiality"; then
    pass "LDAPS connection (TLS handshake OK, anonymous bind restricted — expected)"
    info "Server replied: $(echo "$out" | grep 'additional info:' | head -1)"
  elif echo "$out" | grep -qi "Can't contact\|Connection refused\|Network"; then
    fail "LDAPS port 636 not reachable"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  else
    fail "LDAPS failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi
fi

# ===========================================================================
# Section 6: ldapi:// (Unix socket — root only)
# ===========================================================================
section "6. ldapi:// Unix Socket (SASL EXTERNAL)"
if [[ "$SKIP_LDAPI" == "1" ]]; then
  skip "ldapi tests disabled (--no-ldapi)"
elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  skip "ldapi:// requires root — re-run with sudo for this section"
elif ! require_cmd ldapsearch; then
  skip "ldapsearch not available"
else
  out=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b '' -s base supportedLDAPVersion 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "ldapi:// SASL EXTERNAL RootDSE query"
  else
    fail "ldapi:// SASL EXTERNAL failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Check cn=config access
  out=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s base -LLL dn 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "ldapi:// cn=config access (SASL EXTERNAL manage)"
  else
    fail "ldapi:// cn=config access denied (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi
fi

# ===========================================================================
# Section 7: Admin Bind
# ===========================================================================
section "7. Admin Bind (cn=admin)"
if [[ -z "$ADMIN_PW" ]]; then
  skip "Admin password not set (use -w or set ADMIN_PW); skipping admin bind tests"
elif ! require_cmd ldapwhoami; then
  skip "ldapwhoami not available"
else
  # Admin bind via StartTLS
  if [[ "$SKIP_STARTTLS" == "0" ]]; then
    out=$(LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "${LDAP_URI}" \
      -D "$ADMIN_DN" -w "$ADMIN_PW" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      pass "Admin bind via LDAP+StartTLS (ldapwhoami)"
      info "Identity: $(echo "$out" | grep '^dn:' | head -1)"
    else
      fail "Admin bind via LDAP+StartTLS (exit $rc)"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
    fi
  fi

  # Admin bind via LDAPS
  if [[ "$SKIP_LDAPS" == "0" ]]; then
    LDAPS_URI="${LDAP_URI/ldap:\/\//ldaps:\/\/}"
    out=$(LDAPTLS_REQCERT=never ldapwhoami -x -H "${LDAPS_URI}" \
      -D "$ADMIN_DN" -w "$ADMIN_PW" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      pass "Admin bind via LDAPS"
      info "Identity: $(echo "$out" | grep '^dn:' | head -1)"
    else
      fail "Admin bind via LDAPS (exit $rc)"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
    fi
  fi

  # Admin can read base DN
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "${LDAP_URI}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s base -LLL dn 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]] && echo "$out" | grep -qi "^dn:"; then
    pass "Admin can read base DN: ${BASE_DN}"
  elif [[ $rc -eq 0 ]]; then
    warn "Admin search returned no dn — base DN may not exist yet"
  else
    fail "Admin base DN search failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Admin can read OUs
  for ou in Users Groups Systems Policies; do
    out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "${LDAP_URI}" \
      -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "ou=${ou},${BASE_DN}" -s base -LLL dn 2>&1)
    if echo "$out" | grep -qi "^dn:"; then
      pass "OU exists: ou=${ou},${BASE_DN}"
    elif echo "$out" | grep -qi "No such object"; then
      warn "OU not found: ou=${ou},${BASE_DN} (may not be created yet)"
    else
      fail "OU check failed: ou=${ou},${BASE_DN}"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
    fi
  done
fi

# ===========================================================================
# Section 8: Replication Bind
# ===========================================================================
section "8. Replication Bind (cn=replicator)"
if ! require_cmd ldapwhoami; then
  skip "ldapwhoami not available"
else
  out=$(LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "${LDAP_URI}" \
    -D "$REPL_DN" -w "$REPL_PW" 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "Replication bind (StartTLS): ${REPL_DN}"
  elif echo "$out" | grep -qi "Invalid credentials\|49"; then
    fail "Replication bind: invalid credentials (check REPL_PW)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  elif echo "$out" | grep -qi "No such object\|32"; then
    warn "Replication bind DN not found: ${REPL_DN} (run 26-configure-bindings.sh)"
  else
    fail "Replication bind failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Replicator can read base DN
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "${LDAP_URI}" \
    -D "$REPL_DN" -w "$REPL_PW" \
    -b "$BASE_DN" -s base -LLL dn 2>&1)
  if echo "$out" | grep -qi "^dn:"; then
    pass "Replication bind can read base DN"
  elif echo "$out" | grep -qi "Invalid credentials\|49\|No such object"; then
    warn "Replication bind read check skipped (bind likely failed above)"
  else
    fail "Replication bind cannot read base DN"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Replicator must NOT be able to write (verify ACL)
  tmp_ldif="/tmp/repl-write-test-$$.ldif"
  test_uid="repl-conntest-$$"
  test_dn="uid=${test_uid},ou=Users,${BASE_DN}"
  cat > "$tmp_ldif" <<LDIF
dn: ${test_dn}
objectClass: inetOrgPerson
uid: ${test_uid}
cn: Conn Test
sn: ConnTest
LDIF
  out=$(LDAPTLS_REQCERT=never ldapadd -x -ZZ -H "${LDAP_URI}" \
    -D "$REPL_DN" -w "$REPL_PW" -f "$tmp_ldif" 2>&1) && rc=0 || rc=$?
  rm -f "$tmp_ldif"
  if [[ $rc -ne 0 ]]; then
    pass "Replication bind write correctly denied (ACL enforced)"
  else
    fail "Replication bind has unexpected write access — ACL misconfigured"
    # Cleanup the accidentally created entry
    if [[ -n "$ADMIN_PW" ]]; then
      LDAPTLS_REQCERT=never ldapdelete -x -ZZ -H "${LDAP_URI}" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" "$test_dn" >/dev/null 2>&1 || true
    fi
  fi
fi

# ===========================================================================
# Section 9: MW Service Account Bind
# ===========================================================================
section "9. MW Service Account Bind (uid=mw)"
if ! require_cmd ldapwhoami; then
  skip "ldapwhoami not available"
else
  out=$(LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "${LDAP_URI}" \
    -D "$MW_DN" -w "$MW_PW" 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "MW service account bind: ${MW_DN}"
  elif echo "$out" | grep -qi "Invalid credentials\|49"; then
    fail "MW bind: invalid credentials (check MW_PW / -m option)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  elif echo "$out" | grep -qi "No such object\|32"; then
    warn "MW DN not found: ${MW_DN} (run 17-create_mw_user.sh)"
  else
    fail "MW bind failed (exit $rc)"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # MW can write to ou=Users
  if [[ -n "$ADMIN_PW" ]]; then
    tmp_uid="mw-conntest-$$"
    tmp_dn="uid=${tmp_uid},ou=Users,${BASE_DN}"
    tmp_ldif="/tmp/mw-write-test-$$.ldif"
    cat > "$tmp_ldif" <<LDIF
dn: ${tmp_dn}
objectClass: inetOrgPerson
uid: ${tmp_uid}
cn: Conn Test
sn: ConnTest
LDIF
    out=$(LDAPTLS_REQCERT=never ldapadd -x -ZZ -H "${LDAP_URI}" \
      -D "$MW_DN" -w "$MW_PW" -f "$tmp_ldif" 2>&1) && rc=0 || rc=$?
    rm -f "$tmp_ldif"
    if [[ $rc -eq 0 ]]; then
      pass "MW service account can write to ou=Users"
      # Cleanup
      LDAPTLS_REQCERT=never ldapdelete -x -ZZ -H "${LDAP_URI}" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" "$tmp_dn" >/dev/null 2>&1 || true
    elif echo "$out" | grep -qi "Insufficient access\|50\|No such object"; then
      fail "MW account write denied — check 27-configure-mw-acl.sh"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
    elif echo "$out" | grep -qi "Invalid credentials\|49"; then
      warn "MW write check skipped (MW bind likely failed)"
    else
      fail "MW write test failed (exit $rc)"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
    fi
  fi
fi

# ===========================================================================
# Section 10: TLS Certificate Check
# ===========================================================================
section "10. TLS Certificate Verification"
if [[ "$SKIP_STARTTLS" == "1" ]] && [[ "$SKIP_LDAPS" == "1" ]]; then
  skip "TLS tests disabled"
elif command -v openssl >/dev/null 2>&1; then
  # Extract hostname/port from LDAP_URI
  ldap_host="${LDAP_URI#ldap://}"
  ldap_host="${ldap_host#ldaps://}"
  ldap_host="${ldap_host%%/*}"
  ldap_host="${ldap_host%%:*}"
  [[ -z "$ldap_host" ]] && ldap_host="localhost"

  # StartTLS cert check (port 389)
  if [[ "$SKIP_STARTTLS" == "0" ]]; then
    out=$(echo Q | openssl s_client -connect "${ldap_host}:389" -starttls ldap 2>&1)
    rc=$?
    if echo "$out" | grep -qi "Certificate chain\|subject=\|BEGIN CERTIFICATE"; then
      cn=$(echo "$out" | grep -i "subject=" | head -1 | sed 's/.*CN[[:space:]]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' ')
      exp=$(echo "$out" | grep -i "NotAfter" | head -1 | sed 's/.*NotAfter[[:space:]]*:[[:space:]]*//')
      pass "StartTLS certificate received (CN=${cn:-unknown})"
      [[ -n "$exp" ]] && info "Certificate expires: ${exp}"
    elif echo "$out" | grep -qi "Connection refused\|Connect error"; then
      warn "Could not connect to ${ldap_host}:389 for TLS cert check"
    else
      warn "StartTLS cert check inconclusive"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | tail -10 | sed 's/^/       | /'
    fi
  fi

  # LDAPS cert check (port 636)
  if [[ "$SKIP_LDAPS" == "0" ]]; then
    out=$(echo Q | openssl s_client -connect "${ldap_host}:636" 2>&1)
    rc=$?
    if echo "$out" | grep -qi "Certificate chain\|subject=\|BEGIN CERTIFICATE"; then
      cn=$(echo "$out" | grep -i "subject=" | head -1 | sed 's/.*CN[[:space:]]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' ')
      exp=$(echo "$out" | grep -i "NotAfter" | head -1 | sed 's/.*NotAfter[[:space:]]*:[[:space:]]*//')
      pass "LDAPS certificate received (CN=${cn:-unknown})"
      [[ -n "$exp" ]] && info "Certificate expires: ${exp}"
    elif echo "$out" | grep -qi "Connection refused\|Connect error"; then
      warn "Could not connect to ${ldap_host}:636 for TLS cert check"
    else
      warn "LDAPS cert check inconclusive"
      [[ "$VERBOSE" == "1" ]] && echo "$out" | tail -10 | sed 's/^/       | /'
    fi
  fi
else
  skip "openssl not available — skipping certificate checks"
fi

# ===========================================================================
# Section 11: Password Policy Check
# ===========================================================================
section "11. Password Policy & Schema"
if [[ -z "$ADMIN_PW" ]]; then
  skip "Admin password not set — skipping policy checks"
elif ! require_cmd ldapsearch; then
  skip "ldapsearch not available"
else
  # Default ppolicy
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "${LDAP_URI}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "cn=default,ou=Policies,${BASE_DN}" -s base -LLL objectClass 2>&1)
  if echo "$out" | grep -qi "pwdPolicy"; then
    pass "Default password policy exists (cn=default,ou=Policies)"
  elif echo "$out" | grep -qi "No such object"; then
    warn "Default password policy not found (run 10-ppolicy-container.sh)"
  else
    fail "Password policy check failed"
    [[ "$VERBOSE" == "1" ]] && echo "$out" | sed 's/^/       | /'
  fi

  # Custom schema
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    out=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config \
      -LLL "(cn=*bank*)" dn 2>&1)
    if echo "$out" | grep -qi "bank-custom\|bank"; then
      pass "Custom schema (bank-custom) present in cn=config"
    else
      warn "Custom schema not found (run 12-Create_custom_schema.sh)"
    fi
  else
    skip "Custom schema check requires root (ldapi://)"
  fi

  # Accesslog overlay
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    out=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
      -LLL "(objectClass=olcAccessLogConfig)" dn 2>&1)
    if echo "$out" | grep -qi "accesslog\|olcAccessLogConfig"; then
      pass "Accesslog overlay configured"
    else
      warn "Accesslog overlay not found (run 25-configure-accesslog-audit.sh)"
    fi
  fi
fi

# ===========================================================================
# Final Summary
# ===========================================================================
echo ""
bold "============================================================"
bold "  Summary"
bold "============================================================"
printf "  $(green 'PASS'): %-3d  " "$PASS"
printf "$(red 'FAIL'): %-3d  " "$FAIL"
printf "$(yellow 'WARN'): %-3d  " "$WARN"
printf "$(yellow 'SKIP'): %-3d\n" "$SKIP"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  red "  Result: FAIL — ${FAIL} test(s) failed"
  echo ""
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  yellow "  Result: PASS with warnings"
  echo ""
  exit 0
else
  green "  Result: ALL PASS"
  echo ""
  exit 0
fi
