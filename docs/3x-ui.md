# Using Dragon Fruit Relay with 3x-ui

Dragon Fruit Relay is designed to provide the network path beneath a 3x-ui-managed Xray deployment. It deliberately does not duplicate the control-panel functions already provided by 3x-ui.

## Responsibility boundary

| 3x-ui / Xray | Dragon Fruit Relay |
|---|---|
| Create and manage inbounds | Establish and monitor IKEv2/IPsec links |
| Create users and subscriptions | Create Linux XFRM interfaces |
| Apply expiry, quota, and IP limits | Install source-based policy-routing rules |
| Record client and inbound traffic | Forward and source-NAT traffic at the egress hub |
| Select Xray outbounds with routing rules | Maintain DNS, recovery, and packet diagnostics |

Dragon Fruit Relay does not access the 3x-ui database, create users, edit inbounds, or rewrite the Xray configuration. 3x-ui and Dragon Fruit Relay are installed and updated independently.

## Typical traffic path

```text
remote client
    |
    v
3x-ui-managed Xray inbound
    |
    | Xray routing rule selects an outbound
    v
Xray outbound bound to the Dragon Fruit Relay XFRM address
    |
    | Linux source rule selects the relay routing table
    v
Dragon Fruit Relay ingress xfrm0
    |
    | IKEv2 / IPsec
    v
Dragon Fruit Relay egress profile
    |
    | forwarding and source NAT
    v
egress network
```

## Setup outline

1. Install 3x-ui on the ingress host and configure the required inbounds, clients, and subscriptions.
2. Create a Dragon Fruit Relay connection on the egress hub.
3. Pair the ingress host with the generated token.
4. Note the ingress XFRM source address shown in the Dragon Fruit Relay summary. It is also stored as `XFRM_LOCAL_IP` in `/etc/dragonfruit-relay/dragonfruit-relay.conf`.
5. In the 3x-ui Xray configuration, create or edit the outbound used for relay traffic and set its `sendThrough` value to that XFRM source address.
6. Use the normal 3x-ui/Xray routing rules to direct the intended inbounds, users, domains, or other selected traffic to that outbound.
7. Verify the path from Dragon Fruit Relay's egress connection diagnostics. The live DNS and live traffic views show packets on the selected XFRM interface and egress path.

The exact 3x-ui screen labels may change between releases. Refer to the upstream project documentation for the current panel workflow and Xray configuration syntax.

## Independence and attribution

3x-ui and Xray are independent projects and are not bundled with Dragon Fruit Relay. Dragon Fruit Relay is not affiliated with, sponsored by, or endorsed by their maintainers.

## Upstream references

- [3x-ui repository](https://github.com/MHSanaei/3x-ui)
- [Xray outbound configuration and `sendThrough`](https://xtls.github.io/en/config/outbound.html)
