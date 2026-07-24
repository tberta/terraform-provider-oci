#!/usr/bin/env bash
# Stamp the release version into internal/globalvar/version.go.
#
# Version and ReleaseDate are declared `const`, not `var`. The linker only
# rewrites variables, so `-ldflags -X` cannot inject them -- and main.go
# declares no `version`/`commit` variable either, which makes GoReleaser's
# stock `-X main.version=...` a silent no-op in this repo. Rewriting the
# source before the build is the only way the binary reports its own version
# (`-version`, and the [INFO] line PrintVersion writes to the log).
#
# Called from the `before.hooks` section of .goreleaser.yml. Leaving the file
# modified afterwards is fine: GoReleaser's dirty-tree check runs in the git
# pipe, which is ordered ahead of the before-hooks pipe.
set -euo pipefail

VERSION="${1:?usage: stamp-version.sh <version>   e.g. 8.23.0-fix.1}"
FILE="internal/globalvar/version.go"
RELEASE_DATE="$(date -u +%F)"

if [ ! -f "$FILE" ]; then
  echo "stamp-version: $FILE not found -- run from the repository root" >&2
  exit 1
fi

# -i.bak + rm keeps this working on BSD sed (macOS) as well as GNU sed.
sed -i.bak \
  -e "s/^const Version = \".*\"/const Version = \"${VERSION}\"/" \
  -e "s/^const ReleaseDate = \".*\"/const ReleaseDate = \"${RELEASE_DATE}\"/" \
  "$FILE"
rm -f "${FILE}.bak"

grep -E '^const (Version|ReleaseDate)' "$FILE"

# A failed substitution must abort the release rather than ship a binary that
# reports the wrong version.
if ! grep -qF "const Version = \"${VERSION}\"" "$FILE"; then
  echo "stamp-version: failed to stamp '${VERSION}' into ${FILE}" >&2
  exit 1
fi
