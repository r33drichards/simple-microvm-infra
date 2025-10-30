# Minimal MicroVM Infrastructure Design

**Date:** 2025-10-31
**Status:** Approved
**Purpose:** Production learning template for NixOS MicroVM infrastructure

## Overview

A simplified, minimal version of the DD-IX MicroVM infrastructure designed as a production learning template. Reduces complexity from 29 VMs to 4 VMs while maintaining core production patterns and best practices.

**Key Characteristics:**
- 4 completely isolated MicroVMs on a single NixOS hypervisor
- Each VM on separate IPv4 subnet with internet access via NAT
- Accessible via Tailscale subnet routing
- Shared /nix/store for disk efficiency
- Clean minimal codebase with zero cruft

## Requirements

### Functional Requirements
- **4 MicroVMs:** Each running on isolated network subnet
- **Complete isolation:** VMs cannot communicate with each other
- **Internet access:** VMs can access internet via NAT through host
- **Tailscale routing:** External access via Tailscale subnet routes (10.1.0.0/24, 10.2.0.0/24, 10.3.0.0/24, 10.4.0.0/24)
- **NixOS hypervisor:** Declarative infrastructure-as-code

### Technical Requirements
- **Keep from DD-IX:** ZFS filesystem, virtiofs shared /nix/store, Flakes, module system
- **Simplify from DD-IX:** Remove SOPS secrets, IPv6, 25+ VMs, monitoring stack, complex modules
- **Networking:** IPv4 only, separate bridge per VM, NAT to internet
- **Storage:** ZFS for VM storage and /nix

### Non-Functional Requirements
- **Learnable:** Clear code, obvious purpose for every line
- **Extensible:** Easy to add features (secrets, monitoring) later
- **Production patterns:** Real patterns teams can fork and expand

## Architecture

### Overall System Architecture

```
External Client (via Tailscale)
    ↓
Tailscale on Host (advertising 10.1.0.0/24, 10.2.0.0/24, 10.3.0.0/24, 10.4.0.0/24)
    ↓
Host Bridges (4 separate: br-vm1, br-vm2, br-vm3, br-vm4)
    ↓
TAP Interfaces (vm-vm1, vm-vm2, vm-vm3, vm-vm4)
    ↓
MicroVMs (10.1.0.2/24, 10.2.0.2/24, 10.3.0.2/24, 10.4.0.2/24)
    ↓
NAT via Host → Internet
```

### Network Architecture

**Subnets:**
- VM1: 10.1.0.0/24 (gateway: 10.1.0.1, VM: 10.1.0.2)
- VM2: 10.2.0.0/24 (gateway: 10.2.0.1, VM: 10.2.0.2)
- VM3: 10.3.0.0/24 (gateway: 10.3.0.1, VM: 10.3.0.2)
- VM4: 10.4.0.0/24 (gateway: 10.4.0.1, VM: 10.4.0.2)

**Network Flow:**
- VM → Bridge → Host NAT → Internet ✓
- VM → Bridge → Host → Other Bridge → Other VM ✗ (blocked by firewall)
- VM ← Tailscale subnet route ← External client ✓

**Isolation Strategy:**
- Each VM on separate Linux bridge (no shared bridge)
- IP forwarding enabled for NAT
- iptables rules block inter-bridge forwarding
- Result: VMs can reach internet but not each other

### Storage Architecture

**ZFS Layout:**
```
rpool/
├── microvms/          → /var/lib/microvms (VM persistent data)
└── nix/               → /nix (shared store)
```

**VM Filesystem (virtiofs shares):**
- `/nix/.ro-store` → Host `/nix/store` (read-only, shared across all VMs)
- `/etc` → Host `/var/lib/microvms/<vm>/etc` (per-VM writable)
- `/var` → Host `/var/lib/microvms/<vm>/var` (per-VM writable)

**Benefits:**
- Shared /nix/store: ~90% disk space savings
- Each VM has private /etc and /var
- Fast deployments (no package copying)

## Repository Structure

```
simple-microvm-infra/
├── flake.nix                 # Main entry point, dependencies
├── flake.lock               # Locked versions
│
├── hosts/                   # VM configurations
│   ├── default.nix         # Host registry (imports all VMs)
│   ├── hypervisor/         # Physical host config
│   │   ├── default.nix    # Hypervisor system config
│   │   └── network.nix    # Bridge setup, Tailscale, NAT
│   ├── vm1/
│   │   └── default.nix    # VM1 config (subnet 10.1.0.0/24)
│   ├── vm2/
│   │   └── default.nix    # VM2 config (subnet 10.2.0.0/24)
│   ├── vm3/
│   │   └── default.nix    # VM3 config (subnet 10.3.0.0/24)
│   └── vm4/
│       └── default.nix    # VM4 config (subnet 10.4.0.0/24)
│
├── modules/                 # Reusable modules
│   ├── microvm-base.nix   # Shared MicroVM config (virtiofs, networking)
│   └── networks.nix       # Network definitions (subnets, bridges)
│
├── lib/                     # Helper functions
│   └── default.nix         # microvmSystem builder
│
└── README.md               # Tutorial-style documentation
```

**Design Rationale:**
- Flat structure, minimal nesting
- Each VM self-contained in own directory
- Only 2 modules: base config and network definitions
- Single lib file for building MicroVMs
- Clear separation: hypervisor vs VMs

## Key Components

### 1. Flake Configuration (`flake.nix`)

```nix
{
  description = "Minimal MicroVM Infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    microvm.url = "github:astro/microvm.nix";
  };

  outputs = { self, nixpkgs, microvm }: {
    nixosConfigurations = {
      hypervisor = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/hypervisor ];
      };

      vm1 = self.lib.microvmSystem { modules = [ ./hosts/vm1 ]; };
      vm2 = self.lib.microvmSystem { modules = [ ./hosts/vm2 ]; };
      vm3 = self.lib.microvmSystem { modules = [ ./hosts/vm3 ]; };
      vm4 = self.lib.microvmSystem { modules = [ ./hosts/vm4 ]; };
    };

    lib.microvmSystem = import ./lib { inherit self nixpkgs microvm; };
  };
}
```

**Purpose:** Defines dependencies and all system configurations (hypervisor + 4 VMs).

### 2. Network Definitions (`modules/networks.nix`)

```nix
{
  networks = {
    vm1 = { subnet = "10.1.0"; bridge = "br-vm1"; };
    vm2 = { subnet = "10.2.0"; bridge = "br-vm2"; };
    vm3 = { subnet = "10.3.0"; bridge = "br-vm3"; };
    vm4 = { subnet = "10.4.0"; bridge = "br-vm4"; };
  };
}
```

**Purpose:** Data-driven network configuration. Single source of truth for subnet/bridge mapping.

### 3. MicroVM Base Module (`modules/microvm-base.nix`)

**Responsibilities:**
- Configure virtiofs shares (/nix/store, /etc, /var)
- Create TAP interface for VM networking
- Setup systemd-networkd with static IP
- Derive network settings from networks.nix
- Set Cloud-Hypervisor as hypervisor

**Key Sections:**

```nix
# Virtiofs shares
microvm.shares = [
  {
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  }
  {
    source = "/var/lib/microvms/${config.networking.hostName}/etc";
    mountPoint = "/etc";
    tag = "etc";
    proto = "virtiofs";
  }
  {
    source = "/var/lib/microvms/${config.networking.hostName}/var";
    mountPoint = "/var";
    tag = "var";
    proto = "virtiofs";
  }
];

# TAP interface
microvm.interfaces = [{
  type = "tap";
  id = "vm-${config.networking.hostName}";
  mac = "02:00:00:00:00:0${lib.substring 2 1 config.microvm.network}";
}];

# Network configuration
systemd.network.networks."10-eth0" = {
  matchConfig.Name = "eth0";
  networkConfig = {
    Address = "${vmNetwork.subnet}.2/24";
    Gateway = "${vmNetwork.subnet}.1";
    DNS = "1.1.1.1";
  };
};
```

### 4. Hypervisor Configuration

**`hosts/hypervisor/default.nix`:**
- Enable MicroVM host support
- Configure ZFS support
- Enable Tailscale service
- Import hardware-configuration.nix and network.nix

**`hosts/hypervisor/network.nix`:**

```nix
# Create 4 isolated bridges
networking.bridges = {
  br-vm1 = { interfaces = []; };
  br-vm2 = { interfaces = []; };
  br-vm3 = { interfaces = []; };
  br-vm4 = { interfaces = []; };
};

# Assign gateway IPs
networking.interfaces = {
  br-vm1.ipv4.addresses = [{ address = "10.1.0.1"; prefixLength = 24; }];
  br-vm2.ipv4.addresses = [{ address = "10.2.0.1"; prefixLength = 24; }];
  br-vm3.ipv4.addresses = [{ address = "10.3.0.1"; prefixLength = 24; }];
  br-vm4.ipv4.addresses = [{ address = "10.4.0.1"; prefixLength = 24; }];
};

# Enable IP forwarding for NAT
boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

# NAT for internet access
networking.nat = {
  enable = true;
  externalInterface = "eth0";  # Replace with actual interface
  internalInterfaces = [ "br-vm1" "br-vm2" "br-vm3" "br-vm4" ];
};

# Block inter-VM traffic
networking.firewall.extraCommands = ''
  # Drop traffic between VM bridges (12 rules for all combinations)
  iptables -I FORWARD -i br-vm1 -o br-vm2 -j DROP
  iptables -I FORWARD -i br-vm1 -o br-vm3 -j DROP
  # ... (all other combinations)
'';
```

**Note:** Must change `externalInterface = "eth0"` to match actual physical interface.

### 5. VM Configuration

**Example `hosts/vm1/default.nix`:**

```nix
{ config, pkgs, ... }:
{
  imports = [ ../../modules/microvm-base.nix ];

  networking.hostName = "vm1";

  # Network assignment (references networks.nix)
  microvm.network = "vm1";

  # Resources
  microvm.vcpu = 2;
  microvm.mem = 1024;  # 1GB

  # Minimal services
  services.openssh.enable = true;

  system.stateVersion = "24.05";
}
```

**Pattern:** Each VM only specifies hostname, network name, and resources. All plumbing handled by microvm-base.nix.

### 6. Library Helper (`lib/default.nix`)

```nix
{ self, nixpkgs, microvm }:
{ modules }:

nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    microvm.nixosModules.microvm
    ../modules/microvm-base.nix
  ] ++ modules;
}
```

**Purpose:** Wraps nixosSystem to automatically include MicroVM modules for all VMs.

## Deployment Process

### Initial Setup

**1. Install NixOS on hypervisor**
- Standard NixOS installation
- Ensure hardware supports virtualization (Intel VT-x/AMD-V)

**2. Setup ZFS pools:**

```bash
# Create ZFS pool (replace /dev/sda with actual disk)
zpool create -f rpool /dev/sda
zfs create -o mountpoint=/var/lib/microvms rpool/microvms
zfs create -o mountpoint=/nix rpool/nix

# Create VM storage directories
mkdir -p /var/lib/microvms/{vm1,vm2,vm3,vm4}/{etc,var}
```

**3. Clone and build:**

```bash
git clone <repo-url> /etc/nixos/simple-microvm-infra
cd /etc/nixos/simple-microvm-infra

# Build and activate hypervisor config
nixos-rebuild switch --flake .#hypervisor

# Build and start VMs
microvm -u vm1
microvm -u vm2
microvm -u vm3
microvm -u vm4
```

**4. Configure Tailscale:**

```bash
# Authenticate and advertise routes
tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24

# In Tailscale admin console: approve subnet routes
```

### Daily Operations

**Update VM configuration:**
```bash
cd /etc/nixos/simple-microvm-infra
# Edit hosts/vm1/default.nix
microvm -u vm1  # Rebuild and restart
```

**Monitor VMs:**
```bash
systemctl status microvm@vm1
journalctl -u microvm@vm1 -f
```

**Access VMs:**
```bash
# From hypervisor
ssh root@10.1.0.2

# From anywhere (via Tailscale)
ssh root@10.1.0.2  # After Tailscale connected
```

**Update dependencies:**
```bash
nix flake update
nixos-rebuild switch --flake .#hypervisor
microvm -u vm1 vm2 vm3 vm4
```

## Design Decisions

### Why This Approach?

**Clean minimal build-up (chosen) vs alternatives:**

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| Stripped DD-IX fork | Maintains production structure | Carries unused complexity | ✗ |
| Clean minimal build | Zero cruft, clear purpose | More work to add features | ✓ Chosen |
| Progressive commits | Git history as tutorial | Complex to maintain | ✗ |

**Rationale:** For a learning template, clarity trumps comprehensiveness. Every line should have obvious purpose.

### Key Trade-offs

**Removed from DD-IX:**
- **SOPS secrets:** Adds complexity, plain config sufficient for learning
- **IPv6:** Less familiar to most engineers, IPv4 simpler
- **25 VMs:** Reduces cognitive load, 4 VMs demonstrates patterns
- **Monitoring stack:** Can be added later as extension exercise
- **Complex modules:** DD-IX has 15+ modules, we have 2

**Kept from DD-IX:**
- **ZFS:** Production-grade storage, snapshots valuable for learning rollback
- **Virtiofs /nix/store:** Core efficiency pattern, demonstrates shared storage
- **Flakes:** Modern Nix, proper dependency management
- **Module system:** Reusable patterns, professional structure
- **Cloud-Hypervisor:** Fast, lightweight, production-ready hypervisor

## Future Extensions

**Easy to add later:**
1. **SOPS secrets:** Add sops-nix input, .sops.yaml, per-VM keys
2. **Monitoring:** Add Prometheus/Grafana/Loki VMs
3. **More VMs:** Copy VM config, add to networks.nix, rebuild
4. **IPv6:** Dual-stack configuration in network module
5. **Domain filtering:** DNS server (Pi-hole/blocky) + firewall enforcement

**Teaching progression:**
1. Start here (minimal 4-VM setup)
2. Add secrets management (SOPS tutorial)
3. Add monitoring (observability patterns)
4. Add more complex services (multi-tier app)
5. Fork for production use

## Success Criteria

**Learning template succeeds if:**
- ✓ New user can deploy from scratch in < 1 hour
- ✓ Every configuration line has clear, obvious purpose
- ✓ Easy to extend with new VMs or features
- ✓ Demonstrates production patterns (virtiofs, flakes, modules)
- ✓ Teams can fork and customize for real deployments

**Technical success:**
- ✓ VMs boot in < 5 seconds
- ✓ VMs accessible via Tailscale
- ✓ VMs have internet access
- ✓ VMs isolated from each other
- ✓ Disk usage < 10GB total (4 VMs + shared store)

## References

- **DD-IX nix-config:** https://github.com/dd-ix/nix-config
- **microvm.nix:** https://github.com/astro/microvm.nix
- **NixOS Manual:** https://nixos.org/manual/nixos/stable/
- **Original documentation:** DD-IX-MICROVM-SETUP.md

---

**Next Steps:** Create implementation plan with detailed tasks for building this infrastructure.
