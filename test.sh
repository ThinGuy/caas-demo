#!/bin/bash
printf '%s\n' smcup rmam civis|tput -S -
clear
# Cloud vars
export CLOUD=aws
export REGION=us-west-1
export CONTROLLER="${CLOUD}-${REGION}"

# Script vars
export PROG_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export PROG="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/${BASH_SOURCE[0]##*/}"
export BIN_DIR="${PROG_DIR}/bin"
export YAML_DIR="${PROG_DIR}/yaml"
export LMA_DIR="${PROG_DIR}/lma"
export LOG_DIR=${PROG_DIR}/log
export LOG=${LOG_DIR}/caas-demo-${CLOUD}.log
export FUNCTIONS="${BIN_DIR}/functions"
# Load demo functions
# ## todo - command w/out use of functions if missing
[[ -f ${FUNCTIONS} ]] && source ${FUNCTIONS} || { printf "Missing functions file! \n";exit; }
[[ -d ${LOG_DIR} ]] || mkdir -p ${LOG_DIR}
[[ -f ${LOG} ]] && rm -rf ${LOG}


# CDK vars
export CDK_RUNTIME=cotainerd # runtime can be either containerd or docker
export CDK_MODEL="cdk-${CLOUD}"
export CDK_BUNDLE=stable-kubernetes-${CLOUD}-bionic-${CDK_RUNTIME,,}.yaml
export IMG_STREAM=daily
export SERIES=bionic

# k8s vars
export KUBECONFIG="~/.kube/${CLOUD}-config"
export K8S_CLOUD="k8s-${CLOUD}"
export K8S_MODEL="k8s-gitlab-${CLOUD}"
export K8S_POOL="${K8S_MODEL}-pool"
export K8S_BUNDLE=${K8S_MODEL}.yaml
# number of database instances to deploy
export K8S_DB_SCALE=2
# number of work-load PVs needed (in this case, only mariadb-k8s needs it)
export K8S_WORKLOAD_PV_SCALE=2
file ${YAML_DIR}/${CLOUD}/${CDK_BUNDLE}
grep -oP '(?<=^export )[^=]+' $PROG|xargs -rn1 bash -c 'eval echo $0=\$${0}'
while true;do printf '\rHello there. this is a test\e[K';done
printf '%s\n' rmcup smam cnorm|tput -S -

