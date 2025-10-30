# Simple MicroVM Infrastructure

A minimal, production-ready template for running 4 isolated NixOS MicroVMs on a single hypervisor.

## Overview

This project provides a simplified version of enterprise MicroVM infrastructure, designed as a learning template that teams can fork and expand. It demonstrates core production patterns while maintaining clarity and simplicity.

**Key Features:**
- 4 completely isolated MicroVMs on NixOS hypervisor
- Each VM on separate IPv4 subnet with internet access
- Accessible via Tailscale subnet routing
- Shared /nix/store for 90% disk space savings
- ZFS storage with snapshot capability
- Clean, minimal codebase with zero cruft

## Architecture

```
External Client (via Tailscale)
    ↓
Tailscale on Host
    ↓
Host Bridges (4 isolated: br-vm1, br-vm2, br-vm3, br-vm4)
    ↓
TAP Interfaces
    ↓
MicroVMs (10.1.0.2, 10.2.0.2, 10.3.0.2, 10.4.0.2)
    ↓
NAT → Internet
```

**Network Isolation:**
- ✓ VMs can access internet via NAT
- ✓ VMs accessible via Tailscale subnet routes
- ✗ VMs cannot communicate with each other
- ✗ VMs cannot bypass isolation

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
# This will:
# - Configure network bridges and NAT
# - Setup ZFS support
# - Create EBS volume management
nixos-rebuild switch --flake .#hypervisor

# IMPORTANT: Reboot to load ZFS kernel module
# SSH connectivity will be maintained after reboot
sudo reboot

# Wait for reboot (60-90 seconds), then SSH back in

# Create VM storage directories
mkdir -p /var/lib/microvms/{vm1,vm2,vm3,vm4}/{etc,var}

# Start VMs
microvm -u vm1 vm2 vm3 vm4

# Configure Tailscale
tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24
# Approve routes in Tailscale admin console
```

**Access VMs:**

```bash
# From hypervisor
ssh root@10.1.0.2

# From anywhere (via Tailscale)
ssh root@10.1.0.2
```

## Project Structure

```
simple-microvm-infra/
├── docs/
│   ├── DEPLOYMENT.md   # Step-by-step deployment guide
│   ├── TESTING.md      # Testing and validation guide
│   └── plans/          # Design documentation
├── hosts/              # VM configurations
│   ├── hypervisor/     # Physical host config
│   ├── vm1/            # VM1: 10.1.0.0/24
│   ├── vm2/            # VM2: 10.2.0.0/24
│   ├── vm3/            # VM3: 10.3.0.0/24
│   └── vm4/            # VM4: 10.4.0.0/24
├── modules/            # Reusable NixOS modules
│   ├── ebs-volume/     # EBS volume management with ZFS
│   ├── microvm-base.nix   # Shared MicroVM config
│   └── networks.nix       # Network topology
├── lib/                # Helper functions
│   └── default.nix     # microvmSystem builder
└── flake.nix          # Main entry point
```

## Documentation

**📘 [Deployment Guide](docs/DEPLOYMENT.md)** - Step-by-step deployment instructions

**🧪 [Testing Guide](docs/TESTING.md)** - Validation and testing procedures

**📐 [Design Document](docs/plans/2025-10-31-minimal-microvm-infrastructure-design.md)** - Complete architecture specification

**📋 [Implementation Plan](docs/plans/IMPLEMENTATION-PLAN.md)** - Detailed task breakdown used to build this project

**💾 [EBS Volume Module](modules/ebs-volume/README.md)** - Automated EBS volume management with ZFS

**What's documented:**
- Complete architecture and network topology
- Storage design with ZFS and virtiofs
- Deployment process and daily operations
- Testing and validation procedures
- Design decisions and trade-offs
- Future extension paths

## Design Philosophy

**Kept from enterprise patterns:**
- ZFS for production-grade storage
- Automated EBS volume lifecycle management
- Virtiofs shared /nix/store for efficiency
- Flakes for reproducible builds
- Module system for reusable patterns

**Simplified for learning:**
- No secrets management (plain config)
- IPv4 only (not dual-stack)
- 4 VMs (not 29)
- Minimal modules (2 vs 15+)

**Result:** Every line of code has clear, obvious purpose.

## Use Cases

**Learning:**
- Understand NixOS MicroVM infrastructure
- Study network isolation patterns
- Practice declarative infrastructure

**Development:**
- Isolated development environments
- Multi-service testing
- Network simulation

**Production Template:**
- Fork and customize for real deployments
- Add secrets management (SOPS)
- Add monitoring (Prometheus/Grafana)
- Scale to more VMs

## Requirements

- **Platform:** AWS EC2 ARM instance or ARM bare metal (Graviton-based recommended)
- **Hardware:** aarch64-linux system with virtualization support
- **OS:** NixOS 24.05 or later
- **IAM Permissions:** EC2 volume operations (create, attach, describe, tag)
- **Network:** Tailscale account for remote access
- **Knowledge:** Basic NixOS, AWS, networking, and virtualization concepts

## Status

✅ **Ready to Deploy**

- ✅ Design complete
- ✅ Implementation complete (~1000 LOC)
- ✅ Documentation complete
- 📦 Ready for deployment on NixOS hypervisor

## Contributing

This is a learning template. Fork it, customize it, break it, fix it, and share your improvements!

## References

- **Based on:** [DD-IX nix-config](https://github.com/dd-ix/nix-config)
- **MicroVM framework:** [microvm.nix](https://github.com/astro/microvm.nix)
- **NixOS:** [NixOS Manual](https://nixos.org/manual/nixos/stable/)

## License

MIT License - See LICENSE file for details

---

**Questions?** Open an issue or check the design document for detailed explanations.
