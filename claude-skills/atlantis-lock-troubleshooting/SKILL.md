---
name: atlantis-lock-troubleshooting
description: Use when an Atlantis lock is stuck/orphaned and blocks plans — "discard plan & unlock won't work", "No lock found" on the lock-detail page, a lock left by a merged/closed MR, or a lock stranded on the OLD Atlantis after a repo's webhook moved to a new instance. Covers finding which Atlantis holds the lock, the broken detail-href bug, and clearing it headlessly via the DELETE /locks API (== the UI button). EIS IaC: shared Atlantis = atlantis-iac.dev.aws0.iac.aws.eislab.cloud; per-client EC2 = aws0<code>atlantis01.infra.aws0.<code>.eislab.cloud.
---

# Atlantis lock troubleshooting

An Atlantis project/workspace lock is held in Atlantis's own BoltDB (NOT terraform state). A merged/closed MR, or a repo migrated to a different Atlantis instance, can leave the lock **orphaned** — blocking new plans for that dir. Clearing it discards only the stored plan + lock; it touches **no terraform state, no AWS, no infra**.

## 0. Which Atlantis holds the lock? (the migration trap)

`atlantis unlock` commented on an MR routes to the repo's **current webhook target only**. If the repo was switched to a new Atlantis (e.g. shared → per-client EC2), a lock created on the OLD instance during early plans is now unreachable by comment — the bot will happily reply "All Atlantis locks for this PR have been unlocked" while the orphan survives elsewhere.

```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com
# current webhook (the only instance MR comments reach):
glab api "projects/<url-enc-path>/hooks" | python3 -c "import json,sys;[print(h['url']) for h in json.load(sys.stdin)]"
# role_default/role_pnthub in lower/*/global.tfvars also name the instances.
```
EIS instances: shared IaC = `https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud`; per-client = `https://aws0<code>atlantis01.infra.aws0.<code>.eislab.cloud`. URLs resolve **in-VPC only (VPN)**.

## 1. List locks on each candidate instance

```bash
curl -sk --max-time 12 "<atlantis>/" -o /tmp/atl.html
grep -oiE "<repo-name>/terraform #[0-9]+" /tmp/atl.html | sort -u   # which MRs hold locks
grep -oiE 'href="/lock\?id=[^"]+"' /tmp/atl.html                    # detail links
```

## 2. Find the REAL lock key (detail-href is buggy)

The index lock-detail href wrongly appends the **project name** to the dir path → e.g. `…/lower/infra/bootstrap/default/lower-infra-bootstrap`. Opening it returns `No lock found` — so the UI "Discard Plan & Unlock" button is dead for that lock. The real key is `<repoFullName>/<dir>/<workspace>` with **no** project-name suffix.

Probe candidates (HIT = ~3KB page with "Discard Plan & Unlock"; MISS = 115-byte "No lock found"):
```bash
base="https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud"
enc(){ python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe='').replace('%','%25'))" "$1"; }
key="iac/projects/aws/pto-reference/terraform/lower/infra/bootstrap/default"   # repo/dir/workspace
curl -sk "$base/lock?id=$(enc "$key")" | grep -qi "No lock found" && echo MISS || echo HIT
```
The valid detail page's `#discardYes` button carries `data="<single-enc real key>"` — that's the authoritative key.

## 3. Clear it (== the Discard Plan & Unlock button)

Routes: GET detail = `/lock` (singular); **DELETE = `/locks` (plural)**. `DELETE /lock` → 405.
```bash
curl -sk -X DELETE --max-time 15 -w "\nHTTP %{http_code}\n" "$base/locks?id=$(enc "$key")"
# → Deleted lock id '...'   HTTP 200
```

## 4. Verify
```bash
curl -sk "$base/" | grep -coiE "<repo-name>/terraform #"   # expect 0 for that repo (or only active MRs)
```
Leave locks belonging to **open** MRs alone — only discard orphans (merged/closed MRs, or wrong-instance leftovers).

## Related Atlantis-iac issues
- `atlantis plan` → "Text file busy"/segfault on the IaC Atlantis = truncated terraform binary from a concurrent-fetch race → use skill **atlantis-iac-binary-recovery** (rm corrupt `/atlantis-data/bin/terraform<ver>` + restart pod `atlantis-0`, both needed).
- State-lock (`.tflock` in S3) acquire 403 = plan/apply role missing `s3:PutObject` on `<prefix>tfstate/*` — a permission bug, not a stuck lock.

Reference run: pto-reference !11 (merged 2026-01-16, "switch to EC2 atlantis") — lock orphaned on shared IaC Atlantis, cleared 2026-06-25. Memory: `atlantis_orphaned_lock_post_migration.md`.
