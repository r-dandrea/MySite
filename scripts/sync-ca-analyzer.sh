#!/usr/bin/env bash
#
# Build the CA Policy Analyzer (React/Vite SPA) and copy its static output into
# this Hugo site, so it gets published at:
#     https://robertodandrea.com/tool/ca-policy-analyzer/
#
# Usage:
#   ./scripts/sync-ca-analyzer.sh [path-to-analyzer-web-dir]
#
# Then commit MySite and push (master) — the normal Hugo GitHub Action publishes it.
#
set -euo pipefail

# Source repo (ca-policy-analyzer) — override by passing the web/ dir as $1
ANALYZER_WEB="${1:-$HOME/Desktop/Coreview2/ca-policy-analyzer/web}"

# Destination inside this Hugo site (static/ is copied verbatim into public/)
SITE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$SITE_ROOT/static/tool/ca-policy-analyzer"

if [[ ! -d "$ANALYZER_WEB" ]]; then
  echo "✗ Analyzer web dir not found: $ANALYZER_WEB" >&2
  echo "  Pass it explicitly:  $0 /path/to/ca-policy-analyzer/web" >&2
  exit 1
fi

echo "→ Building analyzer  (base=/tool/ca-policy-analyzer/)"
( cd "$ANALYZER_WEB" && npm ci --silent && VITE_BASE_PATH=/tool/ca-policy-analyzer/ npm run build )

echo "→ Syncing dist → static/tool/ca-policy-analyzer/"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$ANALYZER_WEB/dist/." "$DEST/"

# These belong to the standalone subdomain deploy, NOT to a sub-path on this site:
#  - CNAME (ca.robertodandrea.com) would be ignored anyway, but keep it out
#  - 404.html at a sub-path is unnecessary (Hugo owns the site 404)
rm -f "$DEST/CNAME" "$DEST/404.html"

# Publish the one-time setup script so users can download + run it directly from
# the site (the app's setup modal links to it). No repo clone needed.
cp "$ANALYZER_WEB/Register-CAAnalyzerApp.ps1" "$DEST/"

echo "✓ Done."
echo "  Next:  git -C \"$SITE_ROOT\" add static/tool && git commit -m 'tool: update CA Policy Analyzer' && git push"
