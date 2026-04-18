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

      branches.main.name = "main";
      poller.period = 15;
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

  # Auto-restart slots after Comin deploys so host-side config changes
  # (e.g., microvm.mem bumps) actually take effect without a manual step.
  # The update script diffs `current` vs `booted` symlinks and only restarts
  # slots whose declared runner has changed.
  services.microvm-auto-restart = {
    enable = true;
    triggerAfterComin = true;
  };
}
