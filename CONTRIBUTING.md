# Contributing

Focused bug fixes, Debian compatibility work, diagnostics improvements, and documentation corrections are welcome.

Before opening a pull request:

1. Run `bash -n install.sh` and `bash -n dragon-fruit-relay.sh`.
2. Preserve backup, rollback, and removal behavior.
3. Do not replace administrator-owned files without an ownership check.
4. Keep pairing tokens, PSKs, logs, packet captures, and host-specific state out of commits.
5. Update `CHANGELOG.md` for user-visible changes.
6. Keep `VERSION`, `install.sh`, and `APP_VERSION` consistent.

Use semantic version tags in the form `vMAJOR.MINOR.PATCH`.
