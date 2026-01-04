# modules/microvm-base.nix
# Minimal base configuration for MicroVM slots
# Goal: smallest possible erofs, everything else goes on data.img
#
# What's in erofs (read-only, ~300-500MB):
#   - Kernel + initrd
#   - systemd
#   - openssh
#   - networkd
#   - nix (for nixos-rebuild)
#
# What's on data.img (read-write, user adds via nixos-rebuild):
#   - Everything else
{ config, lib, pkgs, ... }:

let
  networks = import ./networks.nix;
  slotNetwork = networks.networks.${config.microvm.network};
  stateName = config.microvm.stateName;
in
{
  # Options
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network/slot name (e.g., slot1)";
  };

  options.microvm.stateName = lib.mkOption {
    type = lib.types.str;
    default = config.networking.hostName;
    description = "State dataset name for persistent storage";
  };

  options.microvm.allowIMDS = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Allow AWS IMDS access";
  };

  config = {
    # Hypervisor
    microvm.hypervisor = "qemu";

    # Minimal erofs store + writable overlay on data.img
    microvm.storeOnDisk = true;
    microvm.writableStoreOverlay = "/nix/.rw-store";

    # Use squashfs instead of erofs for multi-threaded builds (much faster)
    microvm.storeDiskType = "squashfs";

    microvm.shares = [];

    # Minimal resources
    microvm.vcpu = lib.mkDefault 1;
    microvm.mem = lib.mkDefault 1024;

    # Only essential kernel modules
    boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" ];
    boot.initrd.systemd.enable = false;

    # Single data volume - state is one file
    microvm.volumes = [{
      image = "/var/lib/microvms/states/${stateName}/data.img";
      size = 65536;
      autoCreate = true;
      fsType = "ext4";
      mountPoint = "/";
      label = "${stateName}-root";
    }];

    # Network
    microvm.interfaces = [{
      type = "tap";
      id = "vm-${config.networking.hostName}";
      mac = "02:00:00:00:00:0${networks.slotNumber config.microvm.network}";
    }];

    systemd.network.enable = true;
    systemd.network.networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        Address = "${slotNetwork.subnet}.2/24";
        Gateway = "${slotNetwork.subnet}.1";
        DNS = "${slotNetwork.subnet}.1";
      };
    };

    # Minimal nix config (needed for nixos-rebuild)
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # SSH access
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];

    # No extra packages in erofs - user adds what they need
    environment.systemPackages = [];

    # Minimal settings
    time.timeZone = "UTC";
    security.sudo.wheelNeedsPassword = false;

    system.stateVersion = "24.05";
  };
}
