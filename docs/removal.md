# Removal and rollback

Dragon Fruit Relay records the relevant pre-install files, package state, service state, firewall state, and selected runtime settings under:

```text
/var/lib/dragonfruit-relay
```

## Delete relay configuration

This removes the configured relay and restores the recorded host state while leaving the management command installed.

## Complete uninstall

This additionally removes the management command and can remove packages that Dragon Fruit Relay originally installed, after confirmation.

## Failed setup

A failed setup invokes rollback automatically. Backups are retained if the script cannot verify a clean state.

Do not delete `/var/lib/dragonfruit-relay` manually before removal; it contains the restoration manifest and original files.
