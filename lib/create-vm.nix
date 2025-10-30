# lib/create-vm.nix
# Factory function for creating MicroVM configurations
# Provides a DRY way to define VMs with optional custom modules

# Usage in hosts/vmX/default.nix:
#   import ../../lib/create-vm.nix {
#     hostname = "vm1";
#     network = "vm1";
#     modules = [ ./my-custom-config.nix ];
#     packages = with pkgs; [ git docker ];
#   }

{
  # Required parameters
  hostname,
  network,

  # Optional parameters
  modules ? [],           # Additional NixOS modules to import
  packages ? [],          # Extra packages to install (beyond defaults)
  enableSSH ? true,       # Enable SSH server (default: true)
  stateVersion ? "24.05", # NixOS state version
}:

{ config, pkgs, ... }:

{
  imports = [
    ../../modules/microvm-base.nix
  ] ++ modules;

  # Set hostname and network from parameters
  networking.hostName = hostname;
  microvm.network = network;

  # VM resources inherited from modules/vm-resources.nix
  # To override in a VM: pass a module that sets microvm.vcpu/mem
  # Example: modules = [{ microvm.vcpu = 4; microvm.mem = 8192; }];

  # Enable SSH for remote access (if enabled)
  services.openssh.enable = enableSSH;

  # Default useful packages + any extras provided
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ] ++ packages;

  # NixOS version
  system.stateVersion = stateVersion;
}
