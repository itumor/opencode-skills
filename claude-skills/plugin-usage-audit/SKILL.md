---
name: plugin-usage-audit
description: Use when asked which Claude Code plugins are used, unused, overlapping or worth disabling, or when trimming enabledPlugins in ~/.claude/settings.json to cut cost. Gives last-use dates from real Skill/MCP tool calls in transcripts, a backup-first disable recipe, and the caveats for hook-only plugins.
---

# Plugin usage audit

## Procedure

1. List enabled plugins (key format is `name@marketplace`):
   `jq -r '.enabledPlugins | to_entries[] | select(.value==true) | .key' ~/.claude/settings.json | sort`
2. Get last use from REAL tool calls only. Do NOT grep plain text for the plugin name: the current session's system prompt names every plugin, so every plugin looks used at "now".
   - Skill calls: `grep -rHoE '"skill": ?"[A-Za-z0-9_.-]+:[A-Za-z0-9_-]+"' ~/.claude/projects --include='*.jsonl'`, take the prefix before `:` as the plugin name, then `stat -f %m` on each file (newest wins).
   - MCP tool calls: look for `"name":"mcp__<server>__` in tool_use blocks, same mtime approach.
   - File mtime is the last WRITE to that transcript, so dates are approximate.
3. Classify each plugin:
   - Skill/MCP trace found: keep unless it overlaps something better.
   - No trace: may be hook-only or UI-only (status bands, safety hooks, caveman/ponytail modes). Mark CHECK, not unused.
4. Overlap pass: group by function (memory, process skills, status bands, destructive-command guards, cost/usage, integrations). Keep one per group.
5. Before changing anything, show the table and get an explicit yes on the list.
6. Disable with a backup first:
   `cp ~/.claude/settings.json <scratchpad>/settings.json.bak-<date>` then
   `jq '.enabledPlugins |= with_entries(if (.key|split("@")[0]) as $n | ($drop|index($n)) != null then .value=false else . end)' --argjson drop '[...]' ~/.claude/settings.json > new.json && jq -e . new.json && cp new.json ~/.claude/settings.json`
   Verify with a count of `.value==true`.
7. Plugin changes apply in a NEW session. Say so, and say it was not tested live.

## Caveats

- Plugin manifests: `find ~/.claude/plugins -name plugin.json -path '*/.claude-plugin/*'` gives name and description.
- Never edit settings.json without a backup. Never put `#` comments in it.
- Hook-only plugins (caveman, ponytail, prod-guard, the claude-mods-lab bands) show no trace even when working. Do not disable them on "no trace" alone.
