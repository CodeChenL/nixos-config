# ChenRadxaOrionO6N OpenWrt container config

This host now uses a **minimal Nix-declared OpenWrt model** for core router
configuration instead of treating imported `/etc/config/*` files as the long-term
source of truth.

- Nix-declared core UCI files:
  - `system`
  - `network`
  - `dhcp`
  - `firewall`
- Plugin fragments that remain raw for now:
  - `openclash`

## Deployment stages

The O6N host intentionally defaults to:

```nix
o6n.openwrt.mode = "bootstrap";
```

This keeps the host on a safe single-NIC management bridge while you install
NixOS, pull the OpenWrt image, render secrets, and validate the container.
Bootstrap uses an Incus-managed bridge in the same `192.168.33.0/24` LAN as
the declared OpenWrt LAN, with host-side bridge address `192.168.33.254/24`.

Only switch to:

```nix
o6n.openwrt.mode = "cutover";
```

after you are ready to move the host into the final two-bridge topology:

- `enp49s0 -> vmbr1 -> OpenWrt eth0` (LAN)
- `enp1s0  -> vmbr0 -> OpenWrt eth1` (WAN / PPPoE)

In cutover mode the host LAN management address is `192.168.33.100/24` on
`vmbr1`, with default gateway `192.168.33.1` provided by OpenWrt.

## Temporary host networking for bootstrap

The O6N host includes the basic tools needed to get temporary WAN access before
OpenWrt takes over:

- `ethtool`
- `ppp`
- `rp-pppoe`

Typical bootstrap flow on the host:

```sh
sudo ip link set dev enp1s0 down
sudo ip link set dev enp1s0 address 88:C3:97:9B:92:03
sudo ip link set dev enp1s0 up

sudo pppoe-setup
sudo pppoe-start
```

Use this only to bootstrap NixOS / Incus / OpenWrt. Stop host-side PPPoE before
switching to `o6n.openwrt.mode = "cutover"`, otherwise the host and OpenWrt
will compete for the same WAN uplink.

## Secrets

Runtime secrets live outside Git and outside the Nix store:

```text
/etc/nixos/secrets/o6n-openwrt.env   # source of truth inside repo checkout
/var/lib/o6n-openwrt/secrets.env     # runtime copy used by reconcile
```

Create the source file on the O6N host as `root:root` with mode `0600`:

```sh
sudo install -d -m 0700 /etc/nixos/secrets
sudo install -m 0600 /dev/null /etc/nixos/secrets/o6n-openwrt.env
sudoedit /etc/nixos/secrets/o6n-openwrt.env
```

You can start from the tracked example file:

```sh
sudo install -d -m 0700 /etc/nixos/secrets
sudo install -m 0600 hosts/ChenRadxaOrionO6N/openwrt/o6n-openwrt.env.example /etc/nixos/secrets/o6n-openwrt.env
sudoedit /etc/nixos/secrets/o6n-openwrt.env
```

Required keys currently used by the declared config and plugin fragments:

```text
WAN_PPPOE_USERNAME=
WAN_PPPOE_PASSWORD=
WG_VAMRS_PRIVATE_KEY=
WG_CHEN_INTERFACE_PRIVATE_KEY=
WG_CHEN_PEER1_PRIVATE_KEY=
WG_CHEN_PEER2_PRIVATE_KEY=
OPENCLASH_DASHBOARD_PASSWORD=
OPENCLASH_SUBSCRIBE_ADDRESS=
OPENCLASH_SUBSCRIBE_INFO_URL=
RPCD_ROOT_PASSWORD_HASH=
```

If a value contains characters that are awkward to store literally, use
`NAME=base64:<base64-value>`. The reconcile service fails closed if the secret
file is missing, too permissive, or lacks a required key.

## Migration references

The previously imported raw OpenWrt config files under `openwrt/etc/config/`
are kept only as migration references. They are no longer the active source of
truth for reconcile on this branch. If you need to compare semantics while
extending the Nix model, use those files together with the backup branch created
during the migration rewrite:

```text
backup/o6n-openwrt-raw-config
```
