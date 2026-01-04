# modules/slot-vm.nix
# Minimal slot config - user adds everything else via nixos-rebuild
# State (data.img) is just block storage that can be swapped
{ config, lib, pkgs, ... }:

{
  # User for SSH access
  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
    ];
  };
}
