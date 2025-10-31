# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix and microvm-base.nix modules
{ self, nixpkgs, microvm, impermanence }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include impermanence module (manages persistent state)
    impermanence.nixosModules.impermanence

    # Include our base MicroVM config
    ../modules/microvm-base.nix
  ] ++ modules;  # Append VM-specific modules
}
