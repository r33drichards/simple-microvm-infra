# Webhook Setup Guide

This guide explains how to configure and use the automated deployment webhook system for your MicroVM infrastructure.

## Overview

The webhook system allows you to trigger automated deployments via HTTP requests. This is useful for:
- **GitHub/GitLab webhooks**: Automatically deploy when you push to your repository
- **Manual deployments**: Trigger deployments from scripts or CI/CD pipelines
- **Remote management**: Deploy from anywhere without SSH access

## Architecture

```
GitHub/GitLab Push
        ↓
    Internet
        ↓
  [Caddy HTTPS :443]
        ↓ (reverse proxy)
  [Webhook :9000]
        ↓ (executes)
 [Deployment Script]
        ↓
  nixos-rebuild switch
```

## Prerequisites Checklist

Before enabling the webhook system, you need to provide the following:

### ✅ Required Configuration

- [ ] **Domain name**: A domain or subdomain pointing to your hypervisor's public IP
  - Example: `webhooks.example.com` → `16.144.20.78`
  - You'll need to create an A record in your DNS provider

- [ ] **Email address**: For Let's Encrypt certificate notifications
  - Example: `admin@example.com`
  - Let's Encrypt will email you about certificate renewals

- [ ] **Secret token**: A secure random string for webhook authentication
  - Generate with: `openssl rand -hex 32`
  - This prevents unauthorized deployments

- [ ] **Infrastructure directory**: Path to your git repository on the hypervisor
  - Current assumption: `/home/robertwendt/simple-microvm-infra`
  - Verify with: `ls -la /home/robertwendt/simple-microvm-infra`

- [ ] **Git branch**: The branch to pull from
  - Default: `main`
  - Could be: `master`, `production`, etc.

### ⚙️ Optional Configuration

- [ ] **Allowed IPs**: Restrict webhook access to specific IP addresses
  - Useful for GitHub webhook IPs
  - GitHub webhook IPs: https://api.github.com/meta (look for `hooks` IPs)
  - Example: `["192.30.252.0/22", "185.199.108.0/22"]`

## Configuration Steps

### Step 1: Configure DNS

Create an A record pointing to your hypervisor:

```
Type: A
Name: webhooks (or your chosen subdomain)
Value: 16.144.20.78
TTL: 300 (or your preference)
```

Wait for DNS propagation (check with: `dig webhooks.example.com`)

### Step 2: Generate Secret Token

On your local machine or hypervisor:

```bash
openssl rand -hex 32
```

Save this token securely - you'll need it for:
1. NixOS configuration
2. GitHub/GitLab webhook configuration

### Step 3: Update NixOS Configuration

Edit `hosts/hypervisor/default.nix`:

```nix
  # Enable webhook service for automated deployments
  services.microvm-webhook = {
    enable = true;
    infrastructureDir = "/home/robertwendt/simple-microvm-infra"; # ← Verify this path
    gitBranch = "main"; # ← Update if needed
    secretToken = "your-secret-token-here"; # ← Paste your generated token
    port = 9000;
  };

  # Enable Caddy reverse proxy for webhook
  services.microvm-caddy = {
    enable = true; # ← Change to true
    domain = "webhooks.example.com"; # ← Replace with your domain
    email = "admin@example.com"; # ← Replace with your email
    webhookPort = 9000;
  };
```

### Step 4: Deploy Configuration

On the hypervisor:

```bash
# Ensure you're in the infrastructure directory
cd /home/robertwendt/simple-microvm-infra

# Rebuild the hypervisor with new configuration
sudo nixos-rebuild switch --flake .#hypervisor

# Check that services are running
sudo systemctl status webhook
sudo systemctl status caddy

# Check logs
sudo journalctl -u webhook -f
sudo journalctl -u caddy -f
```

### Step 5: Test the Webhook

Test the health check endpoint:

```bash
curl https://webhooks.example.com/hooks/health
# Should return: {"success": true}
```

Test the deployment endpoint (replace TOKEN):

```bash
curl "https://webhooks.example.com/hooks/deploy?token=YOUR-SECRET-TOKEN"
# Should return: {"success": true, "message": "Deployment started successfully"}
```

Check deployment logs:

```bash
sudo tail -f /var/log/webhook-deploy.log
```

## Available Endpoints

### 1. Health Check (No Auth)

**URL**: `https://webhooks.example.com/hooks/health`

**Method**: GET

**Purpose**: Check if webhook service is running

**Response**:
```json
{"success": true}
```

### 2. Full Deployment (Auth Required)

**URL**: `https://webhooks.example.com/hooks/deploy?token=YOUR-SECRET-TOKEN`

**Method**: POST or GET

**Purpose**: Pull latest code and rebuild infrastructure

**What it does**:
1. Pull latest changes from git
2. Run `nixos-rebuild switch --flake .#hypervisor --update-input nixpkgs`
3. Log all output to `/var/log/webhook-deploy.log`

**Response**:
```json
{"success": true, "message": "Deployment started successfully"}
```

### 3. Rebuild Only (Auth Required)

**URL**: `https://webhooks.example.com/hooks/rebuild?token=YOUR-SECRET-TOKEN&REBUILD_VMS=true`

**Method**: POST or GET

**Purpose**: Rebuild without pulling from git (for testing)

**Parameters**:
- `token`: Your secret token
- `REBUILD_VMS`: Set to `true` to also rebuild and restart VMs

**Response**:
```json
{"success": true, "message": "Rebuild started successfully"}
```

## GitHub Webhook Integration

### Step 1: Add Webhook in GitHub

1. Go to your repository on GitHub
2. Navigate to **Settings** → **Webhooks** → **Add webhook**
3. Configure:
   - **Payload URL**: `https://webhooks.example.com/hooks/deploy?token=YOUR-SECRET-TOKEN`
   - **Content type**: `application/json`
   - **Secret**: (leave empty, we're using URL token)
   - **Which events**: Just the push event
   - **Active**: ✅

### Step 2: Test

1. Make a commit and push to your repository
2. GitHub will send a webhook
3. Check webhook delivery in GitHub Settings → Webhooks → Recent Deliveries
4. Check deployment logs on hypervisor: `sudo tail -f /var/log/webhook-deploy.log`

## GitLab Webhook Integration

1. Go to your repository on GitLab
2. Navigate to **Settings** → **Webhooks**
3. Configure:
   - **URL**: `https://webhooks.example.com/hooks/deploy?token=YOUR-SECRET-TOKEN`
   - **Trigger**: Push events
   - **Enable SSL verification**: ✅

## Security Considerations

### Secret Token

- **CRITICAL**: Keep your secret token secure
- Don't commit it to git (use `secretToken = builtins.readFile /path/to/secret;` instead)
- Rotate periodically
- Use a strong random token (at least 32 bytes)

### IP Allowlist

For additional security, restrict webhook access to specific IPs:

```nix
services.microvm-webhook = {
  # ...
  allowedIPs = [
    "192.30.252.0/22"    # GitHub webhook IPs
    "185.199.108.0/22"   # GitHub webhook IPs
    "140.82.112.0/20"    # GitHub webhook IPs
    # Add your CI/CD IPs here
  ];
};
```

### HTTPS Only

- Caddy automatically provisions Let's Encrypt certificates
- Never use HTTP for webhooks (secrets in URL would be visible)
- Ensure firewall only allows port 443 (HTTPS)

### Rate Limiting

Caddy is configured with rate limiting:
- 10 requests per minute per IP
- Prevents abuse and DoS attacks

## Troubleshooting

### Certificate Issues

If Let's Encrypt certificates fail:

```bash
# Check Caddy logs
sudo journalctl -u caddy -n 100

# Common issues:
# 1. DNS not propagated yet (wait 5-10 minutes)
# 2. Firewall blocking port 80 (needed for ACME challenge)
# 3. Domain doesn't point to your server
```

### Webhook Not Responding

```bash
# Check webhook service
sudo systemctl status webhook

# Check if listening on port
sudo ss -tlnp | grep 9000

# Check Caddy reverse proxy
curl http://127.0.0.1:9000/hooks/health

# Test through Caddy
curl https://webhooks.example.com/hooks/health
```

### Deployment Failures

```bash
# Check deployment logs
sudo tail -f /var/log/webhook-deploy.log

# Check for lock file (prevents concurrent deployments)
ls -la /var/run/deploy.lock

# Remove stuck lock if needed
sudo rm /var/run/deploy.lock

# Run deployment manually to test
sudo /nix/store/.../deploy-infrastructure
```

### Permission Errors

If deployment script can't run `nixos-rebuild`:

```bash
# Webhook runs as root (configured in module)
sudo journalctl -u webhook -n 50

# Check that webhook user is root
ps aux | grep webhook
```

## Monitoring

### Check Webhook Logs

```bash
# Real-time webhook logs
sudo journalctl -u webhook -f

# Recent webhook activity
sudo journalctl -u webhook -n 100

# Deployment log
sudo tail -f /var/log/webhook-deploy.log
```

### Check Caddy Access Logs

```bash
# Real-time access logs
sudo tail -f /var/log/caddy/webhook-access.log

# Parse JSON logs
sudo cat /var/log/caddy/webhook-access.log | jq
```

### Metrics

Check webhook metrics:

```bash
# Number of successful deployments
grep "Deployment completed successfully" /var/log/webhook-deploy.log | wc -l

# Recent deployments
grep "Starting deployment" /var/log/webhook-deploy.log | tail -5
```

## Advanced Configuration

### Custom Deployment Script

To customize what happens during deployment, edit `modules/webhook.nix`:

```nix
deployScript = pkgs.writeScriptBin "deploy-infrastructure" ''
  #!${pkgs.bash}/bin/bash
  set -euo pipefail

  # Your custom deployment logic here
  log "Custom step 1..."
  # ...
'';
```

### Additional Hooks

Add more webhook endpoints in `modules/webhook.nix`:

```nix
hooks = {
  # ...

  restart-vms = {
    id = "restart-vms";
    execute-command = "/path/to/restart-script.sh";
    response-message = "VMs restart initiated";
  };
};
```

### Environment Variables

Pass environment variables to deployment script:

```nix
services.webhook.environment = {
  SLACK_WEBHOOK_URL = "https://hooks.slack.com/...";
  ENVIRONMENT = "production";
};
```

## Files Reference

- **`modules/webhook.nix`**: Webhook service configuration
- **`modules/caddy.nix`**: Caddy reverse proxy configuration
- **`modules/nixos-webhook.nix`**: NixOS webhook module (upstream)
- **`hosts/hypervisor/default.nix`**: Main configuration (enable services here)
- **`/var/log/webhook-deploy.log`**: Deployment logs
- **`/var/log/caddy/webhook-access.log`**: HTTP access logs

## Next Steps

After setting up webhooks, consider:

1. **Secrets management**: Use sops-nix or agenix for secret token
2. **Monitoring**: Set up alerts for failed deployments
3. **Backup**: Automate backups before deployments
4. **Testing**: Create staging environment for testing deployments
5. **Notifications**: Send Slack/Discord messages on deployments

## Support

- **Webhook documentation**: https://github.com/adnanh/webhook
- **Caddy documentation**: https://caddyserver.com/docs/
- **NixOS manual**: https://nixos.org/manual/nixos/stable/

## Security Disclosure

If you discover a security issue with this setup, please:
1. Do NOT open a public GitHub issue
2. Contact the maintainer privately
3. Allow time for a fix before disclosure
