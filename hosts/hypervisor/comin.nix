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

      branches.main = {
        name = "main";
      };
    }];

    # Deployment hooks
    # These run after successful deployment
    postDeployHook = pkgs.writeShellScript "post-deploy-hook" ''
      set -eu

      echo "=== Comin Post-Deploy Hook ==="
      echo "Deployment completed at: $(date)"
      echo "Branch: $COMIN_BRANCH"
      echo "Commit: $COMIN_COMMIT"

      # Log the deployment
      logger -t comin "Deployment successful: $COMIN_BRANCH @ $COMIN_COMMIT"

      # Check microvm status
      echo "=== MicroVM Status ==="
      systemctl list-units 'microvm@*' --no-pager || true

      # Log active VMs
      ACTIVE_VMS=$(systemctl list-units 'microvm@*' --state=active --no-legend | wc -l)
      echo "Active MicroVMs: $ACTIVE_VMS"
      logger -t comin "Active MicroVMs after deployment: $ACTIVE_VMS"

      echo "=== Deployment Complete ==="
    '';
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
