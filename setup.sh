#!/usr/bin/env bash
. ~/.bash_profile

echo "Installing helper tools"
sudo yum -y install jq bash-completion

echo "Uninstalling AWS CLI 1.x"
sudo pip uninstall awscli -y

echo "Installing AWS CLI 2.x"
curl --silent --no-progress-meter \
    "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "awscliv2.zip"
unzip -qq awscliv2.zip
sudo ./aws/install --update
PATH=/usr/local/bin:$PATH
/usr/local/bin/aws --version
rm -rf aws awscliv2.zip

CLOUD9_INSTANCE_ID=$(curl --silent --no-progress-meter \
                    http://169.254.169.254/latest/meta-data/instance-id)
export AWS_REGION=$(curl --silent --no-progress-meter \
                    http://169.254.169.254/latest/dynamic/instance-identity/document \
                    | jq -r '.region')
export AWS_DEFAULT_REGION=$AWS_REGION

# Configure Cloud9 instance with IMDSv2
echo "Configuring Cloud9 instance with IMDSv2"
aws ec2 modify-instance-metadata-options \
    --region ${AWS_REGION} \
    --instance-id ${CLOUD9_INSTANCE_ID} \
    --http-tokens required \
    --http-endpoint enabled 2>&1 > /dev/null

export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)

echo "Installing kubectl"
sudo curl --silent --no-progress-meter --location -o /usr/local/bin/kubectl \
  https://s3.us-west-2.amazonaws.com/amazon-eks/1.24.7/2022-10-31/bin/linux/amd64/kubectl

sudo chmod +x /usr/local/bin/kubectl

kubectl version --short --client=true

echo "Installing bash completion for kubectl"
kubectl completion bash >>  ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion

echo "Installing eksctl"
curl --silent --no-progress-meter \
    --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
    | tar xz -C /tmp

sudo mv -v /tmp/eksctl /usr/local/bin

echo "eksctl Version: $(eksctl version)"

echo "Installing bash completion for eksctl"
eksctl completion bash >> ~/.bash_completion
. /etc/profile.d/bash_completion.sh
. ~/.bash_completion

test -n "$AWS_REGION" && echo AWS_REGION is "$AWS_REGION" || echo AWS_REGION is not set
echo "export ACCOUNT_ID=${ACCOUNT_ID}" | tee -a ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" | tee -a ~/.bash_profile
echo "export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}" | tee -a ~/.bash_profile
aws configure set default.region ${AWS_REGION}

export EKS_CLUSTER_NAME="dynamic-policy-saas"
echo "export EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}" | tee -a ~/.bash_profile

# Creating S3 Bucket + Access Logging Bucket for Vault Agent Templates
echo "Creating S3 Bucket for Vault Agent Templates"
RANDOM_STRING=$(cat /dev/urandom \
                | tr -dc '[:alpha:]' \
                | fold -w ${1:-20} | head -n 1 \
                | cut -c 1-8 \
                | tr '[:upper:]' '[:lower:]')
export VAULT_AGENT_TEMPLATES_BUCKET="vault-agent-template-${RANDOM_STRING}"
export VAULT_AGENT_TEMPLATES_BUCKET_LOGS=${VAULT_AGENT_TEMPLATES_BUCKET}-access-logs

aws s3api wait bucket-exists \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} 2>&1 > /dev/null

while [ $? -eq 0 ]
do
    RANDOM_STRING=$(cat /dev/urandom \
                    | tr -dc '[:alpha:]' \
                    | fold -w ${1:-20} | head -n 1 \
                    | cut -c 1-8 \
                    | tr '[:upper:]' '[:lower:]')
    export VAULT_AGENT_TEMPLATES_BUCKET="vault-agent-template-${RANDOM_STRING}"
    export VAULT_AGENT_TEMPLATES_BUCKET_LOGS=${VAULT_AGENT_TEMPLATES_BUCKET}-access-logs
    
    aws s3api wait bucket-exists \
        --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} 2>&1 > /dev/null
done

# Create Vault Agent Templates S3 Bucket
aws s3 mb s3://${VAULT_AGENT_TEMPLATES_BUCKET}

if [[ $? -eq 0 ]]
then
    echo "export VAULT_AGENT_TEMPLATES_BUCKET=${VAULT_AGENT_TEMPLATES_BUCKET}" \
        | tee -a ~/.bash_profile
fi

echo "export RANDOM_STRING=${RANDOM_STRING}" | tee -a ~/.bash_profile

# Create Logging Bucket
aws s3 mb s3://${VAULT_AGENT_TEMPLATES_BUCKET_LOGS}

# Block Public Access to Buckets
echo "Blocking public access to buckets"
aws s3api put-public-access-block \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-public-access-block \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET_LOGS} \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enabling Bucket Encryption
echo "Enabling SSE-S3 bucket encryption"
aws s3api put-bucket-encryption \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} \
    --server-side-encryption-configuration \
    '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'

aws s3api put-bucket-encryption \
    --bucket ${VAULT_AGENT_TEMPLATES_BUCKET_LOGS} \
    --server-side-encryption-configuration \
    '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'

# Enable Bucket Logging
echo "Enabling bucket access logging"
envsubst < s3-logging-enablement.json | \
xargs -0 -I {} aws s3api put-bucket-logging \
            --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} \
            --bucket-logging-status {}

# Applying Bucket Policy to S3 Buckets
echo "Applying bucket policies"
envsubst < s3-bucket-policy.json | \
xargs -0 -I {} aws s3api put-bucket-policy \
            --bucket ${VAULT_AGENT_TEMPLATES_BUCKET} \
            --policy {}

envsubst < s3-access-logging-policy.json | \
xargs -0 -I {} aws s3api put-bucket-policy \
            --bucket ${VAULT_AGENT_TEMPLATES_BUCKET_LOGS} \
            --policy {}

echo "Enabling S3 LogDelivery service to deliver access logs"
aws s3api put-bucket-acl --bucket ${VAULT_AGENT_TEMPLATES_BUCKET_LOGS}  \
    --grant-write URI=http://acs.amazonaws.com/groups/s3/LogDelivery \
    --grant-read-acp URI=http://acs.amazonaws.com/groups/s3/LogDelivery 

# Creating S3 Bucket Policy Vault Agent Templates
echo "Creating S3 Bucket Policy for Vault Agent Templates"
envsubst < s3-object-access-policy.json | \
xargs -0 -I {} aws iam create-policy \
              --policy-name s3-object-access-policy-${RANDOM_STRING} \
              --policy-document {} 2>&1 > /dev/null

echo "Creating ECR Repositories"
ECR_REPO_AWSCLI=$(aws ecr create-repository \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-aws-cli \
  --encryption-configuration encryptionType=KMS)
REPO_URI_AWSCLI=$(echo ${ECR_REPO_AWSCLI}|jq -r '.repository.repositoryUri')
ECR_REPO_VAULT=$(aws ecr create-repository \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault \
  --encryption-configuration encryptionType=KMS)
REPO_URI_VAULT=$(echo ${ECR_REPO_VAULT}|jq -r '.repository.repositoryUri')
ECR_REPO_VAULTK8S=$(aws ecr create-repository \
  --repository-name ${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault-k8s \
  --encryption-configuration encryptionType=KMS)
REPO_URI_VAULTK8S=$(echo ${ECR_REPO_VAULTK8S}|jq -r '.repository.repositoryUri')

# Pull Docker Images
echo "Pulling Docker images for Vault, Vault Injector, and AWS CLI"
docker pull hashicorp/vault
docker pull hashicorp/vault-k8s
docker pull public.ecr.aws/aws-cli/aws-cli:latest

echo "Pushing Docker Image to ECR Repo"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS \
  --password-stdin $REPO_URI_AWSCLI
docker tag $(docker images public.ecr.aws/aws-cli/aws-cli:latest --format "{{.ID}}") \
  $REPO_URI_AWSCLI:latest
docker push $REPO_URI_AWSCLI:latest
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS \
  --password-stdin $REPO_URI_VAULT
docker tag $(docker images hashicorp/vault:latest --format "{{.ID}}") \
  $REPO_URI_VAULT:latest
docker push $REPO_URI_VAULT:latest
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS \
  --password-stdin $REPO_URI_VAULTK8S
docker tag $(docker images hashicorp/vault-k8s:latest --format "{{.ID}}") \
  $REPO_URI_VAULTK8S:latest
docker push $REPO_URI_VAULTK8S:latest

echo "export REPO_URI_AWSCLI=${REPO_URI_AWSCLI}" | tee -a ~/.bash_profile
echo "export REPO_URI_VAULT=${REPO_URI_VAULT}" | tee -a ~/.bash_profile
echo "export REPO_URI_VAULTK8S=${REPO_URI_VAULTK8S}" | tee -a ~/.bash_profile

echo "Installing helm"
curl --no-progress-meter \
    -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

helm version --template='Version: {{.Version}}'; echo

echo "Creating KMS Key and Alias"
aws kms create-alias --alias-name alias/dynamic-policy-ref-arch-${RANDOM_STRING} \
    --target-key-id $(aws kms create-key --query KeyMetadata.Arn --output text)

export MASTER_ARN=$(aws kms describe-key --key-id alias/dynamic-policy-ref-arch-${RANDOM_STRING} \
    --query KeyMetadata.Arn --output text)

echo "export MASTER_ARN=${MASTER_ARN}" | tee -a ~/.bash_profile

aws sts get-caller-identity --query Arn | grep dynamic-policy-ref-arch-admin -q && echo "IAM role valid. You can continue setting up the EKS Cluster." || echo "IAM role NOT valid. Do not proceed with creating the EKS Cluster or you won't be able to authenticate. Ensure you assigned the role to your EC2 instance as detailed in the README.md"
