#!/usr/bin/bash
source ~/.bash_profile

export VAULT_NS="vault"
export VAULT_ADDR="vault.${VAULT_NS}.svc.cluster.local:8200"
export VAULT_TOKEN=$(aws secretsmanager get-secret-value \
                    --secret-id VAULT_ROOT_TOKEN_${RANDOM_STRING} \
                    --region ${AWS_REGION} \
                    --query SecretString \
                    | xargs)
export VAULT_POD=$(kubectl -n ${VAULT_NS} get pods \
                  --selector='app.kubernetes.io/name=vault' \
                  -o jsonpath='{.items[0].metadata.name}')

TENANTS="tenanta tenantb"
for TENANT in $TENANTS
do
    export TENANT
    export APPLICATION_NS=${TENANT}
    export VAULT_AGENT_ROLE=${TENANT}

    kubectl -n ${VAULT_NS} exec -i ${VAULT_POD} -c vault \
        -- env VAULT_TOKEN=$VAULT_TOKEN \
                RANDOM_STRING=$RANDOM_STRING \
                ACCOUNT_ID=${ACCOUNT_ID} \
                AWS_REGION=${AWS_REGION} \
                /bin/sh -c \
            "echo \"Creating Vault Role for ${TENANT}\"
             echo \"=================================\"
             vault write aws/roles/${TENANT} \
                role_arns=arn:aws:iam::${ACCOUNT_ID}:role/vault-role-${RANDOM_STRING} \
                credential_type=assumed_role \
                policy_document=-<<EOF
{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {
            \"Action\": [
                \"dynamodb:GetItem\",
                \"dynamodb:BatchGetItem\",
                \"dynamodb:Query\",
                \"dynamodb:DescribeTable\"
            ],
            \"Resource\": \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/Products_${RANDOM_STRING}\",
            \"Effect\": \"Allow\",
            \"Condition\": {
                \"ForAllValues:StringEquals\": {
                    \"dynamodb:LeadingKeys\": [ \"${TENANT}\" ]
                }
            }
        }
    ]
}
EOF
            vault read aws/roles/${TENANT}

            echo \"Creating Vault Policy for ${TENANT}\"
            echo \"===================================\"
            vault policy write ${TENANT}-policy -<<EOF
path \"aws/sts/${TENANT}\" {
  capabilities = [\"read\", \"list\"]
}
EOF
            vault policy read ${TENANT}-policy

            echo \"Creating Vault credentials endpoint for ${TENANT}\"
            echo \"=================================================\"
            vault write aws/sts/${TENANT} ttl=60m

            vault read aws/sts/${TENANT}"

    # Create AppRole role
    kubectl -n ${VAULT_NS} exec -i ${VAULT_POD} -c vault \
        -- env VAULT_TOKEN=$VAULT_TOKEN \
            TENANT=${TENANT} \
            /bin/sh -c \
            "vault write auth/approle/role/${TENANT} \
                token_policies=${TENANT}-policy
             vault read auth/approle/role/${TENANT}"

    export RID="$(
        kubectl -n ${VAULT_NS} exec -i vault-0 -c vault \
            -- env VAULT_TOKEN=$VAULT_TOKEN \
                TENANT=${TENANT} \
                /bin/sh -c \
                'vault read -field=role_id \
                    auth/approle/role/'${TENANT}'/role-id'
            )"

    export ROLE_ID=$(echo "${RID}" | base64)

    export SID="$(
        kubectl -n ${VAULT_NS} exec -i vault-0 -c vault \
            -- env VAULT_TOKEN=$VAULT_TOKEN \
            TENANT=${TENANT} \
            /bin/sh -c \
                'vault write -f -field=secret_id \
                    auth/approle/role/'${TENANT}'/secret-id'
            )"
    
    export SECRET_ID=$(echo "${SID}" | base64)

    # Create Application Namespace
    kubectl create ns ${APPLICATION_NS}

    # Create Secret in App Namespace
    envsubst < vault-agent-approle-secret.yaml \
        | kubectl -n ${APPLICATION_NS} apply -f -

    # Deploy Vault Agent ConfigMap
    envsubst < vault-agent-configmap.yaml \
        | kubectl -n ${APPLICATION_NS} apply -f -

    # Deploy Vault Agent Example Pod
    export VAULT_REPO_NAME=${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-vault
    export VAULT_IMAGE_TAG=$(
    aws ecr describe-images \
        --repository-name ${VAULT_REPO_NAME} \
        --query 'imageDetails[?imageTags[0]==`latest`].imageDigest' \
        --output text | awk -F 'sha256:' '{print $2}'
    	)

    export AWSCLI_REPO_NAME=${EKS_CLUSTER_NAME}-repo-${RANDOM_STRING}-aws-cli
    export AWSCLI_IMAGE_TAG=$(
        aws ecr describe-images \
        --repository-name ${AWSCLI_REPO_NAME} \
        --query 'imageDetails[?imageTags[0]==`latest`].imageDigest' \
        --output text | awk -F 'sha256:' '{print $2}'
    	)

    envsubst < vault-agent-example.yaml \
        | kubectl -n ${APPLICATION_NS} apply -f -

    kubectl -n ${APPLICATION_NS} get all
done