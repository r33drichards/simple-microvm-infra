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

    # Use virtiofs sharing from host instead of creating disk image
    microvm.storeOnDisk = false;

    # Default resource allocation (can be overridden by individual VMs)
    microvm.vcpu = lib.mkDefault config.vmDefaults.vcpu;
    microvm.mem = lib.mkDefault config.vmDefaults.mem;

    # Kernel modules for virtio devices (required for ARM64)
    boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];

    # Disable systemd in initrd to prevent mount unit overrides that break writable overlay
    # microvm.nix creates systemd.mounts overrides when boot.initrd.systemd.enable = true
    # which conflicts with writableStoreOverlay
    boot.initrd.systemd.enable = false;

    # Virtiofs filesystem shares from host
    # Share /nix/store from host (read-only, space-efficient)
    # When writableStoreOverlay is set, this becomes the lower layer of the overlay
    microvm.shares = [{
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }];

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
    # - Lower layer: shared read-only /nix/.ro-store from host
    # - Upper layer: writable /mnt/storage/nix-overlay/store
    # - Work dir: /mnt/storage/nix-overlay/work
    microvm.writableStoreOverlay = "/mnt/storage/nix-overlay";

    # Tmpfiles rules for persistent directories
    systemd.tmpfiles.rules = [
      "d /mnt/storage/persist 0755 root root -"
      # Create Nix state directories with proper permissions
      "d /nix/var 0755 root root -"
      "d /nix/var/nix 0755 root root -"
      "d /nix/var/nix/profiles 0755 root root -"
      "d /nix/var/nix/profiles/per-user 0755 root root -"
      "d /nix/var/nix/gcroots 0755 root root -"
      "d /nix/var/nix/gcroots/per-user 0755 root root -"
      "d /nix/var/nix/temproots 0755 root root -"
      "d /nix/var/nix/db 0755 root root -"
    ];

    # Configure journald for volatile storage (since /var is ephemeral)
    services.journald.extraConfig = ''
      Storage=volatile
      RuntimeMaxUse=100M
    '';

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

        # Nix user profiles (for nix profile install)
        "/nix/var/nix/profiles"
        "/nix/var/nix/profiles/per-user"
        "/nix/var/nix/gcroots"
        "/nix/var/nix/gcroots/per-user"
        "/nix/var/nix/temproots"
        "/nix/var/nix/db"
      ];

      files = [
        # Machine ID - used by systemd and various services
        "/etc/machine-id"

        # SSH host keys - persist individual key files only
        # Do NOT persist entire /etc/ssh as it shadows sshd_config
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
      ];

      users.robertwendt = {
        directories = [
          # User home directory persistence
          "Documents"
          "Downloads"
          ".ssh"
          { directory = ".local/share"; mode = "0700"; }
          ".nix-defexpr"
        ];
        files = [
          ".bash_history"
          { file = ".nix-profile"; parentDirectory = { mode = "0755"; }; }
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
