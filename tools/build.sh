#!/usr/bin/env bash
# Package each module directory into a Magisk-installable zip in dist/.
#
# Magisk only accepts STORED (0) or DEFLATE (8) entries, so plain `zip` is fine
# but XZ / 7z / LZMA archives are not -- do not swap this for those tools.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
mkdir -p "$dist"

for dir in "$root"/*/; do
  name="$(basename "$dir")"
  prop="$dir/module.prop"
  [ -f "$prop" ] || continue

  id="$(sed -n 's/^id=//p' "$prop" | tr -d '\r')"
  ver="$(sed -n 's/^version=//p' "$prop" | tr -d '\r')"
  out="$dist/${id}-${ver}.zip"
  rm -f "$out"

  # Normalise line endings and permissions before packing.
  find "$dir" -type f \( -name '*.sh' -o -name '*.prop' \) -exec sed -i 's/\r$//' {} +
  find "$dir" -type f -name '*.sh' -exec chmod 755 {} +

  ( cd "$dir" && zip -qr -X "$out" . -x '.git*' -x '*~' )

  echo "built $out"
done
