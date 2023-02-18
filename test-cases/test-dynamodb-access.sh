export TENANT=tenanta

export AWS_SHARED_CREDENTIALS_FILE=/vault/secrets/${TENANT}
export AWS_PROFILE=${TENANT}

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenanta"}, "ProductID": {"S": "1"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenanta"}, "ProductID": {"S": "2"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantb"}, "ProductID": {"S": "3"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantb"}, "ProductID": {"S": "4"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantc-1"}, "ProductID": {"S": "5"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantc-2"}, "ProductID": {"S": "6"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantd-1"}, "ProductID": {"S": "7"}}'

aws dynamodb get-item \
    --table-name $TABLE_NAME \
    --key '{"ShardID": {"S": "tenantd-2"}, "ProductID": {"S": "8"}}'

