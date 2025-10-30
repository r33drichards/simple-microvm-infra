# hosts/vm3/default.nix
# MicroVM 3 configuration
# Network: 10.3.0.2/24 (bridge: br-vm3)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm3";
  microvm.network = "vm3";

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
