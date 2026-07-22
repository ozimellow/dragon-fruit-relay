# Security policy

Security fixes are applied to the latest published release.

## Reporting a vulnerability

Use GitHub private vulnerability reporting when it is enabled for the repository. Do not disclose complete pairing tokens, pre-shared keys, or unredacted diagnostic archives in a public issue.

Include the Dragon Fruit Relay version, Debian version, configured role, reproduction steps, and the smallest redacted log excerpt that demonstrates the issue.

## Sensitive data

Pairing tokens contain the connection pre-shared key. If a token is exposed, remove that egress connection and create a new one.
