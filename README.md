
# Juju Container As A Service (CAAS) Demo - Featuring GitLab

###Pre-Reqs
* AWS EC2 Account
* Ubuntu 18.04 LTS (Bionic)
    * 18.04 LTS (Bionic)
* Juju
    * > v.2.5.0
* Charm Tool
    * > v.2.5.1
* jq
    * > v.2.5.0
* gawk


#### Update Juju's Cloud Information
juju update-public-clouds
#### Update/Add AWS Credentials
##### Gather AWS Credentials

> If you do not know your AWS access credentials, please review the
> section titled **Gathering credential information** in the [Juju
> documentation for AWS](https://docs.jujucharms.com/aws-cloud)

##### Specify AWS Credentials 

> Run the following from a terminal

    export AWS_ACCESS_KEY_ID='AAAAAAAAAAAAAAAAAAAA'
    export AWS_SECRET_ACCESS_KEY='SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS'
    juju autoload-credentials

#### Bootstrap Juju Controller
> Using the same terminal used to export AWS credentials, run the following to bootstrap a Juju Controller on AWS

    juju bootstrap aws/us-west-1 aws-juju-controller --bootstrap-series=bionic --debug --show-log

#### Deploy CDK Bundle to AWS

     juju deploy \
    	/srv/yaml/cdk-aws/new-fkb-aws.yaml \
    	--overlay /srv/yaml/cdk-aws/new-fkb-aws-integrator-overlay.yaml \
    	--overlay /srv/yaml/cdk-aws/new-fkb-aws-e2e-overlay.yaml
#### Trust aws-integrator charm   

> This allows the aws-integrator charm to have access to your AWS
> credentials when setting up storages, services, etc

     juju trust aws-integrator

#### Setup kubectl
     juju scp kubernetes-master/0:config ~/.kube/config
     sudo snap install kubectl --classic
     juju config kubernetes-master enable-dashboard-addons=true
     kubectl proxy &
     kubectl cluster-info

#### Access k8s Dashboard

> Once the kubectl proxy is running, you may access the k8s dashboard @
> http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!/login

##### Smoke test (optional)

    juju run-action kubernetes-worker/0 microbot replicas=5 --wait
    kubectl get pods
    kubectl get services,endpoints
    kubectl get ingress
    juju run-action kubernetes-worker/0 microbot delete=true --wait
    kubectl get pods

## Add k8s substrate to Juju
$ KUBECONFIG=~/.kube/config juju add-k8s \ 
  --cloud aws \ 
  --region=us-west-1 \ 
  --controller=aws-juju-controller \ 
  --cluster-name juju-cluster \ 
  --storage=default \
  cdk8s-aws

### Add CAAS Model to k8s substrate

> *Note: when adding CAAS models, you must give model-name then the name of the cloud (via juju clouds) where CDK is deployed*

     juju add-model gitlab-caas cdk8s-aws

##### Create Storage Pools for Model
> *Note: Juju storage is unique per model*

    juju create-storage-pool operator-storage kubernetes storage-class=juju-operator-storage storage-provisioner=kubernetes.io/aws-ebs
    juju create-storage-pool charm-storage kubernetes storage-class=juju-unit-storage storage-provisioner=kubernetes.io/aws-ebs

##### Deploy CAAS Charms to CAAS model

    juju deploy cs:~juju/gitlab-k8s
    juju deploy cs:~juju/mariadb-k8s --storage database=charm-storage,100M
    juju relate gitlab-k8s mariadb-k8s

##### Allow CAAS App to be accessed externally

 1. Get public IP of k8s worker from CDK model
 2. Set juju-external-hostname for gitlab-k8s container to  {IP of k8s-worker}.xip.io

> Note: *If kubernetes-worker/0 has a public IP of 54.193.41.116, then
> juju-external-hostname will be 54.193.41.116.xip.io*

 3. Expose CAAS App
######
    export KWPI=$(juju run -m cdk8s --unit kubernetes-worker/0 'unit-get public-address')
    juju config gitlab-k8s juju-external-hostname=\${KWPI}.xip.io
    juju expose gitlab-k8s

##### Tune ingress Settings
>*The k8s ingress module uses nginx. By default, it has the option `proxy-body-size` to `1m`. Since this demo uses gitlab, this limite will be a problem if a any file larger than 1m is uploaded. To solve it, we only have to add an annotation to the ingress*

    kubectl -n gitlab-k8s edit ingress

> The preceding command will launch an editor so you can add the following to annotations
> section:

    nginx.ingress.kubernetes.io/proxy-body-size: "0"

## Access CAAS App (gitlab)

> You now should be able to get to the application via the following
> URL: http://{k8s-worker-public-IP}.xio.io

**Example:**
*If kubernetes-worker/0 has a public IP of 54.193.41.116, then the URL to access the application will be:* [http://54.193.42.116.xip.io](http://54.193.42.116.xip.io/)


