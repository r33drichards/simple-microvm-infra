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

    # Impermanence - manage persistent state on ephemeral systems
    impermanence = {
      url = "github:nix-community/impermanence";
    };
  };

  outputs = { self, nixpkgs, microvm, comin, impermanence }:
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

              # Install AWS CLI and jq for secret fetching
              environment.systemPackages = with nixpkgs.legacyPackages.aarch64-linux; [
                awscli2
                jq
              ];

              # Create systemd service to fetch AWS Secrets Manager secret
              systemd.services.fetch-aws-secrets = {
                description = "Fetch secrets from AWS Secrets Manager";
                wantedBy = [ "multi-user.target" ];
                before = [ "docker-sandbox.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -euo pipefail

                  SECRET_NAME="bmnixos"
                  REGION="us-west-2"
                  ENV_FILE="/run/secrets/sandbox.env"

                  # Create secrets directory
                  mkdir -p /run/secrets
                  chmod 700 /run/secrets

                  # Fetch secret from AWS Secrets Manager
                  echo "Fetching secret from AWS Secrets Manager..."
                  SECRET_JSON=$(${nixpkgs.legacyPackages.aarch64-linux.awscli2}/bin/aws secretsmanager get-secret-value \
                    --secret-id "$SECRET_NAME" \
                    --region "$REGION" \
                    --query SecretString \
                    --output text)

                  # Parse JSON and write to env file
                  echo "Writing environment variables to $ENV_FILE..."
                  echo "$SECRET_JSON" | ${nixpkgs.legacyPackages.aarch64-linux.jq}/bin/jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$ENV_FILE"

                  # Secure the file
                  chmod 600 "$ENV_FILE"

                  echo "Successfully fetched and wrote secrets to $ENV_FILE"
                '';
              };

              virtualisation.oci-containers = {
                backend = "docker";
                containers = {
                  sandbox = {
                    image = "wholelottahoopla/sandbox:latest";
                    autoStart = true;
                    ports = [ "0.0.0.0:8080:8080" ];
                    # Load environment variables from secret file
                    environmentFiles = [ "/run/secrets/sandbox.env" ];
                  };
                };
              };
            }
          ];
        };
        vm2 = { };
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
      lib.microvmSystem = import ./lib { inherit self nixpkgs microvm impermanence; };
    };
}
