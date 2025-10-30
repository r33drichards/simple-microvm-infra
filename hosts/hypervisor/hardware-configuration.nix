# hosts/hypervisor/hardware-configuration.nix
# AWS EC2 a1.metal (ARM bare metal) hardware configuration
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    # AWS EC2 specific configuration
    "${modulesPath}/virtualisation/amazon-image.nix"
  ];

  # Boot loader configuration for EC2 ARM instances
  # a1.metal uses UEFI boot
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };

  boot.loader.timeout = 1;

  # Root filesystem configuration
  # EC2 uses /dev/nvme0n1p1 for root on a1.metal instances
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # EC2 metadata and user-data support
  services.cloud-init.enable = false;  # We use ec2-metadata from amazon-image.nix

  # Enable serial console for EC2
  boot.kernelParams = [ "console=ttyS0" "earlyprintk=ttyS0" ];

  # Network configuration for EC2
  networking.useDHCP = lib.mkDefault true;
  networking.useNetworkd = true;

  # AWS recommends these settings
  boot.initrd.availableKernelModules = [
    "nvme"
    "ena"  # Elastic Network Adapter
    "ixgbevf"
  ];

  boot.kernelModules = [ ];

  # Enable trim for SSDs
  services.fstrim.enable = lib.mkDefault true;

  # a1.metal specific settings
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
