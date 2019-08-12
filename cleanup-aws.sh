#!/bin/bash
# This script will tear down what /srv/Dropbox/caas-demo/aws-demo.sh built
printf "\e[1mDestroying model and storage for aws-us-west-1:k8s-gitlab-aws\e[0m\n"
juju destroy-model k8s-gitlab-aws --destroy-storage -y
printf "\e[1mRemoving k8s cloud k8s-aws\e[0m\n"
juju remove-k8s k8s-aws
printf "\e[1mDestroying model and storage for cdk-aws\e[0m\n"
juju destroy-model cdk-aws --destroy-storage -y
printf "\e[1mDestroying controller aws-us-west-1\e[0m\n"
juju destroy-controller aws-us-west-1 --destroy-all-models --destroy-storage -y
