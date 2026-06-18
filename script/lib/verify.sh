#!/usr/bin/env bash
# lib/verify.sh — health checks (auto-detects master vs replica)
# ponytail: single source of truth for all health checks

verify() {
  section "Health Verification"
  local role=$(detect_role)

  # ---- Service ----
  local svc=$(find_service)
  if [[ -n "$svc" ]]; then
    systemctl is-active --quiet "$svc" 2>/dev/null && ok "$svc is running" || bad "$svc not running"
  else
    pgrep -x slapd >/dev/null 2>&1 && ok "slapd running (no systemd)" || bad "slapd not running"
  fi

  # ---- Ports ----
  port_listening 389 && ok "Port 389 listening" || bad "Port 389 not reachable"
  port_listening 636 && ok "Port 636 listening" || warn "Port 636 not reachable"

  # ---- LDAPI ----
  ldapi_whoami >/dev/null 2>&1 && ok "LDAPI EXTERNAL bind works" || bad "LDAPI EXTERNAL bind failed"

  # ---- Admin TLS bind ----
  if admin_bind; then
    ok "Admin StartTLS bind works"
  else
    bad "Admin StartTLS bind failed — check ADMIN_PW/TLS"
  fi

  # ---- Base DN ----
  if admin_search "${BASE_DN}" -s base -LLL dn 2>/dev/null | grep -q "^dn:"; then
    ok "Base DN readable"
  else
    bad "Base DN not readable"
  fi

  # ---- Entry count ----
  local entries=$(entry_count)
  ok "Entry count: ${entries}"

  # ---- contextCSN ----
  local csn=$(get_context_csn)
  [[ -n "$csn" ]] && ok "contextCSN: ${csn}" || warn "No contextCSN found"

  # ---- Syncprov (master only) ----
  if [[ "$role" == "master" ]]; then
    has_overlay "syncprov" && ok "Syncprov overlay present" || warn "Syncprov overlay missing"
  fi

  # ---- Syncrepl indices ----
  local db=$(db_dn)
  local idx=$(ldapi_search "$db" -s base -LLL olcDbIndex 2>/dev/null || true)
  echo "$idx" | grep -q "entryUUID" && ok "entryUUID index present" || warn "entryUUID index missing"
  echo "$idx" | grep -q "entryCSN" && ok "entryCSN index present" || warn "entryCSN index missing"

  # ---- Replica-specific ----
  if [[ "$role" == "replica" ]]; then
    # Syncrepl config
    ldapi_search "$db" -s base -LLL olcSyncrepl 2>/dev/null | grep -q "starttls=yes" \
      && ok "Syncrepl uses StartTLS" || warn "Syncrepl missing starttls=yes"
    ldapi_get_attr "$db" "olcReadOnly" | grep -q "TRUE" \
      && ok "Database is readonly" || warn "Database not readonly"
    # ppolicy overlay
    has_overlay "ppolicy" && ok "ppolicy overlay present" || warn "ppolicy overlay missing"
  fi

  # ---- Replicator bind (master) ----
  if [[ "$role" == "master" ]]; then
    repl_bind && ok "Replicator StartTLS bind works" || warn "Replicator bind failed"
  fi

  # ---- Log analysis ----
  if [[ -n "$svc" ]]; then
    local log=$(journalctl -u "$svc" --no-pager --since "5 minutes ago" 2>/dev/null || true)
    echo "$log" | grep -qi "checksum error" && warn "Checksum errors in logs" || ok "No checksum errors"
    echo "$log" | grep -qi "err=13\|confidentiality required" && warn "err=13 in logs" || ok "No err=13"
    echo "$log" | grep -qi "TLS negotiation failure" && warn "TLS failures in logs" || ok "No TLS failures"
  fi
}
