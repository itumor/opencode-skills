#!/usr/bin/env bash
set -euo pipefail

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi
  if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
    export PATH="/opt/symas/bin:${PATH}"
  fi
  if [[ ":${PATH}:" != *":/opt/symas/sbin:"* ]]; then
    export PATH="/opt/symas/sbin:${PATH}"
  fi
}

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] $bin not found in PATH" >&2
    exit 1
  fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root (required for ldapi:/// SASL/EXTERNAL)" >&2
  exit 1
fi

ensure_symas_env
require_cmd ldapwhoami
require_cmd ldapsearch
require_cmd ldapadd
require_cmd ldapdelete

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
EXAMPLEDB_FILE="${ROOT_DIR}/Exampledb/exampledb.sh"

read_exampledb_password() {
  local file="$1"
  local pw=""
  if [[ -f "$file" ]]; then
    pw="$(awk '
      /^[[:space:]]*#/ {next}
      $1 == "rootpw" {print $2; exit}
      $1 == "olcRootPW:" {print $2; exit}
      $1 == "olcRootPw:" {print $2; exit}
    ' "$file")"
  fi
  [[ -n "$pw" ]] || return 1
  echo "$pw"
}

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
LDAP_STARTTLS="${LDAP_STARTTLS:-1}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-$(read_exampledb_password "$EXAMPLEDB_FILE" || true)}"

REPL_CN="${REPL_CN:-replicator}"
REPL_DN="${REPL_DN:-cn=${REPL_CN},${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"

echo "======================================"
echo "Test 26 - Bindings (Replication Bind DN)"
echo "BASE_DN: ${BASE_DN}"
echo "LDAP_URI: ${LDAP_URI}"
echo "REPL_DN: ${REPL_DN}"
echo "======================================"

echo "[INFO] Running script/26-configure-bindings.sh"
BASE_DN="$BASE_DN" LDAP_URI="$LDAP_URI" REPL_DN="$REPL_DN" REPL_PW="$REPL_PW" \
  VERIFY_STARTTLS="$LDAP_STARTTLS" LDAPTLS_REQCERT="$LDAPTLS_REQCERT" \
  bash "${ROOT_DIR}/26-configure-bindings.sh" >/tmp/test_bindings_script.out 2>/tmp/test_bindings_script.err

bind_args=(-x -H "$LDAP_URI" -D "$REPL_DN" -w "$REPL_PW")
if [[ "$LDAP_STARTTLS" == "1" ]]; then
  bind_args+=(-ZZ)
  export LDAPTLS_REQCERT
fi

echo "[INFO] Verifying replication bind (ldapwhoami)"
if ldapwhoami "${bind_args[@]}" >/dev/null 2>&1; then
  echo "[PASS] Replication bind authentication OK"
else
  echo "[FAIL] Replication bind authentication failed" >&2
  cat /tmp/test_bindings_script.err >&2 || true
  exit 1
fi

echo "[INFO] Verifying replication bind can read BASE_DN"
if ldapsearch "${bind_args[@]}" -b "$BASE_DN" -s base -LLL dn >/dev/null 2>&1; then
  echo "[PASS] Replication bind can read BASE_DN"
else
  echo "[FAIL] Replication bind cannot read BASE_DN" >&2
  exit 1
fi

echo "[INFO] Verifying replication bind cannot write (expected failure)"
tmp_ldif="/tmp/repl_write_test.$$".ldif
test_dn="uid=repl-write-test-$$,ou=people,${BASE_DN}"
cat >"$tmp_ldif" <<LDIF
dn: ${test_dn}
objectClass: inetOrgPerson
cn: repl-write-test-$$
sn: repl-write-test-$$
uid: repl-write-test-$$
LDIF

if ldapadd "${bind_args[@]}" -f "$tmp_ldif" >/tmp/test_bindings_write.out 2>/tmp/test_bindings_write.err; then
  echo "[FAIL] Replication bind unexpectedly has write access (added ${test_dn})" >&2
  echo "[INFO] Attempting cleanup via admin bind"
  if [[ -n "$ADMIN_PW" ]]; then
    admin_args=(-x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW")
    if [[ "$LDAP_STARTTLS" == "1" ]]; then
      admin_args+=(-ZZ)
      export LDAPTLS_REQCERT
    fi
    ldapdelete "${admin_args[@]}" "$test_dn" >/dev/null 2>&1 || true
  fi
  exit 1
else
  echo "[PASS] Replication bind write denied as expected"
fi
rm -f "$tmp_ldif"

echo "[SUCCESS] Bindings verification completed"
