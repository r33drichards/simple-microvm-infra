# hosts/vm5/default.nix
# MicroVM 5 configuration
# Network: 10.5.0.2/24 (bridge: br-vm5)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm5";
  microvm.network = "vm5";

  # VM resources inherited from modules/vm-resources.nix
  # To override: uncomment and set custom values
  # microvm.vcpu = 4;
  # microvm.mem = 8192;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
