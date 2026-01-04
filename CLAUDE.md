# Claude Code Instructions

This document helps Claude Code understand and operate this MicroVM infrastructure.

## Quick Reference

### Current Infrastructure

| Machine | IP Address | SSH Command | Role |
|---------|------------|-------------|------|
| **Hypervisor** | 34.219.181.99 | `ssh -i ~/.ssh/rw-ssh-key root@34.219.181.99` | Host machine (AWS a1.metal) |
| **VM1** | 10.1.0.2 | Via hypervisor (see below) | Desktop VM (XRDP + XFCE) |
| **VM2** | 10.2.0.2 | Via hypervisor (see below) | Desktop VM (XRDP + XFCE) |
| **VM3** | 10.3.0.2 | Via hypervisor (see below) | Desktop VM (XRDP + XFCE) |
| **VM4** | 10.4.0.2 | Via hypervisor (see below) | K3s (Kubernetes) |
| **VM5** | 10.5.0.2 | Via hypervisor (see below) | Incus container host |

### SSH Connection Patterns

```bash
# Connect to hypervisor
ssh -i ~/.ssh/rw-ssh-key root@34.219.181.99

# Connect to a VM (two-step via hypervisor)
ssh -i ~/.ssh/rw-ssh-key root@34.219.181.99 'ssh -i /root/.ssh/id_ed25519 root@10.1.0.2 "COMMAND"'

# Or use ProxyJump for interactive session
ssh -o ProxyJump=root@34.219.181.99 -i ~/.ssh/rw-ssh-key root@10.1.0.2
```

### Common Tasks

| Task | Command |
|------|---------|
| Check VM status | `ssh HYPERVISOR 'systemctl status microvm@vm1'` |
| Restart a VM | `ssh HYPERVISOR 'systemctl restart microvm@vm1'` |
| View VM logs | `ssh HYPERVISOR 'journalctl -u microvm@vm1 -f'` |
| List ZFS snapshots | `ssh HYPERVISOR 'zfs list -t snapshot'` |
| Create VM snapshot | `ssh HYPERVISOR 'zfs snapshot microvms/storage/vm1@backup'` |
| Deploy config | `NIX_SSHOPTS="-i ~/.ssh/rw-ssh-key" nixos-rebuild switch --flake .#hypervisor --target-host root@34.219.181.99` |

## Task-Based Instructions

### When asked to "service the hypervisor" or "work on the host":
1. SSH to `root@34.219.181.99` using `~/.ssh/rw-ssh-key`
2. Check system status: `systemctl status`, `zpool status`, `df -h`
3. For config changes, edit local files and deploy via `nixos-rebuild`

### When asked to "service vm1" (or vm2, vm3, etc.):
1. SSH through hypervisor: `ssh HYPERVISOR 'ssh VM "command"'`
2. VM IPs are `10.X.0.2` where X matches the VM number
3. VMs have impermanence - root is ephemeral, `/persist` survives reboots
4. For config changes, edit `flake.nix` or module files, rebuild VM runner

### When asked to "deploy" or "update configuration":
1. Edit Nix files locally
2. Commit and push to git (Comin will auto-deploy to hypervisor)
3. Or manually: `nixos-rebuild switch --flake .#hypervisor --target-host root@34.219.181.99`
4. For VMs: rebuild runner with `nix build .#nixosConfigurations.vmX.config.microvm.declaredRunner`

### When asked to "snapshot" or "backup" a VM:
```bash
# Create snapshot
ssh HYPERVISOR 'zfs snapshot microvms/storage/vmX@$(date +%Y%m%d-%H%M)'

# List snapshots
ssh HYPERVISOR 'zfs list -t snapshot'

# Rollback (WARNING: destroys current state)
ssh HYPERVISOR 'zfs rollback microvms/storage/vmX@snapshot-name'
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ AWS a1.metal - Hypervisor (34.219.181.99)                   │
│ Region: us-west-2 │ Instance: i-0d7593fccda7e14de           │
│                                                              │
│  ZFS Pool: microvms (100GB EBS volume)                      │
│  ├── microvms/storage/vm1  →  /var/lib/microvms/vm1         │
│  ├── microvms/storage/vm2  →  /var/lib/microvms/vm2         │
│  ├── microvms/storage/vm3  →  /var/lib/microvms/vm3         │
│  ├── microvms/storage/vm4  →  /var/lib/microvms/vm4         │
│  └── microvms/storage/vm5  →  /var/lib/microvms/vm5         │
│                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│  │   VM1    │ │   VM2    │ │   VM3    │ │   VM4    │ │   VM5    │
│  │10.1.0.2  │ │10.2.0.2  │ │10.3.0.2  │ │10.4.0.2  │ │10.5.0.2  │
│  │ Desktop  │ │ Desktop  │ │ Desktop  │ │   K3s    │ │  Incus   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
└─────────────────────────────────────────────────────────────┘
```

## Storage Architecture

### Hypervisor Storage
- **Root**: 50GB NVMe (NixOS system)
- **VM Storage**: 100GB EBS volume with ZFS pool `microvms`
  - Each VM has independent dataset for snapshots
  - Mounted at `/var/lib/microvms`

### VM Storage (Impermanence)
- **Root (`/`)**: tmpfs (2GB) - **ephemeral, cleared on reboot**
- **Persistent (`/persist`)**: 64GB ext4 - **survives reboots**
- **Nix Store**: Overlay on shared virtiofs from hypervisor

### What Persists in VMs
- `/var/log`, `/var/lib/systemd`, `/var/lib/nixos`
- `/etc/machine-id`
- User home directories (`.config`, `.local`, `.cache`, `.ssh`, etc.)
- `/var/lib/docker` (for VMs with Docker)

## Key Files

| File | Purpose |
|------|---------|
| `flake.nix` | VM definitions, inputs |
| `modules/microvm-base.nix` | Base VM config (network, storage, impermanence) |
| `modules/desktop-vm.nix` | Desktop VM config (XRDP, Firefox) |
| `modules/k3s-vm.nix` | Kubernetes VM config |
| `hosts/hypervisor/default.nix` | Hypervisor config |
| `modules/ebs-volume/default.nix` | ZFS/EBS volume management |

## Deep Dive Documentation

For more details, read these files:
- **Network topology**: `NETWORK-TOPOLOGY.md`
- **Deployment procedures**: `DEPLOYMENT.md`
- **Development workflow**: `DEVELOPMENT.md`
- **AWS provisioning**: `docs/AWS-PROVISION.md`
- **VM customization**: `docs/vm-customization.md`

## Troubleshooting

### VM won't start
```bash
# Check service status
ssh HYPERVISOR 'systemctl status microvm@vmX'
# Check if runner exists
ssh HYPERVISOR 'ls -la /var/lib/microvms/vmX/current'
# Rebuild runner if missing
ssh HYPERVISOR 'cd /root/simple-microvm-infra && nix build .#nixosConfigurations.vmX.config.microvm.declaredRunner -o /var/lib/microvms/vmX/current'
```

### Can't SSH to VM
```bash
# Check VM is running
ssh HYPERVISOR 'systemctl is-active microvm@vmX'
# Check bridge is up
ssh HYPERVISOR 'ip link show br-vmX'
# Check VM has network
ssh HYPERVISOR 'journalctl -u microvm@vmX | grep -i network'
```

### ZFS issues
```bash
# Check pool status
ssh HYPERVISOR 'zpool status'
# Check EBS volume service
ssh HYPERVISOR 'systemctl status ebs-volume-microvm-storage'
# Reimport pool if needed
ssh HYPERVISOR 'zpool import microvms'
```

## Important Notes

- **SSH Key**: Always use `~/.ssh/rw-ssh-key` for connections
- **GitOps**: Hypervisor auto-deploys from git via Comin (checks every 60s)
- **VMs are ephemeral**: Root filesystem resets on reboot - only `/persist` survives
- **ZFS snapshots**: Each VM can be independently snapshotted
- **ARM64**: This is aarch64-linux, not x86_64
