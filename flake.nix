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

    # Impermanence for ephemeral root filesystem
    impermanence = {
      url = "github:nix-community/impermanence";
    };
  };

  outputs = { self, nixpkgs, microvm, comin, impermanence }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Custom packages
      playwright-mcp = pkgs.callPackage ./pkgs/playwright-mcp {};

      # VM definitions - add/remove VMs here
      # Each VM gets its own isolated network (10.X.0.0/24)
      vms = {
        vm1 = {
          # Remote desktop VM with browser access (XRDP + XFCE)
          modules = [
            ./modules/desktop-vm.nix
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
          # Incus container/VM host with Web UI
          modules = [
            ./modules/incus-vm.nix
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
      # Custom packages
      packages.${system} = {
        inherit playwright-mcp;
      };

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
      lib.microvmSystem = import ./lib { inherit self nixpkgs microvm impermanence playwright-mcp; };
    };
}
