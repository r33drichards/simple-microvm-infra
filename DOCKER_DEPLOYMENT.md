# Docker Sandbox Container Deployment

## Summary

This document describes the deployment of the `wholelottahoopla/sandbox:latest` Docker container to vm1 using NixOS declarative OCI container management.

## Changes Made

### 1. Configuration Changes (flake.nix:22-42)
- Used `virtualisation.oci-containers.backend = "docker"` for Docker backend
- Declaratively defined the sandbox container with `autoStart = true`
- Container is managed by NixOS systemd service (`docker-sandbox.service`)
- No manual docker commands needed - everything is declarative

### 2. Deployment Script (deploy-vm1-docker.sh)
Created an automated deployment script that:
- Checks out the configuration branch
- Rebuilds vm1 with declarative container configuration
- Container automatically starts via systemd
- Verifies deployment via systemd service status

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

# 3. Rebuild and restart vm1 with declarative container configuration
microvm -Ru vm1

# 4. Wait for vm1 to be ready
sleep 15

# 5. Verify the container is running
ssh root@10.1.0.2 'docker ps -a'

# 6. Check the systemd service status
ssh root@10.1.0.2 'systemctl status docker-sandbox.service'
```

**Note**: With the declarative approach, NixOS automatically pulls the image and starts the container via systemd. No manual docker commands are required!

## Verification

After deployment, verify the container is running:

```bash
# From the hypervisor
ssh root@10.1.0.2 'docker ps'

# Expected output should show the sandbox container running
```

## Container Management

With declarative OCI containers, the container is managed by systemd as the `docker-sandbox.service` unit.

### View container logs
```bash
# Via systemd (recommended)
ssh root@10.1.0.2 'journalctl -u docker-sandbox.service -f'

# Or via docker
ssh root@10.1.0.2 'docker logs sandbox'
```

### Stop the container
```bash
ssh root@10.1.0.2 'systemctl stop docker-sandbox.service'
```

### Start the container
```bash
ssh root@10.1.0.2 'systemctl start docker-sandbox.service'
```

### Restart the container
```bash
ssh root@10.1.0.2 'systemctl restart docker-sandbox.service'
```

### Check container status
```bash
# Via systemd
ssh root@10.1.0.2 'systemctl status docker-sandbox.service'

# Or via docker
ssh root@10.1.0.2 'docker ps -a'
```

### Disable auto-start (requires configuration change)
To prevent the container from auto-starting, edit `flake.nix` and set `autoStart = false;`, then rebuild:
```bash
microvm -Ru vm1
```

## Network Access

The container runs on vm1 which has the following network configuration:
- VM IP: `10.1.0.2`
- Gateway: `10.1.0.1` (hypervisor bridge)
- Subnet: `10.1.0.0/24`

### Exposing Container Ports

To expose container ports, edit `flake.nix` and add the `ports` configuration:

```nix
virtualisation.oci-containers.containers.sandbox = {
  image = "wholelottahoopla/sandbox:latest";
  autoStart = true;
  ports = [
    "8080:80"  # Expose container port 80 on host port 8080
    "443:443"  # Expose additional ports as needed
  ];
};
```

Then rebuild vm1:
```bash
microvm -Ru vm1
```

Once ports are exposed, you can access them via:
- From hypervisor: `10.1.0.2:8080`
- Via Tailscale VPN: `10.1.0.2:8080` (from any device on your Tailnet)

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

## NixOS Declarative Container Benefits

This deployment uses NixOS's declarative OCI container management, which provides several advantages:

1. **Infrastructure as Code**: Container configuration is version-controlled in `flake.nix`
2. **Automatic Management**: NixOS handles pulling images, creating containers, and managing lifecycle
3. **Systemd Integration**: Container runs as `docker-sandbox.service` with proper logging and monitoring
4. **Reproducibility**: Same configuration always produces same result
5. **Atomic Updates**: Configuration changes are atomic and can be rolled back
6. **No Manual Commands**: No need to run `docker pull` or `docker run` manually

### Configuration Options

The `virtualisation.oci-containers.containers.<name>` module supports many options:

```nix
virtualisation.oci-containers.containers.sandbox = {
  image = "wholelottahoopla/sandbox:latest";
  autoStart = true;

  # Port mappings
  ports = [ "8080:80" ];

  # Environment variables
  environment = {
    KEY = "value";
  };

  # Environment files (for secrets)
  environmentFiles = [ "/path/to/env/file" ];

  # Volumes
  volumes = [
    "/host/path:/container/path"
  ];

  # Command override
  cmd = [ "arg1" "arg2" ];

  # Entrypoint override
  entrypoint = "/custom/entrypoint.sh";

  # Container dependencies
  dependsOn = [ "other-container" ];

  # Extra docker options
  extraOptions = [
    "--privileged"
    "--cap-add=NET_ADMIN"
  ];
};
```

## Notes

- The container is managed by systemd with automatic restart on failure
- Container data is stored in vm1's `/var` directory at `/var/lib/microvms/vm1/var/lib/docker`
- The Docker daemon in vm1 uses virtiofs shared storage for container images and volumes
- vm1 is on ARM64 architecture (aarch64), ensure the container image supports ARM64
- All container changes must be made in `flake.nix` and deployed with `microvm -Ru vm1`
