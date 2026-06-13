# macOS Package Maintenance Notes

Session-derived notes for system package maintenance runs on macOS.

## Useful patterns
- Audit managers in this order: Homebrew, npm globals, pip, gem.
- Prefer machine-readable output when available (`--json=v2` for brew, `--json` for npm/pip).
- Re-run audits after upgrades to confirm what remains outdated.

## Observed quirks
- Homebrew formula upgrades may succeed while cask cleanup still reports sudo-required cleanup or missing app sources.
- `npm update -g` can complete cleanly even after many packages were initially outdated.
- When the `pip` shell command is missing or inconsistent, `python3 -m pip` is a reliable fallback for both audits and upgrades.
- Bulk pip upgrades may leave dependency-conflict warnings; these are informational unless a concrete tool breakage is observed.
- `gem update --system` may fail under `/Library/Ruby/Gems/...` without elevated permissions.

## Verification pattern
- Report both the pre-update inventory and the post-update remainder.
- Separate the final report into: outdated before update, what changed, and warnings/errors.
