#!/usr/bin/env bash
#
# catch-prompt.sh — run this WHILE a permission prompt from Scout is on the screen.
#
# The thread that asked for the permission is blocked waiting for the answer, so a sample taken
# while the prompt is still up catches it in the act and names the exact call that triggered it.
# Answer the prompt afterwards, not before.
#
#   bin/catch-prompt.sh
#
# Writes one file to the Desktop. It contains stack traces and file paths, no file contents.
set -uo pipefail

OUT="$HOME/Desktop/scout-prompt-$(date +%Y%m%d-%H%M%S).txt"

{
  echo "Taken: $(date)"
  echo
  echo "== every Scout running, and where it was launched from =="
  ps -Ao pid,lstart,args | grep "[S]cout.app/Contents/MacOS/Scout" || echo "(none running)"
  echo
  echo "== every Scout installed on this Mac =="
  mdfind "kMDItemFSName == 'Scout.app'" 2>/dev/null || true
  echo

  PIDS="$(pgrep -x Scout || true)"
  if [ -z "$PIDS" ]; then
    echo "No Scout process to sample — the prompt may have come from something else."
  fi
  for pid in $PIDS; do
    echo "== what pid $pid is doing =="
    sample "$pid" 3 -file /dev/stdout 2>/dev/null
    echo
  done
} > "$OUT" 2>&1

echo "Saved to $OUT"
