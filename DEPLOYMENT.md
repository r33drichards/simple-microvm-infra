# Deployment Guide

This document describes the automated GitOps deployment strategy using Comin for the MicroVM infrastructure.

## Overview

This infrastructure uses **Comin** for automated, pull-based GitOps deployments. Comin runs on the hypervisor and periodically polls the Git repository for changes, automatically deploying updates to the NixOS configuration.

### Key Characteristics

- **Pull-Based**: Hypervisor polls Git repository (no push access needed)
- **Automatic**: Changes are deployed without manual intervention
- **Safe**: NixOS atomic upgrades with rollback capability
- **Monitored**: Deployment hooks log all changes to journald
- **Branch-Aware**: Can track specific branches or multiple remotes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ GitHub Repository                                           │
│ r33drichards/simple-microvm-infra                          │
│                                                             │
│ main branch ──────────────────────┐                        │
└───────────────────────────────────┼─────────────────────────┘
                                    │
                                    │ Poll every 60s (default)
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│ Hypervisor (54.201.157.166)                                    │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Comin Service (systemd)                              │  │
│  │                                                       │  │
│  │  1. Poll repository for changes                      │  │
│  │  2. Fetch new commits                                │  │
│  │  3. Build new NixOS configuration                    │  │
│  │  4. Switch to new configuration                      │  │
│  │  5. Run post-deploy hooks                            │  │
│  │  6. Log deployment status                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  MicroVMs automatically restart if needed                  │
└─────────────────────────────────────────────────────────────┘
```

## How Deployment Works

### Step 1: Make Changes

Edit configuration files locally or via GitHub:

```bash
# Local workflow
git clone https://github.com/r33drichards/simple-microvm-infra.git
cd simple-microvm-infra
# Make your changes
git commit -am "Update VM configuration"
git push origin main
```

### Step 2: Automatic Detection

Comin service on the hypervisor:
- Polls the repository every 60 seconds (configurable)
- Detects new commits on the main branch
- Fetches the latest changes

### Step 3: Build and Deploy

When changes are detected:
1. Comin builds the new NixOS configuration
2. Performs a system switch (equivalent to `nixos-rebuild switch`)
3. Services/VMs are restarted as needed
4. Post-deploy hooks execute

### Step 4: Verification

Post-deploy hook logs:
- Deployment timestamp
- Git commit hash
- Active MicroVM status
- Any errors or warnings

## Monitoring Deployments

### Check Comin Service Status

```bash
# View Comin service status
systemctl status comin

# Check recent Comin logs
journalctl -u comin -f

# View last 100 Comin log lines
journalctl -u comin -n 100
```

### Monitor Deployment Activity

```bash
# Filter for Comin deployment logs
journalctl -t comin -f

# View deployment history
journalctl -t comin --since "1 day ago"

# Check last deployment
journalctl -t comin | tail -20
```

### Check MicroVM Status After Deployment

```bash
# List all MicroVM services
systemctl list-units 'microvm@*'

# Check specific VM status
systemctl status microvm@vm1

# View VM logs
journalctl -u microvm@vm1 -f
```

### Deployment Logs

The post-deploy hook logs the following:
- **Deployment timestamp**: When the deployment completed
- **Branch and commit**: Which git ref was deployed
- **Active VMs count**: How many MicroVMs are running
- **Service status**: Status of all microvm services

Example log output:
```
Nov 01 10:30:45 hypervisor comin[1234]: Deployment successful: main @ abc123def
Nov 01 10:30:46 hypervisor comin[1234]: Active MicroVMs after deployment: 5
```

## Configuration Files

### Primary Configuration

**`hosts/hypervisor/comin.nix`** - Comin service configuration:
- Repository URL
- Branch tracking
- Poll interval (default: 60s)
- Post-deploy hooks

**`flake.nix`** - Comin integration:
- Comin input declaration
- Module import for hypervisor

### Customizing Deployment

Edit `hosts/hypervisor/comin.nix` to customize:

```nix
services.comin = {
  enable = true;

  remotes = [{
    name = "origin";
    url = "https://github.com/r33drichards/simple-microvm-infra.git";

    # Track a different branch
    branches.main = {
      name = "main";  # Change to "staging" or "production"
    };

    # Or track multiple branches
    branches.staging = {
      name = "staging";
    };
  }];
};
```

## Testing Changes Safely

### Option 1: Use a Test Branch

Create a test branch in Comin configuration:

```nix
# Add to hosts/hypervisor/comin.nix
branches.testing = {
  name = "testing";
};
```

Comin will track both main and testing branches, allowing you to test changes before merging to main.

### Option 2: Manual Deployment (Bypass Comin)

If you need to test changes before committing:

```bash
# SSH to hypervisor
ssh root@hypervisor

# Manual rebuild
nixos-rebuild switch --flake /var/lib/microvms/hypervisor/flake

# Or test without switching
nixos-rebuild test --flake /var/lib/microvms/hypervisor/flake
```

### Option 3: Rollback

If a deployment breaks something:

```bash
# SSH to hypervisor
ssh root@hypervisor

# List previous generations
nixos-rebuild list-generations

# Rollback to previous generation
nixos-rebuild switch --rollback

# Or switch to specific generation
nixos-rebuild switch --switch-generation 42
```

## Troubleshooting

### Problem: Deployments Not Happening

**Diagnosis:**
```bash
# Check if Comin is running
systemctl status comin

# Check Comin logs for errors
journalctl -u comin -n 100
```

**Common Causes:**
- Comin service not started: `systemctl start comin`
- Network issues preventing git fetch
- Invalid repository URL or branch name
- Git authentication issues (if using private repo)

### Problem: Deployment Failed

**Diagnosis:**
```bash
# Check build errors
journalctl -u comin | grep -i error

# Check NixOS rebuild logs
journalctl -u nixos-rebuild
```

**Solution:**
1. Fix the configuration error in Git
2. Push the fix to main branch
3. Comin will automatically retry with the new commit
4. Or manually rollback: `nixos-rebuild switch --rollback`

### Problem: VMs Not Restarting

**Diagnosis:**
```bash
# Check if VM services are enabled
systemctl list-units 'microvm@*'

# Check specific VM status
systemctl status microvm@vm1
```

**Solution:**
- Manually restart VM: `systemctl restart microvm@vm1`
- Check VM logs: `journalctl -u microvm@vm1 -n 100`

### Problem: Repository Authentication

If using a private repository:

```nix
# Add SSH key or token to Comin config
services.comin.remotes = [{
  name = "origin";
  url = "git@github.com:r33drichards/simple-microvm-infra.git";
  # Ensure hypervisor has SSH key with repo access
}];
```

## Security Considerations

### Repository Access

- **Public repos**: No authentication needed (current setup)
- **Private repos**: Requires SSH key or token with read access
- **Branch protection**: Use protected branches to prevent unauthorized deployments

### Deployment Safety

- **Atomic updates**: NixOS ensures atomic configuration changes
- **Automatic rollback**: Failed builds don't affect running system
- **Generation history**: All previous configurations are preserved
- **Testing first**: Use test branches or manual testing before production

### Network Security

- **Outbound only**: Hypervisor only makes outbound connections to GitHub
- **No inbound deployment**: No webhooks or push access needed
- **Tailscale access**: Remote monitoring via secure VPN

## Advanced Usage

### Multiple Remotes

Track changes from multiple repositories:

```nix
services.comin.remotes = [
  {
    name = "origin";
    url = "https://github.com/r33drichards/simple-microvm-infra.git";
    branches.main.name = "main";
  }
  {
    name = "upstream";
    url = "https://github.com/upstream/microvm-infra.git";
    branches.main.name = "main";
  }
];
```

### Custom Poll Interval

Adjust how frequently Comin checks for changes:

```nix
# Check every 5 minutes instead of default 60 seconds
systemd.services.comin.serviceConfig.Environment = "COMIN_INTERVAL=300";
```

### Enhanced Hooks

Extend the post-deploy hook for custom automation:

```nix
postDeployHook = pkgs.writeShellScript "post-deploy-hook" ''
  # ... existing hook content ...

  # Send notification
  curl -X POST https://notify.example.com/webhook \
    -d "Deployed $COMIN_COMMIT to hypervisor"

  # Run custom health checks
  /path/to/health-check.sh

  # Backup configuration
  cp /etc/nixos/configuration.nix /backups/config-$(date +%Y%m%d-%H%M%S).nix
'';
```

## Comparison with Manual Deployment

| Aspect | Manual (nixos-rebuild) | Comin (GitOps) |
|--------|------------------------|----------------|
| **Trigger** | Manual SSH + command | Automatic on git push |
| **Access Required** | SSH access to hypervisor | Git push access only |
| **Deployment Speed** | Immediate | ~60 seconds delay |
| **Audit Trail** | Manual logging | Automatic git history |
| **Rollback** | Manual generation switch | Git revert + auto-deploy |
| **Multi-machine** | SSH to each machine | All machines auto-update |
| **Network Dependency** | Inbound SSH | Outbound git fetch only |

## Best Practices

1. **Commit Discipline**:
   - Write clear commit messages
   - One logical change per commit
   - Test locally before pushing (if possible)

2. **Branch Strategy**:
   - Keep main branch stable
   - Use feature branches for testing
   - Merge to main only after verification

3. **Monitoring**:
   - Regularly check Comin logs
   - Monitor VM status after deployments
   - Set up alerting for failed deployments

4. **Safety**:
   - Keep rollback procedure documented
   - Test major changes in staging branch first
   - Always verify deployments completed successfully

5. **Documentation**:
   - Document all configuration changes
   - Keep CLAUDE.md updated with architecture changes
   - Maintain this DEPLOYMENT.md with deployment procedures

## VM Deployment

VMs are deployed automatically when the hypervisor configuration is rebuilt. The hypervisor manages VM runners via `microvm@` systemd services.

### Fresh VM Deployment (Clean State)

```bash
# On hypervisor: Stop VMs and delete disk images
for vm in vm1 vm2 vm3 vm4 vm5; do
  systemctl stop microvm@$vm
  rm -f /var/lib/microvms/$vm/*.img
done

# Rebuild hypervisor (installs new VM runners)
cd /root/simple-microvm-infra && git pull
nixos-rebuild switch --flake .#hypervisor

# Start VMs (new disk images auto-created)
for vm in vm1 vm2 vm3 vm4 vm5; do
  systemctl start microvm@$vm
done

# Create base snapshots after VMs boot
sleep 60
for vm in vm1 vm2 vm3 vm4 vm5; do
  zfs snapshot microvms/storage/$vm@base
done
```

### Reset VM to Clean State

```bash
# Stop, rollback, restart
systemctl stop microvm@vm1
zfs rollback microvms/storage/vm1@base
systemctl start microvm@vm1
```

### VM Storage Architecture

Each VM has three disk images:
- **erofs store**: Read-only Nix closure (built at deploy time)
- **data.img**: 64GB ext4 root filesystem
- **nix-overlay.img**: 8GB ext4 writable Nix store overlay

The erofs store is rebuilt when the VM configuration changes. The data.img and nix-overlay.img persist until manually deleted or rolled back via ZFS.

## References

- **Comin GitHub**: https://github.com/nlewo/comin
- **Configuration**: `hosts/hypervisor/comin.nix`
- **Architecture**: `CLAUDE.md`
- **Development**: `DEVELOPMENT.md`
