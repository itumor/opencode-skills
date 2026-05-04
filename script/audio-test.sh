#!/usr/bin/env bash
set -uo pipefail

# "Audible confirmation" helper.
# Goal:
# - Always attempt a terminal bell.
# - On macOS, attempt system audio (best-effort).
# - Never fail the caller just because audio playback isn't possible.
# Env:
# - AUDIO_TEST_VERBOSE=1: print diagnostics if playback fails.
# - AUDIO_TEST_SECONDS=5: duration to play system audio (macOS only).
# - AUDIO_TEST_VOLUME=1.0: afplay volume (0.0-1.0, macOS only).

# Terminal bell
# Can't reliably control loudness/duration of terminal bells; best-effort: ring a few times.
printf '\a'; sleep 0.1; printf '\a'; sleep 0.1; printf '\a'

is_macos() { [[ "${OSTYPE:-}" == darwin* ]]; }
is_verbose() { [[ "${AUDIO_TEST_VERBOSE:-0}" == "1" ]]; }

try_afplay() {
  command -v afplay >/dev/null 2>&1 || return 127
  local sound="/System/Library/Sounds/Glass.aiff"
  [[ -f "$sound" ]] || return 2

  local secs vol
  secs="${AUDIO_TEST_SECONDS:-5}"
  vol="${AUDIO_TEST_VOLUME:-1.0}"

  local err
  err="$(mktemp -t audio-test-afplay.XXXXXX)"

  # Prefer bounded duration so callers get a consistent confirmation.
  # Some older afplay builds may not support -t; if so, fall back to replaying.
  if afplay -v "$vol" -t "$secs" "$sound" 2>"$err"; then
    rm -f "$err"
    return 0
  fi

  if grep -qiE 'unknown option|illegal option|unrecognized option' "$err" 2>/dev/null; then
    : >"$err" || true
    local i loops
    loops="$secs"
    [[ "$loops" =~ ^[0-9]+$ ]] || loops=5
    for ((i=0; i<loops; i++)); do
      afplay -v "$vol" "$sound" 2>>"$err" || true
      sleep 1
    done
    rm -f "$err"
    return 0
  fi

  if is_verbose; then
    # Common failure on headless/SSH sessions: "AudioQueueStart failed (-66680)"
    echo "audio-test: afplay failed:" >&2
    sed 's/^/  /' "$err" >&2 || true
  fi
  rm -f "$err"
  return 1
}

print_macos_diagnostics() {
  echo "audio-test: diagnostics (macOS):" >&2
  if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]]; then
    echo "  note: SSH session detected; macOS audio may not be available in this context." >&2
  fi
  if command -v osascript >/dev/null 2>&1; then
    local muted vol
    muted="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
    vol="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || true)"
    [[ -n "$muted" ]] && echo "  output muted: $muted" >&2
    [[ -n "$vol" ]] && echo "  output volume: $vol" >&2
  fi
  echo "  if you expect sound: check System Settings -> Sound -> Output device, and that output isn't muted." >&2
}

if is_macos; then
  if try_afplay; then
    exit 0
  fi
  if is_verbose; then
    print_macos_diagnostics
  fi
  exit 0
fi

if is_verbose; then
  echo "audio-test: non-macOS; only terminal bell attempted." >&2
fi
exit 0
