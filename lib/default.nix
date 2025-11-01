# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix and microvm-base.nix modules
{ self, nixpkgs, microvm, impermanence, playwright-mcp, multi-mcp }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";

  specialArgs = {
    inherit playwright-mcp;
    multi-mcp-pkg = multi-mcp.packages."aarch64-linux".default;
  };

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include impermanence module
    impermanence.nixosModules.impermanence

    # Include our base MicroVM config
    ../modules/microvm-base.nix
  ] ++ modules;  # Append VM-specific modules
}
