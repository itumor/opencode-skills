#!/usr/bin/env bash
set -Eeuo pipefail

# collect-symas-diagnostics.sh
# Safe diagnostic bundle collector for Symas OpenLDAP on RHEL 9.
# Gathers config, logs, runtime state, TLS metadata, LDAP diagnostics.
#
# PRIVACY: This script does NOT export, dump, or include any LDAP
# user/employee/customer data. It captures only configuration (cn=config),
# system state, logs, and metadata. No slapcat -n 1 data dumps.
#
# Default behavior:
# - Redacts passwords, credentials, tokens, userPassword, olcRootPW, emails
# - Does NOT copy private keys
# - Does NOT copy raw LMDB files
# - Does NOT dump LDAP user data (entry counts only, no attributes/DNs)
#
# Usage:
#   sudo bash collect-symas-diagnostics.sh
#   sudo bash collect-symas-diagnostics.sh --since "14 days ago"
#   sudo bash collect-symas-diagnostics.sh --include-raw-db   # DANGER: raw data
#   sudo bash collect-symas-diagnostics.sh --no-redaction

CONFIG_DIR="/opt/symas/etc/openldap/slapd.d"
OPENLDAP_ETC="/opt/symas/etc/openldap"
DATA_DIR="/var/symas/openldap-data/example"
SINCE="7 days ago"
OUT_BASE="/tmp"
SERVICE_HINT=""
INCLUDE_RAW_DB="false"
INCLUDE_PRIVATE_KEYS="false"
REDACT="true"

HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_BASE}/symas-openldap-collect-${HOST}-${TS}"

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --config-dir PATH          slapd.d path.                 Default: ${CONFIG_DIR}
  --openldap-etc PATH        OpenLDAP etc path.            Default: ${OPENLDAP_ETC}
  --data-dir PATH            LMDB data dir.                Default: ${DATA_DIR}
  --out-base PATH            Output parent dir.            Default: /tmp
  --since "TIME"             journal/log time range.       Default: "7 days ago"
  --service NAME             systemd service name if known (e.g. symas-openldap)

  --include-raw-db           Copy raw data.mdb and lock.mdb. DANGER: all user data.
  --include-private-keys     Copy TLS private key files. Very sensitive.
  --no-redaction             Do not redact passwords/credentials from output.

  -h, --help                 Show help

Examples:
  sudo bash $0
  sudo bash $0 --since "24 hours ago"
  sudo bash $0 --service symas-openldap
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir)       CONFIG_DIR="$2";       shift 2 ;;
    --openldap-etc)     OPENLDAP_ETC="$2";     shift 2 ;;
    --data-dir)         DATA_DIR="$2";         shift 2 ;;
    --out-base)         OUT_BASE="$2";         shift 2 ;;
    --since)            SINCE="$2";            shift 2 ;;
    --service)          SERVICE_HINT="$2";     shift 2 ;;
    --include-raw-db)      INCLUDE_RAW_DB="true";       shift ;;
    --include-private-keys) INCLUDE_PRIVATE_KEYS="true"; shift ;;
    --no-redaction)        REDACT="false";             shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "${OUT_DIR}"/{commands,files,logs,ldap,system,meta,errors}
chmod 700 "${OUT_DIR}"

export PATH="/opt/symas/bin:/opt/symas/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

LDAPSEARCH="$(command -v ldapsearch || true)"
LDAPWHOAMI="$(command -v ldapwhoami || true)"
LDAPMODIFY="$(command -v ldapmodify || true)"
SLAPCAT="$(command -v slapcat || true)"
SLAPTEST="$(command -v slaptest || true)"
OPENSSL="$(command -v openssl || true)"
JOURNALCTL="$(command -v journalctl || true)"
SYSTEMCTL="$(command -v systemctl || true)"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${OUT_DIR}/meta/collector.log"
}

redact_stream() {
  if [[ "${REDACT}" == "false" ]]; then
    cat
  else
    sed -E \
      -e 's/(olcRootPW:[[:space:]]*).*/\1<REDACTED>/Ig' \
      -e 's/(userPassword(::|:)?[[:space:]]*).*/\1<REDACTED>/Ig' \
      -e 's/(credentials=)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(credential[s]?[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(bindpw[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(password[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(passwd[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(token[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(secret[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(api[-_]?key[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/(private[-_]?key[[:space:]]*[:=][[:space:]]*)[^,[:space:]]+/\1<REDACTED>/Ig' \
      -e 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/<EMAIL_REDACTED>/g'
  fi
}

run_shell() {
  local name="$1"
  local cmd="$2"
  local outfile="${OUT_DIR}/commands/${name}.txt"

  {
    echo "### COMMAND"
    echo "${cmd}"
    echo
    echo "### OUTPUT"
    bash -lc "${cmd}"
  } > "${outfile}.tmp" 2>&1 || {
    echo >> "${outfile}.tmp"
    echo "### EXIT_CODE: $?" >> "${outfile}.tmp"
  }

  redact_stream < "${outfile}.tmp" > "${outfile}"
  rm -f "${outfile}.tmp"
}

copy_text_file() {
  local src="$1"
  [[ -f "${src}" ]] || return 0

  local rel="${src#/}"
  local dst="${OUT_DIR}/files/${rel}"
  mkdir -p "$(dirname "${dst}")"

  if file "${src}" 2>/dev/null | grep -qiE 'text|ldif|ASCII|UTF-8|empty|script|certificate|PEM'; then
    redact_stream < "${src}" > "${dst}" || true
    chmod 600 "${dst}" || true
  else
    echo "Skipped non-text file: ${src}" >> "${OUT_DIR}/meta/skipped-files.txt"
  fi
}

copy_binary_file() {
  local src="$1"
  [[ -f "${src}" ]] || return 0

  local rel="${src#/}"
  local dst="${OUT_DIR}/files/${rel}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}" || true
}

copy_tree_text_redacted() {
  local src_dir="$1"
  [[ -d "${src_dir}" ]] || return 0

  find "${src_dir}" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    case "${f}" in
      *.key|*private*|*secret*)
        if [[ "${INCLUDE_PRIVATE_KEYS}" == "true" ]]; then
          copy_binary_file "${f}"
        else
          echo "Skipped sensitive key/private file: ${f}" >> "${OUT_DIR}/meta/skipped-files.txt"
        fi
        ;;
      *)
        copy_text_file "${f}"
        ;;
    esac
  done
}

# ── Collector functions ────────────────────────────────────────────────

collect_basic_meta() {
  log "Collecting basic host metadata"

  cat > "${OUT_DIR}/meta/README.txt" <<EOF
Symas OpenLDAP diagnostic bundle
Host: ${HOST}
Timestamp: ${TS}
Config dir: ${CONFIG_DIR}
OpenLDAP etc: ${OPENLDAP_ETC}
Data dir: ${DATA_DIR}
Since: ${SINCE}
Redaction enabled: ${REDACT}
Include raw DB: ${INCLUDE_RAW_DB}
Include private keys: ${INCLUDE_PRIVATE_KEYS}

PRIVACY: This bundle does NOT contain LDAP user/employee/customer data.
It captures only configuration (cn=config), system state, and logs.

IMPORTANT: Review this bundle before sharing externally.
Logs may contain usernames, DNs, IPs, hostnames, and operational data.
EOF

  run_shell "date"        "date -Is; uptime"
  run_shell "hostname"    "hostname; hostname -f || true; hostname -I || true"
  run_shell "os-release"  "cat /etc/os-release 2>/dev/null || true; uname -a"
  run_shell "whoami-id"   "whoami; id"
  run_shell "path-binaries" "echo PATH=\$PATH; which slapd || true; which ldapsearch || true; which ldapmodify || true; which slapcat || true; which slaptest || true"
  run_shell "versions"    "slapd -VV 2>&1 || true; ldapsearch -VV 2>&1 || true; slapcat -V 2>&1 || true"
  run_shell "packages-symas-openldap" "rpm -qa | sort | grep -Ei 'symas|openldap|cyrus|openssl|nss|krb|sasl' || true"
  run_shell "dnf-repos"   "dnf repolist all 2>/dev/null | grep -Ei 'symas|openldap|repo id|enabled' || true"
}

collect_systemd() {
  log "Collecting systemd/service information"

  run_shell "systemd-units-ldap" "systemctl list-unit-files 2>/dev/null | grep -Ei 'symas|ldap|slapd|solserver' || true"
  run_shell "systemd-running-ldap" "systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'symas|ldap|slapd|solserver' || true"

  local units=()
  if [[ -n "${SERVICE_HINT}" ]]; then
    units+=("${SERVICE_HINT}")
  fi

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] && units+=("${unit}")
  done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'symas|ldap|slapd|solserver' || true)

  printf '%s\n' "${units[@]}" | sort -u > "${OUT_DIR}/system/detected-services.txt"

  while IFS= read -r unit; do
    [[ -z "${unit}" ]] && continue
    run_shell "systemctl-status-${unit}" "systemctl status '${unit}' --no-pager -l 2>&1 || true"
    run_shell "systemctl-cat-${unit}"   "systemctl cat '${unit}' 2>&1 || true"
    run_shell "systemctl-show-${unit}"  "systemctl show '${unit}' 2>&1 || true"
  done < "${OUT_DIR}/system/detected-services.txt"
}

collect_runtime_process() {
  log "Collecting runtime process/network information"

  run_shell "ps-slapd"      "ps -efww | grep -E '[s]lapd|[s]olserver|[s]ymas' || true"
  run_shell "ports"         "ss -lntup 2>/dev/null | grep -Ei ':389|:636|ldap|slapd|symas' || ss -lntup 2>/dev/null || true"
  run_shell "lsof-ldap"     "lsof -nP 2>/dev/null | grep -Ei 'slapd|ldap|symas|data.mdb|lock.mdb' || true"
  run_shell "limits"        "ulimit -a"
  run_shell "sysctl-interesting" "sysctl fs.file-max net.core.somaxconn vm.max_map_count 2>/dev/null || true"
}

collect_files() {
  log "Copying selected config/schema/environment files"

  # slapd.d runtime config tree (redacted)
  copy_tree_text_redacted "${CONFIG_DIR}"

  # Schema files
  copy_tree_text_redacted "${OPENLDAP_ETC}/schema"

  # Key config files
  copy_text_file "${OPENLDAP_ETC}/ldap.conf"
  copy_text_file "${OPENLDAP_ETC}/slapd.conf"
  copy_text_file "/etc/profile.d/symas_env.sh"
  copy_text_file "/opt/symas/etc/openldap/symas_env.sh"
  copy_text_file "/opt/symas/etc/openldap/sysmas_env.sh"
  copy_text_file "/etc/yum.repos.d/symas.repo"

  # systemd unit files
  find /etc/systemd/system /usr/lib/systemd/system -maxdepth 1 -type f \
    \( -iname '*ldap*' -o -iname '*slapd*' -o -iname '*symas*' -o -iname '*solserver*' \) \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
      copy_text_file "${f}"
    done

  # TLS directory (certs only by default, private keys only if opted in)
  if [[ -d "${OPENLDAP_ETC}/tls" ]]; then
    find "${OPENLDAP_ETC}/tls" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
      case "${f}" in
        *.key|*private*|*secret*)
          if [[ "${INCLUDE_PRIVATE_KEYS}" == "true" ]]; then
            copy_binary_file "${f}"
          else
            echo "Skipped TLS/private key: ${f}" >> "${OUT_DIR}/meta/skipped-files.txt"
          fi
          ;;
        *.crt|*.pem|*.cer)
          copy_text_file "${f}"
          ;;
        *)
          copy_text_file "${f}"
          ;;
      esac
    done
  fi
}

collect_file_metadata() {
  log "Collecting file metadata and permissions"

  run_shell "tree-openldap-etc" "find '${OPENLDAP_ETC}' -maxdepth 6 -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true"
  run_shell "tree-data-dir"    "find '${DATA_DIR}' -maxdepth 3 -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort || true"
  run_shell "disk-usage"       "df -hT; echo; du -sh '${OPENLDAP_ETC}' '${DATA_DIR}' 2>/dev/null || true"
  run_shell "selinux-contexts" "getenforce 2>/dev/null || true; ls -lZ '${OPENLDAP_ETC}' '${CONFIG_DIR}' '${DATA_DIR}' 2>/dev/null || true"
}

collect_tls_metadata() {
  log "Collecting TLS certificate metadata"

  if [[ -n "${OPENSSL}" && -d "${OPENLDAP_ETC}/tls" ]]; then
    find "${OPENLDAP_ETC}/tls" -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.cer' \) -print0 2>/dev/null | while IFS= read -r -d '' cert; do
      safe_name="$(echo "${cert}" | sed 's#[/ ]#_#g')"
      run_shell "cert-${safe_name}" "openssl x509 -in '${cert}' -noout -subject -issuer -serial -dates -fingerprint -sha256 2>&1 || true"
    done
  fi
}

collect_ldap_queries() {
  log "Collecting LDAP/cn=config diagnostics"

  if [[ -z "${LDAPSEARCH}" ]]; then
    echo "ldapsearch not found" > "${OUT_DIR}/errors/ldapsearch-not-found.txt"
    return 0
  fi

  run_shell "ldap-whoami-external" \
    "ldapwhoami -Y EXTERNAL -H ldapi:/// 2>&1 || true"

  run_shell "cn-config-dn-tree" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config dn 2>&1 || true"

  run_shell "cn-config-root-global" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config -s base '*' '+' 2>&1 || true"

  run_shell "cn-config-modules" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(objectClass=olcModuleList)' dn olcModulePath olcModuleLoad 2>&1 || true"

  run_shell "cn-config-databases" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(olcDatabase=*)' dn olcDatabase olcSuffix olcDbDirectory olcRootDN olcAccess olcReadOnly olcUpdateRef olcSyncrepl olcDbIndex 2>&1 || true"

  run_shell "cn-config-acls" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(olcDatabase=*)' dn olcAccess 2>&1 || true"

  run_shell "cn-config-syncrepl" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(olcSyncrepl=*)' dn olcSyncrepl olcUpdateRef olcReadOnly 2>&1 || true"

  run_shell "cn-config-ppolicy-overlay" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(olcOverlay=ppolicy)' dn objectClass olcOverlay olcPPolicyDefault olcPPolicyHashCleartext olcPPolicyUseLockout olcPPolicyForwardUpdates 2>&1 || true"

  run_shell "cn-config-syncprov-overlay" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config '(olcOverlay=syncprov)' dn objectClass olcOverlay olcSpCheckpoint olcSpSessionlog 2>&1 || true"

  run_shell "cn-config-schema-list" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=schema,cn=config dn cn 2>&1 || true"

  run_shell "cn-config-tls" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=config -s base olcTLSCACertificateFile olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCipherSuite olcTLSProtocolMin 2>&1 || true"

  run_shell "root-dse" \
    "ldapsearch -x -LLL -o ldif-wrap=no -s base -b '' '*' '+' 2>&1 || true"

  run_shell "monitor" \
    "ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -o ldif-wrap=no -b cn=Monitor -s base '*' '+' 2>&1 || true"
}

collect_slapcat() {
  log "Collecting slapcat/slaptest outputs"

  if [[ -n "${SLAPTEST}" ]]; then
    run_shell "slaptest-config-check" "slaptest -F '${CONFIG_DIR}' -u 2>&1 || true"
  else
    echo "slaptest not found" > "${OUT_DIR}/errors/slaptest-not-found.txt"
  fi

  if [[ -n "${SLAPCAT}" ]]; then
    run_shell "slapcat-config-n0" "slapcat -F '${CONFIG_DIR}' -n 0 2>&1 || true"

    run_shell "slapcat-data-stats" \
      "echo 'Entry count:'; slapcat -F '${CONFIG_DIR}' -n 1 2>/dev/null | grep -c '^dn:' || echo '0'; echo; echo 'Top-level DNs (no attributes):'; slapcat -F '${CONFIG_DIR}' -n 1 -s one -a '(objectClass=*)' 2>&1 | grep '^dn:' || true"
  else
    echo "slapcat not found" > "${OUT_DIR}/errors/slapcat-not-found.txt"
  fi
}

collect_raw_db_optional() {
  if [[ "${INCLUDE_RAW_DB}" != "true" ]]; then
    echo "Skipped raw LMDB files. --include-raw-db copies ALL user data — use only with explicit approval and delete after review." > "${OUT_DIR}/meta/raw-db-skipped.txt"
    return 0
  fi

  log "Copying raw LMDB database files because --include-raw-db was used"

  mkdir -p "${OUT_DIR}/files/${DATA_DIR#/}"
  for f in "${DATA_DIR}/data.mdb" "${DATA_DIR}/lock.mdb"; do
    if [[ -f "${f}" ]]; then
      copy_binary_file "${f}"
    fi
  done
}

collect_logs() {
  log "Collecting logs"

  if [[ -n "${JOURNALCTL}" ]]; then
    run_shell "journal-all-ldap-since" \
      "journalctl --since '${SINCE}' --no-pager -o short-iso 2>/dev/null | grep -Ei 'ldap|slapd|symas|solserver|mdb|ppolicy|syncprov|syncrepl|TLS|SASL|bind|ACL|constraint|error|fail|warn' || true"

    if [[ -f "${OUT_DIR}/system/detected-services.txt" ]]; then
      while IFS= read -r unit; do
        [[ -z "${unit}" ]] && continue
        run_shell "journal-${unit}" \
          "journalctl -u '${unit}' --since '${SINCE}' --no-pager -o short-iso 2>&1 || true"
      done < "${OUT_DIR}/system/detected-services.txt"
    fi

    run_shell "journal-slapd-identifier" \
      "journalctl SYSLOG_IDENTIFIER=slapd --since '${SINCE}' --no-pager -o short-iso 2>&1 || true"
  fi

  for lf in \
    /var/log/messages \
    /var/log/secure \
    /var/log/audit/audit.log \
    /var/log/syslog \
    /var/log/daemon.log
  do
    if [[ -f "${lf}" ]]; then
      base="$(echo "${lf}" | sed 's#/#_#g')"
      run_shell "log-${base}" \
        "grep -Ei 'ldap|slapd|symas|solserver|mdb|ppolicy|syncprov|syncrepl|TLS|SASL|bind|ACL|constraint|error|fail|warn' '${lf}' 2>/dev/null || true"
    fi
  done

  find /var/log -maxdepth 3 -type f \
    \( -iname '*ldap*' -o -iname '*slapd*' -o -iname '*symas*' -o -iname '*solserver*' \) \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
      base="$(echo "${f}" | sed 's#/#_#g')"
      run_shell "log-file-${base}" "cat '${f}' 2>/dev/null || true"
    done
}

create_summary() {
  log "Creating quick summary"

  {
    echo "# Symas OpenLDAP Diagnostic Summary"
    echo
    echo "Host: ${HOST}"
    echo "Timestamp: ${TS}"
    echo "Output: ${OUT_DIR}"
    echo
    echo "## Detected services"
    cat "${OUT_DIR}/system/detected-services.txt" 2>/dev/null || true
    echo
    echo "## Important files copied"
    find "${OUT_DIR}/files" -type f 2>/dev/null | sed "s#${OUT_DIR}/files/##" | sort | head -300 || true
    echo
    echo "## Skipped files (private keys, LMDB — excluded for privacy)"
    cat "${OUT_DIR}/meta/skipped-files.txt" 2>/dev/null || true
    cat "${OUT_DIR}/meta/raw-db-skipped.txt" 2>/dev/null || true
    echo
    echo "## Errors"
    find "${OUT_DIR}/errors" -type f -maxdepth 1 -print -exec cat {} \; 2>/dev/null || true
  } > "${OUT_DIR}/SUMMARY.md"
}

make_archive() {
  log "Creating tar.gz archive"

  local parent
  parent="$(dirname "${OUT_DIR}")"
  local base
  base="$(basename "${OUT_DIR}")"
  local archive="${OUT_DIR}.tar.gz"

  tar -czf "${archive}" -C "${parent}" "${base}"
  sha256sum "${archive}" > "${archive}.sha256" 2>/dev/null || true

  echo
  echo "============================================"
  echo " Diagnostic collection complete."
  echo "============================================"
  echo " Bundle: ${archive}"
  echo " Checksum: ${archive}.sha256"
  echo
  echo " Review before sharing:"
  echo "   tar -tzf ${archive} | less"
  echo "   grep -RniE 'password|credential|secret|token|private|userPassword|olcRootPW|@.*\.' ${OUT_DIR}"
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "WARNING: Not running as root. Some logs/configs may be missing." | tee -a "${OUT_DIR}/meta/collector.log"
  fi

  if [[ "${REDACT}" == "false" ]]; then
    echo "WARNING: --no-redaction used. Bundle will contain raw passwords, credentials, and emails." | tee -a "${OUT_DIR}/meta/collector.log"
  fi

  if [[ "${INCLUDE_PRIVATE_KEYS}" == "true" ]]; then
    echo "WARNING: --include-private-keys used. Bundle may contain TLS private keys." | tee -a "${OUT_DIR}/meta/collector.log"
  fi

  if [[ "${INCLUDE_RAW_DB}" == "true" ]]; then
    echo "DANGER: --include-raw-db used. Bundle will contain ALL LDAP user/employee/customer data. Review and delete after use." | tee -a "${OUT_DIR}/meta/collector.log"
  fi

  collect_basic_meta
  collect_systemd
  collect_runtime_process
  collect_files
  collect_file_metadata
  collect_tls_metadata
  collect_ldap_queries
  collect_slapcat
  collect_raw_db_optional
  collect_logs
  create_summary
  make_archive
}

main "$@"
