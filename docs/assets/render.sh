#!/usr/bin/env bash
# Re-render the README diagram from workflow.html, in both colour themes, at 2x.
# Needs Google Chrome (or Chromium) - set CHROME to its path if it is not found.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-}"
if [ -z "$CHROME" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "$(command -v google-chrome 2>/dev/null)" "$(command -v chromium 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
[ -n "$CHROME" ] || { echo "Chrome not found - set CHROME=/path/to/chrome" >&2; exit 1; }
page="file://$PWD/workflow.html"
for theme in light dark; do
  hash=""; [ "$theme" = dark ] && hash="#dark"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1400,720 --default-background-color=00000000 \
    --screenshot="$PWD/workflow-$theme.png" "$page$hash" >/dev/null 2>&1
  echo "rendered workflow-$theme.png"
done
