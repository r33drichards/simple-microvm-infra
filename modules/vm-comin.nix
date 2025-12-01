# modules/vm-comin.nix
# Comin GitOps configuration for MicroVMs
# Enables VMs to self-update by pulling from the git repository
{ config, pkgs, lib, ... }:

{
  # Enable Comin for GitOps deployment
  services.comin = {
    enable = true;

    # CRITICAL: hostname must match the nixosConfigurations key (e.g., "vm1")
    # Comin uses this to find the correct configuration to build
    hostname = config.networking.hostName;

    # Git repository configuration - same repo as hypervisor
    remotes = [{
      name = "origin";
      url = "https://github.com/r33drichards/simple-microvm-infra.git";
      branches.main.name = "master";
    }];
  };

  # Git is required for Comin
  environment.systemPackages = with pkgs; [
    git
  ];

  # Ensure journald logs are retained for deployment monitoring
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=1week
  '';
}
