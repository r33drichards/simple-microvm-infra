# lib/create-vm.nix
# Factory function for creating MicroVM slot configurations
#
# Portable State Architecture:
# - Slots are fixed network identities (slot1 = 10.1.0.2, etc.)
# - States are block storage that can be snapshotted and swapped
# - Users customize VMs via nixos-rebuild from inside the VM

{
  # Required parameters
  hostname,            # Slot name (e.g., "slot1")
  network,             # Network name from networks.nix

  # Optional parameters
  stateName ? hostname, # State dataset name (defaults to hostname)
  modules ? [],         # Additional NixOS modules
  stateVersion ? "24.05",
}:

{ config, pkgs, ... }:

{
  imports = [
    ../modules/slot-vm.nix  # Minimal base config
  ] ++ modules;

  # Set slot identity
  networking.hostName = hostname;
  microvm.network = network;

  # Set state name (which dataset to use for persistent storage)
  microvm.stateName = stateName;

  # NixOS version
  system.stateVersion = stateVersion;
}
