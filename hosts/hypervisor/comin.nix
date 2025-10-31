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

    # Note: postDeployHook is not yet supported in the current version of Comin
    # Will be added once the feature is available
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
}
