# modules/claude-code-auth.nix
# Configurable module for Claude Code authentication via AWS Secrets Manager
# This module sets up automatic fetching of Anthropic API key from AWS Secrets Manager
# and configures Claude Code to use it via an apiKeyHelper script.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.claudeCode.auth;
in
{
  options.services.claudeCode.auth = {
    enable = mkEnableOption "Claude Code authentication via AWS Secrets Manager";

    user = mkOption {
      type = types.str;
      default = "robertwendt";
      description = "User account for Claude Code authentication";
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group for Claude Code authentication files";
    };

    secretName = mkOption {
      type = types.str;
      default = "bmnixos";
      description = "AWS Secrets Manager secret name";
    };

    region = mkOption {
      type = types.str;
      default = "us-west-2";
      description = "AWS region for Secrets Manager";
    };

    envFile = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.env";
      description = "Path to the .env file where secrets will be stored";
    };

    apiKeyHelperPath = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/apiKeyHelper";
      description = "Path to the apiKeyHelper script";
    };
  };

  config = mkIf cfg.enable {
    # Systemd service to fetch secrets from AWS Secrets Manager on boot
    systemd.services.fetch-claude-secrets = {
      description = "Fetch Claude Code API key from AWS Secrets Manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
      };
      script = ''
        set -e

        # Fetch secrets from AWS Secrets Manager
        ${pkgs.awscli2}/bin/aws secretsmanager get-secret-value \
          --secret-id ${cfg.secretName} \
          --region ${cfg.region} \
          --query SecretString \
          --output text | ${pkgs.jq}/bin/jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > ${cfg.envFile}

        # Set correct permissions
        chmod 600 ${cfg.envFile}
        chown ${cfg.user}:${cfg.group} ${cfg.envFile}

        echo "Claude Code secrets fetched successfully"
      '';
    };

    # Systemd service to set up Claude Code configuration files
    # This must run AFTER /home is mounted
    systemd.services.setup-claude-code-auth = {
      description = "Setup Claude Code authentication configuration";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];  # Run after filesystem
      before = [ "fetch-claude-secrets.service" ];  # Run before secrets are fetched
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -e

        # Create apiKeyHelper script
        mkdir -p /home/${cfg.user}
        cat > ${cfg.apiKeyHelperPath} <<'EOF'
#!/bin/sh

# Read the ANTHROPIC_API_KEY from .env file
if [ -f "$HOME/.env" ]; then
    # Extract the API key value from the .env file
    key=$(grep '^ANTHROPIC_API_KEY=' "$HOME/.env" | cut -d '=' -f 2-)
    if [ -n "$key" ]; then
        echo "$key"
        exit 0
    fi
fi

# If we couldn't find the key, exit with error
echo "Error: ANTHROPIC_API_KEY not found in $HOME/.env" >&2
exit 1
EOF
        chmod +x ${cfg.apiKeyHelperPath}
        chown ${cfg.user}:${cfg.group} ${cfg.apiKeyHelperPath}

        # Create .claude directory and settings.json (for apiKeyHelper only)
        mkdir -p /home/${cfg.user}/.claude
        cat > /home/${cfg.user}/.claude/settings.json <<EOF
{
 "apiKeyHelper": "${cfg.apiKeyHelperPath}"
}
EOF
        chown -R ${cfg.user}:${cfg.group} /home/${cfg.user}/.claude
        chmod 755 /home/${cfg.user}/.claude
        chmod 644 /home/${cfg.user}/.claude/settings.json

        echo "Claude Code authentication configuration created successfully"
      '';
    };

    # Ensure home directory exists
    systemd.tmpfiles.rules = [
      "d /home/${cfg.user} 0700 ${cfg.user} ${cfg.group} -"
    ];

    # Ensure required packages are available
    environment.systemPackages = with pkgs; [
      awscli2
      jq
    ];
  };
}
