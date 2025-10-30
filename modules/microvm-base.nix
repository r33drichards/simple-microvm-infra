# modules/microvm-base.nix
# Base configuration shared by all MicroVMs
# Handles: virtiofs shares, TAP interface, network config
{ config, lib, pkgs, ... }:

let
  # Load network definitions
  networks = import ./networks.nix;

  # Look up this VM's network config
  vmNetwork = networks.networks.${config.microvm.network};
in
{
  # Option: which network this VM belongs to
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network name from networks.nix (vm1, vm2, vm3, or vm4)";
    example = "vm1";
  };

  config = {
    # Use Cloud-Hypervisor (fast, lightweight)
    microvm.hypervisor = "cloud-hypervisor";

    # Virtiofs filesystem shares from host
    microvm.shares = [
      {
        # Shared /nix/store (read-only, massive space savings)
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      {
        # Per-VM /var (writable)
        source = "/var/lib/microvms/${config.networking.hostName}/var";
        mountPoint = "/var";
        tag = "var";
        proto = "virtiofs";
      }
    ];

    # TAP network interface
    microvm.interfaces = [{
      type = "tap";
      id = "vm-${config.networking.hostName}";
      # Generate MAC from network name (vm1->01, vm2->02, etc)
      mac = "02:00:00:00:00:0${lib.substring 2 1 config.microvm.network}";
      # Add TAP interface to the appropriate bridge
      bridge = "br-${config.microvm.network}";
    }];

    # Enable systemd-networkd for network config
    systemd.network.enable = true;

    # Configure eth0 with static IP
    systemd.network.networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        # VM gets .2 in its subnet (gateway is .1 on host)
        Address = "${vmNetwork.subnet}.2/24";
        Gateway = "${vmNetwork.subnet}.1";
        DNS = "1.1.1.1";  # Cloudflare DNS
      };
    };

    # Basic system settings
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    # Allow root login with password (for learning/setup)
    # CHANGE THIS in production!
    users.users.root.initialPassword = "nixos";

    # Disable sudo password for convenience
    security.sudo.wheelNeedsPassword = false;
  };
}
