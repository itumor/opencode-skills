---
name: ai-mr-review-bakeoff
description: Use when evaluating, comparing or re-testing AI merge-request reviewers or automated MR checks (PR-Agent, Kodus/Kody, Alibaba Open Code Review, a linter or custom checker, a new LLM model) on EIS GitLab repos — "which review bot is best", "rank the review tools", "score this reviewer", "add a new tool/model to the bake-off", "re-run on a blind set", "update the bake-off dashboard", "do the review skills/instructions help", "test with the rules off", "run skills arms S0/S1/S2". Runs sandbox copies, replay + planted + blind held-out MRs, independent scoring, pooled results and the shareable dashboard.
---

# AI MR-review bake-off

Measure reviewers on GitLab MRs the honest way: sandbox copies, real past MRs, seeded bugs, **blind** held-out sets, independent scoring, then pooled results. The reference run (2026-10-08/09) lives in `eramadan/mr-review-agents` (GitLab project 1632; local `~/gitwork/mr-review-agents`). Dashboard: https://claude.ai/artifact/SkJVC4fALu4YA67oPoBWiC.

Read first: memories `mr_review_bakeoff_pilot`, `feedback_freeze_kodus_config_during_blind_set`, `feedback_blind_heldout_eval`, `gitlab_sandbox_ci_config_path_pattern`, `pr_agent_selfhost_gotchas`, `kodus_selfhost_gotchas`, `eis_ai_router_model_ids`, `ci_runner_egress_host_artifacts_in_gitlab`.

## 1. Sandbox (reuse if it exists)
- Sandboxes are `eramadan/argocd-review-sandbox` (1630) and `eramadan/clusters-template-review-sandbox` (1631). They are plain copies with no fork link, so they never deploy anything.
- `ci_config_path` points at `.gitlab-ci.yml@eramadan/mr-review-agents`, so only the tools' jobs run.
- Jobs are chosen with the project var `REVIEW_TOOLS` (anchored regex per job name). Reset it to the default after launching.
- Each new tool gets its own dir and `review.yml` in the tools repo, an `include:` line in the root CI file, MR-only rules, `tags: [docker]`, and `allow_failure`.
- Binaries and data go in the repo or its generic package registry. The runner's internet egress is flaky.
- Model-specific runs use `extends:` plus job-level `variables:`. Never use project vars for this: they are injected at job start and would contaminate queued jobs.

## 2. LLM endpoint
- Run `smoke/smoke.yml` (pipeline source `api`) first. It lists model ids, probes context sizes via a vLLM `max_tokens` 400, and tests tool calling.
- Copy model ids exactly as `/v1/models` returns them. Benchmark labels differ from router ids.
- Turn off Qwen thinking where the tool allows it (`chat_template_kwargs.enable_thinking=false`).

## 3. Test sets
1. **Replay MRs.** Build them from upstream `diff_refs` (`replay/<iid>-base` / `-head`). Use these for false positives and known later-fixed bugs; a separate agent derives the ground truth from follow-up MRs.
2. **Planted MRs.** Seeded bugs with an answer key. These are only for debugging; tuning against them makes any score optimistic.
3. **Blind held-out sets** (the only score that counts):
   - A fresh author agent is forbidden from reading the tools repo, the `eval/` dir, earlier keys and MR notes.
   - It writes about 10 MRs: 3 clean and roughly 12 defects across 7 or more categories.
   - The answer key is kept in scratch, outside every repo.
   - Subagents cannot commit, so the main loop commits and pushes the `heldoutN/*` branches. Never push to main.
   - Open the MRs with `REVIEW_TOOLS` set, wait about 20 s, then reset it.

## 4. Scoring
- Use an independent scorer agent, never the builder.
- Labels:
  - **TP-known:** matches a key defect.
  - **TP-other:** verified against the code.
  - **FP:** wrong, speculative, or the right line for the wrong reason.
  - **Nit**
- Report two rates: FP raw and FP per distinct defect.
- Output JSON in the `eval/*-scored.json` schema, one row per MR × cell, satisfying `findings == tp_known + tp_other + fp + nit`.
- Compare like with like. If a tool ran on only one repo, recompute the others on that subset.
- **Pool all blind sets before ranking.** About 12 defects per set swings verdicts.
- Bar used so far: at least 2/3 of defects found and FP per distinct defect below 20%.

## 4b. Re-running a new job on the old MRs (procedure from the pr-agent-ctx round, 2026-10-09)
1. Opt-in job per variant; flip `REVIEW_TOOLS` per project (read the current value, set, create `POST merge_requests/<iid>/pipelines`, wait ~25 s, restore the READ value). Waves of at most 12 jobs: job timeout counts runner queue time and the runner has ~4 slots.
2. Collect per MR into a JSON record: job `duration` (already excludes queue; do not subtract `queued_duration`), PR-Agent tokens, retry/verify trace lines, the notes created after `started_at` (paginate notes). Keep the archived records of every round (`ctxrun-v1`, degraded batch).
3. Check run health BEFORE scoring: failed jobs, verify `error` verdicts, median duration vs the earlier round. Router saturation by other users shows as LLM timeouts; discard the batch and re-run in a quiet window (waves of 7).
4. Scorer agent: brief file with inputs, cells and output schema; cells = new job (verified note), same run raw notes (ablation), old job re-scored like-with-like (earliest complete run), plus previous scored files; also ask for verifier drops of true defects, unverified-flag precision and secret quotes.
5. A verify pass must not drop what it cannot disprove: three verdicts (confirmed / unverified / rejected), reject only on contradicting evidence; process words in the MR description ("do not merge", "bake-off") must never count as intent. The first version dropped 10 true findings (10/24 vs 17/24 raw).
6. Same-model self-verification adds no recall; report both columns (verified and raw) and the single-run noise (identical code differed by 3 defects).
7. Freeze protocol with a concurrent blind-set session: `FROZEN <full sha>` only after every flip-needing run is finished; see memory reference_bakeoff_multisession_coordination.

## 5. Dashboard
- It is a Dashboard-type artifact. Every number comes from datasets: `runs`, `matrix`, `defects`, `examples`, `traits`, `ho_runs`, `ho_matrix`, `ho_defects`, `pooled`, `ranking`.
- To update:
  1. Rebuild the JSON in `scratchpad/dash`.
  2. Upload it with Artifact `asset:true`.
  3. Write a `datasets/<id>` update with `if_version` and a new `source.url`.
  4. Edit `files/index.html` (calcs plus render functions).
  5. Run the calc offline with node against the JSON.
  6. Delete the superseded blobs.
- Never put bait or secret values in the datasets.

## Launching a blind set when other sessions own the tools (learned 2026-10-09, set 3)
1. Author in a fresh scratch dir with clones of both sandboxes that have the earlier-set branches removed; commit locally only (scan diffs with gitleaks plus hint words first). The author may list every changed file, the main loop checks the worktrees against `mr-map.json`.
2. Do NOT push or open MRs until all gates are in: each tool session sends a frozen SHA / `KODUS READY` with a state block (helm rev, model alias, token identity, config toggle, rules count and origin); runner quiet (no running/pending/created pipelines on both sandboxes, 3 consecutive checks); the user's decision on missing arms (e.g. Kodus not wired to 1631).
3. One owner opens the MRs (launcher: `open TOOLS`, `run TOOLS N0 N1`, `status`; refuses to flip `REVIEW_TOOLS` unless it reads the default `none`; resets to it; logs UTC times). `pr-agent-ctx` and `pr-agent-tuned` never share an MR run: verify folds every PR-Agent note posted after it starts.
4. Webhook tools (Kodus) start at MR open: open MRs last, after the Kodus config is final; a helm upgrade or model change mid-run voids that arm.
5. Score with: posted findings = confirmed + unverified; "Contradicted by the files" excluded but suppressed TPs recorded; job failures and router-saturation windows recorded separately from findings; label each arm with model + config SHA.
6. If strangers touch the sandboxes: `glab api projects/<id>/events?action=pushed`, then search other sessions' transcripts for the branch prefix. See [[feedback_multi_session_shared_reply_and_staged_launch]] (memory).

## Kodus (self-hosted) in the bake-off
- Pin down config BEFORE any blind set: helm rev, `API_LLM_PROVIDER_MODEL`, token identity (use a GROUP access token so comments post as a bot; project bots cannot join a second project), `kodus-config.yml` + its per-repo UI toggle, rule generator off. Record all five in the results; any change mid-set voids Kodus for that set.
- Kody Rules are auto-mined from existing MR comments (`origin=past_reviews`, API `kody-rules/find-by-organization-id`): connecting Kodus to a repo that already holds other tools' notes contaminates it. Check origins before scoring; never trust a remembered provenance.
- Speed: put a LiteLLM proxy in front of the router that injects `chat_template_kwargs.enable_thinking=false` (Kodus only sends `reasoningEffort`); model A/B = change `API_LLM_PROVIDER_MODEL` + helm upgrade. Time with `@kody start-review --force` on 3 fixed MRs one at a time; Kody edits ONE status note, so latency = note `updated_at - trigger`. The router is shared: repeat, and don't overlap other sessions' CI waves.
- Handshake with the scoring session: send `KODUS READY` (helm rev, model, token identity, toggle, rules count/origin) only after all helm upgrades and UI clicks; the scorer opens MRs; do not touch Kodus until `DONE`. A restart mid-run (helm upgrade, worker bounce) leaves MRs with only "Code Review Started": void and rerun.
- Full trap list: memories `kodus_selfhost_gotchas`, `kodus_jira_dc_mcp_business_logic`, `feedback_freeze_kodus_config_during_blind_set`.

## Guards and credentials (this harness)
- deploy-guard and prod-guard block pushes to main and every cluster write (helm, kubectl apply/patch/restart) unless the user clicks Proceed. Hand those over as paste-ready commands with the literal `--context` ARN.
- Never handle tokens. The user creates project access tokens and masked, unprotected CI vars.
- For cluster secrets, open a Terminal tab with a `read -rs` one-liner. `!` mode cannot read hidden input.
- Verify secrets by key name, flags and length only.

## 6. Model matrix (7 router models x tools), added 2026-10-09
Memory `mr_review_model_matrix_bench` has the state. Procedure:
0. **Pre-flight (2026-10-09, before any flip).** `GET projects/<pid>/pipelines?status=running` and `?status=pending` on both sandboxes, then each pipeline's jobs (`GET projects/<pid>/pipelines/<id>/jobs`). Classify by job name. Pipelines with live `pr-agent-*-coder` / `pr-agent-tuned` / `pr-agent-ctx` jobs belong to another session: leave them. Pipelines whose only jobs are stale (e.g. `bench-ocr` after OCR removal) need the user's OK to cancel. A job pending with no runner never finishes, so a "running" count can stall for hours. Record the variable's current value (`REVIEW_TOOLS` is `pr-agent-tuned-coder` on both sandboxes, not `none`).
1. `bench/` in the tools repo (jobs `bench-probe`, `bench-pr-agent`; `bench-ocr` was removed from main 2026-10-09 with OCR; `aggregate.py` joins metrics, scores and `eval/bench-manifest.json`; scored files use the RAW router id, not the slug). Run probe first: pipeline `POST projects/<pid>/pipeline?ref=main` (source api).
2. Always canary one MR first and check `metrics-*.json` in the artifacts: proxy tokens must equal PR-Agent's footer. `publish_output=false` prints nothing in 0.47.0, so bench posts per-model notes and copies them to artifacts.
3. MR pipelines take no variables: set project var `REVIEW_TOOLS=bench-pr-agent`, `POST projects/<pid>/merge_requests/<iid>/pipelines` per MR, then restore the value you READ in step 0 (rules fire at creation, so restoring right after the POSTs is enough; verify each new pipeline has `bench-pr-agent` jobs). Never overlap two triggers (shared var). Long loops: put them in a script file, `@file` target lists (zsh does not split `$(...)`). Done 2026-10-09: argocd !9-!21 and clusters !5-!11, 20 pipelines.
4. Bench jobs clone the tools repo sparse WITHOUT `eval/` and `docs/` and drop the remote (answer keys live there). Existing pr-agent/ocr/kodus jobs still leak.
5. A model that stalls on the router (Qwen3.5 on 2026-10-09) hogs ~4 runner slots: cancel its queued jobs (`hold_model.py`, record ids, retry later) and report it.
6. Review any subagent-built CI with a second reviewer agent before the user pushes; rerun selftests 10x.

## Finish
State the pooled ranking with scope and caveats: tuning provenance, thin margins, speed, and what it takes to run. Commit `eval/` locally, give the user the push command, and update the dashboard and the pilot memory.

## 7. Hardening + blind-set-3 A/B/C/D run (2026-10-09, DSH session)
Memory: `mr_review_security_and_verify_pipeline`, `helm_offline_render_chart_cache`, `kodus_concurrency_queue_clock_and_trigger`, `blind3_vs_heldout3_multisession_collision`.

- **Security (P0):** shared redaction in `det-checks/secrets.py` (key-name + value-shape: PEM/base64/AWS/GitHub/JWT/Slack/Google/OpenAI/ssh). `scrub_gate` re-scans scrubbed text and WITHHOLDS any note it can't guarantee (posts one idempotent degraded note instead); `ctx.py scrub-notes` (no LLM) scrubs+folds raw notes when verify is skipped so no secret stays posted. Egress: `kodus/network-policy/egress.yaml` (default-deny; DNS/in-cluster/GitLab/router only) is inert until `aws-eks-nodeagent --enable-network-policy=true` (cluster-admin, human). Docs: `credentials-migration.md` (prepared, not executed), `remediation-tls-key.md` (CONFIDENTIAL, fingerprint-based).
- **Context (P0):** `pr-agent-ctx` now renders before/after per affected deployment (field-level: args/env/resources/SA/IAM-annotations/RBAC/secret-refs/added-deleted; non-workload changes fall back to changed dotted paths so EFFECT is never bare). Offline via the pinned `det-checks/chart-cache/` (25 sha256 tgz, 137/143 charts render; 3 unobtainable -> UNKNOWN). Mechanics in `helm_offline_render_chart_cache`.
- **Verify (P0):** deterministic pre-pass (det-checks auto-confirm same-file line±10; renderer auto-reject effect-claims on byte-identical files) BEFORE any LLM call; LLM only for the rest, now with severity; idempotent posting by (MR, head SHA) via `<!-- pr-agent-ctx:verified sha=<12> -->`; inline discussions (CTX_INLINE, default on, `position_type: text`); degraded banner when all LLM calls fail; `verify --no-llm` (CTX_VERIFY=0) for the context-only config.
- **Benchmark configs (all on ONE frozen model — user chose qwen3-coder-next 2026-10-09):** A=`pr-agent-tuned-coder`, B=`pr-agent-ctx-coder-noverify` (CTX_VERIFY=0), C=`pr-agent-ctx-coder`, D=Kodus (argocd subset; shadow on clusters). The `-coder` variants are job-level `LLM_MODEL: qwen3-coder-next` (never a project var). NOTE: a child job's `rules:` REPLACE the parent's — repeat any project-specific rule (e.g. the 1631 `CTX_CHARTS_REPO`) in the child.
- **Triggering Kodus (D) on existing/frozen MRs:** Kodus has NO on-demand review API; it reviews on a NEW COMMIT (`last_commit.id != oldrev`). Push an empty commit to each head branch to fire the webhook; the diff is byte-identical, update the answer-key head_sha. Concurrency is `WORKFLOW_QUEUE_CODE_REVIEW_PREFETCH` (set 2); queue clock is Postgres `kodus_workflow.workflow_jobs`.
- **Runner contention:** a concurrent 7-model bench matrix (`bench-*` jobs) saturates the shared runners + router (OCR 2 min -> 18+ min). Pre-flight: list running/pending pipelines on both sandboxes, classify by job name, and either wait for the bench to drain or get the user's OK to cancel. `wait-config.sh`/`bench-status.sh` in scratch poll a config's jobs to terminal.
- **Multi-session:** two "blind set 3" efforts coexisted (this session's `blind3/*` 28 MRs vs another's `heldout3/*` 20 MRs). Label every result row with branch prefix + config SHA; never pool them; coordinate `REVIEW_TOOLS` flips (see `blind3_vs_heldout3_multisession_collision`).
- **Scoring:** `eval/score.py` (recall + Wilson CI, precision raw + wrong-per-distinct-defect, FP-on-clean, p50/p95, tokens, paired sign test). Independent scorer agent labels every finding TP-known/TP-other/FP/Nit; a withheld/degraded note = zero findings.

## 8. Scoring lessons (2026-10-10, 512k PR-Agent run on original + blind1+2)
In order:
1. **Fetch** bench artifacts: `python3 bench/aggregate.py fetch --project 1630 --iids 1-21` and `--project 1631 --iids 1-11`. Idempotent. Layout keeps the latest job per (tool, model, MR). Over 10 min for 32 MRs: run in background, not a 120 s foreground call.
2. **Split scorers** by set (original 12 MRs; blind1+2 20 MRs), two opus agents in parallel. Brief = rubric path, key path (`keys-all.json`, top-level `mrs` list), MR list from the manifest, output schema, GET-only, no reading other cells. Each returns a rows JSON plus judgement calls in prose.
3. **Validate before use:** `findings == tp_known+tp_other+fp+nit`; `len(labels) == findings`; caught ids belong to that MR's key; caught in NATURAL key order (K2 before K10; a lexical sort gives false alarms); set and class match the manifest.
4. **Strict variant (rubric §4 tie-break):** list every TP-known the scorer marked "alt FP" in judgement calls, flip them, recompute, report both columns. On this run the flips moved blind pooled 16/24 → 11/24 and FP 16% → 50%.
5. **Summarize:** `aggregate.py summarize` lists EVERY tool sharing the model id (OCR cells too). Filter by tool. Default `--out-dir` is the repo `eval/bench`; pass a scratch dir unless committing.
6. **Known deviation:** aggregate's `fp_rate_per_distinct_pct` counts TP-other per finding; rubric §6 counts distinct issues. Align before publishing.
7. **Anti-leak spot check:** `GET projects/<pid>/jobs/<id>/trace`, grep for `eval/` and `docs/`. Expect `tools clone: eval/ docs/ excluded; partial clone filter=blob:none` (checked on argocd !7 job 2547554).
8. **Diffs endpoint:** `merge_requests/<iid>/diffs` returned HTTP 500 on every sandbox MR (10-10). Use `repository/compare` (base_sha → head_sha) and raw files at the head sha.
9. Do not read another session's blind MRs for debugging. See [[reference_bakeoff_multisession_coordination]].

## 8. Webhook-arm runner (pr_agent_bench.py, 2026-10-14)
Arms on the same MRs: `publish` once, then per arm `trigger --label X --commands /review,/improve --wave 4`, `collect --label X`, independent scorer. Pass an absolute `--dir`; `collect` is not time-filtered (record the arm start and filter `created_at`); a `Failed to review PR` note shows as TIMEOUT; never change config or sandbox main (e.g. AGENTS.md) mid-arm; any file added to sandbox main confounds later arms. Compare arms paired per case (sign test) and report single-run noise (~±2 defects). Traps: memory `pr_agent_bench_runner_gotchas`; results: `pr_agent_wh1_arm_a_d_results`.

## 9. Giant planted MRs, no-merge tuning arms, blind set from slots (2026-10-14)
Result: deterministic det-checks v3 8/15 blind (0 FP on clean) vs PR-Agent 3/15; prompt rewrites lost recall. Memory `pr-agent-crazy-mr-stress-test`, report on GENESIS-447327 (`reference-pr-agent-jira-ticket`).
1. **Authors edit, main loop commits.** Harness R9 blocks sub-agent `git checkout/commit`: give author agents a clean slot, let them edit + `git add -N .`, write key/description to scratch; the main loop creates the branch, scans the diff for hint words and token shapes, commits with explicit paths, pushes, opens the MR via `glab api --input <json>`.
2. **Blind slots:** `git clone --single-branch --branch main` of each sandbox (no other refs to peek at), then `git worktree add --detach <slot> main` per MR. Forbid reading tools repo, keys, memory. argocd slots must avoid `components/` (playground-first pre-push guard blocks it; a skip trailer would leak a hint; for a planted components/ MR the user pushes it).
3. **Two reviewers fire on open:** CI job via `REVIEW_TOOLS` (bot `bf03`/`98b9`) and webhook (bot `36cf`/`7aa7`, auto `/review`+`/improve` when parity is live). Separate them by author; the webhook can fail on 25k+ token diffs (see skill `pr-agent-webhook-server` gotchas): record failures as their own row, retry once in a quiet window.
4. **No-merge tuning arm:** project CI vars override job YAML vars. Set candidate instructions as temporary raw project vars, flip `REVIEW_TOOLS` to the arm jobs (e.g. `pr-agent-tuned,pr-agent-tuned-coder`), create MR pipelines, restore `REVIEW_TOOLS` at once, delete the vars only after every job left created/pending (background cleanup with a hard 60 min delete). Split notes per model by the run-details footer.
5. **Deterministic cells run locally:** `python3 det-checks/check.py --repo <slot> --base main --head HEAD --json ...` with `DET_CHART_CACHE=<tools>/det-checks/chart-cache`; no token, no posting. Score them like any reviewer; group repeated items (same check + component + issue) into one finding.
6. **Slices:** `git diff main <head> -- <paths> | git apply --index` per area into new branches (script file, not inline: R7 does not expand `$vars`). Slices lose cross-file defects; score the union across slices.
7. **Order of claims:** stress MRs are debug grade (built by the tuning session); only blind numbers go into recommendations. A fix found on a blind MR after scoring is a v3.1 note, not a blind result.
8. **Subagent-built CI tools get a security reviewer before push**, then re-review each fix round until `BLOCKING: NO` (det-checks v3 needed 3 rounds: dependency-name path traversal, unbounded Jinja/regex, symlinked outputs, root jail).

## 10. Webhook model A/B with no deploy (2026-10-14)
Result: on 24 wh1 MRs, `qwen3.x-27b-h100` scored 15/24 with 2 FP; `Qwen/Qwen3.5-27B-FP8` scored 13/24 with 9 FP. The hub now runs h100 with FP8 and 35B-A3B as fallbacks (argocd !491). Memory `pr-agent-webhook-model-sweep-1014`. Kit: `~/pr-agent-bench/model-sweep-2026-10-14/` (run_models.py, run_wh1.py, make_cells.py, brief.md, brief-wh1.md).
1. **Per-comment override:** post `/review --config.model=hosted_vllm/<router id>` and the same for `/improve`. The hub config is kept and only the model changes, so nothing is deployed. Check that the note footer `Model:` equals the override.
2. **Check ids first:** list `/v1/models` before the run (key `EIS_API_KEY` in `~/.dsh/.credentials.yaml`). The user's names often don't exist. Probe each model with a 1-token request that passes the webhook's `extra_body`.
3. **Pre-flight:** both sandboxes have no running pipelines, and the hub pod log shows no "Reviewing PR" in the last 5-10 min. Other sessions open sandbox MRs that auto-review.
4. **Run:** take waves of 4 MRs. Within a wave, run model A then model B, and alternate which model goes first in each wave. Each MR thread posts `/review`, waits for the bot note (bot ids: 1630=961, 1631=962), then posts `/improve`. Use a 900 s wait cap. Write the results to a JSON file incrementally.
5. **Failure reads:**
   - A note starting `Failed to` = FAILED. Check the pod log: a fast fail is unparseable YAML, a 600 s one is two 300 s timeouts.
   - No note at all can mean `/improve` found nothing ("No code suggestions found" in the pod log). Score that as empty, not as a timeout.
6. **Blind scoring:** relabel the models X/Y or M1..M7 with a seeded shuffle and keep the map in a file the scorer is forbidden to read. Strip the footer from each body. Use one scorer per repo, verifying claims at head_sha with GET-only calls. Validate `findings == tp_known+tp_other+fp+nit`, then unblind, then run a sign test on the discordant defects.
7. **Report** speed (p50/p95 per command), failures, recall, FP, precision and FP-on-clean. Slack posts and Jira comments are blocked for the AI (hook M1), so hand back a report file plus a Jira wiki-markup comment file.

## 11. Skills arms on the CI job + rules ablation (2026-10-14/15)
Memory: `pr_agent_skills_arms_results` (numbers, caveats), `reference_review_arms_runner_gotchas` (traps). Scripts: `scripts/` here (set `ARMS_DIR`, `ARMS_PID`, `ARMS_CI_BOT`; run with `python3 -I`; `arm_run.py --dry-run` first).
1. **Arms are JOBS, not variable flips.** `pr-agent-tuned-skills-org` / `...-org-argocd` extend `pr-agent-tuned` with a job-level `REVIEW_SKILLS`; S0 is plain `pr-agent-tuned`. A project var is read at job start and contaminates queued jobs of the previous arm. One arm per pipeline and window: several jobs of one bot on one MR cannot be told apart in the notes.
2. **Skill-targeted blind set.** The old planted sets (ArgoCD semantics) cannot measure hygiene skills. The author must know the skills' categories but never sees reviewer output: 7 single-defect MRs + 3 clean, shuffled slots, every description carries a rollback line and dependency reasons EXCEPT the MR whose defect is that omission. Detached git worktree slots, author edits only; main loop scans added lines for hint words and token shapes (and checks a secret-shaped value is unique in the repo), commits per branch, pushes, opens MRs via `scripts`-style launcher with `REVIEW_TOOLS=none`. Key stays in scratch; the scorer folder holds only blinded cells + key + diffs.
3. **Run:** `arm_run.py` reads `REVIEW_TOOLS`, refuses unless it is the baseline, then per wave of 5: set arm job, `POST merge_requests/<iid>/pipelines` (synchronous), restore, verify each pipeline has the arm job, wait for terminal, record durations. `collect_arm.py` keeps notes of the CI bot inside the arm window (+90 s). Order arms interleaved (S0a, S1, S2, S0b) and repeat the baseline once: identical prompts gave identical catches, so noise was ~0 here.
4. **Blind:** `prep_score.py` assigns random letters and STRIPS the run-details footer (token counts reveal which arm has skills); the map stays private. Include anchor arms when scoring a second round, so labels stay consistent. A `Failed to review PR` note is a failed run (0 findings, improve note still scored); retry once, keep the failure in `retries*.json`.
5. **Rules ablation without a merge:** project vars override job YAML vars, so temp vars `pr_reviewer__extra_instructions` / `pr_code_suggestions__extra_instructions` set to blank turn the tuned rules off (blank is accepted). Prove it with tokens_in (-390 per review). `run_norules.py` deletes them in `finally` with retries; run it under `caffeinate -i`. Check `GET projects/<pid>/variables` afterwards.
6. **Verify the arm really ran:** job trace grep `review skills:` (S1/S2 must show it, S0 must not); token means per arm (S0 3549, S1 +~460, S2 +~760 per review call).
7. **Finding to carry forward:** `.review_rules` suppress the skills (strict catches of 7: rules 2, rules+skills 2, no rules 2, no rules + skills 4). Test rule removal on the older argocd sets before any change; the set here was written to favour the skills.
