# modules/desktop-vm.nix
# Remote desktop VM configuration with XFCE, XRDP, and Claude Code
# This module provides a full desktop environment accessible via RDP
#
# Note: Anthropic API key authentication is handled by the optional claude-code-auth module.
# To enable authentication via AWS Secrets Manager, import modules/claude-code-auth.nix
# and set: services.claudeCode.auth.enable = true;
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

  # Note: LightDM greeter customization removed
  # Enable xfconf for XFCE configuration
  programs.xfconf.enable = true;

  # Note: Screen lock disabling systemd service removed
  # It was causing RDP sessions to hang. Users can configure via XFCE settings if needed.

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

  # Systemd service to set up Claude Code MCP server configuration
  # Note: Authentication is now handled by the optional claude-code-auth module
  systemd.services.setup-claude-code = {
    description = "Setup Claude Code MCP server configuration";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];  # Run after filesystem
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -e

      # Ensure home directory exists
      mkdir -p /home/robertwendt

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
      "args": ["--executable-path", "${pkgs.chromium}/bin/chromium"],
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

      echo "Claude Code MCP server configuration created successfully"
    '';
  };

  # Ensure robertwendt user can login via RDP
  users.users.robertwendt = {
    # configure shell to zsh
    isNormalUser = true;  # Required to create home directory
    extraGroups = [ "wheel" ];  # Preserve from base config
    # Set hashed password for RDP login
    # Password: "changeme" - change after first login
    hashedPassword = "$6$9vhPdO0pHckaLgWm$8NPkLKelUAGCjDWTWn7RQ871s4ET3wTpf3zN2vxchyT5MYRkHUbOGXrtwXwMBHReKpLp5syshTLPPn9cid3sI/";
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
