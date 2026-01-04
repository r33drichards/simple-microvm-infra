# SSH Access Guide

## Prerequisites

You need the SSH key `~/.ssh/rw-ssh-key` on your local machine.

## Connection Methods

### Method 1: Direct Hypervisor Access

```bash
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181
```

### Method 2: VM Access via Hypervisor (Command Execution)

For running single commands on a VM:

```bash
# Template
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181 \
  'ssh -i /root/.ssh/id_ed25519 root@10.X.0.2 "COMMAND"'

# Examples
# Check VM1 uptime
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181 \
  'ssh -i /root/.ssh/id_ed25519 root@10.1.0.2 "uptime"'

# Check disk space on VM3
ssh -i ~/.ssh/rw-ssh-key root@54.185.189.181 \
  'ssh -i /root/.ssh/id_ed25519 root@10.3.0.2 "df -h"'
```

### Method 3: VM Access via ProxyJump (Interactive)

For interactive sessions on a VM:

```bash
# Template
ssh -o ProxyJump=root@54.185.189.181 \
    -i ~/.ssh/rw-ssh-key \
    root@10.X.0.2

# Example: Interactive session on VM1
ssh -o ProxyJump=root@54.185.189.181 \
    -i ~/.ssh/rw-ssh-key \
    root@10.1.0.2
```

### Method 4: SSH Config (Recommended)

Add to `~/.ssh/config`:

```ssh-config
Host hypervisor
    HostName 54.185.189.181
    User root
    IdentityFile ~/.ssh/rw-ssh-key

Host vm1
    HostName 10.1.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm2
    HostName 10.2.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm3
    HostName 10.3.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm4
    HostName 10.4.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm5
    HostName 10.5.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key
```

Then simply:

```bash
ssh hypervisor   # connects as root
ssh vm1          # connects as robertwendt
ssh vm3          # connects as robertwendt
```

To connect as root to a VM, use:
```bash
ssh -o User=root vm1
```

### One-liner Setup

Copy and paste this to set up your SSH config:

```bash
cat >> ~/.ssh/config << 'EOF'

Host hypervisor
    HostName 54.185.189.181
    User root
    IdentityFile ~/.ssh/rw-ssh-key

Host vm1
    HostName 10.1.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm2
    HostName 10.2.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm3
    HostName 10.3.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm4
    HostName 10.4.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key

Host vm5
    HostName 10.5.0.2
    User robertwendt
    ProxyJump hypervisor
    IdentityFile ~/.ssh/rw-ssh-key
EOF
chmod 600 ~/.ssh/config
```

## IP Address Reference

| Machine | Internal IP | Public IP | Notes |
|---------|-------------|-----------|-------|
| Hypervisor | 172.31.46.94 | 54.185.189.181 | AWS a1.metal in us-west-2 |
| VM1 | 10.1.0.2 | - | Bridge: br-vm1 (10.1.0.1) |
| VM2 | 10.2.0.2 | - | Bridge: br-vm2 (10.2.0.1) |
| VM3 | 10.3.0.2 | - | Bridge: br-vm3 (10.3.0.1) |
| VM4 | 10.4.0.2 | - | Bridge: br-vm4 (10.4.0.1) |
| VM5 | 10.5.0.2 | - | Bridge: br-vm5 (10.5.0.1) |

## Troubleshooting

### "Connection refused" to VM

The VM might be rebooting or not started:

```bash
# Check VM status from hypervisor
ssh hypervisor 'systemctl status microvm@vm1'

# Start VM if stopped
ssh hypervisor 'systemctl start microvm@vm1'
```

### "Host key verification failed" for VM

VMs have impermanence - SSH host keys regenerate on reboot:

```bash
# Remove old key from hypervisor's known_hosts
ssh hypervisor 'ssh-keygen -R 10.X.0.2'

# Or accept new key
ssh hypervisor 'ssh -o StrictHostKeyChecking=accept-new root@10.X.0.2 hostname'
```

### "Permission denied"

Check that the SSH key is correct:

```bash
# Verify key exists
ls -la ~/.ssh/rw-ssh-key

# Check key is loaded
ssh-add -l

# Add key if needed
ssh-add ~/.ssh/rw-ssh-key
```

## File Transfer

### To/From Hypervisor

```bash
# Copy file to hypervisor
scp -i ~/.ssh/rw-ssh-key localfile.txt root@54.185.189.181:/path/

# Copy file from hypervisor
scp -i ~/.ssh/rw-ssh-key root@54.185.189.181:/path/file.txt ./
```

### To/From VM (via Hypervisor)

```bash
# Copy to VM (two-step)
scp -i ~/.ssh/rw-ssh-key localfile.txt root@54.185.189.181:/tmp/
ssh hypervisor 'scp -i /root/.ssh/id_ed25519 /tmp/localfile.txt root@10.1.0.2:/path/'

# Or with ProxyJump
scp -o ProxyJump=root@54.185.189.181 -i ~/.ssh/rw-ssh-key \
    localfile.txt root@10.1.0.2:/path/
```

## Port Forwarding

### Forward VM Port to Local

```bash
# Forward VM1 port 8080 to local 8080
ssh -L 8080:10.1.0.2:8080 -i ~/.ssh/rw-ssh-key root@54.185.189.181

# Access at http://localhost:8080
```

### Forward VM RDP (for remote desktop)

```bash
# Forward VM1 RDP to local
ssh -L 3389:10.1.0.2:3389 -i ~/.ssh/rw-ssh-key root@54.185.189.181

# Connect RDP client to localhost:3389
```
