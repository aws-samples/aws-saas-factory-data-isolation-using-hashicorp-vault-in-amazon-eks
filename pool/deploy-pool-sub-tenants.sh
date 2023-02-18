#!/usr/bin/env bash
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

export TENANTS="tenantc tenantd"

for TENANT in $TENANTS
do
    export APPLICATION_NS=${TENANT}
    export VAULT_AGENT_ROLE=${TENANT}
    SUBTENANTS="${TENANT}-1 ${TENANT}-2"
    export APP_PODS=$(kubectl -n ${APPLICATION_NS} get pod \
                    -l app=vault-agent-example \
                    -o jsonpath='{.items[*].metadata.name}'
                )
    
    for SUBTENANT in $SUBTENANTS
    do
        kubectl -n ${VAULT_NS} exec -it ${VAULT_POD} -c vault \
        -- env VAULT_TOKEN=$VAULT_TOKEN \
                RANDOM_STRING=$RANDOM_STRING \
                ACCOUNT_ID=${ACCOUNT_ID} \
                AWS_REGION=${AWS_REGION} \
                /bin/sh -c \
                "echo \"Creating Vault Role for ${SUBTENANT}\"
                 echo \"=================================\"
                 vault write aws/roles/${SUBTENANT} \
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
                    \"dynamodb:LeadingKeys\": [ \"${SUBTENANT}\" ]
                }
            }
        }
    ]
}
EOF
                vault read aws/roles/${SUBTENANT}
    
                echo \"Creating Vault credentials endpoint for ${SUBTENANT}\"
                echo \"====================================================\"
                vault write aws/sts/${SUBTENANT} ttl=60m
    
                vault read aws/sts/${SUBTENANT}"
    
        # Update vault-agent-configmap for ${APPLICATION_NS}
        export PROFILE="${SUBTENANT}"
        export TEMPLATE=$(envsubst < vault-agent-config-template.hcl)
        echo "$TEMPLATE" > ../config/pool/${TENANT}/template/${PROFILE}.ctmpl
        aws s3 cp ../config/pool/${TENANT}/template/${PROFILE}.ctmpl \
            s3://${VAULT_AGENT_TEMPLATES_BUCKET}/${TENANT}/${PROFILE}.ctmpl
        cat << EOF >> ../config/pool/${TENANT}/${TENANT}.cm

    template {
    destination = "/vault/secrets/${PROFILE}"
    source      = "/vault/template/${PROFILE}.ctmpl"
    }
EOF
        for APP_POD in ${APP_PODS}
        do
            kubectl -n ${APPLICATION_NS} cp \
                ../config/pool/${TENANT}/template/${PROFILE}.ctmpl \
                ${APP_POD}:/vault/template/${PROFILE}.ctmpl \
                 -c vault-agent
        done
    done

    # Restart Vault agent to re-read the template file
    #
    # Vault SIGHUP Behavior
    # https://support.hashicorp.com/hc/en-us/articles/5767318985107-Vault-SIGHUP-Behavior
    #
    
    kubectl -n ${APPLICATION_NS} apply -f ../config/pool/${TENANT}/${TENANT}.cm

    for APP_POD in ${APP_PODS}
    do
        kubectl -n ${APPLICATION_NS} exec -i \
            ${APP_POD} -c vault-agent -- /bin/sh -c \
            "kill -HUP 1"
    done
done