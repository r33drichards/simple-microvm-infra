# flake.nix
# Main entry point for simple-microvm-infra
# Defines: dependencies (nixpkgs, microvm.nix) and all system configs
#
# Portable State Architecture:
# - Slots are fixed network identities (slot1 = 10.1.0.2, slot2 = 10.2.0.2, etc.)
# - States are portable ZFS datasets that can be snapshotted and migrated
# - Any state can run on any slot via the vm-state CLI tool
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
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Custom packages
      playwright-mcp = pkgs.callPackage ./pkgs/playwright-mcp {};

      # Slot definitions - each slot is a fixed network identity
      # States (persistent data) can be assigned to any slot
      #
      # Default state names match slot names for simplicity:
      #   slot1 uses state "slot1", slot2 uses state "slot2", etc.
      #
      # To run a different state on a slot, use the vm-state CLI:
      #   vm-state assign slot1 my-custom-state
      slots = {
        slot1 = {
          # All slots use the unified slot-vm module
          modules = [ ./modules/slot-vm.nix ];
        };
        slot2 = {
          modules = [ ./modules/slot-vm.nix ];
        };
        slot3 = {
          modules = [ ./modules/slot-vm.nix ];
        };
        slot4 = {
          modules = [ ./modules/slot-vm.nix ];
          # Extra resources for heavier workloads
          config = { microvm.mem = 4096; microvm.vcpu = 2; };
        };
        slot5 = {
          modules = [ ./modules/slot-vm.nix ];
        };
      };

      # Generate nixosConfiguration for each slot
      slotConfigurations = nixpkgs.lib.mapAttrs (name: slotConfig:
        self.lib.microvmSystem {
          modules = [
            (import ./lib/create-vm.nix ({
              hostname = name;
              network = name;
              # Default state matches slot name
              stateName = name;
            } // slotConfig))
          ] ++ (if slotConfig ? config then [slotConfig.config] else []);
        }
      ) slots;

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
      } // slotConfigurations;  # Merge in generated slot configurations

      # Export our library function for building MicroVMs
      lib.microvmSystem = import ./lib { inherit self nixpkgs microvm comin playwright-mcp; };
    };
}
