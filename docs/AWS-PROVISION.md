# AWS Provisioning Guide

This guide explains how to provision the a1.metal instance and deploy the MicroVM infrastructure from scratch using AWS CLI.

## Prerequisites

- AWS CLI configured with credentials
- Access to us-west-2 region
- SSH key pair (we'll create this)

## Step 1: Create SSH Key Pair

```bash
# Create a new SSH key pair
aws ec2 create-key-pair \
  --key-name "bm-nixos-us-west-2" \
  --query 'KeyMaterial' \
  --output text > bm-nixos-us-west-2.pem

# Set proper permissions
chmod 400 bm-nixos-us-west-2.pem
```

## Step 2: Configure Security Group

```bash
# Get the default security group ID
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

# Add SSH access if not already present
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 2>/dev/null || echo "SSH rule already exists"
```

## Step 3: Create IAM Role for EBS Management

The hypervisor needs IAM permissions to manage EBS volumes. Run the setup script:

```bash
# From the repo directory
./scripts/setup-hypervisor-iam.sh

# Or specify instance ID after creation:
./scripts/setup-hypervisor-iam.sh $INSTANCE_ID
```

This creates:
- IAM Role: `hypervisor-ebs-role`
- IAM Policy: `hypervisor-ebs-policy` (allows EC2 volume operations)
- Instance Profile: `hypervisor-instance-profile`

## Step 4: Launch a1.metal Instance with NixOS

```bash
# Latest NixOS 25.05 ARM64 AMI (us-west-2)
AMI_ID="ami-07b24968bfc18907e"

# Get default subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Launch instance with 50GB root volume and IAM profile
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type a1.metal \
  --key-name "bm-nixos-us-west-2" \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --security-group-ids $SG_ID \
  --iam-instance-profile Name=hypervisor-instance-profile \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bmnix}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
echo "SSH command: ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP"
```

## Step 5: Wait for Instance to Boot

```bash
# Wait additional time for SSH to be ready
echo "Waiting 60 seconds for SSH to be ready..."
sleep 60

# Test SSH connection
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -i bm-nixos-us-west-2.pem root@$PUBLIC_IP "echo 'SSH connection successful'"
```

## Step 6: Deploy NixOS Configuration

The nixos-rebuild can take 10-20 minutes (compiles QEMU). Run it with nohup so it survives SSH disconnection:

```bash
# Install git and clone repo
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP << 'EOF'
nix --extra-experimental-features "nix-command flakes" profile install nixpkgs#git
git clone https://github.com/r33drichards/simple-microvm-infra.git
EOF

# Start build in background with nohup (survives SSH disconnect)
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP \
  'cd /root/simple-microvm-infra && nohup nixos-rebuild switch --flake .#hypervisor > /tmp/rebuild.log 2>&1 &'

# Poll for completion (can disconnect and reconnect)
echo "Build started. Polling for completion..."
while ssh -i bm-nixos-us-west-2.pem -o ConnectTimeout=5 root@$PUBLIC_IP \
  'pgrep nixos-rebuild > /dev/null' 2>/dev/null; do
  echo "$(date): Still building..."
  ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP 'tail -1 /tmp/rebuild.log' 2>/dev/null
  sleep 60
done

# Check result
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP 'tail -20 /tmp/rebuild.log'
```

## Step 7: Complete MicroVM Setup

```bash
# SSH and complete the setup
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP << 'EOF'
cd simple-microvm-infra

# Storage directories are created automatically by systemd tmpfiles
# Verify they exist
ls -la /var/lib/microvms/

# Start VMs
microvm -u vm1 vm2 vm3 vm4 vm5

# Configure Tailscale
tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24,10.5.0.0/24
EOF

echo "Setup complete! Remember to approve Tailscale routes in admin console."
```

## Agent Context Management

When using Claude Code or other AI agents for provisioning, these techniques prevent context overflow and handle long-running operations:

### 1. Use nohup for Long Builds

Long builds (nixos-rebuild, nix build) should run with nohup so they survive SSH disconnection:

```bash
# Bad: blocks agent, context fills up, killed on disconnect
ssh root@$IP 'nixos-rebuild switch --flake .#hypervisor'

# Good: runs independently, poll for completion
ssh root@$IP 'nohup nixos-rebuild switch --flake .#hypervisor > /tmp/rebuild.log 2>&1 &'
```

### 2. Poll Log Files Instead of Streaming

Instead of streaming output that fills context, poll periodically:

```bash
# Check if still running
ssh root@$IP 'pgrep nixos-rebuild > /dev/null' && echo "Still building..."

# Get last line of progress
ssh root@$IP 'tail -1 /tmp/rebuild.log'

# Get full output only when done
ssh root@$IP 'tail -50 /tmp/rebuild.log'
```

### 3. Use EC2 Console Output for Boot Diagnostics

When SSH is unreachable, check boot status via AWS API (doesn't require SSH):

```bash
# Check instance status
aws ec2 describe-instance-status --instance-ids $INSTANCE_ID \
  --query 'InstanceStatuses[0].{Instance:InstanceStatus.Status,System:SystemStatus.Status}'

# Get console output (boot logs)
aws ec2 get-console-output --instance-id $INSTANCE_ID \
  --query 'Output' --output text | tail -50
```

### 4. Keep Commands Idempotent

Design commands to be safely re-runnable after interruption:

```bash
# Idempotent: won't fail if already exists
git clone https://... || (cd repo && git pull)
mkdir -p /var/lib/microvms

# Idempotent: checks before acting
pgrep nixos-rebuild || nohup nixos-rebuild switch ... &
```

### 5. Split Long Operations

Break multi-step operations into separate SSH calls:

```bash
# Step 1: Install prerequisites (fast)
ssh root@$IP 'nix profile install nixpkgs#git'

# Step 2: Clone repo (fast)
ssh root@$IP 'git clone https://...'

# Step 3: Build (slow, use nohup)
ssh root@$IP 'nohup nixos-rebuild ... &'

# Step 4: Poll until done
# Step 5: Verify
```

## Troubleshooting

### SSH Connection Issues

If you lose SSH connectivity:
1. Check security group rules allow SSH (port 22)
2. Verify instance is running: `aws ec2 describe-instances --instance-ids $INSTANCE_ID`
3. Check console output: `aws ec2 get-console-output --instance-id $INSTANCE_ID --query 'Output' --output text | tail -100`

### Instance Won't Boot

If the instance won't boot after nixos-rebuild:
1. Terminate the instance
2. Start over from Step 3
3. Check the configuration for syntax errors before deploying

## Cleanup

To delete all resources:

```bash
# Terminate instance
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# Delete key pair
aws ec2 delete-key-pair --key-name "bm-nixos-us-west-2"
rm bm-nixos-us-west-2.pem
```

## Next Steps

After successful deployment:
1. Configure Tailscale subnet routing
2. Test VM connectivity
3. Deploy applications to VMs
4. Set up monitoring and backups

See [DEPLOYMENT.md](DEPLOYMENT.md) for application deployment guide.
