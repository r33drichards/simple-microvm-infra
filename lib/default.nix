# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix, impermanence, comin, and microvm-base.nix modules
{ self, nixpkgs, microvm, impermanence, comin, playwright-mcp }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";

  specialArgs = {
    inherit playwright-mcp;
  };

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include impermanence module
    impermanence.nixosModules.impermanence

    # Include comin module (GitOps deployment)
    comin.nixosModules.comin

    # Include our base MicroVM config
    ../modules/microvm-base.nix

    # Include VM Comin configuration (self-updating VMs)
    ../modules/vm-comin.nix
  ] ++ modules;  # Append VM-specific modules
}
