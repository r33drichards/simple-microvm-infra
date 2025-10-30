# hosts/vm4/default.nix
# MicroVM 4 configuration
# Network: 10.4.0.2/24 (bridge: br-vm4)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm4";
  microvm.network = "vm4";

  microvm.vcpu = 2;
  microvm.mem = 1024;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
