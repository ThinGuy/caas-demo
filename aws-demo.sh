#!/bin/bash

# Container as a Service demo using Canonical's Foundation Kuberbetes Build
# Adapted current fkb/sku/stable-kubernetes-aws-bionic bundles on 2019-07-3

# Changes from fkb/sku/stable-kubernetes-aws-bionic master:
# - Add gui annotations so demo display nicely via the webui
# - Add nagios
# - Use containerd by default
# - - Docker version available as well 

# This script will deploy 
# 1) Deploy CDK on AWS
# 2) Create a k8s substrate in juju
# 2) Deploy a k8s bundle (gitlab) into the K8s substrate
# 3) Configure LMA Stack
# # todo CMR for LMA stack to k8s substrate

# Start vars

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
export LOG=${LOG_DIR}/demo.log
export FUNCTIONS="${BIN_DIR}/functions"

# Load demo functions
[[ -f ${FUNCTIONS} ]] && source ${FUNCTIONS} || { printf "Missing functions file! \n";exit; } #
[[ -d ${LOG_DIR} ]] || mkdir -p ${LOG_DIR}
[[ -f ${LOG} ]] && { rm -rf ${LOG};touch ${LOG}; } || touch ${LOG}


# CDK vars
export CDK_RUNTIME=docker # runtime can be either containerd or docker. Getting bad gateway with containerd
export CDK_MODEL="cdk-${CLOUD}"
export CDK_BUNDLE=stable-kubernetes-${CLOUD}-bionic-${CDK_RUNTIME,,}.yaml
export IMG_STREAM=daily
export SERIES=bionic

# k8s vars
export KUBECONFIG=${HOME}/.kube/${CLOUD}-config
export K8S_CLOUD="k8s-${CLOUD}"
export K8S_MODEL="k8s-gitlab-${CLOUD}"
export K8S_POOL="${K8S_MODEL}-pool"
export K8S_BUNDLE=${K8S_MODEL}.yaml
export K8S_DB_SCALE=2 # number of database instances to deploy
export K8S_WORKLOAD_PV_SCALE=2 # number of work-load PVs needed (in this case, only mariadb-k8s needs it)
export K8S_TZ='America/Los_Angeles'


# Set the start time
export CTIME=$(date +%s)

# End vars

# Save screen contents and clear the screen
printf '%s\n' smcup rmam civis clear|tput -x -S -
stty -echo
trap 'reset ; stty echo;printf '"'"'%s\n'"'"' rmcup smam cnorm|tput -S - ; trap - INT TERM EXIT ; [[ -n ${FUNCNAME} ]] && return || exit ; trap - INT TERM EXIT;' INT TERM EXIT

# Set the start time for CDK installation
export CTIME=$(date +%s)

banner -c -t "juju|k8s" -m " CDK & k8s Cloud Demo Part I "
printf "\n\e[2GStarting deployment of Canonical Kubernetes\n"

printf "\e[2G - Updating juju clouds"
juju update-clouds &>>${LOG};tstatus

# See if controller exists, if not, bootstrap it
if [[ -z $(juju 2>/dev/null controllers --format json|jq 2>/dev/null -r '.controllers|select(keys[]=="'${CONTROLLER}'")|keys[]') ]];then
  # Show a spinner while bootstrapping AWS controller
  { SPROG=$(juju bootstrap aws/${REGION} ${CONTROLLER} --bootstrap-series=${SERIES} --debug --show-log &>>${LOG}) &
  export SPID=$!
  export SWAIT=$(date +%s)
  STYPE=S spinner "\e[2G - Bootstrapping Juju controller on \"${CONTROLLER}\" on AWS:${REGION}"; } 2>/dev/null
  unset SPID SWAIT SPROG
else
  printf "\e[2G - Using exisiting Juju controller on \"${CONTROLLER}\" on AWS:${REGION}";tstatus
fi

if [[ -z $(juju 2>/dev/null models -c $CONTROLLER --format json|jq 2>/dev/null -r '.models[]|select(."short-name"=="'${CDK_MODEL}'")|."short-name"') ]];then
  printf "\e[2G - Adding model ${CDK_MODEL} to ${CLOUD}:${REGION}"
  # Add a model for CDK
  juju add-model -c ${CONTROLLER} --config image-stream=${IMG_STREAM} ${CDK_MODEL} &>>${LOG};tstatus
else
  printf "\e[2G - Using existing model ${CDK_MODEL} on ${CLOUD}:${REGION}";tstatus
fi

# Deploy Foundation K8s Build stable-kubernetes-aws-bionic
# Change CDK_BUNDLE variable to choose between
# containerd and docker runtimes
printf "\e[2G - Deploying ${CDK_BUNDLE} to ${CDK_MODEL}";
if [[ ${CLOUD,,} = aws ]];then 
	juju deploy -m ${CDK_MODEL} ${YAML_DIR}/${CLOUD}/${CDK_BUNDLE} \
	      --overlay ${YAML_DIR}/aws/integrator_overlay.yaml \
	      --overlay ${YAML_DIR}/aws/e2e_bundle.yaml &>>${LOG};tstatus
elif [[ ${CLOUD,,} = maas ]];then
	juju deploy -m ${CDK_MODEL} ${YAML_DIR}/${CLOUD}/${CDK_BUNDLE}
fi

# Let aws-integrator charm use our AWS credentials

[[ ${CLOUD,,} = aws ]] && printf "\e[2G - Allowing aws-integrator charm use our AWS credentials";
[[ ${CLOUD,,} = aws ]] && { juju trust -m ${CDK_MODEL} aws-integrator &>>${LOG};tstatus; }

# Get # of k8s-masters to wait for

export KMCOUNT=$(juju status -m ${CDK_MODEL} --format=json|jq 2>/dev/null -r '.applications["kubernetes-master"].units|to_entries[].key'|wc -l)
[[ ${KMCOUNT} -eq 1 ]] && W= || W=s

# Wait for k8s master(s) to display "Kubernetes master running."

export KM_RUNNING_COUNT=$(juju status -m ${CDK_MODEL} --format=json|jq 2>/dev/null -r '.applications["kubernetes-master"].units|to_entries[]|select(.value."workload-status".message=="Kubernetes master running.").key'|wc -l)
printf '%s\n' rmam civis|tput -S -
export SWAIT=$(date +%s)
while [[ ${KM_RUNNING_COUNT} -lt ${KMCOUNT} ]];do
	tput sc 
	printf "\r\e[2G - Waiting for ${KMCOUNT} Kubernetes Master${W} to become ready (elapsed task time: $(duration $SWAIT))\e[K\n"
	export KM_RUNNING_COUNT=$(juju status -m ${CDK_MODEL} --format=json|jq 2>/dev/null -r '.applications["kubernetes-master"].units|to_entries[]|select(.value."workload-status".message=="Kubernetes master running.").key'|wc -l)
	JS="$(juju status -m ${CDK_MODEL} kubernetes-master --color|awk '/Unit/{flag=1;next}/^$/{flag=0}flag {gsub(/^ .*$/,"");print}'|sed '/^$/d'|sed 's/^.*$/      &/g')"
	echo -e "$JS"|while IFS= read -r line;do tput el1 && tput el && echo -e "$line";done
	sleep 1
	printf '%s\n' rc|tput -S -
done
unset SWAIT W
printf '%s\n' cud1 smam cnorm|tput -S -


printf "\n\n\e[2GPreparing k8s dashboard access\n"

# Kill existing proxy and start a new one with the new config

[[ $(pgrep -f 'kubectl proxy') ]] && { printf "\e[2G - Killing existing kubectl proxy";pgrep -f 'kubectl proxy'|xargs -rn1 -P0 sudo kill -9;tstatus; }

# Delete older kubectl config files and remake directory

[[ -f ${KUBECONFIG} ]] && rm -rf ${KUBECONFIG}
[[ -d ${KUBECONFIG%/*} ]] || mkdir -p ${KUBECONFIG%/*}

# Download new kubectl config

printf "\e[2G - Downloading kubectl config from kubernetes-master/0 to ${KUBECONFIG}";
juju scp -m ${CDK_MODEL} kubernetes-master/0:config "${KUBECONFIG}" &>>${LOG};tstatus

# Ensure kubectl is installed

command -v kubectl &>/dev/null || { printf "\e[2G - Installing kubectl snap";sudo snap install kubectl --classic &>>${LOG};tstatus; }

# These are both exposed in the bundle, but keeping here for reference

printf "\e[2G - Enabling k8s dashboard add-ons"
juju 2>/dev/null config -m ${CDK_MODEL} kubernetes-master enable-dashboard-addons=true &>>${LOG};tstatus
printf "\e[2G - Setting k8s workers ingress setting to \"true\""
juju 2>/dev/null config -m ${CDK_MODEL} kubernetes-worker ingress=true &>>${LOG};tstatus


# Start kubectl proxy

printf "\e[2G - Starting new instance of kubectl proxy"
KUBECONFIG=${KUBECONFIG} kubectl proxy &>>${LOG} & tstatus

# Launch a browser to the k8s dashboard

[[ -n $(command 2>/dev/null -v google-chrome) ]] && export BROWSER=google-chrome
[[ -z ${BROWSER} && -n $(command 2>/dev/null -v firefox) ]] && export BROWSER=firefox

[[ $(command 2>/dev/null -v ${BROWSER}) ]] && { printf "\e[2G - Starting browser session to k8s dashboard";${BROWSER} 2>/dev/null 'http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!/login' & &>>${LOG};tstatus;  }

# Get list of deployed apps so we can determine what needs configuring in the LMA stack

declare -ag JUJU_APPS=($(juju 2>/dev/null status -m ${CDK_MODEL} --utc --format=json|jq 2>/dev/null -r '.applications | to_entries[].key'))

# Small function to check if app is deployed

check-juju-app() { local A=${1};(grep -qP '(^|\s)\K'"${A}"'(?=\s|$)' <<< ${JUJU_APPS[@]}) && { true;return 0; } || { false;return 1; }; }

# Configure LMA Stack

printf "\n\n\e[2GConfiguring Logging, Monitoring, and Alerting (LMA) Stack\n"

if [[ $(check-juju-app nagios;echo $?) -eq 0 ]];then
	printf "\e[2G - Gathering nagios information"
	# Nagios
	NAGIOS_LDR=$(juju 2>/dev/null status -m ${CDK_MODEL} nagios|awk '/^nagios.*\*/{gsub(/*/,"");print $1}')
	NAGIOS_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${NAGIOS_LDR} unit-get public-address)
	NAGIOS_USER=nagiosadmin
	NAGIOS_PASS=$(juju 2>/dev/null run -m ${CDK_MODEL} --app nagios 'sudo cat /var/lib/juju/nagios.passwd')
	NAGIOS_URL="http://${NAGIOS_IP}:80"
	[[ -n ${NAGIOS_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app graylog;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering graylog information"
  # Graylog
  GRAYLOG_LDR=$(juju 2>/dev/null status -m ${CDK_MODEL} graylog|awk '/^graylog.*\*/{gsub(/*/,"");print $1}')
  GRAYLOG_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${GRAYLOG_LDR} unit-get public-address)
  GRAYLOG_USER=admin
  GRAYLOG_PASS=$(juju 2>/dev/null run-action -m ${CDK_MODEL} --wait ${GRAYLOG_LDR} show-admin-password|grep -oP '(?<=admin-password: )[^$]+')
  GRAYLOG_URL="http://${GRAYLOG_IP}:9000"
  [[ -n ${GRAYLOG_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app grafana;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering grafana information"
  # GRAFANA
  GRAFANA_LDR=$(juju 2>/dev/null status -m ${CDK_MODEL} grafana|awk '/^grafana.*\*/{gsub(/*/,"");print $1}')
  GRAFANA_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${GRAFANA_LDR} unit-get public-address)
  GRAFANA_USER=admin
  GRAFANA_PASS=$(juju 2>/dev/null run-action -m ${CDK_MODEL} --wait ${GRAFANA_LDR} get-admin-password|grep -oP '(?<=password: )[^$]+')
  GRAFANA_PORT=$(juju 2>/dev/null config -m ${CDK_MODEL} grafana port)
  GRAFANA_URL="http://${GRAFANA_IP}:${GRAFANA_PORT}"
  GRAYLOG_INGRESS_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit graylog/0 'network-get elasticsearch --format yaml --ingress-address' | head -1)
  [[ -n ${GRAFANA_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

# Get kubectl client password

printf "\e[2G - Gathering k8s client credentials"
K8S_PASSWD=$(grep 2>/dev/null -oP '(?<=^    password: )[^/]+' ${KUBECONFIG})
[[ -n ${K8S_PASSWD} ]] && { true;tstatus; } || { false;tstatus; }

# Get KubeAPI LB Ingress IP address

printf "\e[2G - Gathering KubeAPI LB Ingress IP address"
KUBEAPI_INGRESS_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit kubeapi-load-balancer/0 'network-get website --format yaml --ingress-address' | head -1)
[[ -n ${KUBEAPI_INGRESS_IP} ]] && { true;tstatus; } || { false;tstatus; }

# APACHE2 (used as rev proxy)

if [[ $(check-juju-app apache2;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering apache2 information"
  APACHE2_LDR=$(juju 2>/dev/null status -m ${CDK_MODEL} apache2|awk '/^apache2.*\*/{gsub(/*/,"");print $1}')
  [[ -n ${APACHE2_LDR} ]] && APACHE_IP=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${APACHE2_LDR} unit-get public-address)
  [[ -n ${APACHE2_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

# ELASTICSEARCH  

if [[ $(check-juju-app elasticsearch;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering elasticsearch information"
  ES_CLUSTER_NAME=$(juju 2>/dev/null config -m ${CDK_MODEL} elasticsearch cluster-name | sed -e 's/"//g')
  [[ -n ${ES_CLUSTER_NAME} ]] && { true;tstatus; } || { false;tstatus; }
fi

# Configure k8s prometheus scraper

if [[ $(check-juju-app prometheus;echo $?) -eq 0 ]];then
  if [[ -n ${KUBEAPI_INGRESS_IP} && -n ${K8S_PASSWD} ]];then
    printf "\e[2G - Configuring k8s prometheus scraper"
    juju 2>/dev/null config -m ${CDK_MODEL} prometheus \
      scrape-jobs=$(sed 's/K8S_PASSWORD/'"${K8S_PASSWD}"'/g;s/K8S_API_ENDPOINT/'"${KUBEAPI_INGRESS_IP}"'/g' ${PROG_DIR}/lma/prometheus-scrape-k8s.yaml) &>> ${LOG};tstatus
  fi
fi

# Setup grafana dashboards

if [[ $(check-juju-app grafana;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring grafana dashboards"
  printf "\e[2G - Configuring grafana dashboard \"grafana-telegraf\""
  juju 2>/dev/null run-action -m ${CDK_MODEL} --wait grafana/0 import-dashboard dashboard="$(base64 ${PROG_DIR}/lma/grafana-telegraf.json)" &>> ${LOG};tstatus
  printf "\e[2G - Configuring grafana dashboard \"grafana-k8s\""
  juju 2>/dev/null run-action -m ${CDK_MODEL} --wait grafana/0 import-dashboard dashboard="$(base64 ${PROG_DIR}/lma/grafana-k8s.json)" &>> ${LOG};tstatus
fi

# Setup Filebeat to use graylog as a logstash host.

if [[ $(check-juju-app filebeat;echo $?) -eq 0 ]];then
  if [[ -n ${GRAYLOG_INGRESS_IP} ]];then
    printf "\e[2G - Configuring filebeat to use graylog"
    juju 2>/dev/null config -m ${CDK_MODEL} filebeat logstash_hosts="${GRAYLOG_INGRESS_IP}:5044" &>> ${LOG};tstatus
  fi
fi

# Graylog needs a rev proxy

if [[ $(check-juju-app apache2;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring graylog's reverse proxy server"
  juju 2>/dev/null config -m ${CDK_MODEL} apache2 vhost_http_template="$(base64 ${PROG_DIR}/lma/graylog-vhost.tmpl)" &>> ${LOG};tstatus
fi
 
# Graylog needs ES cluster name

if [[ $(check-juju-app graylog;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring graylog's elasticsearch cluster name"
  [[ -n ${ES_CLUSTER_NAME} ]] && { printf "\e[2G - Configuring graylog's elasticsearch cluster name";juju 2>/dev/null config -m ${CDK_MODEL} graylog elasticsearch_cluster_name="${ES_CLUSTER_NAME}" &>> ${LOG};tstatus; }
fi

# Display URLs and Credentials for LMA Stack

[[ -n ${NAGIOS_USER} ]] && printf "\e[4G\e[1mNagios\n\e[4G══════\n\e[0m\e[6G\e[1mUser:\e[0m ${NAGIOS_USER}\n\e[6G\e[1mPassword:\e[0m ${NAGIOS_PASS}\n\e[6G\e[1mURL:\e[0m ${NAGIOS_URL}\n\n"
[[ -n ${GRAFANA_USER} ]] && printf "\e[4G\e[1mGrafana\n\e[4G═══════\n\e[0m\e[6G\e[1mUser:\e[0m ${GRAFANA_USER}\n\e[6G\e[1mPassword:\e[0m ${GRAFANA_PASS}\n\e[6G\e[1mURL:\e[0m ${GRAFANA_URL}\n\n"
[[ -n ${GRAYLOG_USER} ]] && printf "\e[4G\e[1mGraylog\n\e[4G═══════\n\e[0m\e[6G\e[1mUser:\e[0m ${GRAYLOG_USER}\n\e[6G\e[1mPassword:\e[0m ${GRAYLOG_PASS}\n\e[6G\e[1mURL:\e[0m ${GRAYLOG_URL}\n\n"
[[ -n ${GRAYLOG_USER} ]] && printf "\e[6GNOTE: Graylog configuration may still be in progress. It may take up to 5 minutes for\nthe web interface to become ready.\n\n"

# Display CDK Time

printf "\n\e[1GDeployment of CDK finished in $(duration ${CTIME})\e[0m\n\n"
sleep 5

# Set the start time for our k8s cloud
export KTIME=$(date +%s)

banner -c -t "juju|k8s" -m " CDK & k8s Cloud Demo Part II "
printf "\n\e[2GCreating a k8s cloud\n\n"
# Add a "Kubernetes" cloud under the controller that we used to deploy CDK
# Don't change the names here
printf "\e[2G - Adding k8s substrate \"${K8S_CLOUD}\" juju controller ${CONTROLLER}"
KUBECONFIG=${KUBECONFIG} juju add-k8s ${K8S_CLOUD} --cloud aws --region=${REGION} --controller=${CONTROLLER} --cluster-name juju-cluster --storage=default &>>${LOG};tstatus;

# Create a model on our new k8s cloud
printf "\e[2G - Adding k8s model \"${K8S_MODEL}\" to  \"${K8S_CLOUD}\""
juju add-model -c ${CONTROLLER} ${K8S_MODEL} ${K8S_CLOUD} &>>${LOG};tstatus;

# Configure persistent Volumes

# Note: storageClassName must be prefaced by
#       you just added to the k8s cloud
#       (NOT the model name where CDK is deploy)
printf "\n\e[2GConfiguring model-specific persistent storage for \"${K8S_MODEL}\"\n"
printf "\e[2G - Creating k8s persistent volumes (pv) for operator-storage in k8s model \"${K8S_MODEL}\"\n\e[4G - Purpose: k8s internal/undercloud storage requirements\n\e[4G - Name: \"op1\"\n\e[4G - Size: 1032MiB\n\e[4G - storageClassName: \"${K8S_MODEL}-juju-operator-storage\"\n\n"
KUBECONFIG=${KUBECONFIG} kubectl &>>${LOG} create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: op1
spec:
  capacity:
    storage: 1032Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${K8S_MODEL}-juju-operator-storage
  hostPath:
    path: "/mnt/data/op1"
EOF
[[ $? -eq 0 ]] && { tput sc;tput cuu 6;tstatus;tput rc; }

# Note you need a workload pv for each unit that requires storage.  e.g. we are deploying two instances fo mariadb-k8s, so we've created two volumes
for P in $(seq 1 1 ${K8S_WORKLOAD_PV_SCALE});do
  printf "\e[2G - Creating k8s pv #${P} for workload storage in k8s model \"${K8S_MODEL}\"\n\e[4G - Purpose: application storage requirements\n\e[4G - Name: \"vol${P}\"\n\e[4G - Size: 100MiB\n\e[4G - storageClassName: \"${K8S_MODEL}-juju-unit-storage\"\n\n"
  KUBECONFIG=${KUBECONFIG} kubectl &>>${LOG} create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vol${P}
spec:
  capacity:
    storage: 100Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${K8S_MODEL}-juju-unit-storage
  hostPath:
    path: "/mnt/data/vol{P}"
EOF
  [[ $? -eq 0 ]] && { tput sc;tput cuu 6;tstatus;tput rc; }
done

printf "\e[2GCreating Juju Storage Pools\n"
printf "\e[2G - Creating operator storage-pool \"operator-storage\""

# Create operator storage pool
# Note: must be called operator-storage
juju create-storage-pool operator-storage kubernetes \
    storage-class=juju-operator-storage \
    storage-provisioner=kubernetes.io/no-provisioner &>>${LOG};tstatus;

printf "\e[2G - Creating application storage-pool \"${K8S_POOL}\""

# Create application storage pool
# Note: pool name should match the model name
#       you just added to the k8s cloud
#       (NOT the model name where CDK is deploy)
juju create-storage-pool ${K8S_POOL} kubernetes \
    storage-class=juju-unit-storage \
    storage-provisioner=kubernetes.io/no-provisioner &>>${LOG};tstatus;

# Note: You cannot expose a CAAS application without a "juju-external-hostname"
#      value set, run juju config <caas-app> juju-external-hostname=<value> 

# Get IP address of k8s-worker which will be used for public ingress
export KWLDR=$(juju run -m ${CDK_MODEL} --application kubernetes-worker is-leader --format=json|jq -r '.[]|select(.Stdout=="True\n").UnitId')
export KWPI=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${KWLDR} 'unit-get public-address')

[[ -n ${KWPI} ]] && export GIT_FQDN=${KWPI}.xip.io


#### Note:  Currently using a bundle winds up with server relation errror on Mariadb.  Deploy individually
####        for now

printf "\e[2GPreparing k8s bundle\n\e[2G - Name: ${K8S_BUNDLE}\n\e[2G - Location: ${YAML_DIR}/aws/\n"

# Deploy applications into CDK cluster using a k8s bundle

# Note: k8s bundles differs from a standard bundle in the following ways:
# - "bundle:" key is given the value of kubernetes
# - "series:" key is given the value of kubernetes
# - "num_units:" is replaced by key "scale:"
# - "to:" is replaced by key placement: 
# - Can only expose a CAAS application if "juju-external-hostname" is set

cat <<EOF> ${YAML_DIR}/aws/${K8S_BUNDLE}
bundle: kubernetes
applications:
  mariadb-k8s:
    charm: cs:~juju/mariadb-k8s
    scale: 2
    constraints: mem=2G
    storage:
      database: ${K8S_MODEL}-pool,20M
  gitlab-k8s:
    charm: cs:~juju/gitlab-k8s
    options:
      juju-external-hostname: ${KWPI}.xip.io
      kubernetes-ingress-allow-http: True
    expose: true
    scale: 1
relations:
  - [ 'gitlab-k8s:mysql', 'mariadb-k8s:server' ]
EOF

# Deploy the k8s bundle (RFE for juju to accept bundles from stdin?)
printf "\n\e[2G - Deploying ${K8S_BUNDLE} into ${K8S_CLOUD}:${K8S_MODEL}"
juju deploy -m ${CONTROLLER}:${K8S_MODEL} ${YAML_DIR}/aws/${K8S_BUNDLE} &>>${LOG};tstatus;

# CLI version of the above bundle

#printf "\n\e[2GDeploying application into k8s cloud\n"

# Get k8s-w leader unit

#export KWLDR=$(juju run -m ${CDK_MODEL} --application kubernetes-worker is-leader --format=json|jq -r '.[]|select(.Stdout=="True\n").UnitId')

# Get IP address of k8s-w leader which will be used for public ingress

#export KWPI=$(juju 2>/dev/null run -m ${CDK_MODEL} --unit ${KWLDR} 'unit-get public-address')
[[ -n ${KWPI} ]] && export GIT_FQDN=${KWPI}.xip.io
# Deploy Charms

#printf "\e[2G - Deploying gitlab-k8s charm into ${K8S_CLOUD}:${K8S_MODEL}"
#juju deploy -m ${CONTROLLER}:${K8S_MODEL} cs:~juju/gitlab-k8s &>> ${LOG};tstatus;
#printf "\e[2G - Deploying mariadb-k8s charm into ${K8S_CLOUD}:${K8S_MODEL}"
#juju deploy -m ${CONTROLLER}:${K8S_MODEL} cs:~juju/mariadb-k8s --storage database=${K8S_MODEL}-pool,20M &>> ${LOG};tstatus;

# Scale out mariadb

#printf "\e[2G - Scaling out mariadb-k8s to 2 instances"
#juju scale-application -m ${CONTROLLER}:${K8S_MODEL} mariadb-k8s 2 &>> ${LOG};tstatus;

# Relate Charms

#printf "\e[2G - Relating gitab to mariadb-k8s"
#juju relate -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s mariadb-k8s &>> ${LOG};tstatus;

# Set external hostnames for gitlab application

printf "\e[2G - Setting externally reachable hostname for gitlab service via xip.io DNS service"
juju 2>/dev/null config -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s juju-external-hostname=${GIT_FQDN} &>> ${LOG};tstatus;

#printf "\e[2G - Setting gitlab external_url to http://${KWPI}.xip.io/"
#juju 2>/dev/null config -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s external_url="http://${GIT_FQDN}/" &>> ${LOG};tstatus;

# Allow http traffic on ingress

printf "\e[2G - Allowing http traffic on ingress"
juju config gitlab-k8s kubernetes-ingress-allow-http=true &>> ${LOG};tstatus;

# Setting time zone

printf "\e[2G - Setting gitlab timezone to ${K8S_TZ}"
juju config gitlab-k8s time_zone=${K8S_TZ} &>> ${LOG};tstatus;

# Expose gitlab to the interwebs

printf "\e[2G - Exposing service gitlab-k8s"
juju expose -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s &>> ${LOG};tstatus;

# Wait until apps are ready

export K8S_APP_COUNT=$(juju status -m ${K8S_MODEL} --format=json|jq 2>/dev/null -r '.applications[]|.scale'|paste -sd+|bc)
[[ ${K8S_APP_COUNT} -eq 1 ]] && W= || W=s
export K8S_APP_AI_COUNT=$(juju status -m ${K8S_MODEL} --format=json|jq 2>/dev/null -r '.applications[].units|to_entries[]|select((.value."workload-status".current=="active") and .value."juju-status".current=="idle").key'|wc -l)
export K8S_WAIT=$(date +%s)
printf '%s\n' rmam civis|tput -S -
while [[ ${K8S_APP_AI_COUNT} -lt ${K8S_APP_COUNT} ]];do
	printf "\r\e[2G - Waiting for ${K8S_APP_COUNT} application${W} to become ready (elapsed task time: $(duration $K8S_WAIT))\e[K\n"
	export K8S_APP_AI_COUNT=$(juju status -m ${K8S_MODEL} --format=json|jq 2>/dev/null -r '.applications[].units|to_entries[]|select((.value."workload-status".current=="active") and .value."juju-status".current=="idle").key'|wc -l)
  	JS="$(juju status -m ${K8S_MODEL} --color|awk '/Unit/{flag=1;next}/^$/{flag=0}flag {gsub(/^ .*$/,"");print}'|sed '/^$/d'|sed 's/^.*$/      &/g')"
	CUU=$(echo "$JS"|wc -l)
	echo -e "$JS"|sed '/^$/d'|while IFS= read -r line;do { tput el1 && tput el && echo -e "$line"; };done
	sleep 1
  	tput cuu $((${CUU}+1))
done
printf '%s\n' cud1 smam cnorm|tput -S -
unset K8S_WAIT W


# Allow things to settle

countdown -t 60 -p Waiting -P "to allow environment to settle"


# Fix 1MB upload limit on nginx ingress

#printf "\n\e[2GFixing 1MB upload limit ${K8S_MODEL} namespace ingress\n"

#printf "\e[2G - Downloading ingress configuration"
#KUBECONFIG=${KUBECONFIG} kubectl get ingress -n ${K8S_MODEL} -o yaml|tee "/tmp/${K8S_MODEL}-ingress.yaml" &>>${LOG};tstatus;

#printf "\e[2G - Editing ingress configuration"
#sed '/    annotations:/a \ \ \ \ \ \ nginx.ingress.kubernetes.io/proxy-body-size: "0"' -i "/tmp/${K8S_MODEL}-ingress.yaml" &>>${LOG};tstatus;

#printf "\e[2G - Uploading ingress configuration"
#KUBECONFIG=${KUBECONFIG} kubectl replace -n ${K8S_MODEL} -f "/tmp/${K8S_MODEL}-ingress.yaml" &>>${LOG};tstatus;

# Create cleanup script

cat <<EOF |tee 1>/dev/null ${PROG_DIR}/cleanup-${CLOUD}.sh
#!/bin/bash
# This script will tear down what $PROG built
printf "\e[1mDestroying model and storage for ${CONTROLLER}:${K8S_MODEL}\e[0m\n"
juju destroy-model ${K8S_MODEL} --destroy-storage -y
printf "\e[1mRemoving k8s cloud ${K8S_CLOUD}\e[0m\n"
juju remove-k8s ${K8S_CLOUD}
printf "\e[1mDestroying model and storage for ${CDK_MODEL}\e[0m\n"
juju destroy-model ${CDK_MODEL} --destroy-storage -y
printf "\e[1mDestroying controller ${CONTROLLER}\e[0m\n"
juju destroy-controller ${CONTROLLER} --destroy-all-models --destroy-storage -y
EOF

[[ -f ${PROG_DIR}/cleanup-${CLOUD}.sh ]] && { chmod +x ${PROG_DIR}/cleanup-${CLOUD}.sh; }


# Display final messages

printf "\e[1GDeployment of Kubernetes Cloud \"${K8S_CLOUD}\" finished in $(duration ${KTIME})\e[0m\n\n"
printf "\e[4G -- \e[1mDemo cleanup script available @ ${PROG_DIR}/cleanup-${CLOUD}.sh\e[0m\n"


# Wait for gitlab instance to respond with status code of 200

GWAIT=$(date +%s)
export GIT_URL="http://${GIT_FQDN}/users/sign_in?redirect_to_referer=yes#register-pane"
printf '%s\n' rmam civis|tput -S -
while [[ ! $(test-url ${GIT_URL}) = 200 ]];do 
	printf "\r\e[2G - Waiting for http://${GIT_FQDN} to become ready (elapsed task time: $(duration $GWAIT))\e[K"
	sleep 2
done
printf '%s\n' cud1 smam cnorm|tput -S -

# When gitlab-k8s is responding, launch a broswer

[[ -n $(command -v $BROWSER) ]] && { ${BROWSER} 2>/dev/null ${GIT_URL}; }

banner -t "Canonical|k8s" -c -m " End to End Deployment time: $(duration ${CTIME}) "

read -p 'Press enter to continue' CONT

# Cleanup vars set by this script

for V in $(grep -oP '(?<=^export )[^=]+' ${PROG}|sort -u);do unset $V;done

# Clear traps, restore the screen contents, and exit

trap - INT TERM EXIT
printf '%s\n' sgr0 rmcup smam cnorm|tput -x -S -
stty echo
exit 0

