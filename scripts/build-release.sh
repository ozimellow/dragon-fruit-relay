#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $VERSION" >&2; exit 1; }

DIST=${DIST_DIR:-"$ROOT/dist"}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PKG="dragon-fruit-relay-$VERSION"
STAGE="$WORK/$PKG"
VERIFY="$WORK/verify"

rm -rf "$DIST"
mkdir -p "$DIST" "$STAGE/main-engine" "$STAGE/docs" "$STAGE/tests"

for file in VERSION SCHEMA README.md CHANGELOG.md LICENSE SECURITY.md install.sh; do
  cp -a "$ROOT/$file" "$STAGE/$file"
done
cp -a "$ROOT/main-engine/." "$STAGE/main-engine/"
cp -a "$ROOT/docs/." "$STAGE/docs/"
cp -a "$ROOT/tests/." "$STAGE/tests/"

chmod 0755 "$STAGE/install.sh" "$STAGE/main-engine/dragon-fruit-relay-egress.sh" "$STAGE/main-engine/dragon-fruit-relay-ingress.sh" "$STAGE/tests/run-all.sh"
find "$STAGE/tests" -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} +

(
  cd "$STAGE"
  find . -type f ! -name MANIFEST.sha256 -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > MANIFEST.sha256
)

printf '%s\n' "==> Testing staged release tree"
(
  cd "$STAGE"
  ./tests/run-all.sh
)

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)}
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

ZIP="$DIST/$PKG.zip"
(
  cd "$WORK"
  find "$PKG" -type f -print | LC_ALL=C sort | zip -X -q "$ZIP" -@
)

(
  cd "$DIST"
  sha256sum "$PKG.zip" > SHA256SUMS
)

mkdir -p "$VERIFY"
unzip -q "$ZIP" -d "$VERIFY"

printf '%s\n' "==> Testing exact extracted ZIP"
(
  cd "$VERIFY/$PKG"
  ./tests/run-all.sh
)

printf '%s\n' "==> Release artifacts"
printf '  %s\n' "$ZIP" "$DIST/SHA256SUMS"
cat "$DIST/SHA256SUMS"
