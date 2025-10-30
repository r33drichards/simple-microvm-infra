# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix and microvm-base.nix modules
{ self, nixpkgs, microvm }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include our base MicroVM config
    ../modules/microvm-base.nix
  ] ++ modules;  # Append VM-specific modules
}
