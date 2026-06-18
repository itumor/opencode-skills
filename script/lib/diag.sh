#!/usr/bin/env bash
# lib/diag.sh — diagnostics: status dump, log collection, reports
# ponytail: collect what matters, no fluff

diag() {
  section "Diagnostics"
  if [[ "${SKIP_DIAG:-0}" == "1" ]]; then
    skip "Diagnostics skipped (SKIP_DIAG=1)"
    return
  fi

  diag_status
  diag_logs
  ok "Diagnostics collected"
}

diag_status() {
  section "Status Report"
  local svc=$(find_service 2>/dev/null || echo "unknown")
  local role=$(detect_role)

  info "Role:     ${role}"
  info "Service:  ${svc}"
  info "Hostname: $(hostname -f 2>/dev/null || hostname)"

  # contextCSN
  local csn=$(get_context_csn)
  [[ -n "$csn" ]] && info "contextCSN: ${csn}" || warn "No contextCSN"

  # Entry counts
  local entries=$(entry_count)
  info "Entries:  ${entries}"

  # Ports
  port_listening 389 && info "Port 389:  listening" || warn "Port 389: closed"
  port_listening 636 && info "Port 636:  listening" || warn "Port 636: closed"

  # TLS cert expiry
  local cert="${TLS_DIR}/ldap.crt"
  if [[ -f "$cert" ]]; then
    local expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/.*=//')
    info "TLS cert expires: ${expiry:-unknown}"
  else
    warn "No TLS cert found at ${cert}"
  fi

  # DB files
  for dbdir in /var/symas/openldap-data/example /var/symas/openldap-data/accesslog; do
    if [[ -d "$dbdir" ]]; then
      local size=$(du -sh "$dbdir" 2>/dev/null | awk '{print $1}')
      info "DB ${dbdir}: ${size}"
    fi
  done
}

diag_logs() {
  section "Recent Logs (last 20 lines)"
  local svc=$(find_service 2>/dev/null || true)
  if [[ -n "$svc" ]]; then
    journalctl -u "$svc" --no-pager -n 20 2>/dev/null | while IFS= read -r line; do
      info "$line"
    done
  else
    warn "No service found for log collection"
  fi
}
