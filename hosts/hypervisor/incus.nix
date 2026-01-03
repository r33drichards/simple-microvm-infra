# hosts/hypervisor/incus.nix
# Incus on hypervisor for running VMs with full KVM support
# Includes per-container DNS filtering via CoreDNS
{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/incus-dns-filter.nix
  ];

  # Enable Incus (container/VM manager)
  virtualisation.incus = {
    enable = true;

    # Enable the web UI
    ui.enable = true;

    # Preseed configuration for initial setup
    preseed = {
      # Network configuration for VMs/containers
      # DNS is handled by our CoreDNS instance for filtering
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.100.0.1/24";
            "ipv4.nat" = "true";
            "ipv6.address" = "none";
            # Point containers to our filtered DNS (CoreDNS on the gateway)
            "ipv4.dhcp" = "true";
            "dns.mode" = "managed";
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
        # Profile for containers with DNS filtering enabled
        {
          name = "dns-filtered";
          description = "Profile with DNS filtering enabled (use with incus-dns-policy)";
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

  # Enable per-container DNS filtering
  services.incusDnsFilter = {
    enable = true;
    listenAddress = "10.100.0.1";  # Incus bridge gateway
    listenPort = 5353;
    upstreamDNS = [ "1.1.1.1" "8.8.8.8" ];
    defaultPolicy = "allow";  # Default: allow all, use policies for restrictions
    incusBridge = "incusbr0";
    incusNetwork = "10.100.0.0/24";
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
