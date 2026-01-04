# modules/desktop-vm.nix
# Remote desktop VM configuration - MINIMAL VERSION
# Full desktop environment commented out for faster builds
#
# To restore full desktop: uncomment the XFCE, XRDP, and browser sections below
{ pkgs, playwright-mcp, ... }:
{
  # ============================================================
  # MINIMAL CONFIG - SSH only for fast builds
  # ============================================================

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Basic utilities only
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    git
  ];

  # User configuration
  users.users.robertwendt = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$9vhPdO0pHckaLgWm$8NPkLKelUAGCjDWTWn7RQ871s4ET3wTpf3zN2vxchyT5MYRkHUbOGXrtwXwMBHReKpLp5syshTLPPn9cid3sI/";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
    ];
  };

  # Ensure home directory exists
  systemd.tmpfiles.rules = [
    "d /home/robertwendt 0700 robertwendt users -"
  ];

  # ============================================================
  # FULL DESKTOP CONFIG - Uncomment to restore
  # ============================================================

  # # Enable X11 with XFCE desktop environment
  # services.xserver = {
  #   enable = true;
  #   desktopManager = {
  #     xterm.enable = false;
  #     xfce.enable = true;
  #   };
  # };
  #
  # programs.xfconf.enable = true;
  # services.displayManager.defaultSession = "xfce";
  #
  # # Enable XRDP server
  # services.xrdp = {
  #   enable = true;
  #   defaultWindowManager = "startxfce4";
  #   openFirewall = false;
  #   port = 3389;
  # };
  #
  # # Open firewall for RDP
  # networking.firewall.allowedTCPPorts = [ 3389 ];
  #
  # # Desktop utilities and browsers
  # environment.systemPackages = with pkgs; [
  #   firefox
  #   chromium
  #   xfce.thunar
  #   xfce.xfce4-terminal
  #   awscli2
  #   jq
  #   nodejs
  #   git
  #   gh
  #   playwright-driver.browsers
  #   playwright-mcp
  # ];
  #
  # programs.bash.shellAliases = {
  #   ccode = "npx -y @anthropic-ai/claude-code --dangerously-skip-permissions";
  # };
  #
  # # Claude Code MCP server setup
  # systemd.services.setup-claude-code = {
  #   description = "Setup Claude Code MCP server configuration";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "local-fs.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     RemainAfterExit = true;
  #   };
  #   script = ''
  #     set -e
  #     mkdir -p /home/robertwendt
  #     if [ ! -f /home/robertwendt/.claude.json ]; then
  #       cat > /home/robertwendt/.claude.json <<EOF
  # {
  #   "mcpServers": {
  #     "playwright": {
  #       "type": "stdio",
  #       "command": "${playwright-mcp}/bin/mcp-server-playwright",
  #       "args": ["--executable-path", "${pkgs.chromium}/bin/chromium"],
  #       "env": {}
  #     }
  #   }
  # }
  # EOF
  #       chown robertwendt:users /home/robertwendt/.claude.json
  #       chmod 644 /home/robertwendt/.claude.json
  #     fi
  #   '';
  # };
  #
  # users.users.robertwendt.packages = with pkgs; [
  #   xfce.xfce4-panel
  #   xfce.xfce4-session
  # ];
}
