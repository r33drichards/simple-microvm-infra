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
