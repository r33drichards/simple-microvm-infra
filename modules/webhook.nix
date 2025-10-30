# modules/webhook.nix
# Webhook configuration for automated deployments
# Provides HTTP endpoints that trigger deployment scripts
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.microvm-webhook;

  # Deployment script that rebuilds and deploys the infrastructure
  deployScript = pkgs.writeScriptBin "deploy-infrastructure" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    LOG_FILE="/var/log/webhook-deploy.log"
    LOCK_FILE="/var/run/deploy.lock"

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"

    # Function to log with timestamp
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
    }

    # Prevent concurrent deployments
    if [ -f "$LOCK_FILE" ]; then
      log "ERROR: Deployment already in progress"
      exit 1
    fi

    trap 'rm -f "$LOCK_FILE"' EXIT
    touch "$LOCK_FILE"

    log "=== Starting deployment ==="
    log "Triggered by: ''${WEBHOOK_ID:-unknown}"
    log "Remote IP: ''${WEBHOOK_SOURCE_IP:-unknown}"

    # Change to infrastructure directory
    cd ${cfg.infrastructureDir}

    # Pull latest changes if git repo
    if [ -d .git ]; then
      log "Pulling latest changes from git..."
      ${pkgs.git}/bin/git pull origin ${cfg.gitBranch} 2>&1 | tee -a "$LOG_FILE"
    fi

    # Update flake inputs
    log "Updating flake inputs..."
    ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake .#hypervisor --update-input nixpkgs 2>&1 | tee -a "$LOG_FILE"

    # Rebuild VMs if requested
    if [ "''${REBUILD_VMS:-false}" = "true" ]; then
      log "Rebuilding VMs..."
      for vm in vm1 vm2 vm3 vm4 vm5; do
        if systemctl is-active --quiet "microvm@$vm"; then
          log "Rebuilding $vm..."
          microvm -Ru "$vm" 2>&1 | tee -a "$LOG_FILE"
        fi
      done
    fi

    log "=== Deployment completed successfully ==="
  '';

  # Simple health check script
  healthCheckScript = pkgs.writeScriptBin "health-check" ''
    #!${pkgs.bash}/bin/bash
    echo "OK"
  '';

in {
  options.services.microvm-webhook = {
    enable = mkEnableOption "webhook service for MicroVM deployments";

    infrastructureDir = mkOption {
      type = types.path;
      default = "/etc/nixos";
      description = "Path to the infrastructure git repository";
    };

    gitBranch = mkOption {
      type = types.str;
      default = "main";
      description = "Git branch to pull from";
    };

    secretToken = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Secret token for webhook authentication.
        If null, webhooks will be unauthenticated (NOT RECOMMENDED for production).
        Use a strong random token and pass it as a URL parameter or header.
      '';
    };

    allowedIPs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "192.30.252.0/22" "185.199.108.0/22" "140.82.112.0/20" ];
      description = ''
        List of IP addresses or CIDR ranges allowed to trigger webhooks.
        Useful for restricting access to GitHub webhook IPs or specific sources.
        Empty list means all IPs are allowed (use secretToken for auth).
      '';
    };

    port = mkOption {
      type = types.port;
      default = 9000;
      description = "Port for webhook to listen on (will be proxied by Caddy)";
    };
  };

  config = mkIf cfg.enable {
    # Install the webhook package from nixpkgs/modules/services/networking/webhook.nix
    services.webhook = {
      enable = true;
      port = cfg.port;
      ip = "127.0.0.1"; # Only listen on localhost, Caddy will proxy
      openFirewall = false; # Caddy handles external access
      verbose = true;

      hooks = {
        # Main deployment hook
        deploy = {
          id = "deploy";
          execute-command = "${deployScript}/bin/deploy-infrastructure";
          command-working-directory = cfg.infrastructureDir;
          response-message = "Deployment started successfully";

          # Optional: trigger rules for validation
          trigger-rule = mkIf (cfg.secretToken != null) {
            match = {
              type = "value";
              value = cfg.secretToken;
              parameter = {
                source = "url";
                name = "token";
              };
            };
          };

          # Pass webhook metadata as environment variables
          pass-environment-to-command = [
            {
              source = "string";
              name = "WEBHOOK_ID";
              envname = "WEBHOOK_ID";
            }
            {
              source = "string";
              name = "WEBHOOK_SOURCE_IP";
              envname = "WEBHOOK_SOURCE_IP";
            }
          ];
        };

        # Health check endpoint
        health = {
          id = "health";
          execute-command = "${healthCheckScript}/bin/health-check";
          response-message = "Webhook service is healthy";
        };

        # Quick rebuild without git pull
        rebuild = {
          id = "rebuild";
          execute-command = "${deployScript}/bin/deploy-infrastructure";
          command-working-directory = cfg.infrastructureDir;
          response-message = "Rebuild started successfully";

          trigger-rule = mkIf (cfg.secretToken != null) {
            match = {
              type = "value";
              value = cfg.secretToken;
              parameter = {
                source = "url";
                name = "token";
              };
            };
          };

          pass-environment-to-command = [
            {
              source = "string";
              name = "REBUILD_VMS";
              envname = "REBUILD_VMS";
            }
          ];
        };
      };
    };

    # Ensure deployment scripts have necessary permissions
    systemd.services.webhook.serviceConfig = {
      # Allow webhook to run nixos-rebuild and manage services
      AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
      # Run as root to allow system management
      User = mkForce "root";
      Group = mkForce "root";
    };

    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d /var/log/webhook 0755 root root -"
    ];

    # Firewall rules if specific IPs are configured
    networking.firewall.extraCommands = mkIf (cfg.allowedIPs != []) ''
      # Allow webhook access only from specific IPs
      ${concatMapStrings (ip: ''
        iptables -A nixos-fw -p tcp --dport ${toString cfg.port} -s ${ip} -j ACCEPT
      '') cfg.allowedIPs}
    '';
  };
}
