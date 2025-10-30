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
