# modules/microvm-base.nix
# Base configuration shared by all MicroVMs
# Handles: virtiofs shares, TAP interface, network config, resource allocation
{ config, lib, pkgs, ... }:

let
  # Load network definitions
  networks = import ./networks.nix;

  # Look up this VM's network config
  vmNetwork = networks.networks.${config.microvm.network};

  # Load VM resource defaults
  vmResources = import ./vm-resources.nix { inherit lib; };
in
{
  imports = [
    vmResources
    ./monitoring/vm-agent.nix
  ];

  # Option: which network this VM belongs to
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network name from networks.nix";
    example = "vm1";
  };

  config = {
    # Use QEMU (better ARM64 device support)
    microvm.hypervisor = "qemu";

    # Use virtiofs sharing from host instead of creating disk image
    microvm.storeOnDisk = false;

    # Default resource allocation (can be overridden by individual VMs)
    microvm.vcpu = lib.mkDefault config.vmDefaults.vcpu;
    microvm.mem = lib.mkDefault config.vmDefaults.mem;

    # Kernel modules for virtio devices (required for ARM64)
    boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];

    # Disable systemd in initrd (simpler boot, no impermanence complexity)
    boot.initrd.systemd.enable = false;

    # Allow writes to /nix/store (required for imperative package management)
    boot.readOnlyNixStore = false;

    # Virtiofs filesystem shares from host
    # Share /nix/store from host (read-only, space-efficient)
    # When writableStoreOverlay is set, this becomes the lower layer of the overlay
    microvm.shares = [{
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }];

    # Dedicated disk volume per VM (virtio-blk for performance)
    # Mounted at /var for persistent state (logs, systemd, Nix DB, etc.)
    microvm.volumes = [
      {
        # Data volume - persistent /var and overlay upper layer
        image = "/var/lib/microvms/${config.networking.hostName}/data.img";
        size = 65536;  # 64GB
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/var";
        label = "${config.networking.hostName}-data";
      }
    ];

    # Bind-mount /nix/var to persistent storage
    # This is required for Nix database to persist across reboots
    fileSystems."/nix/var" = {
      device = "/var/nix-state";
      options = [ "bind" ];
    };

    # Bind-mount /home to persistent storage
    # This is required for user profiles (~/.local/state/nix) to persist across reboots
    fileSystems."/home" = {
      device = "/var/home";
      options = [ "bind" ];
    };

    # TAP network interface
    microvm.interfaces = [{
      type = "tap";
      id = "vm-${config.networking.hostName}";
      # Generate MAC from network name (vm1->01, vm2->02, etc)
      mac = "02:00:00:00:00:0${lib.substring 2 1 config.microvm.network}";
    }];

    # Enable systemd-networkd for network config
    systemd.network.enable = true;

    # Configure first ethernet interface with static IP
    # Match by type but exclude Docker veth interfaces
    systemd.network.networks."10-lan" = {
      matchConfig = {
        Type = "ether";
        Name = "!veth*";  # Exclude Docker veth interfaces
      };
      networkConfig = {
        # VM gets .2 in its subnet (gateway is .1 on host)
        Address = "${vmNetwork.subnet}.2/24";
        Gateway = "${vmNetwork.subnet}.1";
        DNS = "1.1.1.1";  # Cloudflare DNS
        DHCP = "no";
      };
      # Route AWS Instance Metadata Service (IMDS) through gateway
      # This allows VMs to access EC2 instance role credentials
      routes = [
        {
          routeConfig = {
            Destination = "169.254.169.254/32";
            Gateway = "${vmNetwork.subnet}.1";
          };
        }
      ];
    };

    # Basic system settings
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    # Enable Nix experimental features for user-level package management
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      # Don't warn about read-only store
      warn-dirty = false;
      # Use local flake registry in writable location
      flake-registry = "/etc/nix/registry.json";
    };

    # Ensure Nix package is available
    nix.package = pkgs.nix;

    # Enable Nix daemon for multi-user Nix operations
    # Required for imperative package management with overlay store
    systemd.services.nix-daemon = {
      # Unmask the service (it's masked by default in MicroVMs)
      enable = true;
      wantedBy = [ "multi-user.target" ];
    };

    # Enable writable /nix/store using microvm.nix's built-in overlay feature
    # This creates an overlay with:
    # - Lower layer: shared read-only /nix/.ro-store from host (virtiofs)
    # - Upper layer: writable /var/nix-overlay/store (on persistent volume)
    # - Work dir: /var/nix-overlay/work (on persistent volume)
    microvm.writableStoreOverlay = "/var/nix-overlay";

    # Tmpfiles rules to create Nix overlay directories
    # Note: /var is now on persistent volume, so these persist across reboots
    systemd.tmpfiles.rules = [
      # Nix overlay directories
      "d /var/nix-overlay 0755 root root -"
      "d /var/nix-overlay/store 0755 root root -"
      "d /var/nix-overlay/work 0755 root root -"
      # Nix state directory for bind mount
      "d /var/nix-state 0755 root root -"
      # Home directory for bind mount
      "d /var/home 0755 root root -"
    ];

    # Allow root login with password (for learning/setup)
    # CHANGE THIS in production!
    users.users.root.initialPassword = "nixos";

    # SSH key for root user (same as hypervisor)
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
    ];

    # Create robertwendt user (same as hypervisor)
    users.users.robertwendt = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      ];
    };

    # Disable sudo password for convenience
    security.sudo.wheelNeedsPassword = false;
  };
}
