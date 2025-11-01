# hosts/hypervisor/comin.nix
# GitOps deployment automation using Comin
# Manages: automatic pulls from git, NixOS rebuilds, deployment hooks
{ config, pkgs, lib, ... }:
{
  services.comin = {
    enable = true;

    # Git repository configuration
    remotes = [{
      name = "origin";
      url = "https://github.com/r33drichards/simple-microvm-infra.git";

      branches.main.name = "master";
    }];
  };

  # Enable git for Comin to use
  environment.systemPackages = with pkgs; [
    git
  ];

  # Ensure journald logs are retained for monitoring
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  # VM auto-restart module - DISABLED for manual control
  # To manually update VMs after deployment, run: microvm-update-all
  services.microvm-auto-restart = {
    enable = false;  # Set to true to auto-restart VMs on every deployment
    triggerAfterComin = true;  # Only matters if enable = true
  };
}
