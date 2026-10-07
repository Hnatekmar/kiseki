#!/bin/bash

# Creates or recreates cluster for testing

CLUSTER_NAME=dev-envs-test-cluster

if kind get clusters | grep $CLUSTER_NAME; then
  echo "Cluster already exists destroying it and then bringing it up"
  kind delete clusters $CLUSTER_NAME
fi

kind create cluster --name $CLUSTER_NAME
