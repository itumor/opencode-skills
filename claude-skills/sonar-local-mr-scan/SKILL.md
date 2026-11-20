---
name: sonar-local-mr-scan
description: Use when scanning a GitLab MR branch on sfo-cvdevopsgit01 with the local SonarQube server at localhost:9000, or when asked to "scan MR N with sonar local", "sonar the MR", or to run SonarQube on iac/terraform/template/client MRs. Covers fetching the branch, scoping stacked MRs, the docker scan in the user's terminal, and reading the issues back.
---

# Local SonarQube scan of a GitLab MR

Facts and history live in memory `sonarqube-local-docker-scan-recipe`. This skill is the run order.

## Prerequisites (check; never fix credentials yourself)
1. `curl -s http://localhost:9000/api/system/status` returns `"status":"UP"`. Otherwise ask the user to start container `sonar-local-accvend`.
2. `/Users/eramadan/.local/share/sonarqube-cli/bin/sonar auth status` shows Connected. If not, ask the user to run `sonar auth login`. Never read the keychain or config files for a token (memory `feedback-sonar-token-user-supplied-only`).
3. The scanner needs `SONAR_TOKEN` in the user's own shell. Ask them to export it, then run the scan in their terminal tab (step 5). The env is theirs.
4. Image `sonarsource/sonar-scanner-cli:12.2.0.4256_8.1.0` is present (`docker images`).

## Steps
1. **MR metadata.** Always set the host, or glab returns 404:
   `GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com glab mr view <iid> --repo iac/terraform/template/client -F json > <scratch>/mr<iid>.json`
   Read `.source_branch`, `.target_branch`, `.title`, `.author.username`, `.description`.
2. **Clone the head.** `git clone --depth 300 --branch <source_branch> https://sfo-cvdevopsgit01.eqxdev.exigengroup.com/iac/terraform/template/client.git <scratch>/mr<iid>/repo`
3. **Base.** `git -C <repo> fetch --depth 300 origin main`. A single-branch clone has no `origin/main` ref, so use `FETCH_HEAD`: `git merge-base FETCH_HEAD HEAD`.
4. **Stacked MRs.** If `.target_branch` is not `main`, or `git log FETCH_HEAD..HEAD` contains commits from another MR, scope the review and the context to the MR's own commits: `git diff <parent-head>...HEAD`. Name the parent head sha in the report. Review and scan the whole branch, but label findings by commit.
5. **Create the project** (once per MR; key `client-<topic>-mr<iid>`):
   `sonar api post "/api/projects/create?name=<key>&project=<key>&visibility=private"`
6. **Scan in the user's terminal tab** (`mcp__terminal__run_in_terminal`, no `cwd` outside the session folders). One line:
   `docker run --rm -e SONAR_TOKEN --platform linux/amd64 -v "<repo>:/usr/src" sonarsource/sonar-scanner-cli:12.2.0.4256_8.1.0 -Dsonar.host.url=http://host.docker.internal:9000 -Dsonar.projectKey=<key> -Dsonar.sources=. "-Dsonar.exclusions=**/.git/**"`
   Wait for `EXECUTION SUCCESS`. `read_terminal` can time out after 300 s, so re-read.
7. **Issues.** `sonar api get "/api/issues/search?componentKeys=<key>&resolved=false&ps=500&facets=severities,types" > <scratch>/issues<iid>.json`, then `jq` on severities and each issue's component, line and message.
8. **Report.** Severity counts, issues as `file:line rule message`, parse warnings separately, the dashboard link `http://localhost:9000/dashboard?id=<key>`. Also say what was not scanned, for example rendered Copier output.

## Gotchas
- `sonar verify` and `sonar analyze agentic` need SonarQube Cloud. On the local server they fail with "requires a SonarQube Cloud connection". Use the docker scanner.
- Quote `"-Dsonar.exclusions=**/.git/**"` in zsh, or the glob fails with "no matches found".
- Use `host.docker.internal`, not `localhost`, from inside the scanner container (the `--network container:` variant in the memory recipe is the alternative).
- Copier template paths (`upper/[% yield stage ... %][[ stage ]]...`) cause "Cannot parse" warnings. Judge template MRs with a rendered-output scan too.
- Baseline for template/client: 4 INFO `terraform:S1135` TODOs in `vpn.tf` (lower and upper) exist on main. They are not MR findings.
- Do not print the token. Do not dump the keychain.

## After the scan
Nothing is posted to GitLab. Drafts for teammates go through skill `eramadan-voice`. The MR gate stays with `mr-human-review-gate`.
