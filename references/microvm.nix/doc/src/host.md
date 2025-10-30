# Preparing a NixOS host for declarative MicroVMs

**microvm.nix** adds the following configuration for servers to
host MicroVMs reliably:

- a `/var/lib/microvms` state directory with one subdirectory per MicroVM
- systemd services `microvm-tap-interfaces@` to setup TAP network interfaces
- systemd services `microvm-virtiofsd@` to start virtiofsd instances
- systemd services `microvm@` to start a MicroVM
- configuration options to [declaratively build MicroVMs with the host
  system](./declarative.md)
- tools to [manage MicroVMs imperatively](./microvm-command.md)

Prepare your host by including the microvm.nix `host` nixosModule:

```nix
# Your server's flake.nix
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.microvm.url = "github:microvm-nix/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, microvm }: {
    # Example nixosConfigurations entry
    nixosConfigurations.server1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Include the microvm host module
        microvm.nixosModules.host
        # Add more modules here
        {
          networking.hostName = "server1";

          # try to automatically start these MicroVMs on bootup
          microvm.autostart = [
            "my-microvm"
            "your-microvm"
            "their-microvm"
          ];
        }
      ];
    };
  };
}
```

# Preparing a non-Flakes host

If you really cannot migrate to Flakes easily, just import the `host`
module directly in your NixOS configuration:

```nix
imports = [ (builtins.fetchGit {
  url = "https://github.com/microvm-nix/microvm.nix";
} + "/nixos-modules/host") ];
```
