# modules/desktop-vm.nix
# Remote desktop VM configuration with XFCE, XRDP, and Claude Code
# This module provides a full desktop environment accessible via RDP
{ pkgs, playwright-mcp, ... }:
{
  # Enable X11 with XFCE desktop environment
  services.xserver = {
    enable = true;
    desktopManager = {
      xterm.enable = false;
      xfce.enable = true;
    };
  };

  # Set default session to XFCE
  services.displayManager.defaultSession = "xfce";

  # Enable XRDP server (RDP backend for remote desktop)
  # Note: Guacamole removed due to lack of ARM64 support
  # Access via: RDP client to VM IP:3389 (via Tailscale)
  services.xrdp = {
    enable = true;
    defaultWindowManager = "startxfce4";
    openFirewall = false;  # We'll manage firewall manually
    port = 3389;
  };

  # Open firewall for RDP
  networking.firewall.allowedTCPPorts = [ 3389 ];

  # Install desktop utilities and Claude Code dependencies
  environment.systemPackages = with pkgs; [
    firefox
    chromium
    xfce.thunar
    xfce.xfce4-terminal
    # Claude Code dependencies
    awscli2
    jq
    nodejs
    git
    gh  # GitHub CLI
    # Playwright browsers for MCP server
    playwright-driver.browsers
    # MCP servers
    playwright-mcp
  ];

  # Add ccode alias for easy Claude Code access
  programs.bash.shellAliases = {
    ccode = "npx -y @anthropic-ai/claude-code --dangerously-skip-permissions";
  };

  # Systemd service to fetch secrets from AWS Secrets Manager on boot
  systemd.services.fetch-claude-secrets = {
    description = "Fetch Claude Code API key from AWS Secrets Manager";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "robertwendt";
      Group = "users";
    };
    script = ''
      set -e

      # Fetch secrets from AWS Secrets Manager
      ${pkgs.awscli2}/bin/aws secretsmanager get-secret-value \
        --secret-id bmnixos \
        --region us-west-2 \
        --query SecretString \
        --output text | ${pkgs.jq}/bin/jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > /home/robertwendt/.env

      # Set correct permissions
      chmod 600 /home/robertwendt/.env
      chown robertwendt:users /home/robertwendt/.env

      echo "Claude Code secrets fetched successfully"
    '';
  };

  # Systemd service to set up Claude Code configuration files
  # This must run AFTER /home is mounted and home-manager activation
  systemd.services.setup-claude-code = {
    description = "Setup Claude Code configuration files";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "home-manager-robertwendt.service" ];  # Run after filesystem and home-manager
    before = [ "fetch-claude-secrets.service" ];  # Run before secrets are fetched
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e

      # Create apiKeyHelper script
      mkdir -p /home/robertwendt
      cat > /home/robertwendt/apiKeyHelper <<'EOF'
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
      chmod +x /home/robertwendt/apiKeyHelper
      chown robertwendt:users /home/robertwendt/apiKeyHelper

      # Create .claude directory and settings.json (for apiKeyHelper only)
      mkdir -p /home/robertwendt/.claude
      cat > /home/robertwendt/.claude/settings.json <<EOF
{
 "apiKeyHelper": "/home/robertwendt/apiKeyHelper"
}
EOF
      chown -R robertwendt:users /home/robertwendt/.claude
      chmod 755 /home/robertwendt/.claude
      chmod 644 /home/robertwendt/.claude/settings.json

      # Create .claude.json with MCP server configuration only if it doesn't exist
      # This is where Claude Code actually reads MCP server configs from
      # Don't overwrite if it exists, as Claude Code stores other state there
      if [ ! -f /home/robertwendt/.claude.json ]; then
        cat > /home/robertwendt/.claude.json <<EOF
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "${playwright-mcp}/bin/mcp-server-playwright",
      "args": [],
      "env": {}
    }
  }
}
EOF
        chown robertwendt:users /home/robertwendt/.claude.json
        chmod 644 /home/robertwendt/.claude.json
        echo "Created .claude.json with MCP server configuration"
      else
        echo ".claude.json already exists, skipping to preserve existing configuration"
      fi

      echo "Claude Code configuration created successfully"
    '';
  };

  # Ensure robertwendt user can login via RDP
  users.users.robertwendt = {
    # configure shell to zsh
    isNormalUser = true;  # Required to create home directory
    extraGroups = [ "wheel" ];  # Preserve from base config
    # Set initial password for RDP login (change after first login)
    initialPassword = "changeme";
    packages = with pkgs; [
      xfce.xfce4-panel
      xfce.xfce4-session
    ];
    # Preserve SSH keys from base config
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
    ];
  };

  # Ensure home directory exists even when user is "revived"
  # NixOS doesn't create home directories for existing users during revival
  systemd.tmpfiles.rules = [
    "d /home/robertwendt 0700 robertwendt users -"
  ];
}
