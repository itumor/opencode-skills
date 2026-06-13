---
name: cursor-cli-composer-2-fast
description: Run Cursor CLI tasks using the Composer 2 Fast model
version: 1.0.0
author: Ebrahim Ramadan
---

# Cursor CLI – Composer 2 Fast

## When to Use
- Whenever you want to interact programmatically with Cursor CLI and force the use of the Composer 2 Fast model in a trusted workspace.

## Steps
1. Formulate the desired coding prompt.
2. Run:
   ```bash
   agent -p "<prompt>" --model "composer-2-fast" --trust
   ```
3. Pipe or capture the output as needed for automation.

## Tips
- Always use the --trust flag if running in a new or untrusted directory.
- Specify the model slug exactly as "composer-2-fast"—other forms like 'cursor-composer-2-fast' are invalid and will be rejected by the Cursor CLI.
- Replace <prompt> with the desired instruction (e.g., "Refactor the login function").

## Pitfalls
- Autocomplete/model slugs may change in future Cursor releases — verify available models via `agent --help`.
- Some environments may need full path or extra authentication.

## Verification
- The output should mention Composer or show the expected coding result.

---