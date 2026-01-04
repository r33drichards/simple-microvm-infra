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
    # Mounted at /persist for persistent state (with impermanence)
    microvm.volumes = [
      {
        # Data volume - persistent storage for impermanence
        image = "/var/lib/microvms/${config.networking.hostName}/data.img";
        size = 65536;  # 64GB
        autoCreate = true;
        fsType = "ext4";
        mountPoint = "/persist";
        label = "${config.networking.hostName}-data";
      }
    ];

    # Root filesystem as tmpfs (ephemeral, cleared on reboot)
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "defaults" "size=2G" "mode=755" ];
    };

    # Mark /persist as needed for boot (required by impermanence module)
    fileSystems."/persist".neededForBoot = true;

    # Create required directories in /persist during stage 1 boot
    # This runs after /persist is mounted but before bind mounts happen
    # Required for fresh volumes (e.g., after reset-storage)
    boot.initrd.postMountCommands = ''
      mkdir -p /mnt-root/persist/nix-state
      mkdir -p /mnt-root/persist/nix-overlay
    '';

    # Manual bind mount for Nix database (impermanence doesn't support custom mount points)
    # Note: neededForBoot removed - stage 2 will create directory and mount
    fileSystems."/nix/var" = {
      depends = [ "/persist" ];
      device = "/persist/nix-state";
      fsType = "none";
      options = [ "bind" ];
      neededForBoot = false;
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
        # Use hypervisor as DNS (runs CoreDNS with allowlist filtering)
        # All DNS queries are redirected to hypervisor via nftables anyway
        DNS = "${vmNetwork.subnet}.1";
        DHCP = "no";
      };
      # Route AWS Instance Metadata Service (IMDS) through gateway
      # Only enabled when microvm.allowIMDS = true (disabled by default for security)
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
    # - Upper layer: writable /persist/nix-overlay/store (on persistent volume)
    # - Work dir: /persist/nix-overlay/work (on persistent volume)
    microvm.writableStoreOverlay = "/persist/nix-overlay";

    # Tmpfiles rules to ensure directories exist in /persist
    systemd.tmpfiles.rules = [
      "d /persist/nix-state 0755 root root -"
      "d /persist/nix-overlay 0755 root root -"
    ];

    # Impermanence configuration - defines what persists across reboots
    environment.persistence."/persist" = {
      hideMounts = true;
      directories = [
        # System state
        "/var/log"
        "/var/lib/systemd"
        "/var/lib/nixos"

        # Comin GitOps state (git checkout, build state)
        "/var/lib/comin"

        # Docker (for VMs with Docker enabled)
        "/var/lib/docker"
      ];
      files = [
        # Machine ID for consistent systemd identity
        "/etc/machine-id"
      ];
      users.robertwendt = {
        directories = [
          # User home directory
          { directory = ".local"; mode = "0755"; }
          { directory = ".config"; mode = "0755"; }
          { directory = ".cache"; mode = "0755"; }
          # Desktop-specific
          { directory = ".mozilla"; mode = "0755"; }
          { directory = ".ssh"; mode = "0700"; }
          # MCP and Claude Code
          { directory = ".claude"; mode = "0755"; }
          "Downloads"
          "Documents"
          "workspace"
        ];
        files = [
          ".bash_history"
        ];
      };
    };

    # Allow root login with password (for learning/setup)
    # CHANGE THIS in production!
    users.users.root.initialPassword = "nixos";

    # SSH keys for root user
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      # Hypervisor's key - allows SSH from hypervisor to VMs
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII4mlN4JTkdx3C7iBmMF5HporlQygDE2tjN77IE0Ezxn root@hypervisor"
      # AWS Secrets Manager key (rw-ssh-key) - allows ProxyJump from dev machines
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];

    # Create robertwendt user (same as hypervisor)
    users.users.robertwendt = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
        # Hypervisor's key - allows SSH from hypervisor to VMs
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGgfMmLS077IliGfXWUHTzI9ZBWFm6Vkn4m+NXvlmmOw root@ip-172-31-22-108.ec2.internal"
        # AWS Secrets Manager key (rw-ssh-key) - allows ProxyJump from dev machines
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
      ];
    };

    # Disable sudo password for convenience
    security.sudo.wheelNeedsPassword = false;

    # Swap file configuration (4GB on persistent storage)
    # Helps prevent OOM crashes during memory spikes
    swapDevices = [{
      device = "/persist/swapfile";
      size = 4096;  # 4GB in MB
    }];

    # Ensure swap file is created on boot if it doesn't exist
    systemd.services.create-swapfile = {
      description = "Create swap file on persistent storage";
      wantedBy = [ "swap.target" ];
      before = [ "swap.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -e
        SWAPFILE="/persist/swapfile"

        # Only create if it doesn't exist
        if [ ! -f "$SWAPFILE" ]; then
          echo "Creating 4GB swap file at $SWAPFILE..."
          ${pkgs.util-linux}/bin/fallocate -l 4G "$SWAPFILE"
          chmod 600 "$SWAPFILE"
          ${pkgs.util-linux}/bin/mkswap "$SWAPFILE"
          echo "Swap file created successfully"
        else
          echo "Swap file already exists at $SWAPFILE"
        fi
      '';
    };
  };
}
