#!/usr/bin/env bash
source ~/.bash_profile

export APPLICATION_NS=tenanta

export TABLE_NAME="Products_${RANDOM_STRING}"
kubectl -n ${APPLICATION_NS} exec -i -t \
    $(kubectl -n ${APPLICATION_NS} get pod -l app=vault-agent-example \
    -o jsonpath='{.items[0].metadata.name}') -c myapp -- env TABLE_NAME=$TABLE_NAME /bin/sh

