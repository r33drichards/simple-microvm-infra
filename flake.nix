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
          # K3s (lightweight Kubernetes) server
          modules = [
            ./modules/k3s-vm.nix
            # Increase resources for Kubernetes
            { microvm.mem = 4096; microvm.vcpu = 2; }
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

      # Script packages (for multiple systems)
      setupHypervisorIam = system: let
        pkgs' = nixpkgs.legacyPackages.${system};
      in pkgs'.writeShellApplication {
        name = "setup-hypervisor-iam";
        runtimeInputs = with pkgs'; [ awscli2 curl jq ];
        text = builtins.readFile ./scripts/setup-hypervisor-iam.sh;
      };

    in {
      # Custom packages
      packages.${system} = {
        inherit playwright-mcp;
        setup-hypervisor-iam = setupHypervisorIam system;
      };

      # Also provide for x86_64 (for running from local dev machines)
      packages.x86_64-linux.setup-hypervisor-iam = setupHypervisorIam "x86_64-linux";
      packages.x86_64-darwin.setup-hypervisor-iam = setupHypervisorIam "x86_64-darwin";
      packages.aarch64-darwin.setup-hypervisor-iam = setupHypervisorIam "aarch64-darwin";

      # Apps for `nix run`
      apps.${system}.setup-hypervisor-iam = {
        type = "app";
        program = "${setupHypervisorIam system}/bin/setup-hypervisor-iam";
      };
      apps.x86_64-linux.setup-hypervisor-iam = {
        type = "app";
        program = "${setupHypervisorIam "x86_64-linux"}/bin/setup-hypervisor-iam";
      };
      apps.x86_64-darwin.setup-hypervisor-iam = {
        type = "app";
        program = "${setupHypervisorIam "x86_64-darwin"}/bin/setup-hypervisor-iam";
      };
      apps.aarch64-darwin.setup-hypervisor-iam = {
        type = "app";
        program = "${setupHypervisorIam "aarch64-darwin"}/bin/setup-hypervisor-iam";
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
      lib.microvmSystem = import ./lib { inherit self nixpkgs microvm impermanence comin playwright-mcp; };
    };
}
