{ config, pkgs, ... }:

{
  # ── Hostname ────────────────────────────────────────────────────
  networking.hostName = "ChenArchLinux";

  # ── NetworkManager ──────────────────────────────────────────────
  networking.networkmanager.enable = true;

  # ── Firewall ────────────────────────────────────────────────────
  # NixOS native nftables firewall (replaces firewalld)
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      111   # NFS portmapper
      2049  # NFS
      5355  # LLMNR
    ];
    allowedUDPPorts = [
      5353  # mDNS
      5355  # LLMNR
    ];
    # Open broader ranges if needed for development
    allowPing = true;
  };
  networking.nftables.enable = true;

  # ── WireGuard ───────────────────────────────────────────────────
  # WireGuard interfaces are managed by NetworkManager
  # Import your existing WireGuard configs via `nmcli connection import`

  # ── SSH ─────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  # ── NFS Server ──────────────────────────────────────────────────
  services.nfs.server = {
    enable = true;
    exports = ''
      /opt  192.168.2.0/24(rw,async)
    '';
  };

  # ── Wireless regulatory domain ──────────────────────────────────
  # cfg80211 regdom=CN is set in boot.nix via extraModprobeConfig
  # Install wireless-regdb for regulatory data
  hardware.wirelessRegulatoryDatabase = true;

  # ── Proxy / VPN ─────────────────────────────────────────────────
  # Clash Verge Rev is installed as a user package
  # Its system service is handled via its own systemd unit
}
