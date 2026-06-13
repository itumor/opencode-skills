---
name: vault-agent-ssl-onboarding
description: Use when deploying the vault_agent_ssl Ansible role to a host that has non-standard cert paths, non-standard cert filenames, or a Docker nginx container that doesn't match the default grep pattern. Also use when a host's TLS cert has expired because vault-agent was never deployed there.
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
