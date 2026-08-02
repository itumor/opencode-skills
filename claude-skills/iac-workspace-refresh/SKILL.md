---
name: iac-workspace-refresh
description: Safely bring the multi-repo EIS iac monorepo tree (60+ independent git repos under ~/gitwork/iac) back up to date after it has gone stale — fetch all, clone newly-created repos, triage dirty working trees without losing work, and move stale feature branches onto current default. Use when the user says "refresh the workspace", "fetch all repos", "my clones are stale", "clone the missing repos", "get off these old branches", "clean up my working trees", or after returning from an absence. Also use before starting work that spans several repos, when a module/template version looks wrong locally, or when `git status` noise across repos is getting in the way. Encodes the preserve-everything safety net and the four detection traps that make naive loops destroy or mis-report work.
---

# EIS iac workspace refresh

`~/gitwork/iac` is a directory tree that mirrors the GitLab group hierarchy, where **every subdirectory with a `.git` is an independent repo**. There is no superproject. Reference run: 2026-07-31, 47 → **61** repos after a month of staleness.

**Guiding rule: nothing is deleted and no branch ref is removed.** Switching branches loses nothing as long as refs survive; a dirty tree is the only thing that can actually vanish. Build the safety net first, then move.

## Phase 1 — inventory and fetch (read-only, safe)

```bash
cd /Users/eramadan/gitwork/iac
find . -name ".git" -maxdepth 6 -type d | xargs -I{} dirname {} | sed 's|^\./||' | sort > /tmp/repos.txt
cat /tmp/repos.txt | xargs -P8 -I{} sh -c 'git -C "{}" fetch --all --tags --prune --quiet 2>&1 | sed "s|^|{}: |"'
```

Then survey per repo: branch · `origin/HEAD` default · ahead/behind · dirty count. **Skip the junk repos** (trap #4) or they pollute every count.

## Phase 2 — classify the risk BEFORE touching anything

Two distinct risks. Report both to the user before acting.

**Unpushed commits** — HEAD on no remote ref:
```bash
git -C "$d" branch -r --contains HEAD | wc -l     # 0 => candidate
```
This over-reports. Before believing it, check **all** remotes (trap #3) and check whether the work landed upstream under a **different SHA** via rebase/squash-merge — grep `origin/main` for the distinguishing symbol or commit message, not the SHA. On the reference run 2 of 3 "at-risk" branches were already upstream.

**Dirty trees** — list every entry and diff-stat, and actually read the diffs. You must distinguish:
- *regenerable artefacts* (`*.tfplan`, build caches) → removable
- *real WIP* (a half-built feature) → must survive
- *local config that upstream deliberately untracked* → must be restored as untracked (trap #2)

## Phase 3 — safety net

```bash
B=~/gitwork/.workspace-refresh-backup-$(date +%Y%m%d); mkdir -p "$B"
# tag HEAD wherever commits might be unique
git -C "$d" tag -f "wip-backup/$(date +%F)" HEAD
# per dirty repo: patch + verbatim copies of untracked files
git -C "$d" diff > "$B/$safe/tracked.patch"
git -C "$d" diff --cached > "$B/$safe/staged.patch"
git -C "$d" ls-files --others --exclude-standard | while read f; do
  mkdir -p "$B/$safe/untracked/$(dirname "$f")"; cp -a "$d/$f" "$B/$safe/untracked/$f"; done
```

Then `git stash push -u -m "refresh-<date>: <what this is, with ticket>"` per repo. **Descriptive stash messages are the whole point** — an unlabelled stash is lost work six weeks later. Include the Jira key.

## Phase 4 — normalise branches

For each repo: switch to the default branch, then `git merge --ff-only origin/<default>`. **Never delete a branch.** Detached HEADs (`rev-parse --abbrev-ref HEAD` == `HEAD`) → switch to `main`.

⚠️ **Do not derive the default from `origin/HEAD`** — see trap #1. Either hardcode `main`/`master` per repo, or verify `origin/HEAD` resolves to a branch that actually looks like a trunk.

## Phase 5 — clone what's missing

Detect by **remote URL, not path** (trap #1's sibling — see below):

```bash
find . -name ".git" -maxdepth 6 -type d | xargs -I{} dirname {} | while read d; do
  git -C "$d" remote get-url origin 2>/dev/null; done \
  | sed -E 's|.*:2224/||; s|\.git$||' | sort -u > /tmp/local_paths.txt
glab api "groups/1711/projects?include_subgroups=true&per_page=100" \
  | python3 -c "import json,sys
for p in json.load(sys.stdin): print(p['path_with_namespace'])" | sort -u > /tmp/remote_paths.txt
comm -13 /tmp/local_paths.txt /tmp/remote_paths.txt    # missing
comm -23 /tmp/local_paths.txt /tmp/remote_paths.txt    # local-only / forks
```

Clone with a **plain `while read` loop, not `xargs -P`** — nested quoting in `xargs -I{} sh -c "…"` dies with `xargs: command line cannot be assembled, too long` partway through, leaving a half-done job that looks like auth failure.

```bash
H="ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/iac"
while read d; do [ -d "$d/.git" ] && continue
  mkdir -p "$(dirname "$d")"; git clone --quiet "$H/$d.git" "$d" && echo "OK $d" || echo "FAIL $d"; done < /tmp/toclone.txt
```

## Phase 6 — verify and report

Re-survey. Anything still dirty / behind / off-default must be explained, not left silent. Report the stash inventory and backup tags so the user knows where their work went. Surface **pre-existing stashes you did not create** — the reference run found 5, some real WIP, one obvious test debris.

## The four traps

1. **`origin/HEAD` can be wrong server-side.** `terraform/modules/aws/eis-waf` has its remote default set to `feat/initial-module`; `main` is the real trunk (19 commits ahead, carries `v1.0.0`–`v1.0.4`). A trust-`origin/HEAD` loop moves the clone **off** `main`, and every "behind=N" is then measured against the wrong ref. `git remote set-head origin -a` does not help — fix it in GitLab.
2. **A fast-forward can delete a local config file.** `solutions/account-vending`: commit `985b9e7` (COEXT-105822) gitignored **and untracked** `account.env`. Fast-forwarding deletes your filled-in copy. Recover with `git show 'stash@{0}:account.env'` and restore it as an untracked file — that is now the correct end state.
3. **"Unpushed" often means "pushed to the other remote."** `ansible/roles/vault_agent_ssl` has `origin` = the cv-devops fork (Reporter only) while the work lives on the `iac` mirror (Maintainer). Add the mirror as a second remote and check `branch -r --contains HEAD` across all of them.
4. **Nested/stray repos corrupt every survey.** Skip `*/.gitlab-ci-local/*` (a full repo copy left by `gitlab-ci-local`, gitignored by its parent so invisible to that parent's status) and `*/ci/tmp_mock` (mock-render artifact). `projects/aws/pnt-performance/terraform` has zero commits and zero remotes — a stray `git init`, safe to delete but confirm first.

Path-based clone detection also lies: remote `iac/ansible/template/client` lives at `ansible/template`, and `iac/projects/aws/eis-terraform` at `projects/aws/eis-iac/terraform`.

## Related

`eis-absence-catchup-report` (usually runs first) · memories `[[iac-workspace-refresh-gotchas]]`, `[[iac_ansible_roles_vault_agent_ssl_mirror]]`, `[[glab_gitlab_host_env]]`.
