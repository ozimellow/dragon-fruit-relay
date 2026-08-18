# Security Policy

Dragon Fruit Relay handles tunnel credentials, enrollment secrets, Client-release signing material, traffic policy, privileged network configuration, and backups. Treat `/etc/dragon-fruit-relay` and `/var/lib/dragon-fruit-relay` as security-sensitive state and keep them root-owned with the permissions installed by the product.

## Reporting a vulnerability

Do not publish credentials, tokens, PSKs, private keys, registry databases, or exploit details in a public issue. Use the repository's private security-reporting channel when available. Include the affected Dragon Fruit Relay version, role, reproduction steps, and a redacted diagnostic description.

## Release verification

Official release ZIPs are built by GitHub Actions from signed tags. Verify both the published checksum and GitHub artifact attestation before deployment. The exact commands are documented in the README and [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md).

## Operational guidance

Use signed Client releases, keep Debian and strongSwan patched, restrict administrative shell access, protect backups as secrets, limit exposure to the per-connection UDP transport that is actually required, and rotate connection credentials after suspected disclosure.
