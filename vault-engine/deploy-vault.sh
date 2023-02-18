#!/usr/bin/bash
source ~/.bash_profile

export VAULT_NS="vault"
export VAULT_ROLE="vault-role-${RANDOM_STRING}"

echo "Creating Vault Role in IAM"
export VAULT_ROLE_ARN=$(
envsubst < iam/vault-assume-role-policy.json | \
xargs -0 -I {} aws iam create-role \
              --role-name ${VAULT_ROLE} \
              --assume-role-policy-document {} \
              --query 'Role.Arn' \
              --output text
)

echo "Creating DynamoDB Policy in IAM"
export VAULT_DDB_POLICY_ARN=$(
envsubst < iam/dynamodb-policy.json | \
xargs -0 -I {} aws iam create-policy \
                --policy-name dynamodb-policy-${RANDOM_STRING} \
                --policy-document {} \
                --query 'Policy.Arn' \
                --output text
)

echo "Attaching DynamoDB policy to Vault Role"
aws iam attach-role-policy \
    --policy-arn ${VAULT_DDB_POLICY_ARN} \
    --role-name ${VAULT_ROLE}

echo "Creating Vault AssumeRole Policy in IAM"
export VAULT_SA_ASSUMEROLE_POLICY_ARN=$(
envsubst < iam/vault-sa-assume-role-policy.json | \
xargs -0 -I {} aws iam create-policy \
    --policy-name vault-sa-assumerole-policy-${RANDOM_STRING} \
    --policy-document {} \
    --query 'Policy.Arn' \
    --output text
)

echo "Attaching Vault AssumeRole Policy to Vault SA Role"
aws iam attach-role-policy \
    --policy-arn ${VAULT_SA_ASSUMEROLE_POLICY_ARN} \
    --role-name ${EKS_CLUSTER_NAME}-vault-sa-role-${RANDOM_STRING}

echo "Creating Vault namespace in EKS Cluster"
envsubst < namespace-template.yaml | kubectl apply -f -

echo "Installing Vault Engine"
helm search repo hashicorp/vault | grep "hashicorp/vault"
if [[ $? -eq 1 ]]
then
    helm repo add hashicorp https://helm.releases.hashicorp.com
fi
helm repo update

VAULT_REPO_NAME=${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault
VAULT_IMAGE_TAG=$(
aws ecr describe-images \
    --repository-name ${VAULT_REPO_NAME} \
    --query 'imageDetails[?imageTags[0]==`latest`].imageDigest' \
    --output text | awk -F 'sha256:' '{print $2}'
	)

VAULTK8S_REPO_NAME=${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault-k8s
VAULTK8S_IMAGE_TAG=$(
aws ecr describe-images \
    --repository-name ${VAULTK8S_REPO_NAME} \
    --query 'imageDetails[?imageTags[0]==`latest`].imageDigest' \
    --output text | awk -F 'sha256:' '{print $2}'
	)

helm install vault hashicorp/vault \
    --namespace ${VAULT_NS}\
    --set server.image.repository="${REPO_URI_VAULT}@sha256" \
    --set server.image.tag="${VAULT_IMAGE_TAG}" \
    --set server.serviceAccount.name="vault-sa" \
    --set "server.serviceAccount.annotations.eks\.amazonaws\.com/role-arn"="${VAULT_IRSA}" \
    --set server.extraEnvironmentVars.AWS_STS_REGIONAL_ENDPOINTS="regional" \
    --set injector.image.repository="${REPO_URI_VAULTK8S}@sha256" \
    --set injector.image.tag="${VAULTK8S_IMAGE_TAG}"

export VAULT_POD=$(kubectl -n ${VAULT_NS} get pods \
                  --selector='app.kubernetes.io/name=vault' \
                  -o jsonpath='{.items[0].metadata.name}')

# Allow Vault Pod to be provisioned and in Running state
sleep 30

# Initialize and unseal Vault
echo "Initializing and unsealing Vault Engine"
export VAULT_KEYS=$(kubectl -n ${VAULT_NS} \
                    exec -i ${VAULT_POD} -c vault \
                    -- vault operator init)

export UNSEAL_KEYS=$(echo "$VAULT_KEYS" | \
                    grep -m3 "Unseal Key" | \
                    awk -F: '{print $2}' | \
                    xargs)

export ROOT_TOKEN=$(echo "$VAULT_KEYS" | \
                    grep "Initial Root Token" | \
                    awk -F: '{print $2}' | \
                    xargs)

echo "Creating VAULT_ROOT_TOKEN_${RANDOM_STRING} secret in AWS Secrets Manager"
aws secretsmanager create-secret \
    --name VAULT_ROOT_TOKEN_${RANDOM_STRING} \
    --region ${AWS_REGION} \
    --secret-string ${ROOT_TOKEN}\
    --query ARN | \
    xargs

echo "Storing Unseal Keys in AWS Secrets Manager"
UNSEAL_KEYS_ARR=(${UNSEAL_KEYS})
for INDEX in "${!UNSEAL_KEYS_ARR[@]}"
do
    KEY_INDEX=$(($INDEX + 1))
    aws secretsmanager create-secret \
    --name UNSEAL_KEY_${RANDOM_STRING}_${KEY_INDEX} \
    --region ${AWS_REGION} \
    --secret-string ${UNSEAL_KEYS_ARR[$INDEX]} \
    --query ARN | \
    xargs
done

export VAULT_TOKEN=$(aws secretsmanager get-secret-value \
                    --secret-id VAULT_ROOT_TOKEN_${RANDOM_STRING} \
                    --region ${AWS_REGION} \
                    --query SecretString \
                    | xargs)

for KEY in ${UNSEAL_KEYS}
do
    kubectl -n ${VAULT_NS} exec -i ${VAULT_POD} -c vault \
    -- env \
        VAULT_TOKEN=${VAULT_TOKEN} \
        KEY=${KEY} \
        /bin/sh -c \
        "vault operator unseal ${KEY}"
done

# Enable AWS secrets engine & Approle Auth Method
echo "Enabling AWS secrets engine & Approle Auth Method"
kubectl -n ${VAULT_NS} exec -i \
    ${VAULT_POD} -c vault \
    -- env VAULT_TOKEN=${VAULT_TOKEN} \
        /bin/sh -c \
        "vault secrets enable aws
         vault auth enable approle"