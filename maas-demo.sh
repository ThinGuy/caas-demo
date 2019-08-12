#!/bin/bash

# Container as a Service demo using Canonical's Foundation Kuberbetes Build
# Adapted current fkb/sku/stable-kubernetes-maas-bionic bundles on 2019-07-3

# Changes from fkb/sku/stable-kubernetes-maas-bionic master:
# - Add gui annotations so demo display nicely via the webui
# - Add nagios
# - Use containerd by default
# - - Docker version available as well 

# This script will deploy 
# 1) Deploy CDK on MAAS (Orangebox)
# 2) Configure LMA Stack
# 3) Create a k8s substrate in juju
# 4) Deploy a k8s bundle (gitlab) into the K8s substrate
# # todo CMR for LMA stack to k8s substrate


export CLOUD=maas
export REGION=
export CONTROLLER=${CLOUD}


export CDK_MODEL=cdk-${CLOUD}
export CDK_BUNDLE=stable-kubernetes-maas-bionic-containerd-orangebox.yaml
# export CDK_BUNDLE=stable-kubernetes-maas-bionic-docker.yaml
export IMG_STREAM=daily
export SERIES=bionic


export KUBECONFIG=~/.kube/${CLOUD}-config
export K8S_CLOUD=k8s-cloud-${CLOUD}
export K8S_MODEL=gitlab-${CLOUD}
export K8S_POOL=gitlab-${CLOUD}-pool
export K8S_BUNDLE=k8s-caas-demo.yaml

export DEMO_DIR=~/caas-demo
export LOG_DIR=${DEMO_DIR}/log
export LOG=${LOG_DIR}/caas-demo-${CLOUD}.log
[[ -d ${LOG_DIR} ]] || mkdir -p ${LOG_DIR}

# Load demo functions
# ## todo - command w/out use of functions if missing
[[ -f ${DEMO_DIR}/bin/caas-demo-functions.sh ]] && source ${DEMO_DIR}/bin/caas-demo-functions.sh || { printf "Missing functions file! \n";exit; }



# Set the start time
export CTIME=$(date +%s)

# Save screen contents and clear the screen
printf '%s\n' smcup rmam civis clear|tput -S -

trap 'printf '"'"'%s\n'"'"' sgr0 rmcup smam cnorm|tput -S -;trap - INT TERM EXIT; || clear; [[ -n ${FUNCNAME} ]] && return 0;trap - INT TERM EXIT;' INT TERM EXIT

# Set the start time for CDK installation
export CTIME=$(date +%s)

banner -c -t "juju|k8s" -m " CDK & k8s Cloud Demo Part I "
printf "\n\e[2GStarting deployment of Canonical Kubernetes\n"

printf "\e[2G - Updating juju clouds"
juju update-clouds &>> ${LOG};tstatus

# Show a spinner while bootstrapping ${CLOUD} controller
{ SPROG=$(juju bootstrap ${CLOUD} ${CONTROLLER} --bootstrap-series=${SERIES} --debug --show-log &>> ${LOG}) &
export SPID=$!
export SWAIT=$(date +%s)
STYPE=S spinner "\e[2G - Bootstrapping Juju controller on \"${CONTROLLER}\" on ${CONTROLLER}"; } 2>/dev/null
unset SPID SWAIT SPROG

printf "\e[2G - Adding model ${CDK_MODEL} to ${CLOUD}"
# Add a model for CDK
juju add-model -c ${CONTROLLER} --config image-stream=${IMG_STREAM} ${CDK_MODEL}  &>> ${LOG};tstatus

# Deploy Foundation K8s Build stable-kubernetes-${CLOUD}-bionic
# Change CDK_BUNDLE variable to choose between
# containerd and docker runtimes
printf "\e[2G - Deploying ${CDK_BUNDLE} to ${CONTROLLER}:${CDK_MODEL}";
juju deploy -m ${CONTROLLER}:${CDK_MODEL} \
      ${DEMO_DIR}/yaml/${CLOUD}/${CDK_BUNDLE} &>> ${LOG};tstatus


# Show a spinner while we wait for k8s master to be ready
{ SPROG=$(juju ssh 2>/dev/null -m ${CONTROLLER}:controller --pty=true 0 'sudo tail -n +0 --pid=$$ -f /var/log/juju/logsink.log | { sed '"'"'/kubernetes-master\/[0,1].*Kubernetes master running/ q'"'"' &>/dev/null && kill $$ ;}') &
export SPID=$!
export SWAIT=$(date +%s)
STYPE=S spinner "\e[2G - Waiting for Kubernetes Master to become ready"; } 2>/dev/null
unset SPID SWAIT SPROG

printf "\n\n\e[2GPreparing k8s dashboard access\n"
# Delete older kubectl config files and remake directory
[[ -f ${KUBECONFIG} ]] && rm -rf ${KUBECONFIG%/*}
mkdir -p ${KUBECONFIG%/*}

# Download new kubectl config
printf "\e[2G - Downloading kubectl config from kubernetes-master/0 to ${KUBECONFIG}";
juju scp -m ${CONTROLLER}:${CDK_MODEL} kubernetes-master/0:config ${KUBECONFIG} &>> ${LOG};tstatus

# Ensure kubectl is installed
command -v kubectl &>/dev/null || { printf "\e[2G - Installing kubectl snap";sudo snap install kubectl --classic &>> ${LOG};tstatus; }

printf "\e[2G - Enabling k8s dashboard add-ons"
# These are both exposed in the bundle, but keeping here for reference
juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} kubernetes-master enable-dashboard-addons=true &>> ${LOG};tstatus
printf "\e[2G - Setting k8s workers ingress setting to \"true\""
juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} kubernetes-worker ingress=true &>> ${LOG};tstatus

# Kill existing proxy and start a new one with the new config
[[ $(pgrep -f 'kubectl proxy') ]] && { printf "\e[2G - Killing existing kubectl proxy";pgrep -f 'kubectl proxy'|xargs -rn1 -P0 sudo kill -9;tstatus; }
printf "\e[2G - Starting new instance of kubectl proxy"
KUBECONFIG=${KUBECONFIG} kubectl proxy &>> ${LOG} & tstatus

# Launch a browser to the k8s dashboard
[[ $(command -v google-chrome) ]] && { printf "\e[2G - Starting browser session to k8s dashboard";google-chrome 2>/dev/null 'http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!/login' & &>> ${LOG};tstatus;  }


# Check if apps are deployed
declare -ag JUJU_APPS=($(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL} --utc --format=json|jq 2>/dev/null -r '.applications | to_entries[].key'))
check-juju-app() { local A=${1};(grep -qP '(^|\s)\K'"${A}"'(?=\s|$)' <<< ${JUJU_APPS[@]}) && { true;return 0; } || { false;return 1; }; }

# Configure LMA Stack
printf "\n\n\e[2GConfiguring Logging, Monitoring, and Alerting (LMA) Stack\n"

if [[ $(check-juju-app nagios;echo $?) -eq 0 ]];then
	printf "\e[2G - Gathering nagios information"
	# Nagios
	NAGIOS_LDR=$(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL} nagios|awk '/^nagios.*\*/{gsub(/*/,"");print $1}')
	NAGIOS_IP=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit ${NAGIOS_LDR} unit-get public-address)
	NAGIOS_USER=nagiosadmin
	NAGIOS_PASS=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --app nagios 'sudo cat /var/lib/juju/nagios.passwd')
	NAGIOS_URL="http://${NAGIOS_IP}:80"
	[[ -n ${NAGIOS_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app graylog;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering graylog information"
  # Graylog
  GRAYLOG_LDR=$(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL} graylog|awk '/^graylog.*\*/{gsub(/*/,"");print $1}')
  GRAYLOG_IP=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit ${GRAYLOG_LDR} unit-get public-address)
  GRAYLOG_USER=admin
  GRAYLOG_PASS=$(juju 2>/dev/null run-action -m ${CONTROLLER}:${CDK_MODEL} --wait ${GRAYLOG_LDR} show-admin-password|grep -oP '(?<=admin-password: )[^$]+')
  GRAYLOG_URL="http://${GRAYLOG_IP}:9000"
  [[ -n ${GRAYLOG_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app grafana;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering grafana information"
  # GRAFANA
  GRAFANA_LDR=$(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL} grafana|awk '/^grafana.*\*/{gsub(/*/,"");print $1}')
  GRAFANA_IP=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit ${GRAFANA_LDR} unit-get public-address)
  GRAFANA_USER=admin
  GRAFANA_PASS=$(juju 2>/dev/null run-action -m ${CONTROLLER}:${CDK_MODEL} --wait ${GRAFANA_LDR} get-admin-password|grep -oP '(?<=password: )[^$]+')
  GRAFANA_PORT=$(juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} grafana port)
  GRAFANA_URL="http://${GRAFANA_IP}:${GRAFANA_PORT}"
  GRAYLOG_INGRESS_IP=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit graylog/0 'network-get elasticsearch --format yaml --ingress-address' | head -1)
  [[ -n ${GRAFANA_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

printf "\e[2G - Gathering k8s client credentials"
# Get kubectl client password
K8S_PASSWD=$(grep 2>/dev/null -oP '(?<=^    password: )[^/]+' ${KUBECONFIG})
[[ -n ${K8S_PASSWD} ]] && { true;tstatus; } || { false;tstatus; }

printf "\e[2G - Gathering KubeAPI LB Ingress IP address"
# Get KubeAPI LB Ingress IP address
KUBEAPI_INGRESS_IP=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit kubeapi-load-balancer/0 'network-get website --format yaml --ingress-address' | head -1)
[[ -n ${KUBEAPI_INGRESS_IP} ]] && { true;tstatus; } || { false;tstatus; }

if [[ $(check-juju-app apache2;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering apache2 information"
  # APACHE2 (used as rev proxy)
  APACHE2_LDR=$(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL} apache2|awk '/^apache2.*\*/{gsub(/*/,"");print $1}')
  [[ -n ${APACHE2_LDR} ]] && APACHE_IP=$(juju 2>/dev/null status -m ${CONTROLLER}:${CDK_MODEL}-m ${CONTROLLER}:${CDK_MODEL} --unit ${APACHE2_LDR} unit-get public-address)
  [[ -n ${APACHE2_LDR} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app elasticsearch;echo $?) -eq 0 ]];then
  printf "\e[2G - Gathering elasticsearch information"
  # ELASTICSEARCH  
  ES_CLUSTER_NAME=$(juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} elasticsearch cluster-name | sed -e 's/"//g')
  [[ -n ${ES_CLUSTER_NAME} ]] && { true;tstatus; } || { false;tstatus; }
fi

if [[ $(check-juju-app prometheus;echo $?) -eq 0 ]];then
  # Configure k8s prometheus scraper
  if [[ -n ${KUBEAPI_INGRESS_IP} && -n ${K8S_PASSWD} ]];then
    printf "\e[2G - Configuring k8s prometheus scraper"
    juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} prometheus \
      scrape-jobs=$(sed 's/K8S_PASSWORD/'"${K8S_PASSWD}"'/g;s/K8S_API_ENDPOINT/'"${KUBEAPI_INGRESS_IP}"'/g' ${DEMO_DIR}/lma/prometheus-scrape-k8s.yaml) &>> ${LOG};tstatus
  fi
fi

if [[ $(check-juju-app grafana;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring grafana dashboards"
  # Setup grafana dashboards
  printf "\e[2G - Configuring grafana dashboard \"grafana-telegraf\""
  juju 2>/dev/null run-action -m ${CONTROLLER}:${CDK_MODEL} --wait grafana/0 import-dashboard dashboard="$(base64 ${DEMO_DIR}/lma/grafana-telegraf.json)" &>> ${LOG};tstatus
  printf "\e[2G - Configuring grafana dashboard \"grafana-k8s\""
  juju 2>/dev/null run-action -m ${CONTROLLER}:${CDK_MODEL} --wait grafana/0 import-dashboard dashboard="$(base64 ${DEMO_DIR}/lma/grafana-k8s.json)" &>> ${LOG};tstatus
fi

if [[ $(check-juju-app filebeat;echo $?) -eq 0 ]];then
  # Setup Filebeat to use graylog as a logstash host.
  if [[ -n ${GRAYLOG_INGRESS_IP} ]];then
    printf "\e[2G - Configuring filebeat to use graylog"
    juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} filebeat logstash_hosts="${GRAYLOG_INGRESS_IP}:5044" &>> ${LOG};tstatus
  fi
fi

if [[ $(check-juju-app apache2;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring graylog's reverse proxy server"
  # Graylog needs a rev proxy and ES cluster name.
  juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} apache2 vhost_http_template="$(base64 ${DEMO_DIR}/lma/graylog-vhost.tmpl)" &>> ${LOG};tstatus
fi
 
if [[ $(check-juju-app graylog;echo $?) -eq 0 ]];then
  printf "\e[2G - Configuring graylog's elasticsearch cluster name"
  [[ -n ${ES_CLUSTER_NAME} ]] && { printf "\e[2G - Configuring graylog's elasticsearch cluster name";juju 2>/dev/null config -m ${CONTROLLER}:${CDK_MODEL} graylog elasticsearch_cluster_name="${ES_CLUSTER_NAME}" &>> ${LOG};tstatus; }
fi


# Display URLs and Credentials for LMA Stack
#printf "\e[4G\e[1mNagios\n══════\n\e[0m\e[6G\e[1mUser:\e[0m ${NAGIOS_USER}\n\e[6G\e[1mPassword:\e[0m ${NAGIOS_PASS}\n\e[6G\e[1mURL:\e[0m ${NAGIOS_URL}\n\n"
#printf "\e[4G\e[1mGrafana\n═══════\n\e[0m\e[6G\e[1mUser:\e[0m ${GRAFANA_USER}\n\e[6G\e[1mPassword:\e[0m ${GRAFANA_PASS}\n\e[6G\e[1mURL:\e[0m ${GRAFANA_URL}\n\n"
#printf "\e[4G\e[1mGraylog\n═══════\n\e[0m\e[6G\e[1mUser:\e[0m ${GRAYLOG_USER}\n\e[6G\e[1mPassword:\e[0m ${GRAYLOG_PASS}\n\e[6G\e[1mURL:\e[0m ${GRAYLOG_URL}\n\n"
#printf "\e[6GNOTE: Graylog configuration may still be in progress. It may take up to 5 minutes for\nthe web interface to become ready.\n"


printf "\n\e[1GDeployment of CDK finished in $(duration ${CTIME})\e[0m\n\n"
sleep 5


# Set the start time for our k8s cloud
export KTIME=$(date +%s)

banner -c -t "juju|k8s" -m " CDK & k8s Cloud Demo Part II "
printf "\n\e[2GCreating a k8s cloud\n\n"
# Add a "Kubernetes" cloud under the controller that we used to deploy CDK
# Don't change the names here
printf "\e[2G - Adding k8s substrate \"${K8S_CLOUD}\" juju controller ${CONTROLLER}"
juju add-k8s ${K8S_CLOUD} --cloud ${CLOUD} --controller=${CONTROLLER} --cluster-name juju-cluster --storage=${CLOUD} &>> ${LOG};tstatus;

# Create a model on our new k8s cloud
printf "\e[2G - Adding k8s model \"${K8S_MODEL}\" to  \"${K8S_CLOUD}\""
juju add-model -c ${CONTROLLER} ${K8S_MODEL} ${K8S_CLOUD} &>> ${LOG};tstatus;

# Configure persistent Volumes
# Note: storageClassName must be prefaced by
#       you just added to the k8s cloud
#       (NOT the model name where CDK is deploy)

printf "\n\e[2Gonfiguring model-specific persistent storage for \"${K8S_MODEL}\"\n"

printf "\e[2G - Creating k8s persistent volumes (pv) for operator-storage in k8s model \"${K8S_MODEL}\"\n\e[6G - Purpose: k8s cluster internal/undercloud storage requirements\n\e[6G - Name: \"op1\"\n\e[6G - Size: 1032MiB\n\e[6G - storageClassName: \"${K8S_MODEL}-juju-operator-storage\"\n"

KUBECONFIG=${KUBECONFIG} kubectl &>> ${LOG} create -f - <<EOF
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

printf "\e[2G - Creating k8s pv workload storage in k8s model \"${K8S_MODEL}\"\n\e[6G - Purpose: application storage requirements\n\e[6G - Name: \"vol1\"\n\e[6G - Size: 100MiB\n\e[6G - storageClassName: \"${K8S_MODEL}-juju-unit-storage\"\n"
KUBECONFIG=${KUBECONFIG} kubectl &>> ${LOG} create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vol1
spec:
  capacity:
    storage: 100Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${K8S_MODEL}-juju-unit-storage
  hostPath:
    path: "/mnt/data/vol1"
EOF

printf "\e[2G - Creating k8s pv for workload storage in k8s model \"${K8S_MODEL}\"\n\e[6G - Purpose: application storage requirements\n\e[6G - Name: \"vol2\"\n\e[6G - Size: 100MiB\n\e[6G - storageClassName: \"${K8S_MODEL}-juju-unit-storage\"\n"
KUBECONFIG=${KUBECONFIG} kubectl &>> ${LOG} create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vol2
spec:
  capacity:
    storage: 100Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${K8S_MODEL}-juju-unit-storage
  hostPath:
    path: "/mnt/data/vol2"
EOF

printf "\n\e[2GCreating Juju Storage Pools\n"
printf "\e[2G - Creating operator storage-pool \"operator-storage\""

# Create operator storage pool
# Note: must be called operator-storage
juju create-storage-pool operator-storage kubernetes \
    storage-class=juju-operator-storage \
    storage-provisioner=kubernetes.io/no-provisioner &>> ${LOG};tstatus;


printf "\e[2G - Creating application storage-pool \"${K8S_POOL}\""

# Create application storage pool
# Note: pool name should match the model name
#       you just added to the k8s cloud
#       (NOT the model name where CDK is deploy)
juju create-storage-pool ${K8S_POOL} kubernetes \
    storage-class=juju-unit-storage \
    storage-provisioner=kubernetes.io/no-provisioner &>> ${LOG};tstatus;

# Note: You cannot expose a CAAS application without a "juju-external-hostname"
#      value set, run juju config <caas-app> juju-external-hostname=<value> 

# Get IP address of k8s-worker which will be used for public ingress
export KWPI=$(juju 2>/dev/null run -m ${CONTROLLER}:${CDK_MODEL} --unit kubernetes-worker/1 'unit-get public-address')



#printf "\e[2GPreparing k8s bundle\n\e[2G - Name: ${K8S_BUNDLE}\n\e[2G - Location: ${DEMO_DIR}/yaml/${CLOUD}/\n"

# Deploy applications into CDK cluster using a k8s bundle
# Note: k8s bundles differs from a standard bundle in the following ways:
# - "bundle:" key is given the value of kubernetes
# - "series:" key is given the value of kubernetes
# - "num_units:" is replaced by key "scale:"
# - "to:" is replaced by key placement: 
# - Can only expose a CAAS application if "juju-external-hostname" is set
cat <<EOF> ${DEMO_DIR}/yaml/${CLOUD}/${K8S_BUNDLE}
bundle: kubernetes
applications:
  mariadb-k8s:
    charm: cs:~juju/mariadb-k8s
    scale: 1
    constraints: mem=2G
    storage:
      database: gitlab-pool,20M
  gitlab-k8s:
    charm: cs:~juju/gitlab-k8s
    options:
      juju-external-hostname: ${KWPI}.xip.io
      external_url: ${KWPI}.xip.io  
    expose: true
    scale: 1
relations:
  - [ 'gitlab-k8s:mysql', 'mariadb-k8s:server' ]
EOF

# Deploy the k8s bundle (RFE for juju to accept bundles from stdin?)
printf "\e[2G - Deploying ${K8S_BUNDLE} into ${K8S_CLOUD}:${K8S_MODEL}"
juju deploy -m ${CONTROLLER}:${K8S_MODEL} ${DEMO_DIR}/yaml/${CLOUD}/${K8S_BUNDLE} &>> ${LOG};tstatus;

# CLI version of the above bundle
#printf "\e[2G - Deploying gitlab-k8s charm into ${K8S_CLOUD}:${K8S_MODEL}"
#juju deploy -m ${CONTROLLER}:${K8S_MODEL} cs:~juju/gitlab-k8s --scale=1 &>> ${LOG};tstatus;
#printf "\e[2G - Deploying mariadb-k8s charm into ${K8S_CLOUD}:${K8S_MODEL}"
#juju deploy -m ${CONTROLLER}:${K8S_MODEL} cs:~juju/mariadb-k8s --storage database=${K8S_MODEL},20M --scale=2 &>> ${LOG};tstatus;
#printf "\e[2G - Relating gitab to mariadb-k8s"
#juju relate -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s mariadb-k8s &>> ${LOG};tstatus;
#printf "\e[2G - Setting externally reachable hostname for gitlab service via xip.io DNS service"
#juju 2>/dev/null config -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s juju-external-hostname=${KWPI}.xip.io external_url=${KWPI}.xip.io &>> ${LOG};tstatus;
#printf "\e[2G - Exposing service gitlab-k8s"
#juju expose -m ${CONTROLLER}:${K8S_MODEL} gitlab-k8s &>> ${LOG};tstatus;

# Fix 1MB upload limit on nginx ingress
printf "\e[2G - Fixing 1MB upload limit ${K8S_MODEL} namespace ingress"
KUBECONFIG=${KUBECONFIG} kubectl get ingress -n ${K8S_MODEL} -o yaml > ${K8S_MODEL}-ingress.yaml
sed '/    annotations:/a \ \ \ \ \ \ nginx.ingress.kubernetes.io/proxy-body-size: "0"' -i ${K8S_MODEL}-ingress.yaml  
KUBECONFIG=${KUBECONFIG} kubectl replace -f ${K8S_MODEL}-ingress.yaml -n ${K8S_MODEL} &>> ${LOG};tstatus;

printf "\e[1GDeployment of Kubernete Cloud \"${K8S_CLOUD}\" finished in $(duration ${KTIME})\e[0m\n\n"
sleep 3

banner -t "Canonical|k8s" -c -m " Total Deployment time: $(duration ${CTIME}) "

read -p 'Press enter to continue' CONT

# Restore the screen contents and settings
printf '%s\n' sgr0 rmcup smam cnorm|tput -S -;[[ -n ${FUNCNAME} ]] && return 0;trap - INT TERM EXIT
