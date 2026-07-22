# Architecture

Dragon Fruit Relay uses standard Linux networking components. It does not define a custom tunnel protocol.

## Companion architecture with 3x-ui

The intended stack separates the application control plane from the host network path:

```text
3x-ui
  manages Xray inbounds, users, subscriptions, limits, and routing
        |
        v
Xray outbound
  binds to the Dragon Fruit Relay ingress XFRM source address
        |
        v
Dragon Fruit Relay ingress
  applies Linux source-based policy routing
        |
        | IKEv2 / IPsec
        v
Dragon Fruit Relay egress hub
  forwards and source-NATs the selected traffic
```

This separation allows 3x-ui to remain the user-facing management system while Dragon Fruit Relay focuses on the route-based server-to-server transport.

## Roles

### Egress hub

The egress hub accepts one or more independent ingress connections. Each connection has its own:

- `charon-systemd` process
- VICI socket
- IKE identities and PSK
- UDP transport
- XFRM interface and interface ID
- IPv4 `/30` tunnel network
- systemd service
- forwarding and NAT rules

### Ingress client

The ingress client uses the pairing token to configure strongSwan, an XFRM interface, a dedicated policy-routing table, DNS selection, and health monitoring.

## Traffic flow

```text
3x-ui-managed Xray outbound or another application
        |
        | socket bound to the ingress XFRM source address
        v
ingress XFRM interface
        |
        | IKEv2 / IPsec
        v
egress XFRM interface
        |
        | forwarding and source NAT
        v
egress WAN interface
```

The ingress host's normal main default route remains on its physical interface. Only traffic selected by the managed policy rules enters the relay table.
