# flake.nix
# Main entry point for simple-microvm-infra
# Defines: dependencies (nixpkgs, microvm.nix) and all 5 system configs
{
  description = "Minimal MicroVM Infrastructure - Production Learning Template";

  inputs = {
    # NixOS 24.05 (stable)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

    # MicroVM framework
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }: {
    # All system configurations
    nixosConfigurations = {
      # Hypervisor (physical host)
      hypervisor = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.host  # Enable MicroVM host support
          ./hosts/hypervisor
        ];
      };

      # MicroVM 1 (10.1.0.2)
      vm1 = self.lib.microvmSystem {
        modules = [ ./hosts/vm1 ];
      };

      # MicroVM 2 (10.2.0.2)
      vm2 = self.lib.microvmSystem {
        modules = [ ./hosts/vm2 ];
      };

      # MicroVM 3 (10.3.0.2)
      vm3 = self.lib.microvmSystem {
        modules = [ ./hosts/vm3 ];
      };

      # MicroVM 4 (10.4.0.2)
      vm4 = self.lib.microvmSystem {
        modules = [ ./hosts/vm4 ];
      };
    };

    # Export our library function for building MicroVMs
    lib.microvmSystem = import ./lib { inherit self nixpkgs microvm; };
  };
}
