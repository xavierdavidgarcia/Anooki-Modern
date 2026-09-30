#!/usr/bin/env bash
# Download the latest Ruffle self-hosted release and unpack it into Resources/ruffle.
# Re-run any time you want to update Ruffle.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/Resources/ruffle"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Querying latest Ruffle nightly..."
URL=$(curl -fsSL "https://api.github.com/repos/ruffle-rs/ruffle/releases?per_page=1" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)[0]; print(next(a['browser_download_url'] for a in r['assets'] if 'web-selfhosted' in a['name'] and a['name'].endswith('.zip')))")

echo "→ Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/ruffle.zip"

echo "→ Unpacking into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$TMP/ruffle.zip" -d "$OUT"

# Some Ruffle releases nest files inside a top-level folder; flatten if so.
if [ -d "$OUT/ruffle" ]; then
  mv "$OUT/ruffle"/* "$OUT/"
  rmdir "$OUT/ruffle"
fi

echo "→ Ruffle staged. Files:"
ls "$OUT"
