# Release Process

Dragon Fruit Relay releases are built from source by GitHub Actions. Workstation-built ZIP files are not canonical release artifacts.

## Branch model

- `main` is the stable product line. Stable `v2.1.0` is published from a signed tag that points to the exact validated tip of `main`.
- v2.1.0 release candidates are developed on branches named after the signed prerelease tag, for example `release/v2.1.0-rc.1`.
- Pushes to `main` and `release/**` run release-equivalent validation in a Debian 12 job container.
- A prerelease tag must point to the **exact tip** of its matching `release/<tag>` branch.
- The final stable `v2.1.0` tag must point to the **exact tip** of `main`.

## Prepare v2.1.0-rc.1

Work only on the prerelease branch:

```bash
git switch release/v2.1.0-rc.1
git pull --ff-only
git status
```

Push signed commits normally. The Validate workflow runs automatically on the release branch; no merge to `main` is required for a prerelease.

## Public prerelease install commands

Latest v2.1.0 release candidate from the prerelease branch:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/heads/release/v2.1.0-rc.1/install.sh)
```

Pinned v2.1.0-rc.1 after the signed tag/release has been published:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/refs/tags/v2.1.0-rc.1/install.sh)
```

The branch bootstrap defaults to the current release candidate and verifies the GitHub Release ZIP against `SHA256SUMS` before launching the packaged installer. `main` is not used by the prerelease install path.

## Publish the prerelease

After Debian 12 validation is green and real Server/Client testing is satisfactory, create a signed annotated tag from the exact release-branch tip:

```bash
git switch release/v2.1.0-rc.1
git pull --ff-only
git status

git tag -s v2.1.0-rc.1 -m "Dragon Fruit Relay v2.1.0-rc.1"
git tag -v v2.1.0-rc.1
git push origin v2.1.0-rc.1
```

The release workflow rejects lightweight tags, tags that GitHub does not report as signature-verified, version mismatches, and prerelease tags that do not point to the exact tip of their matching release branch.

Pushing the tag triggers `.github/workflows/release.yml`, which builds and retests the exact release archive in Debian 12, creates `SHA256SUMS`, creates GitHub artifact attestations, and publishes the GitHub Release with the prerelease flag.

## Published assets

```text
dragon-fruit-relay-2.1.0.zip
SHA256SUMS
```

The ZIP also contains `MANIFEST.sha256` for its packaged files.

## Verify

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
```

## Promote v2.1.0 to stable

Do not merge the prerelease branch merely to publish a release candidate. Merge or otherwise integrate the final v2.1.0 source into `main` only when v2.1.0 is ready to become the stable line.

After stable validation on `main`:

```bash
git switch main
git pull --ff-only

git tag -s v2.1.0 -m "Dragon Fruit Relay v2.1.0"
git tag -v v2.1.0
git push origin v2.1.0
```

The same release workflow publishes a tag without a prerelease suffix as a normal GitHub release.
