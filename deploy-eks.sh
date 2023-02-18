#!/usr/bin/bash
source ~/.bash_profile

# Specify a CIDR for the EKS Cluster VPC
VPC_CIDR=""
# VPC_CIDR="192.168.0.0/16"

if [ "x${VPC_CIDR}" == "x" ]
then
  echo "Please specify a VPC CIDR"
  echo "This script will be adding a route in the route table associated with"
  echo "this Cloud9 Instance for the EKS Cluster private endpoints"
  exit
fi

echo "export VPC_CIDR=${VPC_CIDR}" \
    | tee -a ~/.bash_profile

TOKEN=$(curl --silent --no-progress-meter \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
CLOUD9_MAC_ID=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
CLOUD9_VPC_ID=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/${CLOUD9_MAC_ID}vpc-id)
CLOUD9_VPC_IP=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/${CLOUD9_MAC_ID}local-ipv4s)
CLOUD9_VPC_SUBNET=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/${CLOUD9_MAC_ID}subnet-id)

test -n "$EKS_CLUSTER_NAME" && echo EKS_CLUSTER_NAME is "$EKS_CLUSTER_NAME" || echo EKS_CLUSTER_NAME is not set

export MASTER_ARN=$(aws kms describe-key --key-id alias/dynamic-policy-ref-arch-${RANDOM_STRING} \
  --query KeyMetadata.Arn --output text)

echo "Deploying EKS Cluster ${EKS_CLUSTER_NAME}"

mkdir -p yaml

cat << EOF > yaml/cluster-config.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${EKS_CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.24"
privateCluster:
  enabled: true
iam:
  withOIDC: true
addons:
- name: aws-ebs-csi-driver
  attachPolicyARNs:
  - arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
availabilityZones: ["${AWS_REGION}a", "${AWS_REGION}b"]
vpc:
  cidr: ${VPC_CIDR}

managedNodeGroups:
- name: nodegroup
  desiredCapacity: 2
  instanceTypes: ["t3a.medium","t3.medium"]
  volumeEncrypted: true
  privateNetworking: true
  ssh:
    allow: false
# Enable all of the control plane logs, uncomment below:
cloudWatch:
  clusterLogging:
    enableTypes: ["*"]
secretsEncryption:
  keyARN: ${MASTER_ARN}
EOF

eksctl create cluster -f yaml/cluster-config.yaml

aws eks update-kubeconfig --name=${EKS_CLUSTER_NAME}

# Associate an OIDC provider with the EKS Cluster
echo "Associating an OIDC provider with the EKS Cluster"
eksctl utils associate-iam-oidc-provider \
--region=${AWS_REGION} \
--cluster=${EKS_CLUSTER_NAME} \
--approve

export OIDC_PROVIDER=$(aws eks describe-cluster \
                      --name ${EKS_CLUSTER_NAME} \
                      --query "cluster.identity.oidc.issuer" \
                      --output text)

export OIDC_ID=$(echo $OIDC_PROVIDER | awk -F/ '{print $NF}')

export CLUSTER_ENDPOINT_SG=$(aws eks describe-cluster \
                        --name ${EKS_CLUSTER_NAME} \
                        --query "cluster.resourcesVpcConfig.securityGroupIds" \
                        --output text)

echo "Creating S3 Access Role in IAM"
export S3_ACCESS_ROLE=${EKS_CLUSTER_NAME}-s3-access-role-${RANDOM_STRING}
export IRSA=$(
envsubst < s3-access-role-trust-policy.json | \
xargs -0 -I {} aws iam create-role \
              --role-name ${S3_ACCESS_ROLE} \
              --assume-role-policy-document {} \
              --query 'Role.Arn' \
              --output text
)
echo "export IRSA=${IRSA}" \
    | tee -a ~/.bash_profile

echo "Attaching S3 Bucket policy to S3 Access Role"
aws iam attach-role-policy \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/s3-object-access-policy-${RANDOM_STRING} \
    --role-name ${S3_ACCESS_ROLE}

echo "Creating Vault IRSA Role in IAM"
export VAULT_NS="vault"
export VAULT_SA_ROLE=${EKS_CLUSTER_NAME}-vault-sa-role-${RANDOM_STRING}
export VAULT_IRSA=$(
envsubst < vault-sa-role-trust-policy.json | \
xargs -0 -I {} aws iam create-role \
              --role-name ${VAULT_SA_ROLE} \
              --assume-role-policy-document {} \
              --query 'Role.Arn' \
              --output text
)
echo "export VAULT_IRSA=${VAULT_IRSA}" \
    | tee -a ~/.bash_profile

export CLUSTER_VPC_ID=$(
  aws eks describe-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text
  )

export CLUSTER_VPC_SUBNETS=$(
  aws eks describe-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --query "cluster.resourcesVpcConfig.subnetIds" \
    --output text | xargs
  )

ROUTE_TABLES=""

for S in ${CLUSTER_VPC_SUBNETS}
do
  RT=$(
    aws ec2 describe-route-tables \
    --query 'RouteTables[*].Associations[?SubnetId==`'$S'`].RouteTableId' \
    --output text | xargs
    )
    
  ROUTE_TABLES+="${RT} "
done

echo "Creating VPC Endpoints for KMS and DynamoDB in the EKS Cluster VPC"
aws ec2 create-vpc-endpoint \
  --vpc-id ${CLUSTER_VPC_ID} \
  --vpc-endpoint-type Interface \
  --private-dns-enabled \
  --service-name com.amazonaws.${AWS_REGION}.kms \
  --subnet-ids ${CLUSTER_VPC_SUBNETS} 2>&1 > /dev/null

aws ec2 create-vpc-endpoint \
  --vpc-id ${CLUSTER_VPC_ID} \
  --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.${AWS_REGION}.dynamodb \
  --route-table-ids ${ROUTE_TABLES} 2>&1 > /dev/null

# Create VPC Peering between Cloud9 and EKS Cluster VPCs               
echo "Creating VPC Peering between Cloud9 and EKS Cluster VPCs"
VPC_PEER_ID=$(
  aws ec2 create-vpc-peering-connection \
    --vpc-id ${CLOUD9_VPC_ID} \
    --peer-vpc-id  ${CLUSTER_VPC_ID} \
    --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
    --output text
  )
echo "export VPC_PEER_ID=${VPC_PEER_ID}" | tee -a ~/.bash_profile

aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id ${VPC_PEER_ID} 2>&1 > /dev/null

aws ec2 modify-vpc-peering-connection-options \
  --vpc-peering-connection-id ${VPC_PEER_ID} \
  --accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true \
  --requester-peering-connection-options AllowDnsResolutionFromRemoteVpc=true 2>&1 > /dev/null

# Add routes for EKS Endpoint to Cloud9 subnet's route table
echo "Add routes for EKS Control Plane to Cloud9 subnet's route table"
CLOUD9_RT=$(
    aws ec2 describe-route-tables \
    --query 'RouteTables[*].Associations[?SubnetId==`'${CLOUD9_VPC_SUBNET}'`].RouteTableId' \
    --output text | xargs
  )
if [ "x$CLOUD9_RT" == "x" ]
then
  CLOUD9_RT=$(
    aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${CLOUD9_VPC_ID}" \
      | jq -r '.RouteTables[].Associations[] | select(.Main==true) | .RouteTableId'
    )
fi

ROUTE_EXISTS=$(
    aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${CLOUD9_VPC_ID}" \
      --query 'RouteTables[*].Routes[?DestinationCidrBlock==`"'${VPC_CIDR}'"`].State' \
      --output text
  )
if [ "x$ROUTE_EXISTS" == "x" ]
then
  aws ec2 create-route \
    --route-table-id ${CLOUD9_RT} \
    --destination-cidr-block ${VPC_CIDR} \
    --vpc-peering-connection-id ${VPC_PEER_ID}
fi

# Allow Cloud9 Instance ingress to the Cluster Endpoint Security Group
echo "Updating EKS Cluster Endpoint Security Group to allow Cloud9 Instance kubectl access"
aws ec2 authorize-security-group-ingress \
    --group-id ${CLUSTER_ENDPOINT_SG} \
    --protocol tcp \
    --port 443 \
    --cidr ${CLOUD9_VPC_IP}/32 2>&1 > /dev/null

# Add routes for Cloud9 Instance to EKS VPC Subnets
echo "Adding routes for Cloud9 Instance to EKS VPC Subnets"
for S in ${CLUSTER_VPC_SUBNETS}
do
  RT=$(
      aws ec2 describe-route-tables \
      --query 'RouteTables[*].Associations[?SubnetId==`'$S'`].RouteTableId' \
      --output text
    )
  ROUTE_EXISTS=$(
      aws ec2 describe-route-tables \
        --route-table-ids ${RT} \
        --query 'RouteTables[*].Routes[?DestinationCidrBlock==`"'${CLOUD9_VPC_IP}'/32"`].State' \
        --output text
    )
  if [ "x$ROUTE_EXISTS" == "x" ]
  then
    aws ec2 create-route \
      --route-table-id ${RT} \
      --destination-cidr-block ${CLOUD9_VPC_IP}/32 \
      --vpc-peering-connection-id ${VPC_PEER_ID} 2>&1 > /dev/null
  fi
done
