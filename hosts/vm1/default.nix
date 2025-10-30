# hosts/vm1/default.nix
# MicroVM 1 configuration
# Network: 10.1.0.2/24 (bridge: br-vm1)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  # Hostname (must match directory name)
  networking.hostName = "vm1";

  # Network assignment (references modules/networks.nix)
  microvm.network = "vm1";

  # VM resources inherited from modules/vm-resources.nix
  # To override: uncomment and set custom values
  # microvm.vcpu = 4;
  # microvm.mem = 8192;

  # Enable SSH for remote access
  services.openssh.enable = true;

  # Example: install some useful packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  # NixOS version
  system.stateVersion = "24.05";
}
