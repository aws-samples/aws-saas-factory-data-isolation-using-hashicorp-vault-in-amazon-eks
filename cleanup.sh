#!/usr/bin/bash
source ~/.bash_profile

export VAULT_NS="vault"
export VAULT_ROLE="vault-role-${RANDOM_STRING}"

echo "Deleting Vault Root Token and Unseal Keys from Secrets Manager"
export SECRETS=$(aws secretsmanager list-secrets \
                --query 'SecretList[?starts_with(Name, `UNSEAL_KEY_'${RANDOM_STRING}'_`) == `true` 
                                  || starts_with(Name, `VAULT_ROOT_TOKEN_'${RANDOM_STRING}'`) == `true`].Name' \
                --output text | xargs
                )
for SECRET in ${SECRETS}
do
    aws secretsmanager delete-secret \
        --secret-id ${SECRET} \
        --force-delete-without-recovery
done

echo "Uninstalling Vault Engine"
helm uninstall vault --namespace ${VAULT_NS}

echo "Delete Vault Engine Namespace"
kubectl delete ns ${VAULT_NS}

echo "Deleting Tenant Namespaces"
kubectl delete ns tenanta
kubectl delete ns tenantb
kubectl delete ns tenantc
kubectl delete ns tenantd

# Delete VPC Endpoints
DDB_ENDPOINT_ID=$(
    aws ec2 describe-vpc-endpoints \
        --query 'VpcEndpoints[?ServiceName==`com.amazonaws.'${AWS_REGION}'.dynamodb`].VpcEndpointId' \
        --output text
    )

KMS_ENDPOINT_ID=$(
    aws ec2 describe-vpc-endpoints \
        --query 'VpcEndpoints[?ServiceName==`com.amazonaws.'${AWS_REGION}'.kms`].VpcEndpointId' \
        --output text
    )

aws ec2 delete-vpc-endpoints \
    --vpc-endpoint-ids ${DDB_ENDPOINT_ID} ${KMS_ENDPOINT_ID}

# Delete VPC Peering Routing Entries
TOKEN=$(curl --silent --no-progress-meter \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
CLOUD9_MAC_ID=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
CLOUD9_VPC_ID=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/${CLOUD9_MAC_ID}vpc-id)
CLOUD9_VPC_SUBNET=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/network/interfaces/macs/${CLOUD9_MAC_ID}subnet-id)

echo "Deleting ECR Repositories"
aws ecr delete-repository \
  --force \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-aws-cli 2>&1 > /dev/null
aws ecr delete-repository \
  --force \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault 2>&1 > /dev/null
aws ecr delete-repository \
  --force \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault-k8s 2>&1 > /dev/null

echo "Deleting EKS Cluster"
eksctl delete cluster --name ${EKS_CLUSTER_NAME} --force
rm -rf yaml

# Remove routes for EKS Endpoint from Cloud9 subnet's route table or VPC main table
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
if [ "x$ROUTE_EXISTS" != "x" ]
then
aws ec2 delete-route \
  --route-table-id ${CLOUD9_RT} \
  --destination-cidr-block ${VPC_CIDR}
fi

# Delete VPC Peering Connection
aws ec2 delete-vpc-peering-connection \
    --vpc-peering-connection-id ${VPC_PEER_ID}

echo "Removing KMS Key and Alias"
export MASTER_ARN=$(aws kms describe-key \
  --key-id alias/dynamic-policy-ref-arch-${RANDOM_STRING} \
  --query KeyMetadata.Arn --output text)

aws kms disable-key \
  --key-id ${MASTER_ARN}

aws kms delete-alias \
  --alias-name alias/dynamic-policy-ref-arch-${RANDOM_STRING}

echo "Deleting EC2 Key-Pair"
aws ec2 delete-key-pair \
  --key-name "dynamic-policy-saas-${RANDOM_STRING}"

echo "Detaching IAM policies from Vault & Vault SA Roles"
aws iam detach-role-policy \
    --role-name ${EKS_CLUSTER_NAME}-vault-sa-role-${RANDOM_STRING} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/vault-sa-assumerole-policy-${RANDOM_STRING}

aws iam detach-role-policy \
    --role-name ${VAULT_ROLE} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/dynamodb-policy-${RANDOM_STRING}

echo "Deleting Vault & Vault SA Roles in IAM"
aws iam delete-role \
    --role-name ${VAULT_ROLE}

aws iam delete-role \
    --role-name ${EKS_CLUSTER_NAME}-vault-sa-role-${RANDOM_STRING}

echo "Deleting Vault STS Policy in IAM"
aws iam delete-policy \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/vault-sa-assumerole-policy-${RANDOM_STRING}

echo "Deleting Vault DynamoDB Policy in IAM"
aws iam delete-policy \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/dynamodb-policy-${RANDOM_STRING}

echo "Deleting Products DynamoDB Table"
aws dynamodb delete-table \
    --table-name Products_${RANDOM_STRING}

echo "Detaching IAM policies from IRSA"
aws iam detach-role-policy \
    --role-name ${EKS_CLUSTER_NAME}-s3-access-role-${RANDOM_STRING} \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/s3-object-access-policy-${RANDOM_STRING}

echo "Deleting IRSA"
aws iam delete-role \
    --role-name ${EKS_CLUSTER_NAME}-s3-access-role-${RANDOM_STRING}

echo "Deleting S3 Object Access Policy for IRSA"
aws iam delete-policy \
    --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/s3-object-access-policy-${RANDOM_STRING}

echo "Deleting S3 Bucket for Vault Agent Templates"
aws s3 rm s3://${VAULT_AGENT_TEMPLATES_BUCKET}/ \
    --recursive
aws s3 rm s3://${VAULT_AGENT_TEMPLATES_BUCKET}-access-logs/ \
    --recursive
aws s3api delete-bucket \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} \
    --region ${AWS_REGION}
aws s3api delete-bucket \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET}-access-logs \
    --region ${AWS_REGION}

# Reset Cloud9 Instance to IMDSv1
TOKEN=$(curl --silent --no-progress-meter \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
CLOUD9_INSTANCE_ID=$(curl --silent --no-progress-meter \
                    -H "X-aws-ec2-metadata-token: $TOKEN" \
                    http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 modify-instance-metadata-options \
    --region ${AWS_REGION} \
    --instance-id ${CLOUD9_INSTANCE_ID} \
    --http-tokens optional \
    --http-endpoint enabled 2>&1 > /dev/null

echo "Removing Environemnt Variables from .bash_profile"
sed -i '/export ACCOUNT_ID/d' ~/.bash_profile
sed -i '/export AWS_DEFAULT_REGION/d' ~/.bash_profile
sed -i '/export AWS_REGION/d' ~/.bash_profile
sed -i '/export MASTER_ARN/d' ~/.bash_profile
sed -i '/export EKS_CLUSTER_NAME/d' ~/.bash_profile
sed -i '/export IRSA/d' ~/.bash_profile
sed -i '/export VAULT_IRSA/d' ~/.bash_profile
sed -i '/export RANDOM_STRING/d' ~/.bash_profile
sed -i '/export VAULT_AGENT_TEMPLATES_BUCKET/d' ~/.bash_profile
sed -i '/export VPC_PEER_ID/d' ~/.bash_profile
sed -i '/export VPC_CIDR/d' ~/.bash_profile
sed -i '/export REPO_URI_AWSCLI/d' ~/.bash_profile
sed -i '/export REPO_URI_VAULT/d' ~/.bash_profile
sed -i '/export REPO_URI_VAULTK8S/d' ~/.bash_profile

unset ACCOUNT_ID
unset AWS_DEFAULT_REGION
unset AWS_REGION
unset MASTER_ARN
unset EKS_CLUSTER_NAME
unset IRSA
unset VAULT_IRSA
unset VAULT_AGENT_TEMPLATES_BUCKET
unset RANDOM_STRING
unset VAULT_AGENT_TEMPLATES_BUCKET
unset VPC_PEER_ID
unset VPC_CIDR
unset REPO_URI_AWSCLI
unset REPO_URI_VAULT
unset REPO_URI_VAULTK8S

rm -rf config
rm -rf $HOME/.ssh/id_rsa