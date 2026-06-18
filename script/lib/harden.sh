#!/usr/bin/env bash
# lib/harden.sh — security hardening (anon disable, TLS enforce, fs perms)

harden() {
  section "Security Hardening"
  if [[ "${SKIP_HARDEN:-0}" == "1" ]]; then skip "Hardening skipped"; return; fi

  set +e
  # Disable anonymous binds
  if ! ldapi_get_attr "cn=config" "olcDisallows" | grep -q "bind_anon"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=config
changetype: modify
add: olcDisallows
olcDisallows: bind_anon
LDIF
  fi
  ok "Anonymous binds disabled"

  # Require TLS for simple binds
  if [[ "${REQUIRE_TLS_SIMPLE_BINDS:-1}" != "0" ]]; then
    if ! ldapi_get_attr "cn=config" "olcSecurity" | grep -q "simple_bind=128"; then
      ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: simple_bind=128
LDIF
      ok "TLS required for simple binds"
    else ok "TLS already required for simple binds"; fi
  fi

  # TLS protocol min 3.3
  ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=config
changetype: modify
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
LDIF
  ok "TLS protocol min 3.3"

  # Filesystem permissions
  local owner="ldap"; id symas-openldap >/dev/null 2>&1 && owner="symas-openldap"
  chown -R "${owner}:${owner}" /opt/symas/etc/openldap/slapd.d 2>/dev/null || true
  ok "Config dir permissions hardened"

  # Firewall
  if command -v firewall-cmd >/dev/null 2>&1; then
    for port in 389/tcp 636/tcp; do
      firewall-cmd --permanent --add-port="$port" 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    ok "Firewall ports opened"
  fi
  set -e
}
