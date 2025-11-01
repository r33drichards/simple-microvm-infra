# modules/microvm-auto-restart.nix
# Modular VM restart logic - can be triggered manually or automatically
# Manages: VM configuration symlink updates and selective restarts
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.microvm-auto-restart;

  # The core VM update script - used by both manual command and auto service
  updateScript = pkgs.writeScriptBin "microvm-update-all" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

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

in {
  options.services.microvm-auto-restart = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to automatically restart VMs when their configuration changes.
        When disabled, you must manually run 'microvm-update-all' to apply VM config changes.
      '';
    };

    triggerAfterComin = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to trigger VM updates after Comin deploys.
        Only takes effect if enable = true.
      '';
    };
  };

  config = {
    # Always make the manual command available, regardless of auto-restart setting
    environment.systemPackages = [ updateScript ];

    # Systemd service for updating VMs (can be triggered manually or automatically)
    systemd.services.microvm-auto-update = {
      description = "Update and restart MicroVMs when configuration changes";

      # Only wire it to run automatically if enabled
      after = mkIf cfg.enable [ "multi-user.target" ];
      wantedBy = mkIf cfg.enable [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };

      script = ''
        ${updateScript}/bin/microvm-update-all
      '';
    };

    # Hook into Comin's postStart if both auto-restart and trigger are enabled
    systemd.services.comin = mkIf (cfg.enable && cfg.triggerAfterComin && config.services.comin.enable) {
      postStart = ''
        # Wait a moment for the system to stabilize
        sleep 2
        # Trigger VM update check
        ${pkgs.systemd}/bin/systemctl start microvm-auto-update.service || true
      '';
    };
  };
}
