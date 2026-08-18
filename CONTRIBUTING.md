# Contributing

Focused bug fixes, Debian compatibility work, diagnostics improvements, release-safety work, and documentation corrections are welcome.

Before opening a pull request:

1. Keep `VERSION`, `SCHEMA`, `install.sh`, and both role engines consistent.
2. Preserve backup, rollback, removal, CONTROL, subscription, accounting, and connection-isolation behavior.
3. Do not replace administrator-owned files without an ownership check.
4. Keep enrollment tokens, PSKs, private keys, logs, packet captures, registries, and host-specific state out of commits.
5. Update `CHANGELOG.md` for user-visible changes.
6. Run `./scripts/build-release.sh` and require the extracted-archive verification to pass.
7. Do not hand-build release ZIPs. GitHub Actions builds published artifacts from a signed tag.

Release tags use semantic versioning. Prereleases use signed annotated tags such as `v2.1.0-rc.1`; the final stable tag is `v2.1.0`.

See [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md).
