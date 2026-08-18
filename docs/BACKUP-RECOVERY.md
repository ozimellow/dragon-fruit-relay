# Backup and Recovery

The Egress Hub supports automatic backups, manual backups, rescue snapshots, verification, retention, and restore. Backups contain only the current DFR registry and current product state needed to reconstruct the Server.

Before restore, use a rescue snapshot when possible. Restore validates the backup, quiesces Server registry/CONTROL/subscription runtime, restores the registry and required secrets/configuration, re-materializes connection profiles, restarts connection services, and then restores core management services.

Ingress recovery rebuilds current managed files, reloads strongSwan, reconciles the Server endpoint, attempts tunnel establishment, restores routing/resolver state after the encrypted peer is reachable, and re-arms health and CONTROL services.

Backups contain credentials and signing material. Store them with the same protection as the live Server.
