# VM Customization Guide

This guide shows how to customize VMs in this infrastructure.

## Basic VM Definition

VMs are defined in `flake.nix` in the `vms` attrset:

```nix
vms = {
  vm1 = { };
  vm2 = { };
  vm3 = { };
};
```

## Adding Custom Packages

To add packages to a specific VM:

```nix
vms = {
  vm1 = {
    packages = with pkgs; [ git docker python3 ];
  };
  vm2 = { };
};
```

## Adding Custom Modules

Create a custom module file and reference it:

```nix
# modules/custom-vm-config.nix
{ config, pkgs, ... }:
{
  services.postgresql.enable = true;

  users.users.developer = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
  };
}
```

Then in `flake.nix`:

```nix
vms = {
  vm1 = {
    modules = [ ./modules/custom-vm-config.nix ];
  };
  vm2 = { };
};
```

## Overriding Resource Allocation

To give a VM more CPU/memory than the defaults:

```nix
vms = {
  vm1 = {
    modules = [{
      microvm.vcpu = 8;
      microvm.mem = 16384;  # 16GB
    }];
  };
  vm2 = { };  # Uses defaults: 3 CPUs, 6GB RAM
};
```

## Complete Example

```nix
vms = {
  vm1 = {
    # Add extra packages
    packages = with pkgs; [ git docker python3 nodejs ];

    # Add custom configuration
    modules = [
      ./modules/database-config.nix
      {
        # Override resources
        microvm.vcpu = 4;
        microvm.mem = 8192;

        # Enable services
        services.postgresql.enable = true;
      }
    ];
  };

  vm2 = {
    # Minimal VM with just defaults
  };

  vm3 = {
    # Custom packages only
    packages = with pkgs; [ rustc cargo ];
  };
};
```

## Adding a New VM

To add a new VM:

1. Add it to the `vms` attrset in `flake.nix`:
   ```nix
   vms = {
     vm1 = { };
     vm2 = { };
     vm6 = { };  # New VM
   };
   ```

2. Add the network definition in `modules/networks.nix`:
   ```nix
   networks = {
     vm1 = { subnet = "10.1.0"; bridge = "br-vm1"; };
     vm2 = { subnet = "10.2.0"; bridge = "br-vm2"; };
     vm6 = { subnet = "10.6.0"; bridge = "br-vm6"; };
   };
   ```

That's it! The hypervisor network configuration will automatically:
- Create the bridge
- Assign the gateway IP
- Add NAT rules
- Configure firewall isolation
