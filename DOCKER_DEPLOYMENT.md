# Docker Sandbox Container Deployment

## Summary

This document describes the deployment of the `wholelottahoopla/sandbox:latest` Docker container to vm1.

## Changes Made

### 1. Configuration Changes (flake.nix:22-32)
- Enabled Docker in vm1 by setting `virtualisation.docker.enable = true`
- Added users `robertwendt` and `root` to the `docker` group for permission management
- Included `docker` package in vm1's system packages

### 2. Deployment Script (deploy-vm1-docker.sh)
Created an automated deployment script that:
- Checks out the configuration branch
- Rebuilds vm1 with Docker support
- Pulls the sandbox container image
- Runs the container with auto-restart policy

## Deployment Instructions

### Option 1: Using the Automated Script

SSH to the hypervisor and run the deployment script:

```bash
ssh -i "bm nixos us west 2.pem" root@16.144.20.78

# Download and run the deployment script
cd /root/simple-microvm-infra
git fetch origin
git checkout claude/deploy-docker-sandbox-011CUeEKVQfDeopHtRiYgA8u
git pull
./deploy-vm1-docker.sh
```

### Option 2: Manual Deployment

If you prefer to deploy step-by-step:

```bash
# 1. SSH to the hypervisor
ssh -i "bm nixos us west 2.pem" root@16.144.20.78

# 2. Update the repository to the Docker-enabled branch
cd /root/simple-microvm-infra
git fetch origin
git checkout claude/deploy-docker-sandbox-011CUeEKVQfDeopHtRiYgA8u
git pull

# 3. Rebuild and restart vm1 with Docker support
microvm -Ru vm1

# 4. Wait for vm1 to be ready
sleep 10

# 5. SSH to vm1 and deploy the container
ssh root@10.1.0.2

# 6. Inside vm1, pull and run the container
docker pull wholelottahoopla/sandbox:latest
docker run -d --name sandbox --restart unless-stopped wholelottahoopla/sandbox:latest

# 7. Verify the container is running
docker ps -a
```

## Verification

After deployment, verify the container is running:

```bash
# From the hypervisor
ssh root@10.1.0.2 'docker ps'

# Expected output should show the sandbox container running
```

## Container Management

### View container logs
```bash
ssh root@10.1.0.2 'docker logs sandbox'
```

### Stop the container
```bash
ssh root@10.1.0.2 'docker stop sandbox'
```

### Start the container
```bash
ssh root@10.1.0.2 'docker start sandbox'
```

### Remove the container
```bash
ssh root@10.1.0.2 'docker rm -f sandbox'
```

### Restart the container
```bash
ssh root@10.1.0.2 'docker restart sandbox'
```

## Network Access

The container runs on vm1 which has the following network configuration:
- VM IP: `10.1.0.2`
- Gateway: `10.1.0.1` (hypervisor bridge)
- Subnet: `10.1.0.0/24`

If the container exposes any ports, you can access them via:
- From hypervisor: `10.1.0.2:<port>`
- Via Tailscale VPN: `10.1.0.2:<port>` (from any device on your Tailnet)

To expose container ports, use Docker's `-p` flag:
```bash
docker run -d --name sandbox -p 8080:80 --restart unless-stopped wholelottahoopla/sandbox:latest
```

## Architecture

```
┌─────────────────────────────────────────────┐
│ Hypervisor (16.144.20.78)                   │
│                                              │
│  ┌────────────────────────────────────────┐ │
│  │ br-vm1 (10.1.0.1/24)                   │ │
│  │         │                               │ │
│  │    ┌────▼────────────────────────────┐  │ │
│  │    │ vm1 (10.1.0.2)                  │  │ │
│  │    │                                  │  │ │
│  │    │  Docker Engine                   │  │ │
│  │    │    └─ sandbox container          │  │ │
│  │    │       (wholelottahoopla/sandbox) │  │ │
│  │    └──────────────────────────────────┘  │ │
│  └────────────────────────────────────────┘ │
│                                              │
│  NAT: 10.1.0.0/24 → Internet                │
│  Tailscale: Routes 10.1.0.0/24              │
└─────────────────────────────────────────────┘
```

## Troubleshooting

### Container not starting
```bash
# Check Docker daemon status
ssh root@10.1.0.2 'systemctl status docker'

# Check Docker logs
ssh root@10.1.0.2 'journalctl -u docker -f'

# Check container logs
ssh root@10.1.0.2 'docker logs sandbox'
```

### Docker service not available
If Docker is not running after deployment, rebuild vm1:
```bash
ssh root@16.144.20.78 'microvm -Ru vm1'
```

### Network issues
Check that vm1 has internet connectivity:
```bash
ssh root@10.1.0.2 'ping -c 3 1.1.1.1'
```

## Rollback

To remove Docker from vm1 and revert changes:

```bash
# 1. SSH to hypervisor
ssh -i "bm nixos us west 2.pem" root@16.144.20.78

# 2. Checkout the main branch
cd /root/simple-microvm-infra
git checkout main  # or master
git pull

# 3. Rebuild vm1
microvm -Ru vm1
```

## Notes

- The container is configured with `--restart unless-stopped` to survive VM reboots
- Container data is stored in vm1's `/var` directory at `/var/lib/microvms/vm1/var/lib/docker`
- The Docker daemon in vm1 uses virtiofs shared storage for container images and volumes
- vm1 is on ARM64 architecture (aarch64), ensure the container image supports ARM64
