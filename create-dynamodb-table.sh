#!/usr/bin/env bash
source ~/.bash_profile

export TABLE_NAME="Products_${RANDOM_STRING}"

echo "Creating DynamoDB table ${TABLE_NAME}"
export DDB_TABLE=$(aws dynamodb create-table \
                    --table-name ${TABLE_NAME} \
                    --attribute-definitions \
                        AttributeName=ShardID,AttributeType=S \
                        AttributeName=ProductID,AttributeType=S \
                    --provisioned-throughput \
                        ReadCapacityUnits=5,WriteCapacityUnits=5 \
                    --key-schema \
                        AttributeName=ShardID,KeyType=HASH \
                        AttributeName=ProductID,KeyType=RANGE \
                    --table-class STANDARD
                    )

sleep 30

echo "Adding data to Products table"

aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenanta','ProductID':'1','ProductName':'SmartWatch'}"

aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenanta','ProductID':'2','ProductName':'PowerBank'}"
                
aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantb','ProductID':'3','ProductName':'AirFreshner'}"
                            
aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantb','ProductID':'4','ProductName':'BabyFormula'}"
                
aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantc-1','ProductID':'5','ProductName':'Book'}"

aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantc-2','ProductID':'6','ProductName':'SmartPhone'}"

aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantd-1','ProductID':'7','ProductName':'RingLight'}"

aws dynamodb execute-statement --statement "INSERT INTO ${TABLE_NAME}  \
                VALUE  \
                {'ShardID':'tenantd-2','ProductID':'8','ProductName':'Laptop'}"