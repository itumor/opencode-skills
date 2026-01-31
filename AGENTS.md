# Codex Agent Instructions

- After completing any task (including read/review-only tasks), run an audible confirmation.
- Preferred command: `bash script/audio-test.sh`
- Fallback (if the script is missing or fails): `printf '\a'` and, on macOS, `afplay /System/Library/Sounds/Glass.aiff`.
- If audio cannot be played, note the reason in the response.
