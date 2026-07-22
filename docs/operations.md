# Operation and diagnostics

Open the role-aware management interface with:

```bash
dragon-fruit-relay
```

## Egress hub

The hub menu creates, lists, starts, stops, repairs, and removes individual connections. Removing one connection does not restart unrelated connections.

## Ingress client

The ingress menu reports tunnel health, routing, DNS state, service status, and recovery actions. Repair regenerates managed files without replacing the pairing configuration.

## Live diagnostics

Each egress connection provides two live captures:

- **Live DNS forwarding capture** shows DNS queries and replies across the selected XFRM and WAN paths.
- **Live tunnel traffic capture** shows decrypted traffic on the selected connection's XFRM interface.

Press `Ctrl+C` to stop a capture and return to the diagnostics menu.

## Logs

```text
/var/log/dragonfruit-relay/installer.log
```

Diagnostic reports are written to the same directory and redact the PSK. Review reports before sharing because host addresses and topology may still be visible.
