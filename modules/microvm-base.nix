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
    # /var is ephemeral (in-memory tmpfs), all persistent data goes to /mnt/storage
    microvm.volumes = [
      {
        # Data volume - for databases, Docker, large files, and any persistent application data
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

    # Configure journald for volatile storage (since /var is ephemeral)
    services.journald.extraConfig = ''
      Storage=volatile
      RuntimeMaxUse=100M
    '';

    # Ensure persist directory exists before impermanence tries to use it
    systemd.tmpfiles.rules = [
      "d /mnt/storage/persist 0755 root root -"
    ];

    # Impermanence: Define what persists to /mnt/storage/persist
    # Since /var is ephemeral (tmpfs), we persist critical state to the dedicated volume
    environment.persistence."/mnt/storage/persist" = {
      hideMounts = true;

      directories = [
        # System state that must survive reboots
        "/var/lib/systemd"           # systemd state (timers, etc.)
        "/var/lib/nixos"             # NixOS state (uid/gid mappings, etc.)

        # Docker state (for VMs with Docker enabled)
        { directory = "/var/lib/docker"; }

        # Network configuration
        "/var/lib/dhcpcd"            # DHCP client state (if used)

        # SSH directory - contains host keys and config
        # Persisting entire directory instead of individual files
        # avoids first-boot chicken-and-egg issue with key generation
        "/etc/ssh"
      ];

      files = [
        # Machine ID - used by systemd and various services
        "/etc/machine-id"
      ];

      users.robertwendt = {
        directories = [
          # User home directory persistence
          "Documents"
          "Downloads"
          ".ssh"
          { directory = ".local/share"; mode = "0700"; }
        ];
        files = [
          ".bash_history"
        ];
      };
    };

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
