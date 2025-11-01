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
          # Docker-enabled VM with sandbox container + Desktop environment
          modules = [
            ./modules/desktop-vm.nix
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
          # Remote desktop VM with browser access (XRDP + XFCE)
          modules = [
            ./modules/desktop-vm.nix
          ];
        };
        vm3 = {
          # Remote desktop VM with browser access (XRDP + XFCE)
          modules = [
            ./modules/desktop-vm.nix
          ];
        };
        vm4 = {
          # Remote desktop VM with browser access (XRDP + XFCE)
          modules = [
            ./modules/desktop-vm.nix
          ];
        };
        vm5 = {
          # Remote desktop VM with browser access (XRDP + XFCE)
          modules = [
            ./modules/desktop-vm.nix
          ];
        };
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
