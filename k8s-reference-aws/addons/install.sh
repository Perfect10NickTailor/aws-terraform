#!/usr/bin/env bash
##
## Add-on installation script — run after: eksctl create cluster -f cluster/eksctl-cluster.yaml
##
## Order matters:
##   1. Karpenter IAM policy + node role (before cluster creation if using eksctl IRSA)
##   2. Karpenter helm install
##   3. AWS Load Balancer Controller
##   4. EFS CSI driver
##   5. External Secrets Operator
##   6. ExternalDNS
##   7. Fluent Bit (CloudWatch logging)
##
## Set these before running:
export CLUSTER_NAME="prod-cluster"
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)

set -euo pipefail

##──────────────────────────────────────────────
## 1. Karpenter IAM (run once before cluster creation if policy doesn't exist)
##──────────────────────────────────────────────

# Create Karpenter controller policy
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/main/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml \
  | aws cloudformation deploy \
    --stack-name KarpenterStack-${CLUSTER_NAME} \
    --template-file /dev/stdin \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ClusterName=${CLUSTER_NAME}

# Create node instance profile for Karpenter-launched nodes
aws iam create-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} 2>/dev/null || true

aws iam add-role-to-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} 2>/dev/null || true

# Tag subnets + security groups so Karpenter can discover them
for SUBNET in $(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=*Private*" \
  --query "Subnets[].SubnetId" --output text); do
  aws ec2 create-tags --resources $SUBNET \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
done

SG_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
aws ec2 create-tags --resources $SG_ID \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}

# Allow Karpenter nodes to join cluster
aws eks create-access-entry \
  --cluster-name ${CLUSTER_NAME} \
  --principal-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME} \
  --type EC2_LINUX 2>/dev/null || true

##──────────────────────────────────────────────
## 2. Karpenter
##──────────────────────────────────────────────

KARPENTER_VERSION="1.0.7"

helm repo add karpenter https://charts.karpenter.sh/ --force-update

helm upgrade --install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --version "${KARPENTER_VERSION}" \
  --wait

# Apply the NodePool + EC2NodeClass
kubectl apply -f ../cluster/karpenter-nodepool.yaml

##──────────────────────────────────────────────
## 3. AWS Load Balancer Controller
##──────────────────────────────────────────────

helm repo add eks https://aws.github.io/eks-charts --force-update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${AWS_REGION} \
  --set vpcId=${VPC_ID} \
  --set replicaCount=2 \
  --wait

##──────────────────────────────────────────────
## 4. EFS CSI Driver
##──────────────────────────────────────────────

# Create EFS filesystem
EFS_FS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value=${CLUSTER_NAME}-efs \
  --query "FileSystemId" --output text)

echo "EFS_FS_ID=${EFS_FS_ID}  ← update app/05-storage.yaml"

# Create mount targets in each private subnet
for SUBNET in $(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=*Private*" \
  --query "Subnets[].SubnetId" --output text); do
  aws efs create-mount-target \
    --file-system-id $EFS_FS_ID \
    --subnet-id $SUBNET \
    --security-groups $SG_ID 2>/dev/null || true
done

# Install EFS CSI Driver
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ --force-update

helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::${AWS_ACCOUNT_ID}:role/eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-efs-csi-controller-sa-Role1 \
  --wait

##──────────────────────────────────────────────
## 5. External Secrets Operator
##──────────────────────────────────────────────

helm repo add external-secrets https://charts.external-secrets.io --force-update

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait

##──────────────────────────────────────────────
## 6. ExternalDNS
##──────────────────────────────────────────────

# Get your hosted zone ID first
# HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name example.com --query "HostedZones[0].Id" --output text | cut -d/ -f3)

helm repo add bitnami https://charts.bitnami.com/bitnami --force-update

helm upgrade --install external-dns bitnami/external-dns \
  --namespace kube-system \
  --set provider=aws \
  --set aws.region=${AWS_REGION} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-dns \
  --set policy=sync \
  --set txtOwnerId=${CLUSTER_NAME} \
  --wait

##──────────────────────────────────────────────
## 7. Fluent Bit → CloudWatch Logs
##──────────────────────────────────────────────

# Creates log groups: /aws/containerinsights/prod-cluster/{application,dataplane,host,performance}

curl -fsSL https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml \
  | kubectl apply -f -

FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
ClusterName=${CLUSTER_NAME}
RegionName=${AWS_REGION}
LogGroupName="/aws/containerinsights/${ClusterName}/application"

curl -fsSL https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluent-bit/fluent-bit.yaml \
  | sed "s/{{cluster_name}}/${ClusterName}/;s/{{region_name}}/${RegionName}/;s/{{http_server_port}}/${FluentBitHttpPort}/;s/{{read_from_head}}/${FluentBitReadFromHead}/" \
  | kubectl apply -f -

echo ""
echo "✅ Add-on installation complete."
echo "Next: update app/05-storage.yaml with EFS_FS_ID=${EFS_FS_ID}"
echo "Then: kubectl apply -f app/ in order (00 → 10)"
