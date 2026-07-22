# Installation and updates

## Supported platform

Dragon Fruit Relay supports Debian with systemd and IPv4 networking. Run it as root.

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ozimellow/dragon-fruit-relay/main/install.sh)
```

The bootstrap downloads `dragon-fruit-relay.sh` to a temporary file. The main script installs the management command at:

```text
/usr/local/sbin/dragon-fruit-relay
```

## Optional 3x-ui companion

Dragon Fruit Relay does not install or modify 3x-ui. Install 3x-ui separately when it will manage Xray inbounds, clients, subscriptions, and Xray routing, then follow [Using Dragon Fruit Relay with 3x-ui](3x-ui.md) to direct the selected Xray outbound through the relay.

## Deployment order

For the recommended 3x-ui companion deployment:

1. Install 3x-ui separately on the ingress host and configure its Xray inbounds and clients.
2. Install and initialize the Dragon Fruit Relay egress hub.
3. Create an egress connection and copy the generated pairing token.
4. Install the Dragon Fruit Relay ingress client and paste the token.
5. Bind the selected Xray outbound to the ingress XFRM source address and select it with the required 3x-ui routing rules.

Pairing tokens contain PSKs and must be protected. See [Using Dragon Fruit Relay with 3x-ui](3x-ui.md) for the responsibility boundary and traffic path.

## Network ports

Standard transport uses:

```text
UDP 500   IKE
UDP 4500  NAT-T and ESP-in-UDP
```

A custom connection uses one UDP port in the configured range. Keep the external and internal port numbers identical when forwarding through a router or cloud firewall.

## Update

Run the install command again, then select **Repair managed configuration**. Existing connection settings are preserved while managed files and services are regenerated.

## Manual review

Administrators who prefer to review the code first can clone the repository and run:

```bash
bash -n dragon-fruit-relay.sh
less dragon-fruit-relay.sh
./dragon-fruit-relay.sh
```
