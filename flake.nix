# flake.nix
# Main entry point for simple-microvm-infra
# Defines: dependencies (nixpkgs, microvm.nix) and all system configs
{
  description = "Minimal MicroVM Infrastructure - Production Learning Template";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # MicroVM framework
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # GitOps deployment automation
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm, comin }:
    let
      # VM definitions - add/remove VMs here
      # Each VM gets its own isolated network (10.X.0.0/24)
      vms = {
        vm1 = {
          # Docker-enabled VM with sandbox container
          modules = [
            {
              # Enable Docker
              virtualisation.docker.enable = true;

              # Allow Docker networking through NixOS firewall
              networking.firewall.trustedInterfaces = [ "docker0" ];
              networking.firewall.allowedTCPPorts = [ 8080 ];

              # Install AWS CLI
              environment.systemPackages = [ nixpkgs.legacyPackages.aarch64-linux.awscli2 ];

              # Mount secrets directory from hypervisor via virtiofs
              # Secrets are fetched on hypervisor (which has AWS credentials)
              # Note: /nix/store share is inherited from microvm-base.nix
              microvm.shares = [
                {
                  source = "/var/lib/microvms/vm1/secrets";
                  mountPoint = "/run/secrets";
                  tag = "secrets";
                  proto = "virtiofs";
                }
              ];

              virtualisation.oci-containers = {
                backend = "docker";
                containers = {
                  sandbox = {
                    image = "wholelottahoopla/sandbox:latest";
                    autoStart = true;
                    ports = [ "0.0.0.0:8080:8080" ];
                    # Load environment variables from secret file
                    # This file is created by fetch-vm1-secrets service on hypervisor
                    environmentFiles = [ "/run/secrets/sandbox.env" ];
                  };
                };
              };
            }
          ];
        };
        vm2 = {
          # Remote desktop VM with browser access (Guacamole + XRDP + XFCE)
          modules = [
            ({ pkgs, ... }: {
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
              # Access via: RDP client to 10.2.0.2:3389 (via Tailscale)
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
                xfce.thunar
                xfce.xfce4-terminal
                # Claude Code dependencies
                awscli2
                jq
                nodejs
                git
                gh  # GitHub CLI
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

              # Create apiKeyHelper script and .claude/settings.json on activation
              system.activationScripts.setup-claude-code = {
                text = ''
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

                  # Create .claude directory and settings.json
                  mkdir -p /home/robertwendt/.claude
                  cat > /home/robertwendt/.claude/settings.json <<'EOF'
{
 "apiKeyHelper": "/home/robertwendt/apiKeyHelper"
}
EOF
                  chown -R robertwendt:users /home/robertwendt/.claude
                  chmod 755 /home/robertwendt/.claude
                  chmod 644 /home/robertwendt/.claude/settings.json
                '';
              };

              # Ensure robertwendt user can login via RDP
              users.users.robertwendt = {
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
            })
          ];
        };
        vm3 = { };
        vm4 = { };
        vm5 = { };
      };

      # Generate nixosConfiguration for each VM
      vmConfigurations = nixpkgs.lib.mapAttrs (name: vmConfig:
        self.lib.microvmSystem {
          modules = [
            (import ./lib/create-vm.nix ({
              hostname = name;
              network = name;
            } // vmConfig))
          ];
        }
      ) vms;

    in {
      # All system configurations
      nixosConfigurations = {
        # Hypervisor (physical host)
        hypervisor = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit self; };
          modules = [
            microvm.nixosModules.host  # Enable MicroVM host support
            comin.nixosModules.comin   # GitOps deployment automation
            ./hosts/hypervisor
          ];
        };
      } // vmConfigurations;  # Merge in generated VM configurations

      # Export our library function for building MicroVMs
      lib.microvmSystem = import ./lib { inherit self nixpkgs microvm; };
    };
}
