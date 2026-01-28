# Docker & AWS Deployment Guide

This guide walks you through containerizing the Reversi Game Engine and deploying it to AWS.

## Prerequisites

- Docker installed locally
- AWS CLI installed and configured
- AWS Account with ECR (Elastic Container Registry) access
- GitHub Actions enabled for your repository

## Local Testing

### Build Docker Image Locally

```bash
docker build -t reversi-game-engine:latest .
```

### Run Container Locally

```bash
docker run -p 9000:9000 \
  -e PLAY_SECRET="your-secret-key" \
  reversi-game-engine:latest
```

The API will be available at `http://localhost:9000`

### Test Health Check

```bash
curl http://localhost:9000/health
```

## AWS Setup

### Step 1: Create OpenID Connect Identity Provider

This enables GitHub Actions to authenticate with AWS without storing credentials.

#### Via AWS Console:

1. Go to [AWS IAM → Identity Providers](https://console.aws.amazon.com/iamv2/home#/idps)
2. Click **"Add provider"**
3. Select **"OpenID Connect"**
4. Fill in:
   - **Provider URL**: `https://token.actions.githubusercontent.com`
   - **Audience**: `sts.amazonaws.com`
5. Click **"Add provider"**

#### Via AWS CLI:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

### Step 2: Create GitHub Actions Deploy Role

This role allows GitHub Actions to push Docker images to ECR.

#### Via AWS Console:

1. Go to [AWS IAM → Roles → Create role](https://console.aws.amazon.com/iamv2/home#/roles/create)
2. Select **"Web identity"** as trusted entity type
3. For Identity provider:
   - Select **"token.actions.githubusercontent.com"** from dropdown
   - Audience: **`sts.amazonaws.com`**
4. Click **"Next"**
5. Search for and attach policy: **`AmazonEC2ContainerRegistryFullAccess`**
   - (Note: If this policy doesn't exist, use the custom policy below)
6. Click **"Next"**
7. Name: **`GitHubActionsDeployRole`**
8. Click **"Create role"**
9. Copy the **ARN** from the role summary (you'll need this in Step 4)

#### Custom Policy (If Full Access Not Available)

If `AmazonEC2ContainerRegistryFullAccess` is not available, create a custom inline policy with the following:

1. After creating the role in Step 2, click on **`GitHubActionsDeployRole`**
2. Go to **"Add permissions"** → **"Create inline policy"**
3. Choose **"JSON"** and paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories"
      ],
      "Resource": "*"
    }
  ]
}
```

4. Click **"Review policy"**
5. Name: `GitHubActionsECRPushPolicy`
6. Click **"Create policy"**

#### Via AWS CLI:

```bash
# Create the role
aws iam create-role \
  --role-name GitHubActionsDeployRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          },
          "StringLike": {
            "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<REPO_NAME>:*"
          }
        }
      }
    ]
  }'

# Attach ECR full access permissions
aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
```
aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPushOnly

# Get the role ARN
aws iam get-role --role-name GitHubActionsDeployRole --query 'Role.Arn' --output text
```

### Step 3: Set Up AWS Infrastructure

Before your first deployment, run the infrastructure setup script:

```bash
chmod +x aws/setup-aws-infrastructure.sh
./aws/setup-aws-infrastructure.sh
```

This script will:
- Create an ECR repository
- Set up CloudWatch Logs groups
- Create necessary IAM roles
- Create an ECS cluster
- Set up security groups

### Step 4: Configure GitHub Actions

Add only **one** secret to your GitHub repository (Settings → Secrets and Variables → Actions):

1. **AWS_ACCOUNT_ID** - Your AWS account ID (12-digit number)
   - Value: `626635407319`

That's it! The workflow will automatically construct the role ARN as:
```
arn:aws:iam::<AWS_ACCOUNT_ID>:role/GitHubActionsDeployRole
```

### Step 5: Update Task Definition

Edit `aws/ecs-task-definition.json.template` and replace:
- `<AWS_ACCOUNT_ID>` with your actual AWS account ID (from Step 4)
- Update environment variables as needed

### Step 6: Deploy to AWS

#### Option A: Automatic Deployment (GitHub Actions)

1. Push to `master`, `main`, or `develop` branch
2. GitHub Actions will automatically:
   - Build the Docker image
   - Push to ECR
   - (Optional) Deploy to ECS

#### Option B: Manual Deployment

```bash
# Authenticate with ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Build and tag image
docker build -t reversi-game-engine:latest .
docker tag reversi-game-engine:latest \
  <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/reversi-game-engine:latest

# Push to ECR
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/reversi-game-engine:latest

# Register task definition
aws ecs register-task-definition \
  --cli-input-json file://aws/ecs-task-definition.json

# Create service (first time only)
aws ecs create-service \
  --cluster reversi-cluster \
  --service-name reversi-game-engine-service \
  --task-definition reversi-game-engine:1 \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx],securityGroups=[sg-xxxxx],assignPublicIp=ENABLED}" \
  --region us-east-1

# Update existing service
aws ecs update-service \
  --cluster reversi-cluster \
  --service reversi-game-engine-service \
  --task-definition reversi-game-engine:2 \
  --region us-east-1
```

## Environment Configuration

### Production Environment Variables

In your ECS task definition, set:

- `PLAY_SECRET` - Application secret key (use AWS Secrets Manager in production)
- `DATABASE_URL` - PostgreSQL connection string (if using database)
- `JAVA_OPTS` - JVM options (e.g., `-Xmx512m`)

Example for using AWS Secrets Manager:

```json
"secrets": [
  {
    "name": "PLAY_SECRET",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:play-secret"
  }
]
```

## Custom Domain Setup (Optional)

To access your API via a custom domain (e.g., `https://www.reversi-game-engine.com`):

### Automated Setup

Run the domain and ALB setup script:

```bash
chmod +x aws/setup-domain-and-alb.sh
./aws/setup-domain-and-alb.sh reversi-game-engine.com reversi-game-engine us-east-1
```

**Parameters:**
- `reversi-game-engine.com` - Your domain name
- `reversi-game-engine` - Repository/service name (matches ECR repo)
- `us-east-1` - AWS region

This script will automatically:
✅ Create security group for ALB
✅ Create Application Load Balancer
✅ Create target group (points to port 9000)
✅ Request SSL certificate in ACM
✅ Create Route53 hosted zone
✅ Add DNS records for your domain
✅ Create HTTPS listener (with HTTP → HTTPS redirect)
✅ Update ECS service to use ALB

### Manual Setup (If Preferred)

If you prefer to set up manually, follow these steps:

#### Step 1: Register a Domain

- Register your domain with Route 53, GoDaddy, Namecheap, or any registrar
- Example: `reversi-game-engine.com`

#### Step 2: Create Application Load Balancer

```bash
# Create security group for ALB
aws ec2 create-security-group \
  --group-name reversi-alb-sg \
  --description "Security group for Reversi ALB" \
  --region us-east-1

# Get the security group ID and allow HTTP/HTTPS
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=reversi-alb-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region us-east-1

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 \
  --region us-east-1

# Create Application Load Balancer
aws elbv2 create-load-balancer \
  --name reversi-alb \
  --subnets subnet-xxxxx subnet-yyyyy \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --region us-east-1
```

#### Step 3: Create SSL Certificate (ACM)

```bash
# Request SSL certificate for your domain
aws acm request-certificate \
  --domain-name reversi-game-engine.com \
  --subject-alternative-names "*.reversi-game-engine.com" \
  --validation-method DNS \
  --region us-east-1
```

Then validate the certificate via DNS records in Route 53.

#### Step 4: Create Target Group

```bash
# Create target group for ECS tasks
aws elbv2 create-target-group \
  --name reversi-targets \
  --protocol HTTP \
  --port 9000 \
  --vpc-id vpc-xxxxx \
  --target-type ip \
  --region us-east-1
```

#### Step 5: Register DNS in Route 53

```bash
# Create hosted zone for your domain (or use existing)
aws route53 create-hosted-zone \
  --name reversi-game-engine.com \
  --caller-reference $(date +%s)

# Get hosted zone ID
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name reversi-game-engine.com \
  --query 'HostedZones[0].Id' \
  --output text | cut -d'/' -f3)

# Create A record pointing to ALB
aws route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "www.reversi-game-engine.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "reversi-alb-xxxxx.us-east-1.elb.amazonaws.com",
          "EvaluateTargetHealth": false
        }
      }
    }]
  }'
```

#### Step 6: Add ALB Listener

```bash
# Get ALB ARN
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names reversi-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

# Get target group ARN
TG_ARN=$(aws elbv2 describe-target-groups \
  --names reversi-targets \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# Create HTTPS listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=arn:aws:acm:us-east-1:<AWS_ACCOUNT_ID>:certificate/xxxxx \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --region us-east-1
```

#### Step 7: Update ECS Service to Use ALB

When creating your ECS service, add load balancer configuration:

```bash
aws ecs create-service \
  --cluster reversi-cluster \
  --service-name reversi-game-engine-service \
  --task-definition reversi-game-engine \
  --desired-count 1 \
  --launch-type FARGATE \
  --load-balancers targetGroupArn=$TG_ARN,containerName=reversi-game-engine,containerPort=9000 \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx],securityGroups=[sg-xxxxx],assignPublicIp=ENABLED}" \
  --region us-east-1
```

### Access Your API

After setup and DNS propagation (5-10 minutes):

```
https://www.reversi-game-engine.com
```

## Monitoring & Logging

### CloudWatch Logs

View logs in CloudWatch:

```bash
aws logs tail /ecs/reversi-game-engine --follow
```

### ECS Service Status

```bash
aws ecs describe-services \
  --cluster reversi-cluster \
  --services reversi-game-engine-service \
  --region us-east-1
```

## Scaling

### Update desired count

```bash
aws ecs update-service \
  --cluster reversi-cluster \
  --service reversi-game-engine-service \
  --desired-count 3 \
  --region us-east-1
```

### Auto Scaling (Optional)

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/reversi-cluster/reversi-game-engine-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 4 \
  --region us-east-1

# Create scaling policy
aws application-autoscaling put-scaling-policy \
  --policy-name reversi-scale-policy \
  --service-namespace ecs \
  --resource-id service/reversi-cluster/reversi-game-engine-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file:///dev/stdin <<EOF
{
  "TargetValue": 70.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
EOF
```

## Troubleshooting

### Container won't start

```bash
# Check task status
aws ecs describe-tasks \
  --cluster reversi-cluster \
  --tasks <TASK_ARN> \
  --region us-east-1

# View logs
aws logs get-log-events \
  --log-group-name /ecs/reversi-game-engine \
  --log-stream-name <STREAM_NAME>
```

### Image not found in ECR

```bash
# List repositories
aws ecr describe-repositories

# List images in repository
aws ecr list-images --repository-name reversi-game-engine
```

## Cleanup

### Delete service

```bash
aws ecs delete-service \
  --cluster reversi-cluster \
  --service reversi-game-engine-service \
  --force \
  --region us-east-1
```

### Delete cluster

```bash
aws ecs delete-cluster --cluster reversi-cluster --region us-east-1
```

### Delete ECR repository (and images)

```bash
aws ecr delete-repository \
  --repository-name reversi-game-engine \
  --force \
  --region us-east-1
```

## Additional Resources

- [Docker Documentation](https://docs.docker.com/)
- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS ECR Documentation](https://docs.aws.amazon.com/ecr/)
- [Play Framework Deployment](https://www.playframework.com/documentation/latest/Deploying)
- [Scala SBT Docker Plugin](https://sbt-native-packager.readthedocs.io/en/latest/)
