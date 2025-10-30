# Implementation Plan: Minimal MicroVM Infrastructure

**Based on:** [2025-10-31-minimal-microvm-infrastructure-design.md](./2025-10-31-minimal-microvm-infrastructure-design.md)

**Target:** Implement complete 4-VM MicroVM infrastructure from design specification

---

## Overview

This plan breaks down the implementation into 10 sequential tasks. Each task includes exact file paths, complete code to write, and verification steps.

**Estimated total time:** 2-3 hours for experienced NixOS engineer, 4-6 hours for learner

---

## Task 1: Create Network Definitions Module

**File:** `modules/networks.nix`

**Purpose:** Define the 4 VM networks in a single data structure

**Code to write:**

```nix
# modules/networks.nix
# Network topology definitions for 4 isolated MicroVMs
# Each VM gets its own bridge and subnet
{
  networks = {
    vm1 = {
      subnet = "10.1.0";
      bridge = "br-vm1";
    };
    vm2 = {
      subnet = "10.2.0";
      bridge = "br-vm2";
    };
    vm3 = {
      subnet = "10.3.0";
      bridge = "br-vm3";
    };
    vm4 = {
      subnet = "10.4.0";
      bridge = "br-vm4";
    };
  };
}
```

**Why this structure:**
- Data-driven: single source of truth for network mapping
- Easy to extend: add vm5 by adding one entry
- Type-safe: networks referenced by name in VM configs

**Verification:**
```bash
# Test that the module can be evaluated
nix eval --file modules/networks.nix networks.vm1.subnet
# Expected output: "10.1.0"
```

---

## Task 2: Create MicroVM Base Module

**File:** `modules/microvm-base.nix`

**Purpose:** Shared configuration for all MicroVMs (virtiofs, networking, TAP interface)

**Code to write:**

```nix
# modules/microvm-base.nix
# Base configuration shared by all MicroVMs
# Handles: virtiofs shares, TAP interface, network config
{ config, lib, pkgs, ... }:

let
  # Load network definitions
  networks = import ./networks.nix;

  # Look up this VM's network config
  vmNetwork = networks.networks.${config.microvm.network};
in
{
  # Option: which network this VM belongs to
  options.microvm.network = lib.mkOption {
    type = lib.types.str;
    description = "Network name from networks.nix (vm1, vm2, vm3, or vm4)";
    example = "vm1";
  };

  config = {
    # Use Cloud-Hypervisor (fast, lightweight)
    microvm.hypervisor = "cloud-hypervisor";

    # Virtiofs filesystem shares from host
    microvm.shares = [
      {
        # Shared /nix/store (read-only, massive space savings)
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
      {
        # Per-VM /etc (writable)
        source = "/var/lib/microvms/${config.networking.hostName}/etc";
        mountPoint = "/etc";
        tag = "etc";
        proto = "virtiofs";
      }
      {
        # Per-VM /var (writable)
        source = "/var/lib/microvms/${config.networking.hostName}/var";
        mountPoint = "/var";
        tag = "var";
        proto = "virtiofs";
      }
    ];

    # TAP network interface
    microvm.interfaces = [{
      type = "tap";
      id = "vm-${config.networking.hostName}";
      # Generate MAC from network name (vm1->01, vm2->02, etc)
      mac = "02:00:00:00:00:0${lib.substring 2 1 config.microvm.network}";
    }];

    # Enable systemd-networkd for network config
    systemd.network.enable = true;

    # Configure eth0 with static IP
    systemd.network.networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        # VM gets .2 in its subnet (gateway is .1 on host)
        Address = "${vmNetwork.subnet}.2/24";
        Gateway = "${vmNetwork.subnet}.1";
        DNS = "1.1.1.1";  # Cloudflare DNS
      };
    };

    # Basic system settings
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";

    # Allow root login with password (for learning/setup)
    # CHANGE THIS in production!
    users.users.root.initialPassword = "nixos";

    # Disable sudo password for convenience
    security.sudo.wheelNeedsPassword = false;
  };
}
```

**Key design decisions:**
- `microvm.network` option: VMs declare network by name, module looks up config
- MAC address generation: derives from network name for predictability
- Static IP via systemd-networkd: modern, declarative networking
- Initial root password: makes learning easier (document security concern)

**Verification:**
```bash
# This will fail until flake.nix exists, but checks syntax
nix-instantiate --parse modules/microvm-base.nix
# Should complete without syntax errors
```

---

## Task 3: Create Library Helper Function

**File:** `lib/default.nix`

**Purpose:** Wrap nixosSystem to automatically include MicroVM modules

**Code to write:**

```nix
# lib/default.nix
# Helper function for building MicroVM configurations
# Automatically includes microvm.nix and microvm-base.nix modules
{ self, nixpkgs, microvm }:

{ modules }:

nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";

  modules = [
    # Include microvm.nix module (provides microvm.* options)
    microvm.nixosModules.microvm

    # Include our base MicroVM config
    ../modules/microvm-base.nix
  ] ++ modules;  # Append VM-specific modules
}
```

**Why this abstraction:**
- DRY: don't repeat microvm imports in every VM config
- Consistency: all VMs get same base setup
- Simplicity: VM configs only specify what's unique to them

**Verification:**
```bash
# Check syntax
nix-instantiate --parse lib/default.nix
```

---

## Task 4: Create Main Flake Configuration

**File:** `flake.nix`

**Purpose:** Entry point, defines dependencies and all system configurations

**Code to write:**

```nix
# flake.nix
# Main entry point for simple-microvm-infra
# Defines: dependencies (nixpkgs, microvm.nix) and all 5 system configs
{
  description = "Minimal MicroVM Infrastructure - Production Learning Template";

  inputs = {
    # NixOS 24.05 (stable)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

    # MicroVM framework
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }: {
    # All system configurations
    nixosConfigurations = {
      # Hypervisor (physical host)
      hypervisor = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          microvm.nixosModules.host  # Enable MicroVM host support
          ./hosts/hypervisor
        ];
      };

      # MicroVM 1 (10.1.0.2)
      vm1 = self.lib.microvmSystem {
        modules = [ ./hosts/vm1 ];
      };

      # MicroVM 2 (10.2.0.2)
      vm2 = self.lib.microvmSystem {
        modules = [ ./hosts/vm2 ];
      };

      # MicroVM 3 (10.3.0.2)
      vm3 = self.lib.microvmSystem {
        modules = [ ./hosts/vm3 ];
      };

      # MicroVM 4 (10.4.0.2)
      vm4 = self.lib.microvmSystem {
        modules = [ ./hosts/vm4 ];
      };
    };

    # Export our library function for building MicroVMs
    lib.microvmSystem = import ./lib { inherit self nixpkgs microvm; };
  };
}
```

**Key points:**
- Uses stable nixpkgs (24.05)
- `microvm.nixosModules.host`: enables hypervisor to manage MicroVMs
- `self.lib.microvmSystem`: our helper function from lib/default.nix
- All 5 configs defined here (1 hypervisor + 4 VMs)

**Verification:**
```bash
# Lock dependencies
nix flake lock

# Show all available configurations
nix flake show

# Expected output:
# └───nixosConfigurations
#     ├───hypervisor: NixOS configuration
#     ├───vm1: NixOS configuration
#     ├───vm2: NixOS configuration
#     ├───vm3: NixOS configuration
#     └───vm4: NixOS configuration
```

---

## Task 5: Create Hypervisor Base Configuration

**File:** `hosts/hypervisor/default.nix`

**Purpose:** Base hypervisor system configuration (ZFS, Tailscale, MicroVM host)

**Code to write:**

```nix
# hosts/hypervisor/default.nix
# Physical hypervisor host configuration
# Manages: ZFS storage, Tailscale, MicroVM lifecycle
{ config, pkgs, ... }:
{
  imports = [
    # Generated by: nixos-generate-config
    # Contains: boot.loader, fileSystems, hardware config
    ./hardware-configuration.nix

    # Network bridges, NAT, firewall
    ./network.nix
  ];

  networking.hostName = "hypervisor";

  # ZFS support
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

  # Required for ZFS (random 8-char hex string)
  # Generate with: head -c 4 /dev/urandom | od -A none -t x4 | tr -d ' '
  networking.hostId = "12345678";  # TODO: Generate unique ID

  # Tailscale for remote access and subnet routing
  services.tailscale.enable = true;

  # Basic system tools
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    tmux
    curl
    wget
  ];

  # SSH with key-only auth
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Allow wheel group to sudo without password (convenience)
  security.sudo.wheelNeedsPassword = false;

  # Create an admin user (customize as needed)
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    # Add your SSH public key here:
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA..." ];
  };

  # NixOS version (don't change after initial install)
  system.stateVersion = "24.05";
}
```

**Important notes:**
- `hardware-configuration.nix`: generated by NixOS installer, will differ per machine
- `networking.hostId`: must be unique, generate randomly
- SSH key setup required for production use

**Verification:**
```bash
# Generate hardware-configuration.nix first (on target machine):
# nixos-generate-config --show-hardware-config > hosts/hypervisor/hardware-configuration.nix

# For now, create placeholder:
mkdir -p hosts/hypervisor
echo '{ ... }: {}' > hosts/hypervisor/hardware-configuration.nix

# Test evaluation
nix eval .#nixosConfigurations.hypervisor.config.networking.hostName
# Expected: "hypervisor"
```

---

## Task 6: Create Hypervisor Network Configuration

**File:** `hosts/hypervisor/network.nix`

**Purpose:** Network bridges, NAT, firewall, VM isolation

**Code to write:**

```nix
# hosts/hypervisor/network.nix
# Networking for hypervisor: bridges, NAT, isolation firewall
{ config, pkgs, lib, ... }:
{
  # Create 4 isolated bridges (no physical interfaces attached)
  networking.bridges = {
    "br-vm1" = { interfaces = []; };
    "br-vm2" = { interfaces = []; };
    "br-vm3" = { interfaces = []; };
    "br-vm4" = { interfaces = []; };
  };

  # Assign gateway IPs to bridges (host side)
  networking.interfaces = {
    br-vm1.ipv4.addresses = [{
      address = "10.1.0.1";
      prefixLength = 24;
    }];
    br-vm2.ipv4.addresses = [{
      address = "10.2.0.1";
      prefixLength = 24;
    }];
    br-vm3.ipv4.addresses = [{
      address = "10.3.0.1";
      prefixLength = 24;
    }];
    br-vm4.ipv4.addresses = [{
      address = "10.4.0.1";
      prefixLength = 24;
    }];
  };

  # Enable IP forwarding (required for NAT)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  # NAT: allow VMs to access internet through host
  networking.nat = {
    enable = true;

    # IMPORTANT: Change this to your actual physical interface!
    # Find with: ip link show
    # Common names: eth0, ens3, enp0s3, wlan0
    externalInterface = "eth0";

    # VM bridges that should be NAT'd
    internalInterfaces = [ "br-vm1" "br-vm2" "br-vm3" "br-vm4" ];
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;

    # Allow Tailscale traffic
    trustedInterfaces = [ "tailscale0" ];

    # Allow SSH from anywhere
    allowedTCPPorts = [ 22 ];

    # Block inter-VM traffic (maintain isolation)
    # Each VM can reach internet but not other VMs
    extraCommands = ''
      # VM1 cannot reach VM2, VM3, VM4
      iptables -I FORWARD -i br-vm1 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm1 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm1 -o br-vm4 -j DROP

      # VM2 cannot reach VM1, VM3, VM4
      iptables -I FORWARD -i br-vm2 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm2 -o br-vm3 -j DROP
      iptables -I FORWARD -i br-vm2 -o br-vm4 -j DROP

      # VM3 cannot reach VM1, VM2, VM4
      iptables -I FORWARD -i br-vm3 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm3 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm3 -o br-vm4 -j DROP

      # VM4 cannot reach VM1, VM2, VM3
      iptables -I FORWARD -i br-vm4 -o br-vm1 -j DROP
      iptables -I FORWARD -i br-vm4 -o br-vm2 -j DROP
      iptables -I FORWARD -i br-vm4 -o br-vm3 -j DROP
    '';
  };
}
```

**Critical configuration:**
- `externalInterface`: MUST match your physical network interface
- Firewall rules: 12 rules for complete VM isolation (4 VMs, 3 blocked targets each)

**How isolation works:**
- VMs send packets to their bridge
- Bridge forwards to host's routing table
- NAT rules allow bridge → external interface (internet access)
- Firewall rules DROP bridge → other bridge (no inter-VM traffic)

**Verification:**
```bash
# Build hypervisor config (will fail if network interface doesn't exist)
nix build .#nixosConfigurations.hypervisor.config.system.build.toplevel

# On actual hypervisor after deployment:
# ip link show  # Should show br-vm1, br-vm2, br-vm3, br-vm4
# ip addr show br-vm1  # Should show 10.1.0.1/24
# iptables -L FORWARD  # Should show DROP rules between bridges
```

---

## Task 7: Create VM1 Configuration

**File:** `hosts/vm1/default.nix`

**Purpose:** Configuration for first MicroVM

**Code to write:**

```nix
# hosts/vm1/default.nix
# MicroVM 1 configuration
# Network: 10.1.0.2/24 (bridge: br-vm1)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  # Hostname (must match directory name)
  networking.hostName = "vm1";

  # Network assignment (references modules/networks.nix)
  microvm.network = "vm1";

  # VM resources
  microvm.vcpu = 2;      # 2 virtual CPUs
  microvm.mem = 1024;    # 1GB RAM

  # Enable SSH for remote access
  services.openssh.enable = true;

  # Example: install some useful packages
  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  # NixOS version
  system.stateVersion = "24.05";
}
```

**Pattern explanation:**
- Imports microvm-base.nix for all common config
- Only specifies: hostname, network name, resources
- Base module handles: virtiofs, TAP interface, IP assignment

**Verification:**
```bash
# Build VM1 configuration
nix build .#nixosConfigurations.vm1.config.system.build.toplevel

# Check that it built successfully
ls -la result/

# Verify network is correctly assigned
nix eval .#nixosConfigurations.vm1.config.microvm.network
# Expected: "vm1"
```

---

## Task 8: Create VM2, VM3, VM4 Configurations

**Files:**
- `hosts/vm2/default.nix`
- `hosts/vm3/default.nix`
- `hosts/vm4/default.nix`

**Purpose:** Configurations for remaining 3 MicroVMs

**Code to write for VM2:**

```nix
# hosts/vm2/default.nix
# MicroVM 2 configuration
# Network: 10.2.0.2/24 (bridge: br-vm2)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm2";
  microvm.network = "vm2";

  microvm.vcpu = 2;
  microvm.mem = 1024;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
```

**Code to write for VM3:**

```nix
# hosts/vm3/default.nix
# MicroVM 3 configuration
# Network: 10.3.0.2/24 (bridge: br-vm3)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm3";
  microvm.network = "vm3";

  microvm.vcpu = 2;
  microvm.mem = 1024;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
```

**Code to write for VM4:**

```nix
# hosts/vm4/default.nix
# MicroVM 4 configuration
# Network: 10.4.0.2/24 (bridge: br-vm4)
{ config, pkgs, ... }:
{
  imports = [
    ../../modules/microvm-base.nix
  ];

  networking.hostName = "vm4";
  microvm.network = "vm4";

  microvm.vcpu = 2;
  microvm.mem = 1024;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
  ];

  system.stateVersion = "24.05";
}
```

**Pattern:**
- All 4 VMs use identical structure
- Only differences: hostname and network name
- Easy to customize later (different resources, services, etc)

**Verification:**
```bash
# Build all VMs
nix build .#nixosConfigurations.vm2.config.system.build.toplevel
nix build .#nixosConfigurations.vm3.config.system.build.toplevel
nix build .#nixosConfigurations.vm4.config.system.build.toplevel

# Or build everything:
nix flake check  # Validates all configurations
```

---

## Task 9: Create Deployment Documentation

**File:** `docs/DEPLOYMENT.md`

**Purpose:** Step-by-step deployment guide for users

**Code to write:**

```markdown
# Deployment Guide

Complete deployment guide for simple-microvm-infra.

## Prerequisites

- NixOS 24.05 or later installed on hypervisor
- Hardware virtualization support (Intel VT-x or AMD-V)
- Disk for ZFS (can be existing system disk)
- Tailscale account (free tier sufficient)

## Step 1: Prepare Hypervisor

### 1.1 Install NixOS

Follow standard NixOS installation: https://nixos.org/manual/nixos/stable/#sec-installation

**Important:** Enable flakes during installation by adding to configuration.nix:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

### 1.2 Find Physical Network Interface

```bash
ip link show
# Look for your physical interface (eth0, ens3, enp0s3, etc)
```

Note the interface name for Step 2.2.

## Step 2: Setup ZFS Storage

```bash
# List available disks
lsblk

# Create ZFS pool (WILL ERASE DISK!)
# Replace /dev/sda with your target disk
sudo zpool create -f rpool /dev/sda

# Create datasets
sudo zfs create -o mountpoint=/var/lib/microvms rpool/microvms
sudo zfs create -o mountpoint=/nix rpool/nix

# Create VM storage directories
sudo mkdir -p /var/lib/microvms/{vm1,vm2,vm3,vm4}/{etc,var}
```

**Alternative:** If using existing ZFS pool, just create datasets:

```bash
sudo zfs create -o mountpoint=/var/lib/microvms rpool/microvms
sudo zfs create -o mountpoint=/nix rpool/nix
sudo mkdir -p /var/lib/microvms/{vm1,vm2,vm3,vm4}/{etc,var}
```

## Step 3: Clone and Configure Repository

```bash
# Clone repository
cd /etc/nixos
sudo git clone https://github.com/r33drichards/simple-microvm-infra.git
cd simple-microvm-infra
```

### 3.1 Generate Hardware Configuration

```bash
# Generate hardware config for this machine
sudo nixos-generate-config --show-hardware-config > hosts/hypervisor/hardware-configuration.nix
```

### 3.2 Update Network Interface

Edit `hosts/hypervisor/network.nix`:

```nix
# Change this line to match your interface from Step 1.2:
externalInterface = "eth0";  # Replace with YOUR interface
```

### 3.3 Generate Unique ZFS Host ID

```bash
# Generate random host ID
head -c 4 /dev/urandom | od -A none -t x4 | tr -d ' '
# Example output: a1b2c3d4
```

Edit `hosts/hypervisor/default.nix`:

```nix
networking.hostId = "a1b2c3d4";  # Replace with your generated ID
```

## Step 4: Deploy Hypervisor

```bash
# Build and activate hypervisor configuration
sudo nixos-rebuild switch --flake .#hypervisor

# Reboot to ensure all changes take effect
sudo reboot
```

After reboot, verify bridges were created:

```bash
ip link show br-vm1  # Should exist
ip addr show br-vm1  # Should show 10.1.0.1/24
```

## Step 5: Deploy MicroVMs

```bash
cd /etc/nixos/simple-microvm-infra

# Start VM1
sudo microvm -u vm1

# Wait a few seconds, then check status
sudo systemctl status microvm@vm1

# If successful, start remaining VMs
sudo microvm -u vm2
sudo microvm -u vm3
sudo microvm -u vm4
```

**Verify VMs are running:**

```bash
sudo systemctl status microvm@vm1
sudo systemctl status microvm@vm2
sudo systemctl status microvm@vm3
sudo systemctl status microvm@vm4
```

**Check VM processes:**

```bash
ps aux | grep microvm
# Should see 4 cloud-hypervisor processes
```

## Step 6: Setup Tailscale

### 6.1 Authenticate Tailscale

```bash
sudo tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24
```

Follow the authentication URL that appears.

### 6.2 Approve Subnet Routes

1. Go to https://login.tailscale.com/admin/machines
2. Find your hypervisor machine
3. Click "Edit route settings"
4. Approve all 4 subnet routes (10.1.0.0/24, 10.2.0.0/24, 10.3.0.0/24, 10.4.0.0/24)

## Step 7: Test Access

### From Hypervisor (Local)

```bash
# SSH to VM1
ssh root@10.1.0.2
# Password: nixos

# Test internet from VM
curl -I https://google.com
# Should return 200 OK

# Exit VM
exit
```

### From Remote Machine (via Tailscale)

On your laptop/workstation:

```bash
# Ensure Tailscale is connected
tailscale status

# SSH to VM1 through Tailscale
ssh root@10.1.0.2
```

## Step 8: Verify Isolation

From VM1, try to reach VM2 (should fail):

```bash
ssh root@10.1.0.2
ping 10.2.0.2  # Should timeout/fail
curl http://10.2.0.2  # Should fail
```

This confirms VMs are isolated from each other. ✓

## Troubleshooting

### VMs Won't Start

```bash
# Check logs
sudo journalctl -u microvm@vm1 -n 100

# Common issues:
# - Storage directories missing: check /var/lib/microvms/vm1/{etc,var}
# - Bridge not created: check `ip link show br-vm1`
# - Build failed: try `nix build .#nixosConfigurations.vm1...`
```

### No Internet from VMs

```bash
# Check NAT is enabled
sudo iptables -t nat -L -n -v | grep MASQUERADE

# Check IP forwarding
sysctl net.ipv4.ip_forward  # Should be 1

# Verify external interface
ip link show eth0  # Should exist and be UP
```

### Can't SSH to VMs via Tailscale

```bash
# Check subnet routes are advertised
tailscale status

# Verify routes are approved in admin console
# https://login.tailscale.com/admin/machines

# Test from hypervisor first
ssh root@10.1.0.2  # Should work locally
```

## Next Steps

- Change VM root passwords (currently "nixos")
- Customize VM resources (CPU/RAM) in hosts/vm*/default.nix
- Add SSH keys to hypervisor and VMs
- Install services on VMs
- Setup monitoring (Prometheus/Grafana)

## Updating Configuration

After making changes:

```bash
cd /etc/nixos/simple-microvm-infra

# Update hypervisor
sudo nixos-rebuild switch --flake .#hypervisor

# Update VMs (will restart them)
sudo microvm -u vm1
sudo microvm -u vm2
sudo microvm -u vm3
sudo microvm -u vm4
```

## Stopping VMs

```bash
sudo systemctl stop microvm@vm1
sudo systemctl stop microvm@vm2
sudo systemctl stop microvm@vm3
sudo systemctl stop microvm@vm4
```

## Uninstall

```bash
# Stop and disable VMs
sudo systemctl stop microvm@{vm1,vm2,vm3,vm4}
sudo systemctl disable microvm@{vm1,vm2,vm3,vm4}

# Remove VM data (DESTRUCTIVE!)
sudo rm -rf /var/lib/microvms/{vm1,vm2,vm3,vm4}

# Remove ZFS datasets (DESTRUCTIVE!)
sudo zfs destroy rpool/microvms
```
```

**Verification:**
```bash
# Ensure markdown is valid
cat docs/DEPLOYMENT.md | head -20
```

---

## Task 10: Create Testing and Validation Guide

**File:** `docs/TESTING.md`

**Purpose:** Test checklist to verify deployment success

**Code to write:**

```markdown
# Testing Guide

Validation checklist for simple-microvm-infra deployment.

## Pre-Deployment Tests

### Syntax Validation

```bash
# Validate all Nix expressions
nix flake check

# Should output: "✓ All checks passed"
```

### Build Tests

```bash
# Build hypervisor config
nix build .#nixosConfigurations.hypervisor.config.system.build.toplevel

# Build all VM configs
nix build .#nixosConfigurations.vm1.config.system.build.toplevel
nix build .#nixosConfigurations.vm2.config.system.build.toplevel
nix build .#nixosConfigurations.vm3.config.system.build.toplevel
nix build .#nixosConfigurations.vm4.config.system.build.toplevel
```

## Post-Deployment Tests

Run these tests after completing deployment.

### Test 1: Hypervisor Services

```bash
# ZFS pool exists
sudo zpool status rpool

# Datasets mounted
df -h | grep -E "microvms|nix"

# Bridges exist
ip link show br-vm1
ip link show br-vm2
ip link show br-vm3
ip link show br-vm4

# Bridges have IPs
ip addr show br-vm1 | grep 10.1.0.1
ip addr show br-vm2 | grep 10.2.0.1
ip addr show br-vm3 | grep 10.3.0.1
ip addr show br-vm4 | grep 10.4.0.1

# IP forwarding enabled
sysctl net.ipv4.ip_forward | grep "= 1"

# NAT configured
sudo iptables -t nat -L -n | grep MASQUERADE

# Tailscale running
sudo systemctl status tailscale
```

### Test 2: VM Status

```bash
# All VMs running
sudo systemctl is-active microvm@vm1
sudo systemctl is-active microvm@vm2
sudo systemctl is-active microvm@vm3
sudo systemctl is-active microvm@vm4

# VM processes exist
ps aux | grep cloud-hypervisor | grep -v grep | wc -l
# Should output: 4
```

### Test 3: VM Network Connectivity

```bash
# Test from hypervisor to VM1
ssh root@10.1.0.2 "hostname"
# Should output: vm1

# Test from hypervisor to all VMs
for i in {1..4}; do
  echo "Testing VM$i..."
  ssh root@10.$i.0.2 "hostname && ip addr show eth0"
done
```

### Test 4: VM Internet Access

```bash
# VM1 can reach internet
ssh root@10.1.0.2 "ping -c 3 1.1.1.1"

# VM1 can resolve DNS
ssh root@10.1.0.2 "nslookup google.com"

# VM1 can fetch HTTPS
ssh root@10.1.0.2 "curl -I https://google.com"
```

### Test 5: VM Isolation

```bash
# VM1 CANNOT reach VM2
ssh root@10.1.0.2 "ping -c 2 10.2.0.2"
# Should timeout/fail

# VM2 CANNOT reach VM3
ssh root@10.2.0.2 "ping -c 2 10.3.0.2"
# Should timeout/fail

# Verify firewall rules exist
sudo iptables -L FORWARD | grep DROP | wc -l
# Should output: 12 (or more)
```

### Test 6: Tailscale Access

From a remote machine on your Tailscale network:

```bash
# Verify routes advertised
tailscale status | grep "10\."

# SSH to VM via Tailscale
ssh root@10.1.0.2 "hostname"
# Should output: vm1

# Test all VMs
for i in {1..4}; do
  ssh root@10.$i.0.2 "echo 'VM$i reachable via Tailscale'"
done
```

### Test 7: Shared Storage

```bash
# Check /nix/store is shared
ssh root@10.1.0.2 "mount | grep virtiofs"
# Should show /nix/.ro-store mounted via virtiofs

# Verify store is read-only
ssh root@10.1.0.2 "touch /nix/.ro-store/test 2>&1"
# Should fail with "Read-only file system"

# Check disk usage savings
ssh root@10.1.0.2 "du -sh /nix/.ro-store"
ssh root@10.2.0.2 "du -sh /nix/.ro-store"
# Both should show same size (shared storage)
```

### Test 8: VM Resources

```bash
# Check VM CPU count
ssh root@10.1.0.2 "nproc"
# Should output: 2

# Check VM memory
ssh root@10.1.0.2 "free -h | grep Mem"
# Should show ~1GB total
```

## Performance Tests

### VM Boot Time

```bash
# Stop and restart VM1, measure boot time
sudo systemctl stop microvm@vm1
time sudo systemctl start microvm@vm1

# Wait for SSH to be available
while ! ssh -o ConnectTimeout=1 root@10.1.0.2 "echo ready" 2>/dev/null; do
  echo "Waiting for VM..."
  sleep 1
done

# Should be ready in < 10 seconds
```

### Network Throughput

```bash
# On VM1
ssh root@10.1.0.2 "nix-shell -p iperf3 --run 'iperf3 -s'" &

# On hypervisor
iperf3 -c 10.1.0.2
# Should show > 1 Gbps
```

## Success Criteria

All tests should pass:

- [ ] Hypervisor services running (ZFS, Tailscale, bridges)
- [ ] 4 VMs running and accessible via SSH
- [ ] VMs have internet access via NAT
- [ ] VMs isolated from each other
- [ ] VMs accessible via Tailscale from remote machines
- [ ] Shared /nix/store working (virtiofs)
- [ ] VM boot time < 10 seconds
- [ ] Network throughput > 1 Gbps

## Debugging

### Enable Verbose Logging

```bash
# VM systemd unit logs
sudo journalctl -u microvm@vm1 -f

# Cloud-Hypervisor logs
sudo cat /var/log/microvm/vm1.log
```

### Check Configuration

```bash
# Show VM network config
nix eval .#nixosConfigurations.vm1.config.systemd.network.networks.\"10-eth0\".networkConfig

# Show hypervisor NAT config
nix eval .#nixosConfigurations.hypervisor.config.networking.nat.externalInterface
```

### Rebuild Configuration

```bash
# Force rebuild hypervisor
sudo nixos-rebuild switch --flake .#hypervisor --show-trace

# Force rebuild VM
sudo microvm -u vm1 --force
```
```

**Verification:**
```bash
cat docs/TESTING.md | head -20
```

---

## Summary of Implementation Tasks

| Task | File | LOC | Est. Time |
|------|------|-----|-----------|
| 1. Network definitions | modules/networks.nix | 15 | 5 min |
| 2. MicroVM base module | modules/microvm-base.nix | 80 | 20 min |
| 3. Library helper | lib/default.nix | 15 | 5 min |
| 4. Main flake | flake.nix | 50 | 15 min |
| 5. Hypervisor base | hosts/hypervisor/default.nix | 60 | 15 min |
| 6. Hypervisor network | hosts/hypervisor/network.nix | 90 | 30 min |
| 7. VM1 config | hosts/vm1/default.nix | 25 | 10 min |
| 8. VM2-4 configs | hosts/vm{2,3,4}/default.nix | 75 | 15 min |
| 9. Deployment docs | docs/DEPLOYMENT.md | 350 | 30 min |
| 10. Testing docs | docs/TESTING.md | 250 | 20 min |
| **Total** | | **~1000** | **~2.5 hours** |

---

## Execution Order

**Phase 1: Core Configuration (Tasks 1-4)**
- Build order: networks.nix → microvm-base.nix → lib/default.nix → flake.nix
- Verify with: `nix flake check`

**Phase 2: Hypervisor (Tasks 5-6)**
- Build order: hypervisor/default.nix → hypervisor/network.nix
- Verify with: `nix build .#nixosConfigurations.hypervisor...`

**Phase 3: VMs (Tasks 7-8)**
- Build order: vm1 → vm2 → vm3 → vm4 (can be parallel)
- Verify with: `nix build .#nixosConfigurations.vm1...`

**Phase 4: Documentation (Tasks 9-10)**
- Write deployment guide
- Write testing guide
- Final verification: deploy and test on actual hardware

---

## Post-Implementation Checklist

After completing all tasks:

- [ ] All files committed to git
- [ ] `nix flake check` passes
- [ ] All 5 configurations build successfully
- [ ] Documentation complete (README, DEPLOYMENT, TESTING)
- [ ] Tested on actual hardware (if available)
- [ ] README updated with correct repo URLs
- [ ] Tagged release: v1.0.0

---

## Future Enhancements (Not in This Plan)

**Easy additions for learners:**
1. Add SOPS secrets management
2. Add Prometheus/Grafana monitoring
3. Add more VMs (copy vm1 pattern)
4. Add domain filtering (Pi-hole)
5. Add IPv6 support

**Each can be separate tutorial/branch.**

---

**Ready to implement? Start with Task 1!**
