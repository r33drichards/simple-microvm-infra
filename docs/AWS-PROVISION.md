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

## Step 3: Launch a1.metal Instance with NixOS

```bash
# Latest NixOS 25.05 ARM64 AMI (us-west-2)
AMI_ID="ami-07b24968bfc18907e"

# Get default subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Launch instance with 30GB root volume
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type a1.metal \
  --key-name "bm-nixos-us-west-2" \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
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

## Step 4: Wait for Instance to Boot

```bash
# Wait additional time for SSH to be ready
echo "Waiting 60 seconds for SSH to be ready..."
sleep 60

# Test SSH connection
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -i bm-nixos-us-west-2.pem root@$PUBLIC_IP "echo 'SSH connection successful'"
```

## Step 5: Deploy NixOS Configuration

```bash
# SSH into the instance and deploy
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP << 'EOF'
# Install git
nix --extra-experimental-features "nix-command flakes" profile install nixpkgs#git

# Clone repository
git clone https://github.com/r33drichards/simple-microvm-infra.git
cd simple-microvm-infra

# Deploy hypervisor configuration
nixos-rebuild switch --flake .#hypervisor

echo "Configuration deployed successfully!"
EOF
```

## Step 6: Complete MicroVM Setup

```bash
# SSH and complete the setup
ssh -i bm-nixos-us-west-2.pem root@$PUBLIC_IP << 'EOF'
cd simple-microvm-infra

# Storage directories are created automatically by systemd tmpfiles
# Verify they exist
ls -la /var/lib/microvms/

# Start VMs
microvm -u vm1 vm2 vm3 vm4

# Configure Tailscale
tailscale up --advertise-routes=10.1.0.0/24,10.2.0.0/24,10.3.0.0/24,10.4.0.0/24
EOF

echo "Setup complete! Remember to approve Tailscale routes in admin console."
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
