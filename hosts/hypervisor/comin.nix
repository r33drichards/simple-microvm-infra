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

  # Auto-restart VMs when their configuration changes after deployment
  # This service runs after system activation and checks if VMs need restarting
  systemd.services.microvm-auto-update = {
    description = "Auto-restart MicroVMs when configuration changes";

    # Run after the system activation is complete
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };

    script = ''
      # List of all VMs
      VMS="vm1 vm2 vm3 vm4 vm5"

      echo "Updating VM configuration symlinks and checking for changes..."

      for vm in $VMS; do
        VM_DIR="/var/lib/microvms/$vm"
        CURRENT="$VM_DIR/current"
        BOOTED="$VM_DIR/booted"

        # Skip if VM directory doesn't exist
        if [ ! -d "$VM_DIR" ]; then
          echo "  $vm: VM directory not found, skipping"
          continue
        fi

        # Find the new runner from the install script
        # First, get the ExecStart path from the service
        INSTALL_SCRIPT=$(${pkgs.systemd}/bin/systemctl cat install-microvm-$vm.service 2>/dev/null | \
          ${pkgs.gnugrep}/bin/grep '^ExecStart=' | ${pkgs.gnused}/bin/sed 's/^ExecStart=//' | ${pkgs.coreutils}/bin/tr -d ' ')

        # Then read the runner path from the script
        if [ -n "$INSTALL_SCRIPT" ] && [ -f "$INSTALL_SCRIPT" ]; then
          NEW_RUNNER=$(${pkgs.gnugrep}/bin/grep -oP 'ln -sTf \K/nix/store/[^ ]+' "$INSTALL_SCRIPT" 2>/dev/null | head -1)
        else
          NEW_RUNNER=""
        fi

        if [ -z "$NEW_RUNNER" ]; then
          echo "  $vm: Could not find new runner path, skipping"
          continue
        fi

        # Update the current symlink to point to the new runner
        echo "  $vm: Updating symlink to $NEW_RUNNER..."
        ln -sTf "$NEW_RUNNER" "$CURRENT"
        chown -h microvm:kvm "$CURRENT"

        # Check if restart is needed
        if [ ! -e "$BOOTED" ] || [ "$(readlink -f "$CURRENT")" != "$(readlink -f "$BOOTED")" ]; then
          echo "  $vm: Configuration changed, restarting..."
          ${pkgs.systemd}/bin/systemctl restart microvm@$vm.service
          echo "  $vm: Restarted successfully"
        else
          echo "  $vm: No configuration change detected"
        fi
      done

      echo "VM configuration update check complete"
    '';
  };

  # Trigger the auto-update service after Comin deploys
  # This ensures VMs are restarted when configuration changes
  systemd.services.comin.postStart = ''
    # Wait a moment for the system to stabilize
    sleep 2
    # Trigger VM update check
    ${pkgs.systemd}/bin/systemctl start microvm-auto-update.service || true
  '';
}
