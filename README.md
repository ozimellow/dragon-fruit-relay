<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="Dragon Fruit Relay" width="680">
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/prerelease-v2.1.0--rc.1-F59E0B?style=flat-square" alt="v2.1.0-rc.1 prerelease">
  <a href="../../actions/workflows/validate.yml"><img src="https://img.shields.io/github/actions/workflow/status/ozimellow/dragon-fruit-relay/validate.yml?branch=main&style=flat-square&label=validation" alt="Validation"></a>
  <a href="https://www.debian.org/"><img src="https://img.shields.io/badge/platform-Debian-A81D33?style=flat-square" alt="Debian"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-C6265A?style=flat-square" alt="GPL-3.0-or-later"></a>
</p>

# Dragon Fruit Relay

Dragon Fruit Relay is a managed IKEv2/XFRM relay for Debian with separate **Egress Hub** and **Ingress Client** roles. The Egress Hub manages multiple isolated Client connections; each Client enrolls with a one-time DFR1 token and builds a route-based strongSwan tunnel using a dedicated XFRM interface and custom UDP transport.

> [!WARNING]
> **v2.1.0-rc.1 is a prerelease.** It is intended for validation and staged deployment before the final v2.1.0 release. Test it on non-critical systems first and keep current backups.

## Highlights

- One public installer with interactive Egress Hub / Ingress Client role selection.
- Public IPv4 works directly; DNS is optional.
- Optional FQDN endpoint with authenticated Client synchronization and endpoint migration.
- Multiple isolated Server-side Client connections with independent PSKs, UDP ports, XFRM interfaces, tunnel allocations, services, and lifecycle controls.
- Per-connection subscription, quota, expiration, suspension, accounting, upload/download speed limits, and lifetime traffic.
- Global Server upload/download shaping policy.
- Authenticated CONTROL/1 management over the encrypted tunnel.
- Client presence, health, managed configuration, endpoint, and software status.
- Signed Server-managed Client releases with STAGED / CANARY / STABLE / REVOKED states and AUTO / MANUAL / PINNED policies.
- Fresh Servers automatically publish their exact bundled v2.1.0 Client as STABLE; newly created connections default to AUTO/LATEST.
- Automatic, manual, and rescue backups with verification and restore.
- Operations Center, connection dossiers, fleet summaries, diagnostics, logs, repair, recovery, and isolated removal workflows.
- Clean standalone DFR registry schema with an exact schema-contract test.

## Dedication

The project name was chosen in solidarity with **Kian Pirfalak** and is dedicated to his memory.

## Install the prerelease

Download the **GitHub Release assets** rather than running the raw `main` branch installer. The release ZIP is built and tested by GitHub Actions from the signed release tag.

```bash
TAG=v2.1.0-rc.1
VERSION=2.1.0

curl -fLO "https://github.com/ozimellow/dragon-fruit-relay/releases/download/${TAG}/dragon-fruit-relay-${VERSION}.zip"
curl -fLO "https://github.com/ozimellow/dragon-fruit-relay/releases/download/${TAG}/SHA256SUMS"

sha256sum -c SHA256SUMS
unzip "dragon-fruit-relay-${VERSION}.zip"
cd "dragon-fruit-relay-${VERSION}"
sudo ./install.sh
```

The installer starts on a clean terminal page and asks for the role on a fresh machine:

```text
DRAGON FRUIT RELAY v2.1.0  |  INSTALLER

  [1] Egress Hub (Server)
  [2] Ingress Client (Client)
```

Open the management interface later with:

```bash
sudo dragon-fruit-relay
```

## Verify the release

Every release ZIP contains `MANIFEST.sha256`; the GitHub Release also includes `SHA256SUMS` for the outer ZIP. The release workflow creates a GitHub artifact attestation using GitHub OIDC/Sigstore provenance.

Verify the downloaded ZIP checksum:

```bash
sha256sum -c SHA256SUMS
```

Verify GitHub build provenance with GitHub CLI:

```bash
gh attestation verify dragon-fruit-relay-2.1.0.zip \
  --repo ozimellow/dragon-fruit-relay \
  --signer-workflow ozimellow/dragon-fruit-relay/.github/workflows/release.yml
```

After extraction, verify every packaged file:

```bash
cd dragon-fruit-relay-2.1.0
sha256sum -c MANIFEST.sha256
```

The source tag is also signed. After fetching the repository:

```bash
git fetch --tags origin
git tag -v v2.1.0-rc.1
```

GitHub should display the signed tag as **Verified** when the signing key is registered with the maintainer account.

## Deployment model

### Egress Hub

The Egress Hub owns connection identity and allocation, subscriptions, quota and speed policy, accounting, Client presence, managed configuration, endpoint migration, Client software releases, backups, diagnostics, and recovery.

Each connection receives its own custom UDP transport, PSK, XFRM identity, `/30` tunnel allocation, systemd runtime, and encrypted-tunnel management listeners.

### Ingress Client

The Ingress Client consumes a DFR1 enrollment token, creates the strongSwan/XFRM runtime, applies policy routing and DNS, receives subscription/configuration/software policy through CONTROL/1, and reports health and convergence state to the Egress Hub.

Applications can use the managed Client XFRM source address as their egress path. Dragon Fruit Relay does not require or manage 3x-ui; it can be used alongside 3x-ui or other applications independently.

## Endpoint model

The Server endpoint can be either a public IPv4 address or an FQDN:

```text
IPv4 -> IPv4
IPv4 -> FQDN
FQDN -> IPv4
FQDN -> FQDN
```

A stable endpoint reports `READY` / `IDLE` with Clients `SYNCED`. An endpoint change becomes `ACTIVE`; when all Clients converge it becomes `READY TO FINISH` until the operator completes the migration and retires retained fallback state.

## Client software management

The Egress Hub can publish bundled or imported Client engines, verify SHA-256 and signatures, assign release status, select rollout policy, track Client update state, and roll back failed deployments.

On a fresh v2.1.0 Server:

- the exact bundled Client is published as **STABLE**;
- new connections default to **AUTO**;
- the current stable v2.1.0 payload is assigned immediately;
- MANUAL and PINNED remain explicit operator choices.

## Persistent state

Server registry:

```text
/var/lib/dragon-fruit-relay/database/registry.sqlite3
```

Managed configuration:

```text
/etc/dragon-fruit-relay
```

Logs:

```text
/var/log/dragon-fruit-relay
```

The standalone v2.1.0 line uses `product_lineage=standalone-dfr` and registry schema 1. It does not import or migrate installations from the retired product line.

## Development and validation

Run release-equivalent validation from the repository root:

```bash
./scripts/build-release.sh
```

That command builds the same release tree used by GitHub Actions, regenerates `MANIFEST.sha256`, runs the complete test suite, creates the ZIP, extracts that ZIP into a clean directory, and runs the suite again against the archive contents.

CI runs the same build on pushes and pull requests. See [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md) for the signed-tag and prerelease process.

## Documentation

| Topic | Guide |
|---|---|
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Database contract | [docs/DATABASE.md](docs/DATABASE.md) |
| Operations | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Backup and recovery | [docs/BACKUP-RECOVERY.md](docs/BACKUP-RECOVERY.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Release verification | [docs/RELEASE-VERIFICATION.md](docs/RELEASE-VERIFICATION.md) |
| Maintainer release process | [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md) |

## Security

Dragon Fruit Relay manages privileged networking, PSKs, enrollment secrets, signing keys, and backup material. Do not publish tokens, credentials, registry databases, private keys, or unredacted diagnostic captures.

See [SECURITY.md](SECURITY.md) for reporting and operational guidance.

## License

Dragon Fruit Relay is released under the [GNU General Public License v3.0 or later](LICENSE).
