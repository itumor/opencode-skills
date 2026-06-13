---
name: system-package-maintenance
description: "System package audit and update workflows: brew, npm, pip, gem. Run as cron or on-demand."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [maintenance, brew, npm, pip, gem, update, cron]
---

# System Package Maintenance

Periodic audit and update of system-level package managers. Designed for cron-driven runs but works on-demand.

Reference notes and a session-derived checklist live in `references/macos-package-maintenance-2026-05.md`.

## Supported Package Managers

| Manager | Command to check | Command to update |
|---------|-----------------|-------------------|
| Homebrew | `brew outdated` | `brew upgrade` |
| npm | `npm outdated -g --depth=0` | `npm update -g` |
| pip | `pip3 list --outdated` | `pip3 install --upgrade <pkgs>` |
| gem | `gem outdated` | `gem update --system` then `gem update` |

**Tip:** If the shell wrapper for `pip`/`pip3` is unavailable or ambiguous, use the active interpreter form (`python3 -m pip ...`) with the same subcommand.


## Standard Audit Order

```
1. brew outdated
2. npm outdated -g --depth=0
3. pip3 list --outdated
4. gem outdated
```

Report current vs. latest versions in a comparison table.

## Standard Update Order

```
1. brew upgrade
2. npm update -g
3. pip3 install --upgrade pip   # upgrade pip first, then use it
4. pip3 install --upgrade <outdated packages>
5. gem update --system
6. gem update
```

Run all in parallel where possible using `background=true`, then collect results.

## pip Mass Upgrades

### Full pip upgrade command

```bash
pip3 list --outdated --format=freeze | cut -d' ' -f1 | xargs pip3 install --upgrade
```

Or enumerate packages explicitly:

```bash
pip3 install --upgrade \
  aiofiles altgraph attrs boto3 botocore certifi \
  charset-normalizer cryptography GitPython google-auth \
  googleapis-common-protos graphviz greenlet hf-xet \
  huggingface_hub idna importlib-resources json5 macholib \
  MarkupSafe mpmath numpy ollama packaging pillow pip \
  psutil pydantic pydantic_core pyee Pygments pypdf \
  python-hcl2 pytz PyYAML requests resolvelib rich ruff \
  s3transfer sentry-sdk setuptools six soxr terraform-local \
  tomlkit torch-einops-utils tqdm typer-slim tzdata \
  urllib3 virtualenv websockets wheel
```

### ⚠️ pip dependency conflicts — expected and safe to ignore

After mass pip upgrades, **dependency conflicts are normal and expected**. The conflict warnings come from OTHER packages in the environment that pin older versions. Do NOT roll back packages to resolve conflicts unless a tool is actually broken.

Known conflict-prone packages (as of 2026):
- `ansible-core` pins: `importlib-resources<5.1`, `resolvelib<1.1.0`
- `diagrams` pins: `graphviz<0.21.0`
- `llm-benchmark` pins: `ollama==0.5.1`, `psutil==5.9.8`, `pyyaml==6.0.1`, `requests==2.32.4`, `typer==0.11.0`

**Correct response:** Report the conflicts in the update summary with a note like:
> "Dependency conflicts are informational only — no packages were rolled back. Review conflicts manually if a tool is actually broken."

## Homebrew Caveats

### sudo required for cask uninstalls

`brew upgrade` may upgrade casks (oracle-jdk, temurin, etc.) but cannot uninstall old versions without sudo. The upgrade still succeeds — the new version is installed. Just note:
> "Upgraded but old version not purged (sudo required). Run `sudo rm -rf /Library/Java/JavaVirtualMachines/...` to clean up manually."

### App not found

If `brew` reports `It seems the App source '/Applications/X.app' is not there`, the app binary was moved or the app structure changed. The package still upgrades — this is cosmetic.

## npm Notes

- `npm update -g` reports deprecation warnings for old packages — these are informational
- Deprecated packages to watch: `uuid@<10`, `glob@<10`, `@mariozechner/*` (renamed to `@earendil-works/*`)
- 560+ packages is normal for a heavily-used global npm install

## gem Caveats

### System gem directory permissions

`gem update` requires write access to `/Library/Ruby/Gems/X.Y/`. On macOS, this is owned by root. Two options:
1. Run with sudo: `sudo gem update`
2. Use a user gem directory: set `GEM_HOME` and `GEM_PATH` in shell profile

If you hit `FilePermissionError`, report it but do NOT try to sudo from a cron context — flag it for manual resolution.

## pip PATH note

After upgrading pip to a new major version, it may install to `~/Library/Python/3.9/bin/` which is not on PATH. The current shell may still reference the old pip. New shells will pick up the updated version. This is cosmetic — no action needed unless pip itself is being used as a tool.

## Cron Output Format

```
## Package Update Report — <date>

### Outdated packages (before update)
...table...

### What was updated
...table per manager...

### Warnings & action items
...bullet list...
```

Keep it concise. Flag sudo-required cleanups and dependency conflicts clearly.
