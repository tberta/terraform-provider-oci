#!/usr/bin/env bash
# Generate provider network mirror metadata for one release and merge it into
# the published mirror tree.
#
# The mirror protocol needs two JSON documents per provider:
#
#   <base>/<hostname>/<namespace>/<type>/index.json   -- every version
#   <base>/<hostname>/<namespace>/<type>/<version>.json -- archives + hashes
#
# The archives themselves stay on the GitHub Release. That is deliberate:
# Terraform does NOT send credentials when fetching a distribution package, so
# the archive URL has to be reachable anonymously. Release assets on a public
# repository are; almost nothing else is.
#
# Hashes are `h1:` dirhashes -- NOT the sha256 of the zip that SHA256SUMS
# carries. Rather than reimplement Go's dirhash, this asks Terraform for the
# value it will itself verify against, via `terraform providers lock`.
#
# Note `terraform providers mirror` is NOT usable here despite emitting exactly
# this file format: it installs from the ORIGIN registry and ignores
# provider_installation, so it fails with "host github.com does not offer a
# Terraform provider registry". `providers lock -fs-mirror` is the one command
# that reads a local mirror. It records no platform->hash association in the
# lock file, so it is run once per platform in an isolated directory.
set -euo pipefail

VERSION="${1:?usage: build-network-mirror.sh <version> <tag> <source-addr> <repo> <site-dir>}"
TAG="${2:?missing tag, e.g. v8.23.0-fix.1}"
SOURCE_ADDR="${3:?missing source address, e.g. github.com/tberta/oci}"
REPO="${4:?missing repo, e.g. tberta/terraform-provider-oci}"
SITE_DIR="${5:?missing site directory, e.g. docs}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FS_MIRROR="$WORK/fs"
PKG_DIR="$FS_MIRROR/$SOURCE_ADDR"
mkdir -p "$PKG_DIR"

# --- 1. This release's archives, into a filesystem mirror -------------------
echo "==> downloading archives for $TAG"
gh release download "$TAG" --repo "$REPO" --dir "$PKG_DIR" --pattern '*.zip'

shopt -s nullglob
zips=("$PKG_DIR"/terraform-provider-oci_"${VERSION}"_*.zip)
if [ ${#zips[@]} -eq 0 ]; then
  echo "build-network-mirror: no archives matching version '${VERSION}' in $TAG" >&2
  exit 1
fi

# Platforms come from the filenames, so this tracks the goreleaser matrix
# instead of duplicating it.
platforms=()
for z in "${zips[@]}"; do
  base="$(basename "$z" .zip)"
  platforms+=( "${base#terraform-provider-oci_${VERSION}_}" )
done
echo "==> platforms: ${platforms[*]}"

# --- 2. Ask Terraform for the h1 hash of each platform ---------------------
HASHES="$WORK/hashes.txt"   # "<platform> <h1:...>" per line
: > "$HASHES"

for plat in "${platforms[@]}"; do
  CFG="$WORK/cfg-$plat"
  mkdir -p "$CFG"
  cat > "$CFG/main.tf" <<EOF
terraform {
  required_providers {
    oci = {
      source  = "${SOURCE_ADDR}"
      version = "${VERSION}"
    }
  }
}
EOF

  echo "==> locking $plat"
  ( cd "$CFG" && terraform providers lock \
      -fs-mirror="$FS_MIRROR" \
      -platform="$plat" \
      "$SOURCE_ADDR" >/dev/null )

  h1="$(grep -oE '"h1:[^"]+"' "$CFG/.terraform.lock.hcl" | head -1 | tr -d '"')"
  if [ -z "$h1" ]; then
    echo "build-network-mirror: no h1 hash produced for $plat" >&2
    exit 1
  fi
  echo "$plat $h1" >> "$HASHES"
  echo "    $plat -> $h1"
done

# --- 3. Compose the documents and merge into the published tree ------------
OUT="$SITE_DIR/providers/$SOURCE_ADDR"
mkdir -p "$OUT"

VERSION="$VERSION" TAG="$TAG" REPO="$REPO" \
HASHES_FILE="$HASHES" \
OUT_DIR="$OUT" python3 - <<'PY'
import json, os, pathlib

version = os.environ["VERSION"]
tag     = os.environ["TAG"]
repo    = os.environ["REPO"]
out_dir = pathlib.Path(os.environ["OUT_DIR"])

# The archives live on the GitHub Release, referenced absolutely: Terraform
# sends no credentials for them, so they must be anonymously reachable.
base = f"https://github.com/{repo}/releases/download/{tag}"
archives = {}
for line in pathlib.Path(os.environ["HASHES_FILE"]).read_text().splitlines():
    if not line.strip():
        continue
    platform, h1 = line.split()
    archives[platform] = {
        "url": f"{base}/terraform-provider-oci_{version}_{platform}.zip",
        "hashes": [h1],
    }

if not archives:
    raise SystemExit("refusing to publish an empty archives object")

doc = {"archives": archives}

version_path = out_dir / f"{version}.json"
version_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(f"wrote {version_path}")

# index.json is authoritative for the WHOLE provider: writing only the new
# version would silently delete every previously published one.
index_path = out_dir / "index.json"
index = {"versions": {}}
if index_path.exists():
    index = json.loads(index_path.read_text())
    index.setdefault("versions", {})
index["versions"][version] = {}
index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
print(f"wrote {index_path} with {len(index['versions'])} version(s): "
      + ", ".join(sorted(index["versions"])))
PY

# GitHub Pages runs Jekyll by default, which does not serve every path
# literally. Without this the `github.com/...` directories are unreliable.
touch "$SITE_DIR/.nojekyll"

echo "==> done"
find "$SITE_DIR/providers" -type f | sort
