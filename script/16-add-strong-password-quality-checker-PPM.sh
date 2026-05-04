#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldap* tools are found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
LDAPMODIFY="${LDAPMODIFY:-$(command -v ldapmodify || true)}"

if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
  exit 1
fi
if [[ -z "$LDAPMODIFY" ]]; then
  echo "[FATAL] ldapmodify not found; ensure Symas clients are installed" >&2
  exit 1
fi

CONFIG_URI="${CONFIG_URI:-ldapi:///}"
CONFIG_AUTH=(-Y EXTERNAL -H "$CONFIG_URI")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLEDB_FILE="${EXAMPLEDB_FILE:-${SCRIPT_DIR}/Exampledb/exampledb.sh}"

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

PPOLICY_DN="${PPOLICY_DN:-}"
POLICY_DN="${POLICY_DN:-cn=default,ou=Policies,dc=eab,dc=bank,dc=local}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
BIND_PW="${BIND_PW:-$(read_exampledb_password "$EXAMPLEDB_FILE" || true)}"

PPM_CONF="${PPM_CONF:-/opt/symas/etc/openldap/ppm.conf}"
PPM_MIN_LENGTH="${PPM_MIN_LENGTH:-12}"
PPM_MIN_UPPER="${PPM_MIN_UPPER:-1}"
PPM_MIN_LOWER="${PPM_MIN_LOWER:-1}"
PPM_MIN_DIGIT="${PPM_MIN_DIGIT:-1}"
PPM_MIN_SPECIAL="${PPM_MIN_SPECIAL:-1}"
PPM_HISTORY_SIZE="${PPM_HISTORY_SIZE:-5}"
PPM_MAX_REPEAT="${PPM_MAX_REPEAT:-2}"
PPM_REJECT_USERNAME="${PPM_REJECT_USERNAME:-true}"
PPM_REJECT_DICTIONARY="${PPM_REJECT_DICTIONARY:-false}"
PPM_FORBIDDEN_WORDS="${PPM_FORBIDDEN_WORDS:-admin password bank welcome}"
PPM_EMBED_CONFIG="${PPM_EMBED_CONFIG:-0}"

echo "[INFO] Locating olcModuleList entry..."
module_dn="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b cn=config '(objectClass=olcModuleList)' dn olcModuleLoad | awk '/^dn: /{print $2; exit}')"
if [[ -z "$module_dn" ]]; then
  echo "[FATAL] No olcModuleList entry found under cn=config" >&2
  exit 1
fi

module_path="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b "$module_dn" -s base olcModulePath | awk -F': ' '/^olcModulePath:/{print $2; exit}')"
module_path="${module_path:-/opt/symas/lib/openldap}"

# Symas packages ship ppm as ppm.so (no .la). Loading "ppm" can fail depending on libtool support.
ppm_load_value="ppm"
if [[ -f "${module_path}/ppm.so" ]]; then
  ppm_load_value="ppm.so"
elif [[ -f "${module_path}/ppm.la" ]]; then
  ppm_load_value="ppm.la"
fi

module_loads="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b "$module_dn" -s base olcModuleLoad || true)"
PPM_AVAILABLE=1
if ! echo "$module_loads" | grep -Eqi '^olcModuleLoad: .*ppm(\.so|\.la)?$'; then
  ldif_file="$(mktemp /tmp/ppm-module-load.XXXXXX.ldif)"
  cat > "$ldif_file" << EOF
dn: $module_dn
changetype: modify
add: olcModuleLoad
olcModuleLoad: ${ppm_load_value}
EOF
  if $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"; then
    rm -f "$ldif_file"
    echo "[INFO] Loaded PPM module (${ppm_load_value}) in $module_dn"
  else
    rm -f "$ldif_file"
    echo "[WARN] Failed to load PPM module (${ppm_load_value}) in $module_dn; continuing without PPM (module may require additional Symas components/licensing)." >&2
    PPM_AVAILABLE=0
  fi
else
  echo "[INFO] PPM module already loaded in $module_dn"
fi

if [[ "$PPM_AVAILABLE" == "1" ]]; then
  if [[ -z "$PPOLICY_DN" ]]; then
    echo "[INFO] Locating ppolicy overlay entry..."
    PPOLICY_DN="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b cn=config '(olcOverlay=ppolicy)' dn olcPPolicyCheckModule | awk '/^dn: /{print $2; exit}')"
  fi
  if [[ -z "$PPOLICY_DN" ]]; then
    echo "[WARN] ppolicy overlay not found under cn=config; skipping PPM integration." >&2
    PPM_AVAILABLE=0
  else
    ppolicy_current="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b "$PPOLICY_DN" -s base olcPPolicyCheckModule | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}')"
    if [[ "$ppolicy_current" != "ppm" ]]; then
      ldif_file="$(mktemp /tmp/ppolicy-check-module.XXXXXX.ldif)"
      cat > "$ldif_file" << EOF
dn: $PPOLICY_DN
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: ppm
EOF
      if $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"; then
        rm -f "$ldif_file"
        echo "[INFO] Set olcPPolicyCheckModule to ppm on $PPOLICY_DN"
      else
        rm -f "$ldif_file"
        echo "[WARN] Failed to set olcPPolicyCheckModule=ppm; continuing without PPM." >&2
        PPM_AVAILABLE=0
      fi
    else
      echo "[INFO] olcPPolicyCheckModule already set to ppm on $PPOLICY_DN"
    fi
  fi
fi

if [[ "$PPM_AVAILABLE" == "1" ]]; then
  PPM_DIR="$(dirname "$PPM_CONF")"
  echo "[INFO] Writing PPM configuration to $PPM_CONF"
  mkdir -p "$PPM_DIR"
  cat > "$PPM_CONF" << EOF
# ============================
# Symas PPM Configuration
# ============================

# Minimum password length
minLength $PPM_MIN_LENGTH

# Character class requirements
minUpper $PPM_MIN_UPPER
minLower $PPM_MIN_LOWER
minDigit $PPM_MIN_DIGIT
minSpecial $PPM_MIN_SPECIAL

# Password history
historySize $PPM_HISTORY_SIZE

# Repetition control
maxRepeat $PPM_MAX_REPEAT

# Reject passwords containing username
rejectUsername $PPM_REJECT_USERNAME

# Reject dictionary-based passwords
rejectDictionary $PPM_REJECT_DICTIONARY

# Optional: forbid specific words
forbiddenWords $PPM_FORBIDDEN_WORDS
EOF

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown ldap:ldap "$PPM_CONF"
    chmod 600 "$PPM_CONF"
  else
    chmod 600 "$PPM_CONF" || true
    echo "[WARN] Not running as root; skipped chown on $PPM_CONF"
  fi

  current_ppm_conf="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b cn=config -s base olcPpmConfigFile | awk -F': ' '/^olcPpmConfigFile:/{print $2; exit}')"
  if [[ "$current_ppm_conf" != "$PPM_CONF" ]]; then
    ldif_file="$(mktemp /tmp/ppolicy-ppm-conf.XXXXXX.ldif)"
    cat > "$ldif_file" << EOF
dn: cn=config
changetype: modify
replace: olcPpmConfigFile
olcPpmConfigFile: $PPM_CONF
EOF
    if $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"; then
      rm -f "$ldif_file"
      echo "[INFO] Set olcPpmConfigFile to $PPM_CONF"
    else
      rm -f "$ldif_file"
      echo "[WARN] Failed to set olcPpmConfigFile; continuing without PPM." >&2
      PPM_AVAILABLE=0
    fi
  else
    echo "[INFO] olcPpmConfigFile already set to $PPM_CONF"
  fi
fi

auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ -n "$BIND_PW" ]]; then
  auth_args+=(-w "$BIND_PW")
else
  echo "[FATAL] BIND_PW is empty and could not be auto-detected from ${EXAMPLEDB_FILE}. Set BIND_PW to run non-interactively." >&2
  exit 1
fi

echo "[INFO] Updating password policy entry $POLICY_DN"
policy_result="$($LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base objectClass pwdCheckQuality pwdCheckModuleArg)"

needs_class=0
if ! echo "$policy_result" | grep -qi '^objectClass: pwdPolicyChecker$'; then
  needs_class=1
fi

current_quality="$(echo "$policy_result" | awk -F': ' '/^pwdCheckQuality:/{print $2; exit}')"
needs_quality=0
if [[ "$current_quality" != "2" ]]; then
  needs_quality=1
fi

needs_module_arg=0
encoded_arg=""
if [[ "$PPM_EMBED_CONFIG" == "1" && "$PPM_AVAILABLE" == "1" ]]; then
  if ! command -v base64 >/dev/null 2>&1; then
    echo "[FATAL] base64 not found but PPM_EMBED_CONFIG=1 was requested" >&2
    exit 1
  fi
  encoded_arg="$(base64 "$PPM_CONF" | tr -d '\n')"
  needs_module_arg=1
elif [[ "$PPM_EMBED_CONFIG" == "1" && "$PPM_AVAILABLE" != "1" ]]; then
  echo "[WARN] PPM_EMBED_CONFIG=1 requested but PPM could not be enabled; skipping pwdCheckModuleArg." >&2
fi

if [[ $needs_class -eq 0 && $needs_quality -eq 0 && $needs_module_arg -eq 0 ]]; then
  echo "[INFO] Password policy already enforces strong checks"
  exit 0
fi

ldif_file="$(mktemp /tmp/ppolicy-strong-check.XXXXXX.ldif)"
{
  echo "dn: $POLICY_DN"
  echo "changetype: modify"
  first_change=1
  if [[ $needs_class -eq 1 ]]; then
    echo "add: objectClass"
    echo "objectClass: pwdPolicyChecker"
    first_change=0
  fi
  if [[ $needs_quality -eq 1 ]]; then
    if [[ $first_change -eq 0 ]]; then
      echo "-"
    fi
    echo "replace: pwdCheckQuality"
    echo "pwdCheckQuality: 2"
    first_change=0
  fi
  if [[ $needs_module_arg -eq 1 ]]; then
    if [[ $first_change -eq 0 ]]; then
      echo "-"
    fi
    echo "replace: pwdCheckModuleArg"
    echo "pwdCheckModuleArg: $encoded_arg"
  fi
} > "$ldif_file"

$LDAPMODIFY "${auth_args[@]}" -f "$ldif_file"
rm -f "$ldif_file"

if [[ "${PPM_AVAILABLE:-0}" == "1" ]]; then
  echo "[SUCCESS] Password policy checker configured (PPM integration: enabled)"
else
  echo "[SUCCESS] Password policy checker configured (PPM integration: disabled)"
fi
