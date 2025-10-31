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
  imports = [ vmResources ];

  # Option: which network this VM belongs to
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network name from networks.nix";
    example = "vm1";
  };

  config = {
    # Use QEMU (better ARM64 device support)
    microvm.hypervisor = "qemu";

    # Default resource allocation (can be overridden by individual VMs)
    microvm.vcpu = lib.mkDefault config.vmDefaults.vcpu;
    microvm.mem = lib.mkDefault config.vmDefaults.mem;

    # Kernel modules for virtio devices (required for ARM64)
    boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];

    # Virtiofs filesystem shares from host
    microvm.shares = [
      {
        # Shared /nix/store (read-only, massive space savings)
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      # /var removed - using virtio-blk volume instead for better performance
    ];

    # Dedicated disk volumes per VM (virtio-blk for performance)
    microvm.volumes = [
      {
        # /var volume - persistent VM state, logs, and application data
        image = "/var/lib/microvms/${config.networking.hostName}/var.img";
        size = 10240;  # 10GB for /var
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/var";
        label = "${config.networking.hostName}-var";
      }
      {
        # Data volume - for databases, Docker, large files
        image = "/var/lib/microvms/${config.networking.hostName}/data.img";
        size = 65536;  # 64GB
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/mnt/storage";
        label = "${config.networking.hostName}-data";
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
    # Match by type instead of name for flexibility
    systemd.network.networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        # VM gets .2 in its subnet (gateway is .1 on host)
        Address = "${vmNetwork.subnet}.2/24";
        Gateway = "${vmNetwork.subnet}.1";
        DNS = "1.1.1.1";  # Cloudflare DNS
        DHCP = "no";
      };
    };

    # Basic system settings
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

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
