# hosts/vm2/default.nix
# MicroVM 2 configuration
# Network: 10.2.0.2/24 (bridge: br-vm2)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm2";
  microvm.network = "vm2";

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
