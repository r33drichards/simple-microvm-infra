# Webhook Setup Checklist

Quick reference for setting up the automated deployment webhook system.

## 📋 Information You Need to Provide

### 1. Domain Configuration

- [ ] **Domain Name**: `______________________________`
  - Example: `webhooks.yourdomain.com`
  - Must point to: `16.144.20.78` (your hypervisor's public IP)
  - Create DNS A record in your DNS provider

- [ ] **Email for Let's Encrypt**: `______________________________`
  - Example: `admin@yourdomain.com`
  - Used for certificate expiration notifications

### 2. Security

- [ ] **Secret Token**: `______________________________`
  - Generate with: `openssl rand -hex 32`
  - Example: `a1b2c3d4e5f6...` (64 characters)
  - Keep this PRIVATE - it's your webhook password

### 3. Repository Configuration

- [ ] **Infrastructure Directory Path**: `______________________________`
  - Current path: `/home/robertwendt/simple-microvm-infra`
  - Verify on hypervisor: `ls -la /home/robertwendt/simple-microvm-infra`

- [ ] **Git Branch**: `______________________________`
  - Default: `main`
  - Could be: `master`, `production`, `develop`, etc.

### 4. Optional: IP Allowlist

- [ ] **Restrict to specific IPs?**: Yes / No
  - If Yes, list IPs or CIDR ranges:
    - `______________________________`
    - `______________________________`
    - `______________________________`
  - GitHub webhook IPs: https://api.github.com/meta
  - Example: `192.30.252.0/22`, `185.199.108.0/22`

## 🔧 Configuration Steps

### Step 1: DNS Setup
```bash
# Create DNS A Record:
# Type: A
# Name: webhooks (or your subdomain)
# Value: 16.144.20.78
# TTL: 300

# Verify DNS propagation:
dig webhooks.yourdomain.com
# or
nslookup webhooks.yourdomain.com
```

### Step 2: Generate Secret Token
```bash
openssl rand -hex 32
# Save the output - you'll need it!
```

### Step 3: Update Configuration File

Edit `hosts/hypervisor/default.nix` (around line 194):

```nix
  services.microvm-webhook = {
    enable = true;
    infrastructureDir = "/home/robertwendt/simple-microvm-infra"; # ← Verify
    gitBranch = "main"; # ← Update if needed
    secretToken = "PASTE-YOUR-SECRET-TOKEN-HERE"; # ← Paste token from Step 2
    port = 9000;
  };

  services.microvm-caddy = {
    enable = true; # ← Change from false to true
    domain = "webhooks.yourdomain.com"; # ← Your domain from Step 1
    email = "admin@yourdomain.com"; # ← Your email for Let's Encrypt
    webhookPort = 9000;
  };
```

### Step 4: Deploy

```bash
# On the hypervisor:
cd /home/robertwendt/simple-microvm-infra

# Deploy the changes
sudo nixos-rebuild switch --flake .#hypervisor

# Verify services are running
sudo systemctl status webhook
sudo systemctl status caddy
```

### Step 5: Test

```bash
# Test health check (no auth needed)
curl https://webhooks.yourdomain.com/hooks/health

# Test deployment (replace with your token)
curl "https://webhooks.yourdomain.com/hooks/deploy?token=YOUR-SECRET-TOKEN"

# Check logs
sudo tail -f /var/log/webhook-deploy.log
```

## 🔗 Webhook Endpoints

After setup, your webhook endpoints will be:

### Health Check
```
https://webhooks.yourdomain.com/hooks/health
```

### Deploy (GitHub/GitLab webhook URL)
```
https://webhooks.yourdomain.com/hooks/deploy?token=YOUR-SECRET-TOKEN
```

### Rebuild Only
```
https://webhooks.yourdomain.com/hooks/rebuild?token=YOUR-SECRET-TOKEN
```

## 📝 GitHub Webhook Setup

1. Go to your GitHub repository
2. Settings → Webhooks → Add webhook
3. Configure:
   - **Payload URL**: `https://webhooks.yourdomain.com/hooks/deploy?token=YOUR-SECRET-TOKEN`
   - **Content type**: `application/json`
   - **Events**: Just the push event
   - **Active**: ✅
4. Save and test!

## 🔒 Security Best Practices

- ✅ Always use HTTPS (never HTTP)
- ✅ Keep secret token private
- ✅ Use strong random token (32+ bytes)
- ✅ Consider IP allowlist for production
- ✅ Monitor deployment logs regularly
- ✅ Rotate tokens periodically

## 📊 Monitoring Commands

```bash
# Watch deployment logs
sudo tail -f /var/log/webhook-deploy.log

# Check webhook service
sudo systemctl status webhook
sudo journalctl -u webhook -f

# Check Caddy
sudo systemctl status caddy
sudo journalctl -u caddy -f

# View access logs
sudo tail -f /var/log/caddy/webhook-access.log
```

## ⚠️ Troubleshooting

| Issue | Solution |
|-------|----------|
| Certificate not provisioning | Wait 5-10 minutes for DNS propagation |
| 502 Bad Gateway | Check `sudo systemctl status webhook` |
| Webhook not responding | Verify domain points to `16.144.20.78` |
| Permission denied | Webhook runs as root, check logs |
| Deployment hanging | Check lock file: `/var/run/deploy.lock` |

## 📚 Documentation

- Full setup guide: `WEBHOOK_SETUP.md`
- Architecture docs: `CLAUDE.md`
- Development workflow: `DEVELOPMENT.md`

## ✅ Post-Setup Verification

After completing setup, verify:

- [ ] DNS points to hypervisor IP
- [ ] HTTPS certificate is valid
- [ ] Health check endpoint responds
- [ ] Deployment endpoint requires token
- [ ] GitHub/GitLab webhook delivers successfully
- [ ] Deployments appear in logs
- [ ] Services auto-restart on failure

## 🎉 You're Done!

Your infrastructure now has automated deployments! Every time you push to your repository, GitHub will trigger a webhook that:

1. Pulls latest code
2. Rebuilds the hypervisor configuration
3. Logs everything to `/var/log/webhook-deploy.log`

Monitor your first few deployments to ensure everything works smoothly!
