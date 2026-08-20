#!/usr/bin/env python3
"""Parked-MR series harness: stage each deliverable as its own local branch+commit, then publish
(push + open MR) in a separate, idempotent pass. NEVER merges.

Why the split: staging needs no network, so a VPN/DNS drop mid-run costs nothing — keep staging,
then call publish() when connectivity returns. publish() skips entries that already have an mr_iid,
so re-running after a partial failure never double-creates an MR.

Adjust the constants below per repo. DIRTY is the one file allowed to stay uncommitted in the
working tree (None if there is none); the assertions exist to keep it out of every MR and to keep
`main` exactly where it started.
"""
import json, os, pathlib, shutil, subprocess, sys

REPO = "/path/to/repo"                      # local checkout
PROJECT_ID = 0                              # GitLab numeric project id
REVIEWER_ID = 0                             # numeric user id: glab api "users?username=<name>"
DIRTY = "BACKLOG.md"                        # intentionally-uncommitted file, or None
DRAFTS = "/path/to/scratch/drafts"          # mirrors repo-relative paths
QUEUE = "/path/to/scratch/mr-queue.json"
COMMIT_TRAILER = "\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
FOOTER = "\n\n\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)"

# GITLAB_HOST must be the host glab is AUTHENTICATED to, which may differ from the git remote's
# hostname (a CNAME glab's config does not know). GITLAB_TOKEN is unset so glab uses its keyring.
ENV = {**os.environ, "GITLAB_HOST": "gitlab.example.com"}
ENV.pop("GITLAB_TOKEN", None)


def git(*args, check=True):
    p = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed:\n{p.stdout}\n{p.stderr}")
    return p.stdout.strip()


def _api(path, method, body):
    """glab api with a raw JSON body. -f/-F silently drop reviewer_ids; only --input works."""
    p = subprocess.run(["glab", "api", path, "-X", method,
                        "-H", "Content-Type: application/json", "--input", "-"],
                       input=json.dumps(body), capture_output=True, text=True, env=ENV)
    raw = p.stdout
    if "}" not in raw:
        sys.exit(f"{method} {path} failed: {raw}\n{p.stderr}")
    return json.loads(raw[:raw.rfind("}") + 1])   # glab can append trailing junk after the JSON


def load_queue():
    return json.load(open(QUEUE)) if os.path.exists(QUEUE) else []


def save_queue(q):
    json.dump(q, open(QUEUE, "w"), indent=1)


def _assert_clean_main():
    status = git("status", "--short").strip()
    expected = {f"M {DIRTY}", f"M  {DIRTY}"} if DIRTY else {""}
    assert status in expected, f"unexpected dirty tree: {status!r}"      # guards the add -A trap
    assert git("rev-parse", "--abbrev-ref", "HEAD") == "main"


def stage(branch, files, commit_msg, title, description):
    """Branch from main, copy drafts in, commit. No push. Queue the MR for publish()."""
    q = load_queue()
    if any(e["branch"] == branch for e in q):
        print(f"skip (already queued): {branch}")
        return
    _assert_clean_main()

    git("checkout", "-b", branch)
    # A dirty file can abort checkout while the script keeps running — verify it actually took,
    # or the commit below lands on main.
    assert git("rev-parse", "--abbrev-ref", "HEAD") == branch, "checkout did not take"

    for rel in files:
        src, dst = pathlib.Path(DRAFTS, rel), pathlib.Path(REPO, rel)
        assert src.is_file(), f"missing draft {src}"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)

    git("add", *files)                                   # never -A / commit -a
    staged = git("diff", "--cached", "--name-only").splitlines()
    assert sorted(staged) == sorted(files), f"staged {staged} != intended {files}"
    print(git("diff", "--cached", "--stat"))
    git("commit", "-m", commit_msg + COMMIT_TRAILER)
    git("checkout", "main")
    assert git("rev-parse", "--abbrev-ref", "HEAD") == "main"

    q.append({"branch": branch, "title": title, "description": description, "mr_iid": None})
    save_queue(q)
    print(f"staged locally: {branch}")


def publish():
    """Push every queued branch and open its MR. Idempotent — re-run freely after a failure."""
    q = load_queue()
    for e in q:
        if e.get("mr_iid"):
            continue
        git("push", "-u", "origin", e["branch"])
        d = _api(f"projects/{PROJECT_ID}/merge_requests", "POST", {
            "source_branch": e["branch"], "target_branch": "main",
            "title": e["title"], "description": e["description"] + FOOTER,
            "assignee_id": REVIEWER_ID, "reviewer_ids": [REVIEWER_ID],
        })
        assert "iid" in d, f"MR create failed for {e['branch']}: {d}"
        revs = [r["username"] for r in d.get("reviewers", [])]
        assert len(revs) == 1, f"reviewers not set on {e['branch']}: {revs}"
        assert d["state"] == "opened"                    # rule zero: never merged
        e["mr_iid"], e["url"] = d["iid"], d["web_url"]
        save_queue(q)
        print(f"!{d['iid']} {d['web_url']}")
    print("all queued MRs published")


def set_reviewer(iid, user_id=None):
    """Repair a reviewer that a -f/-F create silently dropped."""
    d = _api(f"projects/{PROJECT_ID}/merge_requests/{iid}", "PUT",
             {"reviewer_ids": [user_id or REVIEWER_ID]})
    print(iid, [r["username"] for r in d.get("reviewers", [])])
