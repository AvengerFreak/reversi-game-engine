#!/bin/bash

set -e

# Configuration
AWS_REGION="${2}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY_NAME="${1}"
ECS_CLUSTER_NAME="$ECR_REPOSITORY_NAME-cluster"
ECS_SERVICE_NAME="$ECR_REPOSITORY_NAME-service"
CONTAINER_PORT=${3}

echo "Setting up AWS infrastructure..."
echo "AWS Region: $AWS_REGION"

# 1. Create ECR Repository if it doesn't exist
echo "1. Creating ECR repository..."
aws ecr describe-repositories \
  --repository-names $ECR_REPOSITORY_NAME \
  --region $AWS_REGION 2>/dev/null || \
aws ecr create-repository \
  --repository-name $ECR_REPOSITORY_NAME \
  --region $AWS_REGION \
  --encryption-configuration encryptionType=AES

echo "ECR repository created/exists"

# 2. Create CloudWatch Logs Group
echo "2. Creating CloudWatch Logs Group..."
aws logs create-log-group \
  --log-group-name /ecs/$ECR_REPOSITORY_NAME \
  --region $AWS_REGION 2>/dev/null || echo "Log group already exists"

# 3. Create IAM roles
echo "3. Setting up IAM roles..."

# Create trust policy for ECS tasks
cat > /tmp/ecs-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create ecsTaskExecutionRole if it doesn't exist
echo "Creating ecsTaskExecutionRole..."
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file:///tmp/ecs-trust-policy.json 2>/dev/null || echo "Role already exists"

# Attach execution policy
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || echo "Policy already attached"

# Create ecsTaskRole if it doesn't exist
echo "Creating ecsTaskRole..."
aws iam create-role \
  --role-name ecsTaskRole \
  --assume-role-policy-document file:///tmp/ecs-trust-policy.json 2>/dev/null || echo "Role already exists"

# 4. Create ECS Cluster
echo "4. Creating ECS Cluster..."
aws ecs create-cluster \
  --cluster-name $ECS_CLUSTER_NAME \
  --region $AWS_REGION \
  --cluster-settings name=containerInsights,value=enabled 2>/dev/null || echo "Cluster already exists"

# 5. Create VPC security group (if needed)
echo "5. Setting up security group..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=$ECR_REPOSITORY_NAME-sg \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name $ECR_REPOSITORY_NAME-sg \
    --description "Security group for $ECR_REPOSITORY_NAME" \
    --vpc-id $VPC_ID \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text)
  
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port $CONTAINER_PORT \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION
  
  echo "Security group created: $SG_ID"
else
  echo "Security group already exists: $SG_ID"
fi

# 6. Get default subnets
echo "6. Retrieving VPC configuration..."
SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[*].SubnetId' \
  --output text --region $AWS_REGION)

echo ""
echo "✅ AWS Infrastructure Setup Complete!"
echo ""
echo "Summary:"
echo "- ECR Repository: $ECR_REPOSITORY_NAME"
echo "- ECS Cluster: $ECS_CLUSTER_NAME"
echo "- Region: $AWS_REGION"
echo "- VPC: $VPC_ID"
echo "- Security Group: $SG_ID"
echo "- Subnets: $SUBNETS"
echo ""
echo "Next steps:"
echo "1. Update aws/ecs-task-definition.json with your AWS_ACCOUNT_ID"
echo "2. Register the task definition: aws ecs register-task-definition --cli-input-json file://aws/ecs-task-definition.json"
echo "3. Create an ECS service with the task definition"
echo ""
