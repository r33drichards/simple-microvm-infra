# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix and microvm-base.nix modules
{ self, nixpkgs, microvm, home-manager, playwright-mcp }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";

  specialArgs = {
    inherit playwright-mcp;
  };

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include our base MicroVM config
    ../modules/microvm-base.nix
  ] ++ modules;  # Append VM-specific modules

  # Pass home-manager as a special arg so modules can use it
  specialArgs = { inherit home-manager; };
}
