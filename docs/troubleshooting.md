# Troubleshooting

## Start with the built-in diagnostics

Run:

```bash
dragon-fruit-relay
```

Use the health summary before collecting raw output.

## Useful system commands

```bash
systemctl status strongswan --no-pager -l
swanctl --list-conns
swanctl --list-sas
ip -d link show type xfrm
ip -4 rule show
journalctl -u strongswan.service -n 100 --no-pager
```

On an egress hub, inspect the selected per-connection service and VICI socket rather than the disabled shared `strongswan.service`.

## Resolver replaced after DHCP renewal

On dhcpcd-based ingress hosts, Dragon Fruit Relay adds:

```text
nohook resolv.conf
```

to `/etc/dhcpcd.conf`, reloads dhcpcd, and restores the original file during removal. Repair reapplies this integration.

## Reporting a problem

Include:

- Dragon Fruit Relay version
- Debian version
- node role
- relevant service state
- redacted diagnostic output
- exact reproduction steps

Never publish a complete pairing token or PSK.
