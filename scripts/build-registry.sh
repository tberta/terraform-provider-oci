#!/usr/bin/env bash
# Generate self-hosted provider REGISTRY PROTOCOL metadata for one release and
# merge it into the published tree.
#
# This is the sibling of scripts/build-network-mirror.sh. The two publish the
# same release through two different Terraform install protocols:
#
#   network mirror   docs/providers/<host>/<ns>/<type>/{index,<version>}.json
#                    -> consumers need a provider_installation block
#                    -> verified with `h1:` dirhashes, NO signature
#
#   registry (here)  docs/registry/v1/<ns>/<type>/versions
#                    docs/registry/v1/<ns>/<type>/<version>/download/<os>/<arch>
#                    -> consumers need NO CLI config at all, just
#                       source = "tberta.github.io/tberta/oci"
#                    -> verified with the plain sha256 AND a GPG signature
#
# The signature is not optional. Measured: a download response without
# `shasums_signature_url` + `signing_keys` gets as far as downloading and
# checksumming the archive, then fails with "authentication signature from
# unknown issuer". That is the entire trade-off between the two protocols, and
# it is why .goreleaser.yml carries a `signs` section.
#
# Two path facts, both measured against GitHub Pages, that this layout relies on:
#   - Pages serves dot-directories, so `.well-known/terraform.json` in the
#     tberta/tberta.github.io repo can host discovery at the HOST ROOT (the
#     protocol requires that) while pointing `providers.v1` at this project's
#     Pages path.
#   - Pages serves the extensionless `versions` and `download/<os>/<arch>` files
#     as application/octet-stream, and Terraform does not care. The
#     application/json requirement that forced Pages over raw.githubusercontent
#     applies to the MIRROR protocol only.
#
# Hashes here are the plain sha256 from SHA256SUMS -- NOT the `h1:` dirhash the
# mirror uses. Do not copy values between the two scripts.
set -euo pipefail

VERSION="${1:?usage: build-registry.sh <version> <tag> <namespace> <type> <repo> <site-dir> <pubkey-file>}"
TAG="${2:?missing tag, e.g. v8.23.0-fix.2}"
NAMESPACE="${3:?missing namespace, e.g. tberta}"
TYPE="${4:?missing type, e.g. oci}"
REPO="${5:?missing repo, e.g. tberta/terraform-provider-oci}"
SITE_DIR="${6:?missing site directory, e.g. docs}"
PUBKEY="${7:?missing armoured public key file, e.g. scripts/registry-signing-key.asc}"

[ -f "$PUBKEY" ] || { echo "build-registry: no such public key file: $PUBKEY" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SUMS_NAME="terraform-provider-oci_${VERSION}_SHA256SUMS"
SIG_NAME="${SUMS_NAME}.sig"

# --- 1. Fetch the checksum file and its signature --------------------------
# Both must exist on the release. A release cut before signing was restored has
# the sums but no .sig, and would produce endpoints that download, checksum,
# then fail verification -- the exact failure this script exists to avoid.
echo "==> downloading $SUMS_NAME and $SIG_NAME from $TAG"
gh release download "$TAG" --repo "$REPO" --dir "$WORK" \
  --pattern "$SUMS_NAME" --pattern "$SIG_NAME"

for f in "$SUMS_NAME" "$SIG_NAME"; do
  [ -s "$WORK/$f" ] || {
    echo "build-registry: $f missing or empty on release $TAG." >&2
    echo "  The registry protocol REQUIRES the signature; re-cut the tag with" >&2
    echo "  the \`signs\` section of .goreleaser.yml enabled." >&2
    exit 1
  }
done

# --- 2. Verify the signature against the key we are about to advertise -----
# Guards the one mismatch that is easy to introduce and impossible to notice
# from the JSON alone: the release signed with key A while this repo publishes
# key B. Terraform would reject every install; here it fails the release job.
export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$PUBKEY"
if ! gpg --batch --verify "$WORK/$SIG_NAME" "$WORK/$SUMS_NAME" 2>"$WORK/verify.log"; then
  echo "build-registry: $SIG_NAME does not verify against $PUBKEY" >&2
  cat "$WORK/verify.log" >&2
  exit 1
fi
echo "==> signature verifies against $PUBKEY"

# The long key id of the signing key, taken from the key file itself so there is
# a single source of truth. Field 5 of the `pub` record.
KEY_ID="$(gpg --batch --with-colons --show-keys "$PUBKEY" | awk -F: '/^pub:/ {print $5; exit}')"
[ -n "$KEY_ID" ] || { echo "build-registry: could not read key id from $PUBKEY" >&2; exit 1; }
echo "==> signing key id: $KEY_ID"

# --- 3. Compose the documents ---------------------------------------------
OUT="$SITE_DIR/registry/v1/$NAMESPACE/$TYPE"
mkdir -p "$OUT"

VERSION="$VERSION" TAG="$TAG" REPO="$REPO" OUT_DIR="$OUT" \
SUMS_FILE="$WORK/$SUMS_NAME" SUMS_NAME="$SUMS_NAME" SIG_NAME="$SIG_NAME" \
KEY_ID="$KEY_ID" PUBKEY_FILE="$PUBKEY" MANIFEST="terraform-registry-manifest.json" \
python3 - <<'PY'
import json, os, pathlib, re

version  = os.environ["VERSION"]
tag      = os.environ["TAG"]
repo     = os.environ["REPO"]
out_dir  = pathlib.Path(os.environ["OUT_DIR"])
key_id   = os.environ["KEY_ID"]
armor    = pathlib.Path(os.environ["PUBKEY_FILE"]).read_text()

# Protocol versions come from the manifest that ships in the release, so the
# two can never disagree about what the binary speaks.
protocols = json.loads(pathlib.Path(os.environ["MANIFEST"]).read_text())["metadata"]["protocol_versions"]

# Archives are referenced on the GitHub Release absolutely. Terraform sends no
# credentials when fetching a distribution package, so they must be anonymously
# reachable -- the same constraint that pins the mirror to Release assets.
base = f"https://github.com/{repo}/releases/download/{tag}"

# Platforms are read off SHA256SUMS rather than hardcoded, so this tracks the
# goreleaser matrix instead of duplicating it.
pattern = re.compile(
    r"^(?P<sha>[0-9a-f]{64})\s+\**terraform-provider-oci_"
    + re.escape(version) + r"_(?P<os>[a-z0-9]+)_(?P<arch>[a-z0-9]+)\.zip$"
)

platforms = []
for line in pathlib.Path(os.environ["SUMS_FILE"]).read_text().splitlines():
    m = pattern.match(line.strip())
    if not m:
        continue
    os_, arch, sha = m["os"], m["arch"], m["sha"]
    filename = f"terraform-provider-oci_{version}_{os_}_{arch}.zip"

    doc = {
        "protocols": protocols,
        "os": os_,
        "arch": arch,
        "filename": filename,
        "download_url": f"{base}/{filename}",
        "shasums_url": f"{base}/{os.environ['SUMS_NAME']}",
        "shasums_signature_url": f"{base}/{os.environ['SIG_NAME']}",
        "shasum": sha,
        "signing_keys": {
            "gpg_public_keys": [
                {"key_id": key_id, "ascii_armor": armor}
            ]
        },
    }

    dl = out_dir / version / "download" / os_
    dl.mkdir(parents=True, exist_ok=True)
    # Extensionless on purpose: the protocol path is /download/<os>/<arch>.
    (dl / arch).write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {dl / arch}")
    platforms.append({"os": os_, "arch": arch})

if not platforms:
    raise SystemExit(
        f"refusing to publish: no archives for version '{version}' in SHA256SUMS"
    )

# `versions` is authoritative for the WHOLE provider: writing only the new
# version would silently delete every previously published one. Same merge
# discipline as the mirror's index.json.
versions_path = out_dir / "versions"
existing = []
if versions_path.exists():
    existing = json.loads(versions_path.read_text()).get("versions", [])

merged = {v["version"]: v for v in existing}
merged[version] = {
    "version": version,
    "protocols": protocols,
    "platforms": platforms,
}

versions_path.write_text(
    json.dumps({"versions": [merged[k] for k in sorted(merged)]}, indent=2) + "\n"
)
print(f"wrote {versions_path} with {len(merged)} version(s): " + ", ".join(sorted(merged)))
PY

# GitHub Pages runs Jekyll by default, which does not serve every path
# literally -- notably not the `download` directories under a version.
touch "$SITE_DIR/.nojekyll"

echo "==> done"
find "$SITE_DIR/registry" -type f | sort
