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

              # Mount secrets directory from hypervisor via virtiofs
              # Secrets are fetched on hypervisor (which has AWS credentials)
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
