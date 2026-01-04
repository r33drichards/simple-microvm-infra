# Claude Code Instructions

This document helps Claude Code understand and operate this MicroVM infrastructure.

## Quick Reference

### Current Infrastructure

| Machine | IP Address | SSH Command | Role |
|---------|------------|-------------|------|
| **Hypervisor** | 54.185.189.181 | `ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181` | Host machine (AWS a1.metal) |
| **Slot1** | 10.1.0.2 | Via hypervisor (see below) | VM slot (portable state) |
| **Slot2** | 10.2.0.2 | Via hypervisor (see below) | VM slot (portable state) |
| **Slot3** | 10.3.0.2 | Via hypervisor (see below) | VM slot (portable state) |
| **Slot4** | 10.4.0.2 | Via hypervisor (see below) | VM slot (extra resources) |
| **Slot5** | 10.5.0.2 | Via hypervisor (see below) | VM slot (portable state) |

### Portable State Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Slots (fixed network identity)    States (portable data)   │
│                                                              │
│  slot1 (10.1.0.2) ─────────────→ state "slot1" (default)   │
│  slot2 (10.2.0.2) ─────────────→ state "slot2" (default)   │
│  slot3 (10.3.0.2) ─────────────→ state "dev-env" (custom)  │
│                                                              │
│ States can be:                                               │
│  • Snapshotted: vm-state snapshot slot1 before-update       │
│  • Cloned: vm-state clone slot1 my-experiment               │
│  • Migrated: vm-state migrate my-experiment slot3           │
└─────────────────────────────────────────────────────────────┘
```

### SSH Connection Patterns

```bash
# Connect to hypervisor
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181

# Connect to a slot (two-step via hypervisor)
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181 'ssh -i /root/.ssh/id_ed25519 root@10.1.0.2 "COMMAND"'

# Or use ProxyJump for interactive session
ssh -o ProxyJump=root@54.185.189.181 -i ~/.ssh/rw-ssh-key root@10.1.0.2
```

### Common Tasks

| Task | Command |
|------|---------|
| Check slot status | `ssh HYPERVISOR 'systemctl status microvm@slot1'` |
| Restart a slot | `ssh HYPERVISOR 'systemctl restart microvm@slot1'` |
| View slot logs | `ssh HYPERVISOR 'journalctl -u microvm@slot1 -f'` |
| List all states | `ssh HYPERVISOR 'vm-state list'` |
| Snapshot a slot | `ssh HYPERVISOR 'vm-state snapshot slot1 my-backup'` |
| Migrate state to slot | `ssh HYPERVISOR 'vm-state migrate my-state slot2'` |
| Deploy config | `NIX_SSHOPTS="-i ~/.ssh/rw-ssh-key" nixos-rebuild switch --flake .#hypervisor --target-host root@54.185.189.181` |

### vm-state CLI

The `vm-state` command manages portable VM states:

```bash
# List all states and slot assignments
vm-state list

# Create a new empty state
vm-state create my-new-state

# Snapshot current slot's state
vm-state snapshot slot1 checkpoint-jan4

# Assign a state to a slot (requires restart)
vm-state assign slot2 my-new-state
systemctl restart microvm@slot2

# Clone a state for experimentation
vm-state clone slot1 experiment
vm-state migrate experiment slot3

# Restore a snapshot to a new state
vm-state restore checkpoint-jan4 recovered-state
```

## Task-Based Instructions

### When asked to "service the hypervisor" or "work on the host":
1. SSH to `root@54.185.189.181` using `~/.ssh/rw-ssh-key`
2. Check system status: `systemctl status`, `zpool status`, `df -h`
3. For config changes, edit local files and deploy via `nixos-rebuild`

### When asked to "service slot1" (or slot2, slot3, etc.):
1. SSH through hypervisor: `ssh HYPERVISOR 'ssh SLOT "command"'`
2. Slot IPs are `10.X.0.2` where X matches the slot number
3. Slots have persistent root - everything survives reboots
4. For config changes, edit `flake.nix` or module files, rebuild slot runner

### When asked to "deploy" or "update configuration":
1. Edit Nix files locally
2. Commit and push to git (Comin will auto-deploy to hypervisor)
3. Or manually: `nixos-rebuild switch --flake .#hypervisor --target-host root@54.185.189.181`
4. For slots: hypervisor rebuild installs new runners automatically

### When asked to "snapshot" a slot:
```bash
# Snapshot the current state of a slot
ssh HYPERVISOR 'vm-state snapshot slot1 my-snapshot-name'
```

### When asked to "transfer" or "migrate" state between slots:
```bash
# Snapshot current state
ssh HYPERVISOR 'vm-state snapshot slot1 my-state'

# Migrate to another slot (stops, assigns, starts)
ssh HYPERVISOR 'vm-state migrate my-state slot3'
```

### When asked to "reset a slot to clean state":
```bash
# Option 1: Create a fresh state and assign it
ssh HYPERVISOR 'vm-state create fresh-state && vm-state migrate fresh-state slot1'

# Option 2: Delete the data.img and restart (creates new empty volume)
ssh HYPERVISOR 'systemctl stop microvm@slot1 && rm /var/lib/microvms/states/slot1/data.img && systemctl start microvm@slot1'
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ AWS a1.metal - Hypervisor (54.185.189.181)                   │
│ Region: us-west-2 │ Instance: i-02f81409de8ff1c27           │
│                                                              │
│  ZFS Pool: microvms (100GB EBS volume)                      │
│  └── microvms/storage/states/                               │
│      ├── slot1/  (default state for slot1)                  │
│      ├── slot2/  (default state for slot2)                  │
│      ├── slot3/  (default state for slot3)                  │
│      ├── slot4/  (default state for slot4)                  │
│      ├── slot5/  (default state for slot5)                  │
│      └── custom-states/  (user-created states)              │
│                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│  │  Slot1   │ │  Slot2   │ │  Slot3   │ │  Slot4   │ │  Slot5   │
│  │10.1.0.2  │ │10.2.0.2  │ │10.3.0.2  │ │10.4.0.2  │ │10.5.0.2  │
│  │ unified  │ │ unified  │ │ unified  │ │ unified  │ │ unified  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
└─────────────────────────────────────────────────────────────┘
```

## Storage Architecture

### Hypervisor Storage
- **Root**: 50GB NVMe (NixOS system)
- **VM Storage**: 100GB EBS volume with ZFS pool `microvms`
  - States stored in `/var/lib/microvms/states/`
  - Each state is a ZFS dataset for independent snapshots

### Slot Storage (Portable States)
Each slot mounts a state's volumes:
- **Store (`/dev/vda`)**: erofs (read-only) - unified Nix store closure
- **Root (`/dev/vdb`)**: 64GB ext4 - **persistent root filesystem** (from state)
- **Nix Overlay (`/dev/vdc`)**: 8GB ext4 - writable layer (from state)

The Nix store uses an overlay:
- **Lower layer**: Read-only erofs with unified base closure
- **Upper layer**: Writable ext4 for imperative package installs

### What's Portable (in State)
- Root filesystem files and directories
- User home directories and data
- System logs and journal
- Installed packages (via nix-env)
- Any state that doesn't depend on network identity

### What's Slot-Specific (not in State)
- IP address (determined by slot: 10.X.0.2)
- Hostname (determined by slot: slotX)
- MAC address (derived from slot number)
- Network bridge assignment

## Key Files

| File | Purpose |
|------|---------|
| `flake.nix` | Slot definitions, inputs |
| `modules/microvm-base.nix` | Base slot config (network, storage, stateName) |
| `modules/slot-vm.nix` | Unified VM config (all slots use this) |
| `modules/networks.nix` | Network definitions (slot1=10.1.0.0/24, etc.) |
| `hosts/hypervisor/default.nix` | Hypervisor config |
| `scripts/vm-state.sh` | State management CLI |
| `modules/ebs-volume/default.nix` | ZFS/EBS volume management |

## Deep Dive Documentation

For more details, read these files:
- **Network topology**: `NETWORK-TOPOLOGY.md`
- **Deployment procedures**: `DEPLOYMENT.md`
- **Development workflow**: `DEVELOPMENT.md`
- **AWS provisioning**: `docs/AWS-PROVISION.md`
- **VM customization**: `docs/vm-customization.md`

## Troubleshooting

### Slot won't start
```bash
# Check service status
ssh HYPERVISOR 'systemctl status microvm@slot1'
# Check if runner exists
ssh HYPERVISOR 'ls -la /var/lib/microvms/slot1/current'
# Check state directory exists
ssh HYPERVISOR 'ls -la /var/lib/microvms/states/slot1/'
# Rebuild runner if missing
ssh HYPERVISOR 'cd /root/simple-microvm-infra && nix build .#nixosConfigurations.slot1.config.microvm.declaredRunner -o /var/lib/microvms/slot1/current'
```

### Can't SSH to slot
```bash
# Check slot is running
ssh HYPERVISOR 'systemctl is-active microvm@slot1'
# Check bridge is up
ssh HYPERVISOR 'ip link show br-slot1'
# Check slot has network
ssh HYPERVISOR 'journalctl -u microvm@slot1 | grep -i network'
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

### State management issues
```bash
# List all states and assignments
ssh HYPERVISOR 'vm-state list'
# Check ZFS datasets
ssh HYPERVISOR 'zfs list -r microvms'
# Check state directory
ssh HYPERVISOR 'ls -la /var/lib/microvms/states/'
```

## Important Notes

- **SSH Key**: Always use `~/.ssh/rw-ssh-key` for connections
- **GitOps**: Hypervisor auto-deploys from git via Comin (checks every 60s)
- **Slots are persistent**: Root filesystem persists across reboots (in state)
- **States are portable**: Use `vm-state` CLI to snapshot, clone, migrate
- **Unified config**: All slots use the same packages/capabilities
- **ARM64**: This is aarch64-linux, not x86_64
- **Imperative installs**: Slots support `nix-env` / `nix profile install` via writable overlay
