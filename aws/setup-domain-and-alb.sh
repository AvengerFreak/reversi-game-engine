#!/bin/bash

set -e

# ============================================================================
# Domain and ALB Setup Script
# Automates creation of Application Load Balancer with custom domain
# ============================================================================

# Configuration
DOMAIN_NAME="${1}"
REPO_NAME="${2}"
AWS_REGION="${3}"
CONTAINER_PORT="${4}"

# Derived names
WWW_DOMAIN="www.${DOMAIN_NAME}"
ALB_NAME="${REPO_NAME}-alb"
ALB_SG_NAME="${REPO_NAME}-alb-sg"
TARGET_GROUP_NAME="${REPO_NAME}-targets"
CLUSTER_NAME="${REPO_NAME}-cluster"
SERVICE_NAME="${REPO_NAME}-service"

echo "============================================================================"
echo "Domain and ALB Setup Script"
echo "============================================================================"
echo "Domain: $DOMAIN_NAME"
echo "Repo/Service: $REPO_NAME"
echo "AWS Region: $AWS_REGION"
echo "============================================================================"

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Get VPC ID (using default VPC)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "❌ No default VPC found. Please create a VPC or provide one."
  exit 1
fi
echo "VPC ID: $VPC_ID"

# Get availability zones and subnets
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $AWS_REGION)
SUBNET_ARRAY=($SUBNETS)
if [ ${#SUBNET_ARRAY[@]} -lt 2 ]; then
  echo "❌ Need at least 2 subnets for ALB. Found: ${#SUBNET_ARRAY[@]}"
  exit 1
fi
echo "Subnets: ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]}"

# ============================================================================
# 1. Create Security Group for ALB
# ============================================================================
echo ""
echo "1️⃣  Creating Security Group for ALB..."
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name $ALB_SG_NAME \
    --description "Security group for $REPO_NAME ALB" \
    --vpc-id $VPC_ID \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text)
  echo "✅ Created Security Group: $ALB_SG_ID"
else
  echo "✅ Security Group exists: $ALB_SG_ID"
fi

# Allow HTTP and HTTPS
echo "   Adding ingress rules (HTTP/HTTPS)..."
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region $AWS_REGION 2>/dev/null || echo "   HTTP rule already exists"

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 \
  --region $AWS_REGION 2>/dev/null || echo "   HTTPS rule already exists"

# ============================================================================
# 2. Create Application Load Balancer
# ============================================================================
echo ""
echo "2️⃣  Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names $ALB_NAME \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name $ALB_NAME \
    --subnets ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]} \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --region $AWS_REGION \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
  echo "✅ Created ALB: $ALB_ARN"
  sleep 10
else
  echo "✅ ALB exists: $ALB_ARN"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)
echo "   ALB DNS: $ALB_DNS"

# ============================================================================
# 3. Create Target Group
# ============================================================================
echo ""
echo "3️⃣  Creating Target Group..."
TG_ARN=$(aws elbv2 describe-target-groups \
  --names $TARGET_GROUP_NAME \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name $TARGET_GROUP_NAME \
    --protocol HTTP \
    --port $CONTAINER_PORT \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-enabled \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region $AWS_REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
  echo "✅ Created Target Group: $TG_ARN"
else
  echo "✅ Target Group exists: $TG_ARN"
fi

# ============================================================================
# 4. Request SSL Certificate
# ============================================================================
echo ""
echo "4️⃣  Creating SSL Certificate in ACM..."
CERT_ARN=$(aws acm describe-certificates \
  --query "CertificateSummaryList[?DomainName=='$WWW_DOMAIN'].CertificateArn" \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
  CERT_ARN=$(aws acm request-certificate \
    --domain-name $WWW_DOMAIN \
    --subject-alternative-names $DOMAIN_NAME \
    --validation-method DNS \
    --region $AWS_REGION \
    --query 'CertificateArn' \
    --output text)
  echo "✅ Requested SSL Certificate: $CERT_ARN"
  echo "⚠️  NOTE: You must validate the certificate via DNS before it can be used."
  echo "   See validation records in ACM console: https://console.aws.amazon.com/acm"
else
  echo "✅ Certificate exists: $CERT_ARN"
fi

# ============================================================================
# 5. Create or Update Route53 Hosted Zone
# ============================================================================
echo ""
echo "5️⃣  Setting up Route53 DNS..."

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name $DOMAIN_NAME \
  --query 'HostedZones[0].Id' \
  --output text --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  ZONE_ID=$(aws route53 create-hosted-zone \
    --name $DOMAIN_NAME \
    --caller-reference "$(date +%s)" \
    --query 'HostedZone.Id' \
    --output text)
  echo "✅ Created Hosted Zone: $ZONE_ID"
  echo "⚠️  NOTE: Update your domain registrar nameservers to:"
  aws route53 get-hosted-zone --id $ZONE_ID --query 'DelegationSet.NameServers' --output text
else
  echo "✅ Hosted Zone exists: $ZONE_ID"
fi

# Remove leading /hostedzone/
ZONE_ID=${ZONE_ID##*/}

# Get ALB Hosted Zone ID (constant for each region)
case $AWS_REGION in
  us-east-1) ALB_ZONE="Z35SXDOTRQ7X7K" ;;
  us-east-2) ALB_ZONE="Z3AQJSTF5JLSVA" ;;
  us-west-1) ALB_ZONE="Z1H1FL5HABSF5" ;;
  us-west-2) ALB_ZONE="Z1H1FL5HABSF5" ;;
  eu-west-1) ALB_ZONE="Z32O12XQLNTSW2" ;;
  eu-central-1) ALB_ZONE="Z215JFBABC5EQKS" ;;
  ap-southeast-1) ALB_ZONE="Z1LMS91P8CMLE5" ;;
  ap-northeast-1) ALB_ZONE="Z1R25G3KIG2GBW" ;;
  *) ALB_ZONE="Z35SXDOTRQ7X7K" ;; # Default to us-east-1
esac

# Create DNS record for www subdomain
echo "   Creating A record: $WWW_DOMAIN -> $ALB_DNS"
aws route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$WWW_DOMAIN\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"$ALB_ZONE\",
          \"DNSName\": \"$ALB_DNS\",
          \"EvaluateTargetHealth\": false
        }
      }
    }]
  }" \
  --region $AWS_REGION > /dev/null
echo "✅ DNS record created"

# ============================================================================
# 6. Create HTTPS Listener
# ============================================================================
echo ""
echo "6️⃣  Creating HTTPS Listener on ALB..."

# Check if listener exists
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query "Listeners[?Port==\`443\`].ListenerArn" \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=$CERT_ARN \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --region $AWS_REGION > /dev/null
  echo "✅ Created HTTPS listener (port 443)"
else
  echo "✅ HTTPS listener exists"
fi

# Create HTTP listener (redirect to HTTPS)
HTTP_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query "Listeners[?Port==\`80\`].ListenerArn" \
  --output text \
  --region $AWS_REGION 2>/dev/null || echo "")

if [ -z "$HTTP_LISTENER_ARN" ] || [ "$HTTP_LISTENER_ARN" = "None" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=redirect,RedirectConfig="{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}" \
    --region $AWS_REGION > /dev/null
  echo "✅ Created HTTP listener (redirect to HTTPS)"
fi

# ============================================================================
# 7. Get ECS Task Definition and Update Service
# ============================================================================
echo ""
echo "7️⃣  Updating ECS Service to use ALB..."

# Check if service exists
SERVICE_EXISTS=$(aws ecs describe-services \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION \
  --query 'services[0].serviceName' \
  --output text 2>/dev/null || echo "")

if [ ! -z "$SERVICE_EXISTS" ] && [ "$SERVICE_EXISTS" != "None" ]; then
  # Get current task definition
  TASK_DEF=$(aws ecs describe-services \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $AWS_REGION \
    --query 'services[0].taskDefinition' \
    --output text)
  
  # Update service with ALB
  aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --load-balancers targetGroupArn=$TG_ARN,containerName=$REPO_NAME,containerPort=$CONTAINER_PORT \
    --region $AWS_REGION > /dev/null
  echo "✅ Updated service with ALB target group"
else
  echo "⚠️  Service $SERVICE_NAME not found in cluster $CLUSTER_NAME"
  echo "   You'll need to create the service manually or run this script after creating it."
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================================"
echo "✅ Setup Complete!"
echo "============================================================================"
echo ""
echo "Summary:"
echo "  Domain: $DOMAIN_NAME / $WWW_DOMAIN"
echo "  ALB DNS: $ALB_DNS"
echo "  ALB ARN: $ALB_ARN"
echo "  Target Group: $TG_ARN"
echo "  Certificate: $CERT_ARN"
echo "  Hosted Zone: $ZONE_ID"
echo ""
echo "Next Steps:"
echo "  1. ✅ Verify SSL Certificate in ACM (validate DNS records if pending)"
echo "  2. ✅ Update domain registrar nameservers (if new hosted zone created)"
echo "  3. 🔄 Wait 5-10 minutes for DNS propagation"
echo "  4. 🌐 Access your API: https://$WWW_DOMAIN"
echo ""
echo "============================================================================"
