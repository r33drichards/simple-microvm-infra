# modules/microvm-base.nix
# Base configuration shared by all MicroVMs
# Handles: disk volumes, TAP interface, network config, resource allocation
#
# Storage Architecture:
# - /dev/vda: squashfs with VM's Nix closure (read-only, built at deploy time)
# - /dev/vdb: ext4 root filesystem (64GB, persistent)
# - /dev/vdc: ext4 writable Nix store overlay (8GB, for nix-env installs)
#
# Nix Store:
# - /nix/.ro-store: squashfs mount (read-only base)
# - /nix/store: overlay combining ro-store + writable layer
# - Allows imperative package installs while keeping base closure immutable
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
  imports = [ vmResources ];

  # Option: which network this VM belongs to
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network name from networks.nix";
    example = "vm1";
  };

  # Option: allow access to AWS Instance Metadata Service (IMDS)
  # Security: Disabled by default to prevent credential exposure
  options.microvm.allowIMDS = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Whether to allow this VM to access the AWS Instance Metadata Service (IMDS).
      When enabled, adds a route to 169.254.169.254 through the gateway.
      Disabled by default for security - VMs should not have access to EC2
      instance role credentials unless explicitly required.
    '';
  };

  config = {
    # Use QEMU (better ARM64 device support)
    microvm.hypervisor = "qemu";

    # Use VM-specific squashfs for Nix store (fixes whiteout issue)
    # This bakes the VM's closure into a read-only disk image
    microvm.storeOnDisk = true;

    # Enable writable overlay for imperative package installs (nix-env, nix profile)
    microvm.writableStoreOverlay = "/nix/.rw-store";

    # No virtiofs shares - VMs have independent storage
    microvm.shares = [];

    # Default resource allocation (can be overridden by individual VMs)
    microvm.vcpu = lib.mkDefault config.vmDefaults.vcpu;
    microvm.mem = lib.mkDefault config.vmDefaults.mem;

    # Kernel modules for virtio devices (required for ARM64)
    boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];

    # Disable systemd in initrd (simpler boot)
    boot.initrd.systemd.enable = false;

    # Disk volumes
    # Note: With storeOnDisk=true, squashfs is /dev/vda, volumes start at /dev/vdb
    microvm.volumes = [
      {
        # Root filesystem - persistent ext4
        image = "/var/lib/microvms/${config.networking.hostName}/data.img";
        size = 65536;  # 64GB
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/";
        label = "${config.networking.hostName}-root";
      }
      {
        # Writable Nix store overlay - for imperative installs
        image = "/var/lib/microvms/${config.networking.hostName}/nix-overlay.img";
        size = 8192;  # 8GB
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/nix/.rw-store";
        label = "${config.networking.hostName}-nix-rw";
      }
    ];

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
    systemd.network.networks."10-lan" = {
      matchConfig = {
        Type = "ether";
        Name = "!veth*";  # Exclude Docker veth interfaces
      };
      networkConfig = {
        Address = "${vmNetwork.subnet}.2/24";
        Gateway = "${vmNetwork.subnet}.1";
        DNS = "${vmNetwork.subnet}.1";
        DHCP = "no";
      };
      routes = lib.mkIf config.microvm.allowIMDS [
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

    # Nix configuration
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      warn-dirty = false;
      flake-registry = "/etc/nix/registry.json";
      # Must be false for writableStoreOverlay
      auto-optimise-store = false;
    };

    # Weekly garbage collection
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };

    # Ensure Nix package is available
    nix.package = pkgs.nix;

    # Enable Nix daemon for multi-user Nix operations
    systemd.services.nix-daemon = {
      enable = true;
      wantedBy = [ "multi-user.target" ];
    };

    # Allow root login with password (for learning/setup)
    users.users.root.initialPassword = "nixos";

    # SSH keys for root user
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII4mlN4JTkdx3C7iBmMF5HporlQygDE2tjN77IE0Ezxn root@hypervisor"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];

    # Create robertwendt user
    users.users.robertwendt = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGgfMmLS077IliGfXWUHTzI9ZBWFm6Vkn4m+NXvlmmOw root@ip-172-31-22-108.ec2.internal"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
      ];
    };

    # Disable sudo password for convenience
    security.sudo.wheelNeedsPassword = false;

    # Swap file configuration (4GB on root filesystem)
    swapDevices = [{
      device = "/swapfile";
      size = 4096;
    }];

    # Ensure swap file is created on boot if it doesn't exist
    systemd.services.create-swapfile = {
      description = "Create swap file on root filesystem";
      wantedBy = [ "swap.target" ];
      before = [ "swap.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -e
        SWAPFILE="/swapfile"
        if [ ! -f "$SWAPFILE" ]; then
          echo "Creating 4GB swap file at $SWAPFILE..."
          ${pkgs.util-linux}/bin/fallocate -l 4G "$SWAPFILE"
          chmod 600 "$SWAPFILE"
          ${pkgs.util-linux}/bin/mkswap "$SWAPFILE"
          echo "Swap file created successfully"
        fi
      '';
    };
  };
}
