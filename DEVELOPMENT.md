# Development Workflow

This document describes the development workflow for working with the MicroVM infrastructure.

## Overview

This infrastructure uses NixOS flakes to declaratively manage a hypervisor and 4 isolated MicroVMs. Changes are made by editing Nix configuration files, committing to git, and deploying to the remote hypervisor.

## Development Cycle

### 1. Make Changes Locally

Edit configuration files on your local machine:

```bash
cd simple-microvm-infra
# Edit files in modules/, hosts/, etc.
```

Common files to modify:
- `modules/microvm-base.nix` - Configuration shared by all VMs
- `hosts/hypervisor/default.nix` - Hypervisor host configuration
- `hosts/hypervisor/network.nix` - Network bridges and routing
- `hosts/vm1/default.nix` through `hosts/vm4/default.nix` - Per-VM configuration

### 2. Commit Changes

```bash
git add .
git commit -m "Description of changes"
git push
```

### 3. Deploy to Hypervisor

Pull changes and rebuild VMs on the remote hypervisor:

```bash
ssh -i "bm-nixos-us-west-2.pem" root@35.92.20.130 \
  "cd simple-microvm-infra && git pull && microvm -u vm1 vm2 vm3 vm4 vm5"
```

### 4. Restart VMs (if needed)

If the microvm command indicates a restart is needed:

```bash
ssh -i "bm-nixos-us-west-2.pem" root@35.92.20.130 \
  "systemctl restart microvm@vm1 microvm@vm2 microvm@vm3 microvm@vm4"
```

Or use the `-R` flag with microvm to auto-restart:

```bash
ssh -i "bm-nixos-us-west-2.pem" root@35.92.20.130 \
  "cd simple-microvm-infra && microvm -Ru vm1 vm2 vm3 vm4 vm5"
```

## Common Development Tasks

### Adding a Package to All VMs

Edit `modules/microvm-base.nix`:

```nix
config = {
  environment.systemPackages = with pkgs; [
    vim
    htop
    # Add your package here
  ];
};
```

### Adding a Package to One VM

Edit the specific VM's configuration, e.g., `hosts/vm1/default.nix`:

```nix
{
  environment.systemPackages = with pkgs; [
    postgresql
    # VM-specific packages
  ];
}
```

### Adding a User

Edit `modules/microvm-base.nix`:

```nix
users.users.newuser = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];  # for sudo access
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... your-key-here"
  ];
};
```

### Configuring a Service

Example: Enable and configure a service in a VM:

```nix
services.postgresql = {
  enable = true;
  package = pkgs.postgresql_15;
  # Additional configuration...
};
```

### Changing Network Configuration

VM network settings are defined in `modules/networks.nix`:

```nix
networks = {
  vm1 = { subnet = "10.1.0"; };
  vm2 = { subnet = "10.2.0"; };
  # ...
};
```

Each VM gets IP `<subnet>.2` (gateway is `<subnet>.1` on the hypervisor).

## Testing and Debugging

### Check VM Status

```bash
ssh -i "bm nixos us west 2.pem" root@16.144.20.78 "microvm -l"
```

This shows which VMs are running, their build status, and whether they need updates.

### Access a VM via SSH

Through Tailscale (from anywhere):
```bash
ssh robertwendt@10.1.0.2  # vm1
ssh robertwendt@10.2.0.2  # vm2
ssh robertwendt@10.3.0.2  # vm3
ssh robertwendt@10.4.0.2  # vm4
```

From the hypervisor directly:
```bash
ssh root@35.92.20.130
ssh robertwendt@10.1.0.2
```

### View VM Logs

```bash
ssh -i "bm-nixos-us-west-2.pem" root@35.92.20.130 \
  "journalctl -u microvm@vm1 -f"
```

### Run a VM in Foreground (for debugging)

```bash
ssh -i "bm nixos us west 2.pem" root@16.144.20.78
microvm -r vm1
```

This runs the VM in the foreground so you can see boot messages and errors.

### Check Network Connectivity

Test VM networking:
```bash
ssh robertwendt@10.1.0.2 "ping -c 3 1.1.1.1"
```

Test connectivity between VMs:
```bash
ssh robertwendt@10.1.0.2 "ping -c 3 10.2.0.2"
```

### Inspect Bridge Configuration

```bash
ssh -i "bm nixos us west 2.pem" root@16.144.20.78 "ip addr show br-vm1"
ssh -i "bm nixos us west 2.pem" root@16.144.20.78 "bridge link"
```

### Check TAP Interfaces

```bash
ssh -i "bm nixos us west 2.pem" root@16.144.20.78 "ip link show | grep vm-"
```

## Rollback Procedure

If a deployment breaks something:

### 1. Revert Git Changes

```bash
git revert HEAD  # or git reset --hard <previous-commit>
git push
```

### 2. Redeploy Previous Configuration

```bash
ssh -i "bm-nixos-us-west-2.pem" root@35.92.20.130 \
  "cd simple-microvm-infra && git pull && microvm -Ru vm1 vm2 vm3 vm4 vm5"
```

### 3. Or: Use Nix Generations

NixOS keeps previous generations. On the hypervisor:

```bash
# List generations
nix-env --list-generations --profile /nix/var/nix/profiles/system

# Rollback to previous generation
nixos-rebuild switch --rollback
```

## Git Workflow

### Commit Message Conventions

- Use descriptive commit messages
- Reference the component being changed (e.g., "Add PostgreSQL to vm1", "Fix ARM64 networking in microvm-base")
- Include context about why the change was made

### Branch Strategy

Currently using a simple main branch workflow:
- All changes committed directly to `master`
- For experimental changes, consider creating feature branches

## Performance Considerations

### Build Times

- Initial rebuild of all VMs: ~2-5 minutes
- Incremental rebuilds: ~30 seconds - 2 minutes
- Most time is spent downloading/building packages that aren't in the Nix cache

### Storage

- Each VM shares `/nix/store` with the hypervisor (read-only via virtiofs)
- Only `/var` is per-VM and writable
- VM storage is at `/var/lib/microvms/<vmname>/var` on the hypervisor

### Memory

- Each VM is configured with 1GB RAM (adjustable in per-VM config)
- QEMU hypervisor adds some overhead (~100-200MB per VM)

## Remote Development Tips

### SSH Key Management

Your SSH key must be loaded for passwordless access:

```bash
ssh-add ~/.ssh/id_ed25519
ssh-add -l  # verify key is loaded
```

### Using Tailscale

Tailscale provides seamless VPN access to all VM networks:

- VM1 network: 10.1.0.0/24
- VM2 network: 10.2.0.0/24
- VM3 network: 10.3.0.0/24
- VM4 network: 10.4.0.0/24

The hypervisor advertises these routes, so you can SSH directly to VMs from your laptop.

### Working with Flakes

This infrastructure uses Nix flakes. Key commands:

```bash
# Update flake inputs (nixpkgs, etc.)
nix flake update

# Check flake structure
nix flake show

# Build a specific VM configuration locally (for testing)
nix build .#nixosConfigurations.vm1.config.system.build.toplevel
```

## Troubleshooting

### VMs Won't Start

1. Check systemd service status:
   ```bash
   ssh root@35.92.20.130 "systemctl status microvm@vm1"
   ```

2. Check for errors in journal:
   ```bash
   ssh root@35.92.20.130 "journalctl -u microvm@vm1 -n 100"
   ```

3. Try running in foreground:
   ```bash
   ssh root@35.92.20.130 "microvm -r vm1"
   ```

### Network Not Working

1. Verify TAP interface exists and is in bridge:
   ```bash
   ssh root@35.92.20.130 "ip link show vm-vm1"
   ssh root@35.92.20.130 "bridge link show"
   ```

2. Check bridge has correct IP:
   ```bash
   ssh root@35.92.20.130 "ip addr show br-vm1"
   ```

3. Inside VM, verify interface configuration:
   ```bash
   ssh robertwendt@10.1.0.2 "ip addr; ip route"
   ```

### Build Failures

1. Check for syntax errors in Nix files:
   ```bash
   nix flake check
   ```

2. Try building locally to see full error:
   ```bash
   nix build .#nixosConfigurations.vm1.config.system.build.toplevel
   ```

### SSH Connection Issues

1. Verify SSH key is loaded:
   ```bash
   ssh-add -l
   ```

2. Check Tailscale is connected:
   ```bash
   tailscale status
   ```

3. Test connectivity:
   ```bash
   ping 10.1.0.2
   ```

## Architecture Changes

For major architectural changes (new hypervisor, different network topology, etc.), see `CLAUDE.md` for design rationale and key decision points.
