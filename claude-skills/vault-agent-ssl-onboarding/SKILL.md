---
name: vault-agent-ssl-onboarding
description: Use when deploying the vault_agent_ssl Ansible role to a host that has non-standard cert paths, non-standard cert filenames, or a Docker nginx container that doesn't match the default grep pattern. Also use when a host's TLS cert has expired because vault-agent was never deployed there, or when the host terminates TLS via a Kubernetes/RKE2 ingress secret (no docker nginx) — e.g. Sisense aws0caasis01.
---

# vault-agent-ssl onboarding — non-standard host

## Role defaults (reference)

| Var | Default |
|-----|---------|
| `host_ssl_path` | `/opt/ssl` |
| `vault_agent_cert_file_name` | `certificate.cer` |
| `vault_agent_key_file_name` | `private.key` |
| `vault_agent_ca_file_name` | `ca.cer` |
| `nginx_contaner` | `$(docker ps … grep -E '^(nginx\|dashboard-proxy)' \| head -n1)` |
| `project_name` | `ansible` → Vault path `secret2/data/ansible/ssl/…` |
| `project_zone` | looked up from Vault `dns_zone` key |

## Overriding for a non-standard host

Create `inventory/host_vars/<hostname>.yaml` with only the vars that differ:

```yaml
# Example: Keycloak host
host_ssl_path: /opt/compose/keycloak/data/conf.d

vault_agent_cert_file_name: fullchain.pem   # nginx expects this exact name
vault_agent_key_file_name:  privkey.pem
vault_agent_ca_file_name:   ca.cer

# nginx container name doesn't match default grep pattern
nginx_contaner: keycloak-nginx-1

# Vault cert path: secret2/data/caa/ssl/infra.aws0.caa-eis.cloud/ecdsa
project_name: caa
project_zone:  infra.aws0.caa-eis.cloud
```

## nginx_contaner trap

Default grep `'^(nginx|dashboard-proxy)'` misses containers named like `keycloak-nginx-1`, `myapp-nginx`, etc.  
The role has a **multi-token guard** — if the expression resolves to more than one word, the script aborts.  
Override `nginx_contaner` with the exact container name when the default won't match.

## Targeted playbook (don't reuse vault_agent.yaml)

`vault_agent.yaml` targets `all`. Create a separate playbook targeting only the new host:

```yaml
---
- hosts: aws0caakeycloak01
  roles:
    - vault_agent_ssl
```

Run via Docker runner:
```bash
./docker/run.sh playbook playbooks/keycloak.yaml --become --check   # dry run
./docker/run.sh playbook playbooks/keycloak.yaml --become           # apply
```

## Diagnose first: never-deployed vs reload-bug vs k8s-ingress

A host serving an expired cert can be one of three things — check before assuming:

```bash
systemctl is-active vault-agent          # inactive + no /etc/vault.d + empty journal => NEVER deployed
cat /etc/vault.d/nginx-reload.sh         # present but multi-container grep => reload bug (COEXT-104228)
which docker || which kubectl            # no docker + kubectl present => K8s/RKE2 ingress host (below)
echo | openssl s_client -connect localhost:443 -servername <fqdn> 2>/dev/null | openssl x509 -noout -dates
```

Don't trust a ticket note's root-cause guess (sis01 was filed as "same as grok01 reload bug" but was actually never-deployed + K8s ingress).

## K8s / RKE2 ingress host (no docker nginx) — e.g. Sisense aws0caasis01

Here the role's docker-nginx reload **does not apply**. TLS is terminated by an in-cluster
ingress reading a `kubernetes.io/tls` secret. Find the wiring:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml   # rke2 default
K=/usr/local/bin/kubectl                          # NOT on the SSM shell PATH — use absolute path
$K get ingress -A
$K get secret -A --field-selector type=kubernetes.io/tls   # sis01: sisense/sisense-tls
```

Fix = render cert from Vault (no systemd, no docker) **then** re-apply the K8s secret. Run with
`vault_access: false` so only the "Render SSL manually" block runs (controller-side Vault lookup,
`no_log`, copied to `/opt/ssl` over the aws_ssm/S3 channel — key never hits CloudTrail):

```yaml
- name: Restore TLS cert (RKE2 ingress host)
  hosts: aws0caasis01
  gather_facts: false
  become: true
  vars:
    vault_access: false          # manual render only — no vault-agent service, no docker reload
    kubeconfig: /etc/rancher/rke2/rke2.yaml
    kubectl: /usr/local/bin/kubectl   # absolute — SSM shell PATH lacks /usr/local/bin
    sisense_fqdn: aws0caasis01.infra.aws0.caa-eis.cloud
  roles:
    - vault_agent_ssl
  post_tasks:
    - name: Back up + replace the ingress TLS secret
      ansible.builtin.shell: |
        set -eo pipefail
        export KUBECONFIG={{ kubeconfig }}
        {{ kubectl }} -n sisense get secret sisense-tls -o yaml > /opt/ssl/sisense-tls.bak.yaml
        {{ kubectl }} -n sisense create secret tls sisense-tls \
          --cert=/opt/ssl/certificate.cer --key=/opt/ssl/private.key \
          --dry-run=client -o yaml | {{ kubectl }} apply -f -
      args: {executable: /bin/bash}
    # nginx-ingress auto-reloads on secret change (dynamic SSL) — no pod restart.
    # Verify, only restart the DS as fallback:
    - name: Verify served cert is non-expired
      ansible.builtin.shell: |
        echo | openssl s_client -connect localhost:443 -servername {{ sisense_fqdn }} 2>/dev/null \
          | openssl x509 -checkend 86400 -noout && echo SERVED-VALID
      args: {executable: /bin/bash}
      changed_when: false
```

Full working version: `credit-agricole/ansible/playbooks/sisense_cert.yaml`.

Notes:
- `project_name`/`project_zone` already resolve from group_vars (`all.yml`=caa, `infra.yaml`=infra zone) → only `vault_access:false` is strictly needed.
- Vendored CAA `roles/vault_agent_ssl` is **v1.1.1** (has the `vault_access` toggle) even though `requirements.yml` pins v1.1.0.
- This is an **immediate restore only** — there is still no auto-renewal on a K8s-ingress host (docker reload hook doesn't fit). Durable fix = vault-agent/cron that renders **and** re-applies the secret; track as a follow-up.

## Check-mode false failure

In `--check` mode the handler `Start vault-agent and enable at startup` will fail with `Could not find the requested service vault-agent`. This is expected — the service unit file isn't actually written in check mode. Real run succeeds.

## Vault path formula

```
secret2/data/<project_name>/ssl/<project_zone>/ecdsa
```

`project_name != 'ansible'` → AppRole fetched from `secret2/data/common/identities/…` (not project-specific).

## Verification

```bash
systemctl status vault-agent
ls -la <host_ssl_path>/
openssl x509 -noout -dates -in <host_ssl_path>/<cert_file>
```
