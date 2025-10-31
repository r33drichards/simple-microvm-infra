# Architecture Documentation

This document describes the architecture, design decisions, and technical details of the MicroVM infrastructure.

## System Overview

This infrastructure runs on an AWS EC2 a1.metal instance (ARM64 bare metal) and uses NixOS with the microvm.nix framework to manage 5 isolated virtual machines. The key characteristics:

- **Host Platform**: AWS a1.metal (aarch64-linux, ARM64 Graviton processors)
- **Operating System**: NixOS 25.05 with flakes
- **Hypervisor**: QEMU (chosen for ARM64 virtio device support)
- **Network Isolation**: Each VM has its own isolated bridge network
- **Storage**: Shared read-only `/nix/store`, per-VM writable `/var`
- **Remote Access**: Tailscale VPN with subnet routing
- **Deployment**: GitOps automation via Comin (pull-based, automatic)

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ AWS a1.metal (ARM64) - Hypervisor                               │
│ IP: 16.144.20.78 (public), 100.x.x.x (Tailscale)               │
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  br-vm1      │  │  br-vm2      │  │  br-vm3      │  ...     │
│  │  10.1.0.1/24 │  │  10.2.0.1/24 │  │  10.3.0.1/24 │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                  │                   │
│    ┌────▼────┐       ┌────▼────┐       ┌────▼────┐             │
│    │ vm-vm1  │       │ vm-vm2  │       │ vm-vm3  │             │
│    │  (TAP)  │       │  (TAP)  │       │  (TAP)  │             │
│    └────┬────┘       └────┬────┘       └────┬────┘             │
│         │                 │                  │                   │
│    ┌────▼────────┐   ┌────▼────────┐   ┌────▼────────┐         │
│    │   VM1       │   │   VM2       │   │   VM3       │         │
│    │ 10.1.0.2/24 │   │ 10.2.0.2/24 │   │ 10.3.0.2/24 │   ...   │
│    │             │   │             │   │             │         │
│    │ QEMU        │   │ QEMU        │   │ QEMU        │         │
│    │ NixOS       │   │ NixOS       │   │ NixOS       │         │
│    └─────────────┘   └─────────────┘   └─────────────┘         │
│                                                                   │
│  NAT: 10.0.0.0/8 → enP2p4s0 (internet)                          │
│  Tailscale: Advertises 10.1-4.0.0/24 subnets                    │
└─────────────────────────────────────────────────────────────────┘
```

## Network Architecture

### Network Topology

Each VM has its own isolated network segment:

- **VM1**: 10.1.0.0/24 (VM at 10.1.0.2, gateway at 10.1.0.1)
- **VM2**: 10.2.0.0/24 (VM at 10.2.0.2, gateway at 10.2.0.1)
- **VM3**: 10.3.0.0/24 (VM at 10.3.0.2, gateway at 10.3.0.1)
- **VM4**: 10.4.0.0/24 (VM at 10.4.0.2, gateway at 10.4.0.1)

Each network consists of:
1. A bridge interface on the hypervisor (br-vm1, br-vm2, etc.)
2. A TAP interface for the VM (vm-vm1, vm-vm2, etc.)
3. The bridge has IP .1 (gateway for the VM)
4. The VM has IP .2 (static IP configured via systemd-networkd)

### Network Isolation

VMs are isolated from each other at layer 2:
- Each VM is on its own bridge
- No direct connectivity between VMs by default
- Communication between VMs must go through the hypervisor

To enable inter-VM communication, you would need to add routing rules or connect bridges.

### Internet Access

VMs reach the internet via NAT:
- Traffic from 10.0.0.0/8 is masqueraded to the hypervisor's external interface (enP2p4s0)
- Configured in `hosts/hypervisor/network.nix`
- Uses nftables for NAT

### Remote Access via Tailscale

Tailscale provides VPN access from anywhere:
- Hypervisor runs Tailscale client
- Advertises subnet routes: 10.1.0.0/24, 10.2.0.0/24, 10.3.0.0/24, 10.4.0.0/24
- Routes must be approved in Tailscale admin console
- Once approved, you can SSH directly to VMs from any device on your Tailnet

## Storage Architecture

### Shared /nix/store

All VMs share the hypervisor's `/nix/store` via virtiofs:
- **Protocol**: virtiofs (FUSE over virtio)
- **Mount Point**: `/nix/.ro-store` in guest
- **Access**: Read-only
- **Benefits**: Massive space savings (no duplication of packages)

### Per-VM /var

Each VM has its own writable storage:
- **Host Path**: `/var/lib/microvms/<vmname>/var`
- **Mount Point**: `/var` in guest
- **Protocol**: virtiofs
- **Access**: Read-write
- **Contents**: Logs, state files, databases, etc.

### Why Not Disk Images?

This architecture uses shared filesystems instead of disk images:
- **Efficiency**: No duplication of /nix/store across VMs
- **Speed**: Fast boot times (no disk image to copy)
- **Simplicity**: Direct filesystem access from hypervisor
- **Nix-friendly**: Nix store can be safely shared read-only

## Hypervisor Selection: QEMU

### Why QEMU?

We tried three hypervisors:

1. **cloud-hypervisor** (initial attempt)
   - Failed: virtio-net devices not detected in ARM64 guest
   - VMs booted but no network interface appeared

2. **Firecracker** (second attempt)
   - Failed: No virtiofs support (required for /nix/store sharing)
   - Would require disk images or 9p (slower)

3. **QEMU** (final choice)
   - ✅ Excellent ARM64 support
   - ✅ Virtio devices work reliably
   - ✅ Virtiofs support
   - ✅ Well-tested with NixOS
   - Trade-off: Slightly higher overhead than cloud-hypervisor/Firecracker

### ARM64-Specific Configuration

ARM64 requires explicit kernel module configuration. In `modules/microvm-base.nix`:

```nix
boot.kernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi" ];
```

These modules must be loaded for virtio devices to work on ARM64. On x86_64, microvm.nix includes these automatically, but ARM64 requires explicit configuration.

### Network Interface Matching

We match network interfaces by type rather than name:

```nix
systemd.network.networks."10-lan" = {
  matchConfig.Type = "ether";
  # ...
};
```

This is more flexible than matching by name (e.g., "eth0") because device names can vary by hypervisor and platform.

## MicroVM Framework (microvm.nix)

### What is microvm.nix?

microvm.nix is a NixOS framework for running lightweight VMs:
- Integrates with NixOS module system
- Supports multiple hypervisors (QEMU, cloud-hypervisor, Firecracker)
- Provides unified configuration for all hypervisors
- Manages lifecycle through systemd units

### Key Concepts

**Declarative Runners**: microvm.nix generates a "runner" script that starts the VM with the hypervisor. This is built from the NixOS configuration and stored in `/var/lib/microvms/<name>/current`.

**Systemd Integration**: Each VM runs as a systemd service (`microvm@<name>.service`). The service executes the runner script.

**State Directory**: `/var/lib/microvms/<name>/` contains:
- `current/` - symlink to the current runner
- `booted/` - symlink to the runner currently running
- `flake` - path to the flake used to build this VM
- `var/` - the VM's writable /var filesystem

### Management Commands

The `microvm` command (from microvm.nix) provides VM management:

```bash
microvm -c vm1              # Create VM
microvm -u vm1              # Update (rebuild) VM
microvm -Ru vm1             # Update and restart VM
microvm -l                  # List VMs with status
microvm -r vm1              # Run VM in foreground
```

## File Structure

### Key Configuration Files

**`flake.nix`** - Top-level flake defining:
- nixpkgs input
- microvm.nix input
- Host system configuration
- VM configurations

**`modules/microvm-base.nix`** - Base configuration for all VMs:
- Hypervisor selection (QEMU)
- Kernel modules for ARM64
- Virtiofs shares (/nix/store, /var)
- TAP network interface
- Static IP configuration
- User accounts (root, robertwendt)
- SSH keys

**`modules/networks.nix`** - Network definitions:
- Subnet assignments for each VM
- Maps network names (vm1, vm2, etc.) to subnet prefixes

**`hosts/hypervisor/default.nix`** - Hypervisor configuration:
- MicroVM declarations
- Storage setup (tmpfiles for /var/lib/microvms)
- Bridge attachment (systemd services)
- Tailscale configuration

**`hosts/hypervisor/network.nix`** - Network configuration:
- Bridge interfaces (br-vm1 through br-vm5)
- NAT rules for internet access
- IP forwarding

**`hosts/hypervisor/comin.nix`** - GitOps deployment automation:
- Comin service configuration
- Git repository and branch tracking
- Post-deploy hooks for monitoring

**`hosts/vm1/default.nix`** through **`hosts/vm5/default.nix`** - Per-VM config:
- Hostname
- Network assignment (which subnet)
- VM-specific packages/services

## Deployment Automation

### GitOps with Comin

This infrastructure uses **Comin** for automated, pull-based GitOps deployments:

- **Pull-Based**: Hypervisor periodically polls the Git repository
- **Automatic**: Deploys changes without manual intervention
- **Safe**: Atomic NixOS updates with automatic rollback on failure
- **Monitored**: Post-deploy hooks log all deployments to journald

### How It Works

1. **Poll**: Comin service polls GitHub repository every 60 seconds
2. **Detect**: Identifies new commits on tracked branch (main)
3. **Build**: Builds new NixOS configuration from updated flake
4. **Deploy**: Performs atomic system switch (`nixos-rebuild switch`)
5. **Verify**: Runs post-deploy hooks to log status and check VMs
6. **Monitor**: Logs deployment info to journald for auditing

### Deployment Workflow

```
Developer                GitHub                 Hypervisor
    │                       │                       │
    ├─ git push ──────────►│                       │
    │                       │                       │
    │                       │◄────── poll ─────────┤ (every 60s)
    │                       │                       │
    │                       ├─ new commit ────────►│
    │                       │                       │
    │                       │                       ├─ build config
    │                       │                       │
    │                       │                       ├─ nixos-rebuild switch
    │                       │                       │
    │                       │                       ├─ restart services/VMs
    │                       │                       │
    │                       │                       ├─ post-deploy hook
    │                       │                       │
    │                       │                       └─ log to journald
    │                       │                       │
```

### Monitoring Deployments

```bash
# View Comin service status
systemctl status comin

# Monitor deployment logs in real-time
journalctl -u comin -f

# Check deployment history
journalctl -t comin --since "1 day ago"

# View last deployment
journalctl -t comin | tail -20
```

### Post-Deploy Hooks

The post-deploy hook automatically:
- Logs deployment timestamp and commit hash
- Checks status of all MicroVM services
- Counts active VMs
- Reports to journald for auditing

### Safety Features

- **Atomic Updates**: NixOS ensures all-or-nothing configuration changes
- **Automatic Rollback**: Failed builds don't affect running system
- **Generation History**: All previous configurations preserved for rollback
- **Branch Protection**: Only authorized commits to main branch are deployed

### Configuration

Comin is configured in `hosts/hypervisor/comin.nix`:
- **Repository**: https://github.com/r33drichards/simple-microvm-infra.git
- **Branch**: main
- **Poll Interval**: 60 seconds (default)
- **Post-Deploy Hook**: Custom script for logging and monitoring

For detailed deployment procedures and troubleshooting, see **DEPLOYMENT.md**.

## Design Decisions

### Why NixOS?

- **Declarative**: Entire infrastructure defined in code
- **Reproducible**: Same config produces same result
- **Atomic Updates**: Configuration changes are atomic
- **Rollback**: Easy to revert to previous generations
- **Flakes**: Pin dependencies for reproducibility

### Why Isolated Networks?

Each VM gets its own bridge network rather than sharing a single network:
- **Isolation**: VMs can't interfere with each other
- **Flexibility**: Different network policies per VM
- **Security**: Reduced attack surface between VMs
- **Clarity**: Easy to reason about traffic flow

### Why TAP Instead of User Networking?

TAP interfaces provide better performance and flexibility:
- **Performance**: Lower latency than user networking
- **Features**: Support for bridges, VLANs, etc.
- **Real IPs**: VMs have real IPs on host-visible networks
- **Monitoring**: Easy to capture traffic with tcpdump

### Why Static IPs?

VMs use static IP configuration rather than DHCP:
- **Simplicity**: No DHCP server needed
- **Predictability**: IPs never change
- **Speed**: Faster boot (no DHCP negotiation)
- **Clarity**: Easy to understand network topology

## Troubleshooting Guide

### Problem: VM Network Not Working

**Symptoms**: VM boots but no network connectivity.

**Diagnosis**:
1. Check if virtio kernel modules are loaded
2. Check if TAP interface exists on hypervisor
3. Check if TAP interface is attached to bridge
4. Check if VM has network interface detected

**Solution**: See `modules/microvm-base.nix:26-27` for kernel modules.

**Related Commits**:
- `e3b36d6` - Add explicit virtio kernel modules for ARM64 networking

### Problem: VMs Can't Reach Internet

**Symptoms**: VM can ping gateway (10.x.0.1) but not 1.1.1.1.

**Diagnosis**:
1. Check NAT rules on hypervisor
2. Check IP forwarding is enabled
3. Check external interface name

**Solution**: Verify NAT in `hosts/hypervisor/network.nix` and ensure external interface matches actual interface name (enP2p4s0 for a1.metal).

### Problem: Can't SSH to VMs

**Symptoms**: SSH connection refused or times out.

**Diagnosis**:
1. Check Tailscale is connected: `tailscale status`
2. Check subnet routes are approved in Tailscale admin
3. Check SSH key is loaded: `ssh-add -l`
4. Try pinging VM: `ping 10.1.0.2`

**Solution**:
1. Ensure Tailscale subnet routes are approved
2. Load SSH key: `ssh-add ~/.ssh/id_ed25519`

### Problem: VM Won't Start

**Symptoms**: `systemctl start microvm@vm1` fails.

**Diagnosis**:
1. Check journal: `journalctl -u microvm@vm1 -n 100`
2. Look for QEMU errors
3. Try running in foreground: `microvm -r vm1`

**Common Causes**:
- Missing dependencies in configuration
- Syntax errors in Nix files
- Insufficient memory
- Hypervisor not installed

## Performance Characteristics

### Resource Usage

Per VM (approximate):
- **Memory**: 1GB allocated (configurable)
- **CPU**: Shared with hypervisor (no pinning)
- **Disk**: ~10-50MB in /var (most data is shared /nix/store)
- **Overhead**: ~100-200MB RAM per VM for QEMU

Hypervisor (a1.metal):
- **Total RAM**: 32GB (4 VMs = ~5GB used, 27GB free)
- **Total CPUs**: 16 cores
- **Storage**: Root filesystem on EBS

### Network Performance

- **VM to Gateway**: ~0.4ms latency
- **VM to Internet**: Depends on AWS network
- **Throughput**: Limited by virtio-net performance (typically 5-10 Gbps)

### Boot Time

- **Cold Boot**: ~3-5 seconds (VM start to SSH available)
- **Rebuild**: ~30 seconds to 2 minutes (depending on changes)
- **Full Deployment**: ~2-5 minutes (all 4 VMs)

## Future Enhancements

Potential improvements to consider:

1. **Inter-VM Networking**: Add routing to allow VMs to communicate directly
2. **Monitoring**: Add Prometheus/Grafana for metrics
3. **Backup**: Automated snapshots of VM /var directories
4. **CI/CD**: Automated testing of configuration changes
5. **Secrets Management**: Use sops-nix or agenix for secrets
6. **Resource Limits**: Configure CPU/memory limits per VM
7. **Additional VMs**: Easy to add more VMs following same pattern

## References

### External Documentation

- [microvm.nix GitHub](https://github.com/astro/microvm.nix)
- [Comin GitHub](https://github.com/nlewo/comin)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [Tailscale Subnet Routes](https://tailscale.com/kb/1019/subnets/)

### Key Files in This Repo

- `modules/microvm-base.nix` - Core VM configuration
- `hosts/hypervisor/network.nix` - Network architecture
- `hosts/hypervisor/comin.nix` - GitOps deployment automation
- `flake.nix` - System definitions
- `DEPLOYMENT.md` - Deployment procedures and monitoring
- `DEVELOPMENT.md` - Development workflow
- `CLAUDE.md` - Architecture documentation (this file)

### Related Technologies

- **virtiofs**: Modern filesystem sharing (replaces 9p)
- **systemd-networkd**: Network configuration
- **nftables**: Packet filtering and NAT
- **TAP/TUN**: Virtual network interfaces
- **NixOS Flakes**: Hermetic, reproducible configurations
