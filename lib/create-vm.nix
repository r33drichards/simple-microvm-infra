# lib/create-vm.nix
# Factory function for creating MicroVM slot configurations
# Provides a DRY way to define VM slots with optional custom modules
#
# Portable State Architecture:
# - Slots are fixed network identities (slot1 = 10.1.0.2, etc.)
# - States are portable data that can be assigned to any slot
# - Pass stateName to specify which state dataset to use

# Usage in flake.nix:
#   import ./lib/create-vm.nix {
#     hostname = "slot1";
#     network = "slot1";
#     stateName = "dev";  # Optional: defaults to hostname
#     modules = [ ./my-custom-config.nix ];
#   }

{
  # Required parameters
  hostname,            # Slot name (e.g., "slot1")
  network,             # Network name from networks.nix

  # Optional parameters
  stateName ? hostname, # State dataset name (defaults to hostname)
  modules ? [],         # Additional NixOS modules to import
  packages ? [],        # Extra packages to install (beyond defaults)
  enableSSH ? true,     # Enable SSH server (default: true)
  stateVersion ? "24.05", # NixOS state version
}:

{ config, pkgs, ... }:

{
  imports = modules;

  # Set slot identity
  networking.hostName = hostname;
  microvm.network = network;

  # Set state name (which dataset to use for persistent storage)
  microvm.stateName = stateName;

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
