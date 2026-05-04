#!/usr/bin/env bash
set -euo pipefail

# Enable LDAPS (636) on all OpenLDAP nodes (masters + replicas) using SSM.
#
# This script:
# - Reads GA/NLB DNS names from a Terraform outputs snapshot JSON
# - Generates a shared CA + shared server cert (SAN contains GA+NLB names)
# - Pushes ca.crt + ldap.crt + ldap.key to every node
# - Updates cn=config TLS attributes via ldapi (no offline cn=config edits)
# - Updates SLAPD_URLS to include explicit ldap://IP:389 and ldaps://IP:636 (matches olcServerID)
#
# After this, clients can connect with:
# - `ldaps://<ga_write_dns>:636` (writes)
# - `ldaps://<ga_read_dns>:636`  (reads)

REGION="${1:-us-east-1}"
OUT_JSON="${2:-}"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
export AWS_REGION="${AWS_REGION:-$REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"

if [[ -z "$OUT_JSON" ]]; then
  OUT_JSON="reports/logs/terraform_openldap_outputs_$(date -u +%Y-%m-%d).json"
fi
if [[ ! -f "$OUT_JSON" ]]; then
  OUT_JSON="$(ls -1t reports/logs/terraform_openldap_outputs_*.json 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$OUT_JSON" || ! -f "$OUT_JSON" ]]; then
  echo "missing terraform outputs snapshot under reports/logs (run: cd terraform/openldap && terraform output -json > reports/logs/terraform_openldap_outputs_YYYY-MM-DD.json)" >&2
  exit 2
fi

dns_names="$(python3 - "$OUT_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
parts=[]
def add(x):
  if not x: return
  if isinstance(x,str):
    parts.append(x)
  elif isinstance(x,dict):
    for _,v in sorted(x.items()):
      if v: parts.append(v)
add(d.get("ga_write_dns",{}).get("value",""))
add(d.get("ga_read_dns",{}).get("value",""))
add(d.get("write_lb_dns",{}).get("value",{}))
add(d.get("read_lb_dns",{}).get("value",{}))
uniq=[]
for p in parts:
  if p not in uniq:
    uniq.append(p)
print(",".join(uniq))
PY
)"

GA_WRITE="$(python3 -c "import json; d=json.load(open('$OUT_JSON')); print(d.get('ga_write_dns',{}).get('value',''))")"
GA_READ="$(python3 -c "import json; d=json.load(open('$OUT_JSON')); print(d.get('ga_read_dns',{}).get('value',''))")"

echo "Using outputs: ${OUT_JSON}"
echo "TLS SAN DNS: ${dns_names}"
echo "GA write: ${GA_WRITE}"
echo "GA read : ${GA_READ}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CA_KEY="${tmp}/ca.key"
CA_CRT="${tmp}/ca.crt"
SRV_KEY="${tmp}/ldap.key"
SRV_CSR="${tmp}/ldap.csr"
SRV_CRT="${tmp}/ldap.crt"
SAN_CNF="${tmp}/san.cnf"

# Generate CA
openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
  -subj "/C=US/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
  -out "$CA_CRT" >/dev/null 2>&1

# Generate server cert with SANs for GA/NLB DNS names (shared across nodes for this lab).
openssl genrsa -out "$SRV_KEY" 4096 >/dev/null 2>&1

cn="${GA_WRITE:-openldap-mm}"
{
  echo "[ req ]"
  echo "default_bits       = 4096"
  echo "prompt             = no"
  echo "default_md         = sha256"
  echo "distinguished_name = dn"
  echo "req_extensions     = req_ext"
  echo
  echo "[ dn ]"
  echo "C=US"
  echo "O=Lab-Org"
  echo "OU=LDAP"
  echo "CN=${cn}"
  echo
  echo "[ req_ext ]"
  echo "subjectAltName = @alt_names"
  echo
  echo "[ alt_names ]"
  idx=1
  IFS=',' read -r -a names <<<"$dns_names"
  for n in "${names[@]}"; do
    [[ -n "$n" ]] || continue
    echo "DNS.${idx} = ${n}"
    idx=$((idx + 1))
  done
} >"$SAN_CNF"

openssl req -new -key "$SRV_KEY" -out "$SRV_CSR" -config "$SAN_CNF" >/dev/null 2>&1
openssl x509 -req -in "$SRV_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SRV_CRT" -days 825 -sha256 -extensions req_ext -extfile "$SAN_CNF" >/dev/null 2>&1

CA_CRT_B64="$(base64 <"$CA_CRT" | tr -d '\n')"
SRV_CRT_B64="$(base64 <"$SRV_CRT" | tr -d '\n')"
SRV_KEY_B64="$(base64 <"$SRV_KEY" | tr -d '\n')"

# Persist CA cert for local testing.
CA_OUT="reports/logs/openldap_mm_ca_$(date -u +%Y-%m-%d).crt"
cp -f "$CA_CRT" "$CA_OUT"
echo "Wrote CA cert for clients: ${CA_OUT}"

SSM_RUN="terraform/openldap/tools/ssm_run.sh"

nodes_tsv="${tmp}/nodes.tsv"
nodes_json="${tmp}/nodes.json"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=openldap-mm-*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,VPC:Tags[?Key=='VPC']|[0].Value,Role:Tags[?Key=='Role']|[0].Value,InstanceId:InstanceId,PrivateIp:PrivateIpAddress}" \
  --output json >"$nodes_json"

python3 - "$nodes_json" <<'PY' >"$nodes_tsv"
import json,sys
arr=json.load(open(sys.argv[1]))
arr=sorted(arr,key=lambda x:(x.get("VPC",""),x.get("Role",""),x.get("Name","")))
for x in arr:
  print("{}\t{}\t{}\t{}\t{}".format(
    x.get("InstanceId",""),
    x.get("Name",""),
    x.get("PrivateIp",""),
    x.get("VPC",""),
    x.get("Role",""),
  ))
PY

while IFS=$'\t' read -r iid name ip vpc role; do
  [[ -n "$iid" ]] || continue
  [[ -n "$name" ]] || name="$iid"
  echo "LDAPS on ${name} (${vpc}/${role})"

  "$SSM_RUN" "$REGION" "$iid" "$name" enable_ldaps "push certs + configure cn=config + restart" <<CMD
set -euo pipefail
sudo bash -lc '
set -euo pipefail
ip=""
if [ -f /opt/openldap/bootstrap/node.env ]; then
  # shellcheck disable=SC1091
  source /opt/openldap/bootstrap/node.env
  ip="\${PRIVATE_IP:-}"
fi
if [ -z "\$ip" ]; then
  ip="\$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n \"s/.* src \\\\([^ ]*\\\\).*/\\\\1/p\" | head -n 1)"
fi
if [ -z "\$ip" ]; then
  echo "[FATAL] cannot determine node private ip" >&2
  exit 1
fi

mkdir -p /opt/symas/etc/openldap/tls
echo "${CA_CRT_B64}" | base64 -d > /opt/symas/etc/openldap/tls/ca.crt
echo "${SRV_CRT_B64}" | base64 -d > /opt/symas/etc/openldap/tls/ldap.crt
echo "${SRV_KEY_B64}" | base64 -d > /opt/symas/etc/openldap/tls/ldap.key
chmod 600 /opt/symas/etc/openldap/tls/ldap.key
chmod 644 /opt/symas/etc/openldap/tls/ca.crt /opt/symas/etc/openldap/tls/ldap.crt

if id -u symas-openldap >/dev/null 2>&1; then
  chown symas-openldap:symas-openldap /opt/symas/etc/openldap/tls/* || true
elif id -u ldap >/dev/null 2>&1; then
  chown ldap:ldap /opt/symas/etc/openldap/tls/* || true
fi

export PATH=/opt/symas/bin:/opt/symas/sbin:\$PATH
cat >/tmp/tls.ldif <<LDIF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /opt/symas/etc/openldap/tls/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /opt/symas/etc/openldap/tls/ldap.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /opt/symas/etc/openldap/tls/ldap.key
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
LDIF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls.ldif

# SLAPD_URLS must include the explicit ldap://IP:389 to satisfy olcServerID URL matching.
cat >/etc/default/symas-openldap <<EOF
SLAPD_URLS="ldap://\${ip}:389 ldaps://\${ip}:636 ldapi:///"
SLAPD_OPTIONS="-F /opt/symas/etc/openldap/slapd.d"
EOF

systemctl daemon-reload
systemctl restart symas-openldap-servers || systemctl restart slapd
systemctl is-active symas-openldap-servers
ss -lntp | egrep ":(389|636)\\b" || true
'
CMD
done <"$nodes_tsv"

echo "OK: LDAPS enabled. GA endpoints: ${GA_WRITE}:636 (write), ${GA_READ}:636 (read)"
