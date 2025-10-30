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
nix build .#nixosConfigurations.vm5.config.system.build.toplevel
```

## Post-Deployment Tests

Run these tests after completing deployment.

### Test 1: Hypervisor Services

```bash
# EBS volume service running
sudo systemctl is-active ebs-volume-microvm-storage

# ZFS pool exists
sudo zpool status microvm-pool

# ZFS dataset exists and mounted
sudo zfs list microvm-pool/storage
df -h | grep /var/lib/microvms

# EBS volume attached
lsblk | grep nvme
aws ec2 describe-volumes --filters "Name=tag:Name,Values=microvm-storage" --query "Volumes[0].[VolumeId,State,Attachments[0].State]" --output text

# Bridges exist
ip link show br-vm1
ip link show br-vm2
ip link show br-vm3
ip link show br-vm4
ip link show br-vm5

# Bridges have IPs
ip addr show br-vm1 | grep 10.1.0.1
ip addr show br-vm2 | grep 10.2.0.1
ip addr show br-vm3 | grep 10.3.0.1
ip addr show br-vm4 | grep 10.4.0.1
ip addr show br-vm5 | grep 10.5.0.1

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
sudo systemctl is-active microvm@vm5

# VM processes exist
ps aux | grep cloud-hypervisor | grep -v grep | wc -l
# Should output: 5
```

### Test 3: VM Network Connectivity

```bash
# Test from hypervisor to VM1
ssh root@10.1.0.2 "hostname"
# Should output: vm1

# Test from hypervisor to all VMs
for i in {1..5}; do
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
# Should output: 20 (5 VMs with 4 isolation rules each)
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

### Test 9: ZFS Features

```bash
# Check ZFS compression is enabled
sudo zfs get compression microvm-pool/storage
# Should show: zstd

# Check ZFS properties
sudo zfs get all microvm-pool/storage | grep -E "compression|atime|xattr|acltype"

# Test ZFS snapshot capability
sudo zfs snapshot microvm-pool/storage@test
sudo zfs list -t snapshot
sudo zfs destroy microvm-pool/storage@test

# Check ZFS pool health
sudo zpool status microvm-pool
# Should show: ONLINE

# Verify EBS volume persistent across reboots
sudo zpool export microvm-pool
sudo zpool import microvm-pool
sudo zpool status microvm-pool
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

- [ ] EBS volume automatically created, attached, and configured
- [ ] ZFS pool created with optimized settings (zstd compression, etc.)
- [ ] Hypervisor services running (ZFS, Tailscale, bridges)
- [ ] 5 VMs running and accessible via SSH (3 vCPU, 6GB RAM each)
- [ ] VMs have internet access via NAT
- [ ] VMs isolated from each other
- [ ] VMs accessible via Tailscale from remote machines
- [ ] Shared /nix/store working (virtiofs)
- [ ] VM boot time < 10 seconds
- [ ] Network throughput > 1 Gbps
- [ ] ZFS snapshots can be created and destroyed

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
