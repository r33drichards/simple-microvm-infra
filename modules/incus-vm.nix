# modules/incus-vm.nix
# Incus container/VM host with Web UI
# Provides container and VM management via web interface at port 8443
{ config, pkgs, lib, ... }:

{
  # Enable Incus (container/VM manager)
  virtualisation.incus = {
    enable = true;

    # Enable the web UI
    ui.enable = true;

    # Preseed configuration for initial setup
    # This runs on first boot to initialize Incus
    preseed = {
      # Network configuration for containers
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.50.0.1/24";
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
            source = "/persist/incus/storage";
          };
        }
      ];

      # Enable web UI on all interfaces port 8443
      config = {
        "core.https_address" = ":8443";
      };
    };
  };

  # Required for Incus networking
  networking.nftables.enable = true;

  # Enable IP forwarding for container networking
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # Open firewall for Incus Web UI and SSH
  networking.firewall.allowedTCPPorts = [ 22 8443 ];

  # Trust the Incus bridge for container traffic
  networking.firewall.trustedInterfaces = [ "incusbr0" ];

  # User configuration - inherits from microvm-base.nix
  # Add incus-admin group for Incus access
  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" "incus-admin" ];
    # Set hashed password for RDP login (if desktop environment is added)
    # Password: "changeme" - change after first login
    hashedPassword = "$6$9vhPdO0pHckaLgWm$8NPkLKelUAGCjDWTWn7RQ871s4ET3wTpf3zN2vxchyT5MYRkHUbOGXrtwXwMBHReKpLp5syshTLPPn9cid3sI/";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
    ];
  };

  # Create storage directory in persistent storage
  systemd.tmpfiles.rules = [
    "d /persist/incus 0755 root root -"
    "d /persist/incus/storage 0755 root root -"
  ];

  # Persist Incus data across reboots (merges with base config)
  environment.persistence."/persist".directories = [
    "/var/lib/incus"
  ];

  # Useful CLI tools
  environment.systemPackages = with pkgs; [
    incus
  ];
}
