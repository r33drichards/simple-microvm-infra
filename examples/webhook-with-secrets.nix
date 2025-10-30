# Example: Webhook configuration with secrets management
#
# IMPORTANT: Don't commit your secret token to git!
# This file shows secure ways to manage the webhook secret token.

{ config, pkgs, ... }:

{
  # OPTION 1: Read from file (recommended for production)
  #
  # Create the file on your hypervisor:
  #   echo -n "your-secret-token" | sudo tee /root/webhook-secret
  #   sudo chmod 600 /root/webhook-secret
  #
  # Then use it in configuration:
  services.microvm-webhook = {
    enable = true;
    infrastructureDir = "/home/robertwendt/simple-microvm-infra";
    gitBranch = "main";
    secretToken = builtins.readFile /root/webhook-secret;
    port = 9000;
  };

  # OPTION 2: Environment variable (for testing)
  #
  # Set in your shell before rebuilding:
  #   export WEBHOOK_SECRET="your-secret-token"
  #   sudo -E nixos-rebuild switch --flake .#hypervisor
  #
  # services.microvm-webhook = {
  #   enable = true;
  #   infrastructureDir = "/home/robertwendt/simple-microvm-infra";
  #   gitBranch = "main";
  #   secretToken = builtins.getEnv "WEBHOOK_SECRET";
  #   port = 9000;
  # };

  # OPTION 3: sops-nix (recommended for teams)
  #
  # Install sops-nix: https://github.com/Mic92/sops-nix
  #
  # Add to flake.nix inputs:
  #   sops-nix.url = "github:Mic92/sops-nix";
  #
  # Then use secrets:
  # sops.secrets.webhook-token = {
  #   sopsFile = ./secrets.yaml;
  #   owner = "webhook";
  # };
  #
  # services.microvm-webhook = {
  #   enable = true;
  #   infrastructureDir = "/home/robertwendt/simple-microvm-infra";
  #   gitBranch = "main";
  #   secretToken = config.sops.secrets.webhook-token.path;
  #   port = 9000;
  # };

  # OPTION 4: agenix (alternative to sops-nix)
  #
  # Install agenix: https://github.com/ryantm/agenix
  #
  # Add to flake.nix inputs:
  #   agenix.url = "github:ryantm/agenix";
  #
  # Then use secrets:
  # age.secrets.webhook-token.file = ./secrets/webhook-token.age;
  #
  # services.microvm-webhook = {
  #   enable = true;
  #   infrastructureDir = "/home/robertwendt/simple-microvm-infra";
  #   gitBranch = "main";
  #   secretToken = config.age.secrets.webhook-token.path;
  #   port = 9000;
  # };

  # Example: Complete configuration with IP allowlist
  services.microvm-webhook = {
    enable = true;
    infrastructureDir = "/home/robertwendt/simple-microvm-infra";
    gitBranch = "main";
    secretToken = builtins.readFile /root/webhook-secret; # ← Read from file
    port = 9000;

    # Restrict to GitHub webhook IPs
    allowedIPs = [
      # GitHub webhook IPs (as of 2024)
      # Get latest from: https://api.github.com/meta
      "192.30.252.0/22"
      "185.199.108.0/22"
      "140.82.112.0/20"
      "143.55.64.0/20"
      "20.201.28.151/32"
      "20.205.243.166/32"

      # Your CI/CD server
      "203.0.113.10/32"

      # Your office IP (for testing)
      "198.51.100.0/24"
    ];
  };

  # Example: Caddy with multiple domains
  services.microvm-caddy = {
    enable = true;
    domain = "webhooks.example.com";
    email = "admin@example.com";
    webhookPort = 9000;

    # Extra configuration for additional features
    extraConfig = ''
      # Add custom headers
      header {
        X-Robots-Tag "noindex, nofollow"
      }

      # Add basic auth (in addition to token)
      # Generate: caddy hash-password --plaintext 'your-password'
      # basicauth /hooks/deploy {
      #   admin $2a$14$...hashed-password...
      # }

      # Add metrics endpoint (localhost only)
      # @metrics {
      #   path /metrics
      #   remote_ip 127.0.0.1
      # }
      # handle @metrics {
      #   metrics
      # }
    '';
  };

  # Example: Send notifications on deployment
  systemd.services.webhook.environment = {
    # Slack webhook URL
    SLACK_WEBHOOK_URL = builtins.readFile /root/slack-webhook-url;

    # Discord webhook URL
    # DISCORD_WEBHOOK_URL = builtins.readFile /root/discord-webhook-url;

    # Environment name
    ENVIRONMENT = "production";
  };

  # Example: Deployment notification script
  # Modify deployScript in modules/webhook.nix to send notifications:
  #
  # send_notification() {
  #   if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  #     curl -X POST "$SLACK_WEBHOOK_URL" \
  #       -H 'Content-Type: application/json' \
  #       -d "{\"text\": \"🚀 Deployment started on $ENVIRONMENT\"}"
  #   fi
  # }
  #
  # log "=== Starting deployment ==="
  # send_notification
  # ... deployment steps ...
  # send_notification "✅ Deployment completed successfully"
}
