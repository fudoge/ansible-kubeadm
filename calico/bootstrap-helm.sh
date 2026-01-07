#!/usr/bin/env bash

helm repo add projectcalico https://docs.tigera.io/calico/charts

kubectl create namespace tigera-operator

helm install calico projectcalico/tigera-operator --version v3.31.3 -f values.yaml --namespace tigera-operator
