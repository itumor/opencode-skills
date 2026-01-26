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

PPOLICY_DN="${PPOLICY_DN:-}"
POLICY_DN="${POLICY_DN:-cn=default,ou=Policies,dc=eab,dc=bank,dc=local}"
LDAP_URI="${LDAP_URI:-ldap:///}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
BIND_PW="${BIND_PW:-}"

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

module_loads="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b "$module_dn" -s base olcModuleLoad || true)"
if ! echo "$module_loads" | grep -qi '^olcModuleLoad: ppm$'; then
  ldif_file="$(mktemp /tmp/ppm-module-load.XXXXXX.ldif)"
  cat > "$ldif_file" << EOF
dn: $module_dn
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppm
EOF
  $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"
  rm -f "$ldif_file"
  echo "[INFO] Loaded PPM module in $module_dn"
else
  echo "[INFO] PPM module already loaded in $module_dn"
fi

if [[ -z "$PPOLICY_DN" ]]; then
  echo "[INFO] Locating ppolicy overlay entry..."
  PPOLICY_DN="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b cn=config '(olcOverlay=ppolicy)' dn olcPPolicyCheckModule | awk '/^dn: /{print $2; exit}')"
fi
if [[ -z "$PPOLICY_DN" ]]; then
  echo "[FATAL] ppolicy overlay not found under cn=config" >&2
  exit 1
fi

ppolicy_current="$($LDAPSEARCH "${CONFIG_AUTH[@]}" -b "$PPOLICY_DN" -s base olcPPolicyCheckModule | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}')"
if [[ "$ppolicy_current" != "ppm" ]]; then
  ldif_file="$(mktemp /tmp/ppolicy-check-module.XXXXXX.ldif)"
  cat > "$ldif_file" << EOF
dn: $PPOLICY_DN
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: ppm
EOF
  $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"
  rm -f "$ldif_file"
  echo "[INFO] Set olcPPolicyCheckModule to ppm on $PPOLICY_DN"
else
  echo "[INFO] olcPPolicyCheckModule already set to ppm on $PPOLICY_DN"
fi

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
  $LDAPMODIFY "${CONFIG_AUTH[@]}" -f "$ldif_file"
  rm -f "$ldif_file"
  echo "[INFO] Set olcPpmConfigFile to $PPM_CONF"
else
  echo "[INFO] olcPpmConfigFile already set to $PPM_CONF"
fi

auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ -n "$BIND_PW" ]]; then
  auth_args+=(-w "$BIND_PW")
else
  auth_args+=(-W)
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
if [[ "$PPM_EMBED_CONFIG" == "1" ]]; then
  if ! command -v base64 >/dev/null 2>&1; then
    echo "[FATAL] base64 not found but PPM_EMBED_CONFIG=1 was requested" >&2
    exit 1
  fi
  encoded_arg="$(base64 "$PPM_CONF" | tr -d '\n')"
  needs_module_arg=1
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

echo "[SUCCESS] Strong password quality checker (PPM) enabled"
