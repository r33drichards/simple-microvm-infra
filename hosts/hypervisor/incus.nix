# hosts/hypervisor/incus.nix
# Incus on hypervisor for running VMs with full KVM support
{ config, pkgs, lib, ... }:

{
  # Enable Incus (container/VM manager)
  virtualisation.incus = {
    enable = true;

    # Enable the web UI
    ui.enable = true;

    # Preseed configuration for initial setup
    preseed = {
      # Network configuration for VMs/containers
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.100.0.1/24";
            "ipv4.nat" = "true";
            "ipv6.address" = "none";
          };
        }
      ];

      # Default profile for new instances
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
        }
      ];

      # Storage pool configuration
      storage_pools = [
        {
          name = "default";
          driver = "dir";
          config = {
            source = "/var/lib/incus/storage";
          };
        }
      ];

      # Enable web UI on all interfaces port 8443
      config = {
        "core.https_address" = ":8443";
      };
    };
  };

  # Open firewall for Incus Web UI
  networking.firewall.allowedTCPPorts = [ 8443 ];

  # Trust the Incus bridge for VM/container traffic
  networking.firewall.trustedInterfaces = [ "incusbr0" ];

  # Add incus-admin group to users
  users.users.root.extraGroups = [ "incus-admin" ];
  users.users.robertwendt.extraGroups = [ "incus-admin" ];

  # Create storage directory
  systemd.tmpfiles.rules = [
    "d /var/lib/incus/storage 0755 root root -"
    "d /var/lib/incus/iso 0755 root root -"
  ];

  # Useful CLI tools
  environment.systemPackages = with pkgs; [
    incus
  ];
}
