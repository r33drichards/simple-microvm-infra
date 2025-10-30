#!/usr/bin/env bash
# Setup script for webhook configuration
# This script helps you configure the webhook system interactively

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

prompt() {
    echo -e "${GREEN}?${NC} $*"
}

# Banner
echo ""
echo "═══════════════════════════════════════════════"
echo "  Webhook Setup Assistant"
echo "  MicroVM Infrastructure Automated Deployment"
echo "═══════════════════════════════════════════════"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    warning "This script should NOT be run as root"
    warning "It will ask for sudo when needed"
    echo ""
fi

# Step 1: Check prerequisites
info "Step 1: Checking prerequisites..."

# Check if on hypervisor
if [ ! -f /etc/nixos/hardware-configuration.nix ]; then
    error "This doesn't appear to be a NixOS system"
    exit 1
fi

# Check for required tools
for cmd in openssl dig curl; do
    if ! command -v "$cmd" &> /dev/null; then
        error "Required command not found: $cmd"
        exit 1
    fi
done

success "Prerequisites checked"
echo ""

# Step 2: Domain configuration
info "Step 2: Domain Configuration"
echo ""

prompt "Enter your domain name for webhooks (e.g., webhooks.example.com):"
read -r DOMAIN

# Validate domain format
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?\.[a-zA-Z]{2,}$ ]]; then
    error "Invalid domain format"
    exit 1
fi

info "Checking DNS for $DOMAIN..."
if dig +short "$DOMAIN" | grep -q .; then
    IP=$(dig +short "$DOMAIN" | head -n 1)
    success "DNS resolves to: $IP"

    # Try to detect hypervisor IP
    HYPERVISOR_IP=$(curl -s ifconfig.me || echo "unknown")
    if [ "$IP" != "$HYPERVISOR_IP" ]; then
        warning "DNS points to $IP but hypervisor IP is $HYPERVISOR_IP"
        warning "You may need to update your DNS records"
    fi
else
    warning "DNS does not resolve yet for $DOMAIN"
    warning "You'll need to create an A record pointing to your hypervisor IP"
fi

echo ""

# Step 3: Email for Let's Encrypt
info "Step 3: Let's Encrypt Email"
echo ""

prompt "Enter email for Let's Encrypt certificate notifications:"
read -r EMAIL

if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error "Invalid email format"
    exit 1
fi

success "Email: $EMAIL"
echo ""

# Step 4: Generate secret token
info "Step 4: Secret Token Generation"
echo ""

prompt "Generate a new secret token? (y/n):"
read -r GEN_TOKEN

if [[ "$GEN_TOKEN" == "y" || "$GEN_TOKEN" == "Y" ]]; then
    SECRET_TOKEN=$(openssl rand -hex 32)
    success "Generated secret token:"
    echo ""
    echo "    $SECRET_TOKEN"
    echo ""
    warning "SAVE THIS TOKEN SECURELY!"
    warning "You'll need it for GitHub/GitLab webhook configuration"
    echo ""

    # Offer to save to file
    prompt "Save token to /root/webhook-secret? (requires sudo) (y/n):"
    read -r SAVE_TOKEN

    if [[ "$SAVE_TOKEN" == "y" || "$SAVE_TOKEN" == "Y" ]]; then
        echo -n "$SECRET_TOKEN" | sudo tee /root/webhook-secret > /dev/null
        sudo chmod 600 /root/webhook-secret
        success "Token saved to /root/webhook-secret"
        USE_FILE_TOKEN=true
    else
        USE_FILE_TOKEN=false
    fi
else
    prompt "Enter your existing secret token:"
    read -r SECRET_TOKEN
    USE_FILE_TOKEN=false
fi

echo ""

# Step 5: Infrastructure directory
info "Step 5: Infrastructure Directory"
echo ""

DEFAULT_DIR="/home/robertwendt/simple-microvm-infra"
prompt "Enter infrastructure directory path (default: $DEFAULT_DIR):"
read -r INFRA_DIR

if [ -z "$INFRA_DIR" ]; then
    INFRA_DIR="$DEFAULT_DIR"
fi

if [ ! -d "$INFRA_DIR" ]; then
    error "Directory does not exist: $INFRA_DIR"
    exit 1
fi

if [ ! -f "$INFRA_DIR/flake.nix" ]; then
    error "No flake.nix found in $INFRA_DIR"
    exit 1
fi

success "Infrastructure directory: $INFRA_DIR"
echo ""

# Step 6: Git branch
info "Step 6: Git Branch"
echo ""

DEFAULT_BRANCH="main"
prompt "Enter git branch to deploy from (default: $DEFAULT_BRANCH):"
read -r GIT_BRANCH

if [ -z "$GIT_BRANCH" ]; then
    GIT_BRANCH="$DEFAULT_BRANCH"
fi

success "Git branch: $GIT_BRANCH"
echo ""

# Step 7: Generate configuration
info "Step 7: Generating Configuration"
echo ""

CONFIG_FILE="$INFRA_DIR/hosts/hypervisor/default.nix"

if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Check if webhook config already exists
if grep -q "services.microvm-webhook" "$CONFIG_FILE"; then
    warning "Webhook configuration already exists in $CONFIG_FILE"
    prompt "Update configuration? (y/n):"
    read -r UPDATE_CONFIG

    if [[ "$UPDATE_CONFIG" != "y" && "$UPDATE_CONFIG" != "Y" ]]; then
        info "Skipping configuration update"
        exit 0
    fi
fi

# Create backup
BACKUP_FILE="$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
success "Created backup: $BACKUP_FILE"

# Generate new configuration snippet
TOKEN_CONFIG=""
if [ "$USE_FILE_TOKEN" = true ]; then
    TOKEN_CONFIG='builtins.readFile /root/webhook-secret'
else
    TOKEN_CONFIG="\"$SECRET_TOKEN\""
fi

cat << EOF

Configuration snippet to add to $CONFIG_FILE:

  # Webhook service for automated deployments
  services.microvm-webhook = {
    enable = true;
    infrastructureDir = "$INFRA_DIR";
    gitBranch = "$GIT_BRANCH";
    secretToken = $TOKEN_CONFIG;
    port = 9000;
  };

  # Caddy reverse proxy for webhook
  services.microvm-caddy = {
    enable = true;
    domain = "$DOMAIN";
    email = "$EMAIL";
    webhookPort = 9000;
  };

EOF

prompt "Add this configuration to $CONFIG_FILE? (y/n):"
read -r ADD_CONFIG

if [[ "$ADD_CONFIG" == "y" || "$ADD_CONFIG" == "Y" ]]; then
    info "Please manually update the configuration file:"
    info "1. Edit: $CONFIG_FILE"
    info "2. Add the configuration snippet shown above"
    info "3. Set services.microvm-caddy.enable = true"
    info "4. Update the domain, email, and other values"
    echo ""
    warning "Automated configuration update not implemented yet"
    warning "Please update manually and run: sudo nixos-rebuild switch --flake $INFRA_DIR#hypervisor"
fi

echo ""

# Step 8: Summary
info "Step 8: Setup Summary"
echo ""
echo "═══════════════════════════════════════════════"
echo "Domain:           $DOMAIN"
echo "Email:            $EMAIL"
echo "Infrastructure:   $INFRA_DIR"
echo "Git Branch:       $GIT_BRANCH"
echo "Token Saved:      $([ "$USE_FILE_TOKEN" = true ] && echo "/root/webhook-secret" || echo "No")"
echo "═══════════════════════════════════════════════"
echo ""

# Next steps
info "Next Steps:"
echo ""
echo "1. Update configuration file:"
echo "   sudo nvim $CONFIG_FILE"
echo ""
echo "2. Deploy configuration:"
echo "   cd $INFRA_DIR"
echo "   sudo nixos-rebuild switch --flake .#hypervisor"
echo ""
echo "3. Test webhook:"
echo "   curl https://$DOMAIN/hooks/health"
echo ""
echo "4. Configure GitHub webhook:"
echo "   URL: https://$DOMAIN/hooks/deploy?token=YOUR-TOKEN"
echo ""

success "Setup assistant complete!"
echo ""
