# modules/slot-vm.nix
# Minimal VM configuration for portable state architecture
# Users customize their VMs via nixos-rebuild from inside the VM
# State (data.img) is just block storage that can be swapped
{ config, lib, pkgs, ... }:

{
  # SSH for remote access
  services.openssh.enable = true;

  # Minimal packages - user installs what they need
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    git
  ];

  # User with SSH access
  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];
  };

  system.stateVersion = "24.05";
}
