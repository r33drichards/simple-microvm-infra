# Slot Customization Guide

This guide shows how to customize slots in this infrastructure.

## Architecture Overview

Slots use a **minimal bootstrap + user customization** model:

```
Bootstrap (read-only squashfs):     Your Customizations (in data.img):
├── kernel + initrd                 ├── Root filesystem (/)
├── systemd                         ├── Home directories (/home)
├── openssh                         ├── Nix overlay (/nix/.rw-store)
├── networkd                        └── All packages via nixos-rebuild
├── nix
└── nodejs
```

## Customizing a Slot

### Option 1: nixos-rebuild Inside the Slot (Recommended)

The recommended way to customize a slot is from inside the slot itself:

```bash
# SSH into the slot
ssh root@10.1.0.2

# Edit the configuration
nano /etc/nixos/configuration.nix

# Apply changes
nixos-rebuild switch
```

Example configuration changes:

```nix
# /etc/nixos/configuration.nix
{ config, pkgs, ... }:
{
  # Add packages
  environment.systemPackages = with pkgs; [
    git
    docker
    python3
    neovim
  ];

  # Enable services
  services.postgresql.enable = true;

  # Add users
  users.users.developer = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
  };

  # Configure Docker
  virtualisation.docker.enable = true;
}
```

### Option 2: Configure Resources at Slot Definition

Resource overrides (CPU/memory) are defined in `flake.nix`:

```nix
slots = {
  slot1 = {};  # Uses defaults: 1 vCPU, 1GB RAM
  slot2 = {};
  slot3 = {};
  slot4 = { config = { microvm.mem = 4096; microvm.vcpu = 2; }; };  # Extra resources
  slot5 = {};
};
```

## State Management

Customizations are stored in the slot's state (data.img), which can be:

### Snapshotted

```bash
# Create a snapshot before major changes
vm-state snapshot slot1 before-update

# Make changes inside the slot
ssh root@10.1.0.2 "nixos-rebuild switch"

# If something breaks, restore from snapshot
vm-state restore before-update recovered-state
vm-state migrate recovered-state slot1
```

### Cloned

```bash
# Clone an existing customized slot's state
vm-state clone slot1 my-dev-env

# Run the clone on another slot
vm-state migrate my-dev-env slot3
```

### Migrated

```bash
# Move a state to a different slot (different IP)
vm-state migrate my-dev-env slot2

# The state now runs on slot2 (10.2.0.2)
ssh root@10.2.0.2
```

## Adding a New Slot

To add a new slot:

1. Add it to the `slots` attrset in `flake.nix`:
   ```nix
   slots = {
     slot1 = {};
     slot2 = {};
     slot6 = {};  # New slot
   };
   ```

2. Add the network definition in `modules/networks.nix`:
   ```nix
   networks = {
     slot1 = { subnet = "10.1.0"; bridge = "br-slot1"; };
     slot2 = { subnet = "10.2.0"; bridge = "br-slot2"; };
     slot6 = { subnet = "10.6.0"; bridge = "br-slot6"; };
   };
   ```

That's it! The hypervisor network configuration will automatically:
- Create the bridge
- Assign the gateway IP
- Add NAT rules
- Configure firewall isolation

## Common Customization Patterns

### Development Environment

```nix
{ config, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git neovim tmux
    nodejs python3 rustc cargo
    docker-compose
  ];

  virtualisation.docker.enable = true;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_15;
  };
}
```

### Web Server

```nix
{ config, pkgs, ... }:
{
  services.nginx = {
    enable = true;
    virtualHosts."example.com" = {
      root = "/var/www/example";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

### Database Server

```nix
{ config, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    authentication = ''
      host all all 10.0.0.0/8 md5
    '';
  };

  networking.firewall.allowedTCPPorts = [ 5432 ];
}
```

## Best Practices

1. **Snapshot before major changes**: Always create a snapshot before `nixos-rebuild switch` with significant changes

2. **Use states for different environments**: Clone states to create dev, staging, production environments

3. **Keep bootstrap minimal**: Don't modify `microvm-base.nix` unless necessary; customize via nixos-rebuild

4. **Test on a spare slot**: Clone to a spare slot, test changes, then migrate back if successful

## Workflow Example

```bash
# 1. Create a snapshot of current slot1 state
vm-state snapshot slot1 baseline

# 2. Clone to slot3 for testing
vm-state clone slot1 test-env
vm-state migrate test-env slot3

# 3. Make changes in slot3
ssh root@10.3.0.2
nixos-rebuild switch  # apply changes

# 4. If changes work, migrate back to slot1
vm-state snapshot slot3 new-config
vm-state clone slot3 slot1-new
systemctl stop microvm@slot1
vm-state assign slot1 slot1-new
systemctl start microvm@slot1

# 5. Clean up test environment
vm-state delete test-env
```
