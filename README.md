# Simple MicroVM Infrastructure

A minimal, production-ready template for running 5 isolated NixOS MicroVMs on a single hypervisor with **portable state management**.

## Overview

This project provides a simplified version of enterprise MicroVM infrastructure, designed as a learning template that teams can fork and expand. It demonstrates core production patterns while maintaining clarity and simplicity.

**Key Features:**
- 5 VM slots with fixed network identities (slot1-slot5)
- **Portable state** - snapshot, clone, and migrate VM state between slots
- Each slot on separate IPv4 subnet with internet access
- Accessible via Tailscale subnet routing
- Minimal erofs bootstrap + writable overlay for customization
- Declarative slot definitions with easy customization
- `vm-state` CLI for state management

## Architecture

### Portable State Model

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

### Network Topology

```
External Client (via Tailscale)
    ↓
Tailscale on Host
    ↓
Host Bridges (5 isolated: br-slot1, br-slot2, br-slot3, br-slot4, br-slot5)
    ↓
TAP Interfaces (dynamically managed)
    ↓
VM Slots (10.1.0.2, 10.2.0.2, 10.3.0.2, 10.4.0.2, 10.5.0.2)
    ↓
NAT → Internet
```

**Network Isolation:**
- ✓ Slots can access internet via NAT
- ✓ Slots accessible via Tailscale subnet routes
- ✗ Slots cannot communicate with each other
- ✗ Slots cannot bypass isolation

**Slot Resources (defaults):**
- 1 vCPU, 1GB RAM (minimal bootstrap)
- Customizable via `nixos-rebuild` inside VM

## Quick Start

**Prerequisites:**
- AWS account with CLI configured
- Tailscale account (for remote access)

**Full AWS Provisioning:**

See **[AWS Provisioning Guide](docs/AWS-PROVISION.md)** for complete step-by-step instructions to provision everything from scratch using AWS CLI.

**If you already have a NixOS instance:**

```bash
# Clone repository
git clone https://github.com/r33drichards/simple-microvm-infra.git
cd simple-microvm-infra

# Deploy hypervisor configuration
nixos-rebuild switch --flake .#hypervisor

# Start slots
systemctl start microvm@slot1 microvm@slot2 microvm@slot3 microvm@slot4 microvm@slot5

# Configure Tailscale
tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24,10.5.0.0/24
# Approve routes in Tailscale admin console
```

**Access Slots:**

```bash
# From hypervisor
ssh root@10.1.0.2

# From anywhere (via Tailscale)
ssh root@10.1.0.2
```

## State Management

The `vm-state` CLI manages portable VM states:

```bash
# List all states and slot assignments
vm-state list

# Snapshot current slot's state
vm-state snapshot slot1 my-backup

# Clone a state for experimentation
vm-state clone slot1 experiment

# Migrate state to another slot
vm-state migrate experiment slot3

# Create a fresh empty state
vm-state create fresh-env
vm-state assign slot2 fresh-env
systemctl restart microvm@slot2
```

## Storage Architecture

```
Slot boots with:
  /dev/vda (squashfs) - tiny read-only bootstrap (~300-500MB)
  /dev/vdb (data.img) - your state, swappable (64GB)

Bootstrap contains:
  - Kernel + initrd
  - systemd
  - openssh
  - networkd
  - nix (for nixos-rebuild)
  - nodejs

State contains:
  - Root filesystem (/)
  - Home directories (/home)
  - Nix overlay (/nix/.rw-store)
  - All customizations via nixos-rebuild
```

## EBS Volume Setup (Optional)

If you want to use EBS volumes with ZFS for persistent storage with snapshot support, you need to set up IAM permissions for the hypervisor instance.

**Setup IAM Role:**

```bash
# Run from your local machine (requires AWS CLI with admin permissions)
nix run .#setup-hypervisor-iam -- i-0123456789abcdef0

# Or run directly from the hypervisor:
nix run .#setup-hypervisor-iam
```

See the [EBS Volume Module documentation](modules/ebs-volume/README.md) for configuration options.

## Project Structure

```
simple-microvm-infra/
├── docs/
│   ├── DEPLOYMENT.md          # Step-by-step deployment guide
│   ├── TESTING.md             # Testing and validation guide
│   ├── vm-customization.md    # VM customization examples
│   └── plans/                 # Design documentation
├── hosts/
│   └── hypervisor/            # Physical host config
├── modules/                   # Reusable NixOS modules
│   ├── ebs-volume/            # EBS volume management with ZFS
│   ├── microvm-base.nix       # Shared MicroVM config (minimal bootstrap)
│   ├── slot-vm.nix            # Slot-specific config
│   ├── networks.nix           # Network topology definitions
│   └── vm-resources.nix       # Centralized CPU/RAM defaults
├── lib/                       # Helper functions
│   ├── default.nix            # microvmSystem builder
│   └── create-vm.nix          # Slot factory function
├── scripts/                   # Utility scripts
│   ├── vm-state.sh            # State management CLI
│   └── setup-hypervisor-iam.sh  # IAM role setup for EBS
└── flake.nix                  # Main entry point + slot definitions
```

**Key Configuration Files:**
- `flake.nix` - Define all slots in one place
- `modules/networks.nix` - Network topology for all slots
- `modules/microvm-base.nix` - Minimal bootstrap config
- `scripts/vm-state.sh` - State management CLI

## Documentation

**📘 [Deployment Guide](DEPLOYMENT.md)** - Step-by-step deployment instructions

**🧪 [Testing Guide](docs/TESTING.md)** - Validation and testing procedures

**⚙️ [VM Customization Guide](docs/vm-customization.md)** - How to customize individual VMs

**📐 [Design Document](docs/plans/2025-10-31-minimal-microvm-infrastructure-design.md)** - Complete architecture specification

**💾 [EBS Volume Module](modules/ebs-volume/README.md)** - Automated EBS volume management with ZFS

## Design Philosophy

**Portable State Architecture:**
- Slots are fixed network identities (slot1 = 10.1.0.2, etc.)
- States are portable block storage (data.img)
- Minimal bootstrap in squashfs, user customizes via nixos-rebuild
- States can be snapshotted, cloned, and migrated between slots

**Simplified for learning:**
- Minimal dependencies
- Single data.img file per state
- No complex VM-specific configs
- DRY configuration with automatic generation

**Result:** Boot a minimal VM, customize it, snapshot it, swap it.

## Adding Slots

Adding new slots is simple:

1. **Add slot to flake.nix:**
   ```nix
   slots = {
     slot1 = {};
     slot2 = {};
     slot6 = {};  # New slot
   };
   ```

2. **Add network definition to modules/networks.nix:**
   ```nix
   slot6 = { subnet = "10.6.0"; bridge = "br-slot6"; };
   ```

That's it! The infrastructure automatically generates bridges, IPs, NAT rules, and isolation.

## Use Cases

**Learning:**
- Understand NixOS MicroVM infrastructure
- Study network isolation patterns
- Practice declarative infrastructure

**Development:**
- Isolated development environments
- Snapshot before experiments, rollback if needed
- Multi-service testing

**Production Template:**
- Fork and customize for real deployments
- Add secrets management (SOPS)
- Add monitoring (Prometheus/Grafana)
- Scale to more slots

## Requirements

- **Platform:** AWS EC2 ARM instance or ARM bare metal (Graviton-based recommended)
- **Hardware:** aarch64-linux system with virtualization support
- **OS:** NixOS 24.05 or later
- **Storage:** 30GB+ root volume for hypervisor and MicroVMs
- **Network:** Tailscale account for remote access

## Status

✅ **Ready to Deploy**

- ✅ Portable state architecture
- ✅ vm-state CLI for state management
- ✅ Minimal bootstrap for fast builds
- ✅ Documentation updated

## Contributing

This is a learning template. Fork it, customize it, break it, fix it, and share your improvements!

## References

- **Based on:** [DD-IX nix-config](https://github.com/dd-ix/nix-config)
- **MicroVM framework:** [microvm.nix](https://github.com/astro/microvm.nix)
- **NixOS:** [NixOS Manual](https://nixos.org/manual/nixos/stable/)

## License

MIT License - See LICENSE file for details
