# Release Process

Dragon Fruit Relay releases are built from source by GitHub Actions. Do not upload a workstation-built ZIP as the canonical release artifact.

## Release model

- `main` is validated continuously.
- `VERSION` contains the product version, for example `2.1.0`.
- `install.sh` contains `BOOTSTRAP_DEFAULT_TAG`, the release installed by the public no-argument curl command. Update it to the release tag being promoted.
- Prerelease tags use signed annotated SemVer tags such as `v2.1.0-rc.1`.
- The final stable tag uses `v2.1.0`.
- The release workflow accepts `v*` tags, verifies that the tag's base version matches `VERSION`, requires the tag to be an annotated GitHub-verified signed tag, builds the release ZIP, tests the extracted ZIP, generates `SHA256SUMS`, creates GitHub artifact attestations, and publishes the GitHub Release.
- Tags containing a prerelease suffix (`-rc.1`, `-beta.1`, and similar) are published as GitHub prereleases. A tag exactly equal to `v${VERSION}` is published as stable.

## Prepare a release candidate

From an up-to-date `main` checkout:

```bash
git switch main
git pull --ff-only
./scripts/build-release.sh
```

Confirm the working tree is clean and the full release-equivalent suite passes.

## Create the signed prerelease tag

For the first v2.1.0 release candidate:

```bash
git tag -s v2.1.0-rc.1 -m "Dragon Fruit Relay v2.1.0-rc.1"
git tag -v v2.1.0-rc.1
git push origin v2.1.0-rc.1
```

The tag must use a signing key registered with the GitHub account so GitHub marks it **Verified**. The release workflow rejects lightweight or unverified tags.

Pushing the tag triggers `.github/workflows/release.yml`.

## What GitHub Actions publishes

The release workflow produces:

```text
dragon-fruit-relay-2.1.0.zip
SHA256SUMS
```

The ZIP contains a generated `MANIFEST.sha256` for every packaged file. GitHub Actions also publishes cryptographically signed build provenance using `actions/attest` and GitHub OIDC/Sigstore.

## Verify a published artifact

```bash
sha256sum -c SHA256SUMS

gh attestation verify dragon-fruit-relay-2.1.0.zip \
  --repo ozimellow/dragon-fruit-relay \
  --signer-workflow ozimellow/dragon-fruit-relay/.github/workflows/release.yml
```

After extraction:

```bash
cd dragon-fruit-relay-2.1.0
sha256sum -c MANIFEST.sha256
./tests/run-all.sh
```

## Promote to stable

After the release candidate has passed real two-host Debian testing and no release-blocking issues remain:

```bash
git switch main
git pull --ff-only
./scripts/build-release.sh
git tag -s v2.1.0 -m "Dragon Fruit Relay v2.1.0"
git tag -v v2.1.0
git push origin v2.1.0
```

Because the stable tag has no prerelease suffix, the same workflow publishes it as a normal GitHub release rather than a prerelease.
