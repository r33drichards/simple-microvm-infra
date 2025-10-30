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
