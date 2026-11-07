---
name: php-inventory-scan
description: Use when asked to find PHP (or any package/runtime) in all VMs and containers of a client env - "PHP2SHELL", "inventory installed php packages", COEXT-112121, "images not scanned", "unexpected EOF on trivy", "UNAUTHORIZED on registry". Runs ~/.claude/scripts/php-inventory.sh / caa-php-run.sh, proves zero with a positive control, and clears the "unscanned image" list.
---

# PHP / package inventory (VMs + containers)

Tools (all read-only except SSM collector): `~/.claude/scripts/caa-php-run.sh` (`check|control|discover|eks|ecr|ec2|hosts|report|all`), `php-inventory.sh` (modes `fleet discover eks eks-fleet ecr-fleet eks-audit images retry ec2 ec2-fleet`), `php-inventory-report.py`, `registry-cred-probe.py`. All have `--selftest`. Reference run: CAA, COEXT-112121, 2026-11-06 (0 PHP, 459/459 images).

## Quick start (any accounts / clusters)
```bash
S=~/.claude/scripts/php-inventory.sh; O=~/php-inventory/<client>-$(date +%F)
bash $S images php:8.3-cli --out $O/control             # positive control: must flag PHP
bash $S fleet <profile1> <profile2> --out $O --jobs 3   # discover -> every EKS -> newest ECR per repo -> retry -> report (xlsx + html)
bash $S retry --out $O                                   # after docker login / VPN blip: rescan every .err
bash $S eks --context <ctx> --profile <p> --out $O       # one cluster only
bash $S ec2-fleet --inventory $O/inventory.tsv --out $O --yes   # USER runs (SSM send-command)
python3 -I ~/.claude/scripts/php-inventory-report.py $O --accounts <id,id> --title "<client> PHP"
```
Optional `$O/account-profiles.tsv` (`account<TAB>read-profile<TAB>write-profile`) picks ECR/EKS/SSM profiles per account. Private EKS endpoint -> `eks-audit`. Second scanner for a disputed/vendor image: `syft registry:<ref> --platform linux/amd64 --scope all-layers -o syft-json=F` with `SYFT_FILE_METADATA_SELECTION=all`, then jq `.artifacts[].name` and `.files[].location.path` for php (brew syft, added 2026-11-06).

## Rules
1. **Positive control first**: `php:8.3-cli` must be flagged (`caa-php-run.sh control`). Zero results count only after CONTROL PASS the same day.
2. Detection = trivy php/composer pkgs + `PHP_VERSION`/`PHP_*` image env + layer history. Official php images are built from source, no OS package: env/history is the only signal.
3. **One `--out` dir per session.** `discover` rewrites `inventory.tsv` with `>`; a second session or `ec2` during discover sees 0 targets or clobbers it. Use `hosts` (guards against concurrent discover).
4. **`--jobs <=3` per registry/Nexus over VPN (~0.4 MB/s).** More saturates the link and Nexus truncates layers: `unexpected EOF`, `semaphore acquire: context deadline exceeded` (trivy 5 min default; use `--timeout 15m`). Retry with a loop, do not call it "unscannable".
5. **Platform trap: host is arm64, nodes are amd64.** A manifest-list digest scanned/inspected without `--platform linux/amd64` pulls the arm64 manifest (error names an arm64 child digest). Fix: `trivy image --platform linux/amd64 ...`, find the child with `docker buildx imagetools inspect <ref>`. COEXT-112121: nexus `minio` + `bitnami/solr` looked "unscanned" for this reason, both rescanned clean in ~1-6 min.
6. Do not trust a "digest gone / not found" reason from another session; probe `docker buildx imagetools inspect <ref>` on the actual registry first.
7. **Known false positive:** `docker.io/library/sonarqube` -> `org.sonarsource.php:sonar-php-plugin` (type `jar`) = SonarQube's PHP code analyzer in Java, no PHP runtime. Report it as FP, not a finding (pref-dev 2026-11-06).
8. **Remediating a PHP sample app via Argo CD:** merge is not removal. Check the owning app's `.status.operationState` (a `Prune=confirm` app can be stuck on an old prune and skip auto-sync; manual-sync apps need Sync+Prune by the user), then rescan only when `kubectl get pods -A` shows no PHP image. Skill `argocd-playground-first` Gotchas.

## Unscanned-image triage
| Symptom | Meaning | Action |
|---|---|---|
| 401 / UNAUTHORIZED, vendor private (ghcr.io/scaleops-sh) | needs registry login | 1) `registry-cred-probe.py --manifest <repo>:<tag>` on the cluster pull secret (prints status/fingerprint only). 2) Try the vendor's OTHER registry host in the same secret: ScaleOps ghcr PAT is suspended but `registry.scaleops.com/scaleops-sh:<tag>` = 200, same digest. 3) Scan with creds in env only (`TRIVY_USERNAME/PASSWORD`, `SYFT_REGISTRY_AUTH_*`), never echo. User OK'd using our own pull secrets 2026-11-06 |
| 403 from a vendor registry in a python probe | CDN blocks `Python-urllib` User-Agent, NOT a dead cred | send a User-Agent (probe script does); 403 -> 200 for registry.scaleops.com |
| docker.io 401 on public image (minio/minio, even `latest`) | vendor withdrew Docker Hub images | scan the same digest from an internal mirror (Nexus); same sha256 = byte-identical |
| 401 on cvops-reg01 | no docker login | host collector env/history check (`docker image inspect` + history) already covers it |
| NAME_UNKNOWN | repo deleted | CloudTrail for delete; image only in host cache |
| `unsupported artifact type` | OCI static-js artifact, not an image | note, no scan |
| unexpected EOF | VPN truncation | retry loop, lower --jobs, rescan single ref |

## Before you start: other sessions
`ps -axo etime,command | grep '[p]hp-inventory.sh'` - on 2026-11-06 three sessions (fleet run + 2 CAA sessions) scanned the same Nexus at once: VPN stalled for ~10 min, every registry timed out, Nexus truncated layers. One scanner per env; message the other session and split by env/source, do not race.

## Scope + coverage
- Accounts = EIS-owned only (profiles in `~/.aws/config` + client repo `lower/` `upper/` dirs). Account ids in the client repo for PrivateLink/KMS are client-owned: list them as out of scope, no access.
- Env table per account: EKS (context), EC2 (SSM Online Linux / not SSM / Windows / EKS nodes), ECR repos. Private-only EKS: check `aws eks describe-cluster ... resourcesVpcConfig` (`endpointPublicAccess=false`) before blaming VPN.
- ECR: `ecr-fleet` scans only the NEWEST image per repo. Full sweep = every tagged digest (`describe-images` -> `images --file`); untagged digests are mostly per-arch children of multi-arch indexes or superseded pushes - state the count, skip unless asked.
- EKS add-on images `602401143452.dkr.ecr.<region>` need `--profile <any acct in that region> --region <region>` on `images` mode (no account-profiles.tsv row).
- Skip multi-GB images already proven false positive (gitlab-ce ~3 GB, hits 15 min timeout): `pkill -f '<out>/trivy/<registry>_gitlab_gitlab-ce'`; record as deliberate gap.

## Merge results (dedupe across sessions/dirs)
`python3 -I ~/.claude/scripts/php-inventory-merge.py OUT.tsv --tagmap <ecr-all-images.tsv> --images dev=images-<ctx>.tsv --images prod=... --ecr upper=ecr-all-images.tsv --refs hosts=refs.txt` (`--selftest`). Status per ref from ANY trivy result under `~/php-inventory`: exact ref, else same sha256 digest (a Nexus image whose ECR copy scanned counts), else ECR tag->digest via tagmap. Gaps = rows not `ok*`; feed their refs to one low-`--jobs` retry run.

## Known false positives (not a PHP runtime)
| Hit | Why |
|---|---|
| gitlab-ce node-pkg `php` (`.../vscode/extensions/php/package.json`, `sourcegraph-php`) | Web IDE syntax extension |
| Datadog agent python-pkg `datadog-php-fpm` | Python monitoring check |
| sonarqube jar `org.sonarsource.php:sonar-php-plugin` | Java PHP code analyzer |

Verified PHP-free (2026-11-06, trivy + syft all layers): `minio/minio@sha256:bd11edda…` (RHEL 8.3 + Go, 268 pkgs), `scaleops-sh@sha256:3bca33db…` v1.27.2 (Alpine 3.22.3, 24 layers, 873 pkgs).
| collector `php-binary` `.../rouge/demos/php`, `.../unixODBC/.../php3.html` | text/doc files with exec bit; non-default docker root (`/local/OPT/docker`) is not pruned, so layer files are walked |

## Deliverable
`~/gitwork/iac/docs/<KEY>-<client>-php-inventory.md`: verdict, coverage table (env -> account/profile -> cluster/context -> EC2 -> ECR -> n/m scanned + result), findings + false positives, not-scanned table (item, count, why, mitigation), next steps, scan logic + rerun commands, Jira draft. Reference: `docs/COEXT-112121-caa-php-inventory.md`.

## Private EKS (upper CAA): `eks-audit` (Logs Insights over control-plane audit log, ~$1.40/run). No SSM on upper EC2: Amazon Inspector agentless. Windows hosts: collector is Linux-only, run the PowerShell check by hand. Hand-back = Jira wiki comment, caveman, user posts it; keep the 3 gap lines (Windows host, EKS node OS, unscanned refs) honest.

## More traps (caa-2026-11-06 run, session d31e0ca7)
- **Config-only level** when Nexus/VPN too slow for layers: `docker buildx imagetools inspect <ref> --format '{{json .Image}}'` (env + history, no layers). Count as "No PHP (config only)" in `config-check.tsv`, never inside the full-trivy number. Memory `image_config_only_check_slow_registry.md`.
- **eks-audit:** Logs Insights auto-extracts only ~200 fields, nested `requestObject` containers come back EMPTY without error -> parse raw `@message` (script does). Istio `image: auto` = placeholder, skip. Delete raw result JSON (inline env values). Immutable ECR repo -> audit tag = exact digest.
- **Inspector agentless** lists only VULNERABLE packages; 0 php needs positive control (kernel/python findings on same host). EKS nodes may be tag-excluded -> node OS gap. Memory `inspector_agentless_ec2_without_ssm.md`.
- **Lower test cluster:** `CAA-Lower-ReadOnly` has no EKS access entry (Unauthorized) -> `Credit-Agricole` profile for `kubectl get pods` only.
- **Report per env:** `php-inventory-report.py OUT --accounts A,B --title T --report X.html` + optional `env-map.tsv` (regex, env, basis), `cluster-notes.tsv`, `ec2-notes.tsv`, `config-check.tsv`. Environment = last column every sheet. Env from `Stage` tag = verified; from ECR repo path = inferred, say so.
- **Orchestration:** waiter `pgrep -f pattern` matches itself (use `[p]attern`); a job ending kills the trivy server it started (other jobs then "connection refused"); edit the running script via copy + `mv`. Memory `long_running_scan_orchestration_gotchas.md`.
