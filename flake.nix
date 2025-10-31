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

              # Mount secrets directory from hypervisor via virtiofs
              # Secrets are fetched on hypervisor (which has AWS credentials)
              # Note: /nix/store share is inherited from microvm-base.nix
              microvm.shares = [
                {
                  source = "/var/lib/microvms/vm2/secrets";
                  mountPoint = "/run/secrets";
                  tag = "secrets";
                  proto = "virtiofs";
                }
              ];

              # Install desktop utilities and development tools
              environment.systemPackages = with pkgs; [
                firefox
                xfce.thunar
                xfce.xfce4-terminal
                nodejs  # Required for Claude Code
                jq      # Required for parsing secrets
              ];

              # Shell aliases
              environment.shellAliases = {
                "ccode" = "npx -y @anthropic-ai/claude-code --dangerously-skip-permissions";
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
                # Create Claude Code config directory
                "d /home/robertwendt/.config 0755 robertwendt users -"
                "d /home/robertwendt/.config/claude-code 0755 robertwendt users -"
              ];

              # Configure Claude Code settings.json with secrets from AWS Secrets Manager
              systemd.services.setup-claude-code = {
                description = "Setup Claude Code settings.json with AWS secrets";
                wantedBy = [ "multi-user.target" ];
                after = [ "network-online.target" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -euo pipefail

                  SECRETS_FILE="/run/secrets/claude-code.env"
                  CONFIG_DIR="/home/robertwendt/.config/claude-code"
                  SETTINGS_FILE="$CONFIG_DIR/settings.json"

                  # Wait for secrets to be available
                  if [ ! -f "$SECRETS_FILE" ]; then
                    echo "Warning: Secrets file not found at $SECRETS_FILE"
                    exit 0
                  fi

                  # Source the secrets (they're in KEY=VALUE format)
                  source "$SECRETS_FILE"

                  # Ensure config directory exists
                  mkdir -p "$CONFIG_DIR"

                  # Create settings.json with credentials
                  cat > "$SETTINGS_FILE" <<EOF
                  {
                    "sessionKey": "$ANTHROPIC_SESSION_KEY",
                    "deviceId": "$ANTHROPIC_DEVICE_ID"
                  }
                  EOF

                  # Set proper ownership
                  chown -R robertwendt:users "$CONFIG_DIR"
                  chmod 600 "$SETTINGS_FILE"

                  echo "Successfully configured Claude Code settings.json"
                '';
              };
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
