#!/usr/bin/env bash
# Idempotent script to create IAM role for hypervisor EBS volume management
# Usage: ./setup-hypervisor-iam.sh [INSTANCE_ID]
#
# If INSTANCE_ID is not provided, attempts to detect from EC2 instance metadata.

set -euo pipefail

ROLE_NAME="hypervisor-ebs-role"
POLICY_NAME="hypervisor-ebs-policy"
INSTANCE_PROFILE_NAME="hypervisor-instance-profile"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get instance ID from argument or metadata
if [[ "${1:-}" != "" ]]; then
    INSTANCE_ID="$1"
    log_info "Using provided instance ID: $INSTANCE_ID"
else
    log_info "Detecting instance ID from metadata..."
    # Try IMDSv2 first
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)

    if [[ -n "$TOKEN" ]]; then
        INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
    fi

    # Fallback to IMDSv1
    if [[ -z "${INSTANCE_ID:-}" ]]; then
        INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
    fi

    if [[ -z "${INSTANCE_ID:-}" ]]; then
        log_error "Could not detect instance ID. Please provide it as an argument."
        echo "Usage: $0 <instance-id>"
        exit 1
    fi
    log_info "Detected instance ID: $INSTANCE_ID"
fi

# Get region from instance
REGION=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text | sed 's/.$//')
log_info "Region: $REGION"

# EBS policy document
EBS_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EBSVolumeManagement",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:CreateVolume",
                "ec2:DeleteVolume",
                "ec2:AttachVolume",
                "ec2:DetachVolume",
                "ec2:ModifyVolume",
                "ec2:DescribeVolumeStatus",
                "ec2:DescribeVolumeAttribute",
                "ec2:CreateTags",
                "ec2:DescribeTags",
                "ec2:DescribeInstances"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

# EC2 trust policy for the role
TRUST_POLICY=$(cat <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

# Step 1: Create or update IAM policy
log_info "Creating/updating IAM policy: $POLICY_NAME"
POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME"

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
    log_info "Policy exists, creating new version..."
    # Delete oldest version if we have 5 versions (AWS limit)
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    VERSION_COUNT=$(echo "$VERSIONS" | wc -w)
    if [[ "$VERSION_COUNT" -ge 4 ]]; then
        OLDEST=$(echo "$VERSIONS" | awk '{print $NF}')
        log_warn "Deleting oldest policy version: $OLDEST"
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
        --policy-document "$EBS_POLICY" --set-as-default >/dev/null
else
    log_info "Creating new policy..."
    aws iam create-policy --policy-name "$POLICY_NAME" \
        --policy-document "$EBS_POLICY" >/dev/null
fi
log_info "Policy ready: $POLICY_ARN"

# Step 2: Create IAM role if it doesn't exist
log_info "Creating/verifying IAM role: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    log_info "Role already exists"
else
    log_info "Creating new role..."
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

# Step 3: Attach policy to role
log_info "Attaching policy to role..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

# Step 4: Create instance profile if it doesn't exist
log_info "Creating/verifying instance profile: $INSTANCE_PROFILE_NAME"
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    log_info "Instance profile already exists"
else
    log_info "Creating new instance profile..."
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
fi

# Step 5: Add role to instance profile (if not already added)
log_info "Adding role to instance profile..."
EXISTING_ROLE=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_ROLE" == "$ROLE_NAME" ]]; then
    log_info "Role already attached to instance profile"
elif [[ "$EXISTING_ROLE" != "None" && "$EXISTING_ROLE" != "" ]]; then
    log_warn "Different role attached ($EXISTING_ROLE), removing..."
    aws iam remove-role-from-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$EXISTING_ROLE"
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
else
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
fi

# Step 6: Associate instance profile with EC2 instance
log_info "Associating instance profile with instance: $INSTANCE_ID"

# Check current association
CURRENT_PROFILE=$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query 'IamInstanceProfileAssociations[0]' --output json 2>/dev/null || echo "{}")

CURRENT_PROFILE_NAME=$(echo "$CURRENT_PROFILE" | jq -r '.IamInstanceProfile.Arn // empty' | sed 's|.*/||')
ASSOCIATION_ID=$(echo "$CURRENT_PROFILE" | jq -r '.AssociationId // empty')

if [[ "$CURRENT_PROFILE_NAME" == "$INSTANCE_PROFILE_NAME" ]]; then
    log_info "Instance profile already associated with instance"
elif [[ -n "$ASSOCIATION_ID" ]]; then
    log_warn "Different profile associated, replacing..."
    aws ec2 replace-iam-instance-profile-association \
        --association-id "$ASSOCIATION_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" >/dev/null
else
    log_info "Attaching instance profile to instance..."
    # Wait a moment for IAM to propagate
    sleep 5
    aws ec2 associate-iam-instance-profile \
        --instance-id "$INSTANCE_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" >/dev/null
fi

log_info "Waiting for IAM credentials to propagate (this may take up to 60 seconds)..."
sleep 10

echo ""
log_info "Setup complete!"
echo ""
echo "IAM Role:          $ROLE_NAME"
echo "IAM Policy:        $POLICY_NAME"
echo "Instance Profile:  $INSTANCE_PROFILE_NAME"
echo "Instance ID:       $INSTANCE_ID"
echo ""
echo "The instance now has permissions for EBS volume management."
echo "You may need to restart the ebs-volume service:"
echo "  ssh root@<hypervisor> 'systemctl restart ebs-volume-microvm-storage'"
